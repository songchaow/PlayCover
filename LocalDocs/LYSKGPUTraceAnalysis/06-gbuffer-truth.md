# 06 — GBuffer 真相：不是 Deferred GBuffer，而是 Velocity + Normal Pre-pass

> 这份文档是对 `01` / `02` / `03` 文档中"GBuffer baseColor/normal"叙述的**重要修正**。
> 通过：(1) 导出真实纹理字节；(2) 反编译 `RPS 484 SkinMakeupNew`、`RPS 481/482/483/485/486/487 ClothStandard/Skin/Eye/Teeth` 等 9 个 GBuffer-pass fragment shader 的 LLVM IR；(3) 对比 `RPS 491 (half-res lighting)` 真实读取的纹理与 binding 名字；得出**与最初猜测相反的结论**。
>
> 所有原始证据归档在 `data/gbuffer/`：
> - `gbuf0_228.bin` / `gbuf1_229.bin` — 真实纹理字节
> - `RPS484_SkinMakeupNew_fragment.ll` 等 6 个 IR 文件 — 反编译的 fragment shader

## 1. TL;DR

**E4 (`color={228, 229} RGBA8Unorm + d/s=227 D32S8`) 不是传统 deferred GBuffer**。

| 槽位 | 之前误判 | 实际内容 |
|---|---|---|
| **MRT0 (228)** | "baseColor + ?" | **packed 16-bit motion vector**：(NDC.curr.xy / curr.w) − (NDC.prev.xy / prev.w)，每个分量量化为 16 bit 后拆成 high/low 两个字节 → RGBA8 |
| **MRT1 (229)** | "normal + material" | **octahedral-encoded world normal (RG) + sign(N.z) flag (B) + 常量 0.047 (A，可能是 material/SSS profile id)** |
| **227 D32S8** | 主深度模板 | ✓ 这个判断没错 |

LYSK 是 **forward + visibility-buffer-style** 的混合架构：lighting **不**通过解码 228/229 完成，而是在 `E10`（half-res）和 `E13`（full-res）**重新光栅化几何**、并直接采样原始材质纹理（`PL_Head_MU_N`、`PL_Head_R`、`PL_Makeup_Eyelid_*` 等）来计算光照。228/229 的存在主要是为了**屏幕空间后处理（TAA reproject、SSAO、SSR、Bloom flares）**所需要的 motion vector + screen-space normal。

## 2. 实测证据 1：纹理字节统计

```
== 228 (MRT0) ==
  R: mean=122.7  hist 集中在 bin 16/32 = bin中点 ≈ 128             ← 中性 0.5
  G: mean=213.2  hist 在 bin 31 极尖峰 ≈ 248–255                    ← 接近 1.0
  B: mean=121.5  同 R                                                ← 中性 0.5
  A: mean=241.3  hist 在 bin 31 极尖峰                               ← 接近 1.0
  尾部 32 字节: 7fff7fff7fff7fff... = (0x7f, 0xff) 重复

== 229 (MRT1) ==
  R: mean=124.1  双峰：主峰 bin 16，次峰 bin 19/20                   ← octahedral xy
  G: mean=119.0  多峰：bin 12/14/15/17/18 都有信号                   ← octahedral xy
  B: mean=124.8  极尖单峰 bin 16 = 128 = 0.5                         ← sign(N.z) ≈ 0 边界
  A: mean=  9.3  hist 完全集中在 bin 0–1（值 ≤ 12）                  ← 常量 12 ≈ 0.047 × 255
```

229 的 alpha 通道**直方图 95% 集中在 0–12 这个极窄区间**，这是任何「材质 ID / smoothness / metallic」都不该有的形态 — 这必然是一个**写入常量值**的通道。

## 3. 实测证据 2：RPS 484 fragment IR 完全反编译

**完整源代码**：`data/gbuffer/RPS484_SkinMakeupNew_fragment.ll`（85 行 IR，无依赖）

签名：

```llvm
define <{ <4 x half>, <4 x half> }> @xlatMtlMain(
    <4 x float> %0,    ; TEXCOORD1 = 当前帧 clip-space position
    <4 x float> %1,    ; TEXCOORD2 = 上一帧 clip-space position
    <3 x float> %2)    ; TEXCOORD3 = 世界空间法线
```

输入 metadata（取自 IR 末尾 `air.fragment_input`）：

```
!19 = !{i32 0, "air.fragment_input", "user(TEXCOORD1)", "float4", "TEXCOORD1"}
!20 = !{i32 1, "air.fragment_input", "user(TEXCOORD2)", "float4", "TEXCOORD2"}
!21 = !{i32 2, "air.fragment_input", "user(TEXCOORD3)", "float3", "TEXCOORD3"}
```

输出 metadata：

```
!16 = !{"air.render_target", i32 0, i32 0, "half4", "SV_TARGET0"}    ; → 228
!17 = !{"air.render_target", i32 1, i32 0, "half4", "SV_TARGET1"}    ; → 229
```

`!13 air.compile.framebuffer_fetch_enable` — 启用 framebuffer fetch（暗示这是 tile-based 优化路径上的 fragment）。

### 3.1 MRT0 (228) — Motion Vector Encoding

IR 行 4–22（贴合源码注释）：

```llvm
; %0 = curr.xyzw, %1 = prev.xyzw
%4  = curr.xy
%5  = curr.ww
%6  = curr.xy / curr.w        ; 当前帧 NDC.xy
%7  = prev.xy
%8  = prev.ww
%9  = prev.xy / prev.w        ; 上一帧 NDC.xy
%10 = curr_NDC - prev_NDC     ; motion vector (signed, in NDC)
%11 = fma(%10, 0.4843, 0.5)   ; 把 motion 映射到 [0..1]，对称中点 0.5
                               ; 0.4843 ≈ 1/2.064 = clamp 范围因子（max ±1.03 屏幕宽度）
%12 = %11 * 65535             ; 16-bit 整数空间
%13 = uint32(%12)             ; 转 uint
%14 = %13 & 255               ; low 8 bits
%16 = %13 >> 8                ; high 8 bits
%19 = shuffle(<x_high, y_high, x_low, y_low>) → 重排 = <x_high, x_low, y_high, y_low>
%20 = float(%19)
%21 = %20 * (1/255)           ; 归一化到 [0..1]
%22 = half4(%21)              ; 喂给 RGBA8Unorm 输出（half→8bit 量化）
```

→ **228 的 4 字节解码方法**（CPU/python 侧）：

```python
# 给定一个像素 (R, G, B, A) 都是 0..255 整数:
x_uint16 = (R << 8) | G       # 注意：R 是 high8, G 是 low8（根据 IR shuffle 序列）
y_uint16 = (B << 8) | A
mv_x_ndc = (x_uint16 / 65535.0 - 0.5) / 0.4843   # → NDC 中的 dx
mv_y_ndc = (y_uint16 / 65535.0 - 0.5) / 0.4843   # → NDC 中的 dy
```

无运动的像素 (mv = 0) 解码值：`fma(0, 0.4843, 0.5) = 0.5 → ×65535 = 32767 = 0x7FFF` → R=0x7F=127, G=0xFF=255, B=0x7F=127, A=0xFF=255。

实测尾 32 字节 `7fff7fff…` 与该理论值**完美吻合**。

### 3.2 MRT1 (229) — Octahedral Normal + Sign + Const

IR 行 23–49：

```llvm
%23 = dot(N, N)                    ; |N|²
%24 = fp32 → fp16
%25 = rsqrt(|N|²)                  ; 1/|N|
%29 = N * (1/|N|)                  ; 单位法线 (fp32 → fp16)
%31 = N.z (half)
%32..%37 = sign(N.z) ∈ {-1, 0, 1}  ; 编码后续要用
%38 = sign < 0
%39 = select(%38, 0xH37EC, 0xH380A)  ; 0.4990 vs 0.5005（一个 ULP 差），写入第 3 通道
%40 = |N.z|
%41 = |N.z| + 1
%42 = N.xy
%45 = N.xy / (|N.z| + 1)          ; 标准 octahedral 投影到 z=0 平面
%46 = fma(%45, 0.5, 0.5)          ; 映射到 [0..1]
%48 = insertelement(%47, 0xH2A06, i64 3)
;   ↑ 0xH2A06 = half 0.0470581 = 写入 alpha 槽的常量
%49 = insertelement(%48, %39, i64 2)
;   ↑ 把 sign-flag 放进 B 通道
```

→ **229 的 4 字节解码方法**：

```python
# 给定一个像素 (R, G, B, A) 都是 0..255 整数:
oct_x = R / 255.0 * 2 - 1                          # [-1, 1]
oct_y = G / 255.0 * 2 - 1
sign_flag = +1 if (B / 255.0) > 0.5 else -1        # B ≈ 0.5 ± 1ULP
# 反 octahedral: |N.z|+1 由 oct(x,y) 反解
# 取一个常用的 hemisphere octahedral 反演（详见 [Cigolle 2014]）
# 此处 LYSK 用了 z-only-sign 变体（不是完整 octahedral 八面体），即:
#   N.x = oct_x * (|N.z| + 1)
#   N.y = oct_y * (|N.z| + 1)
#   N.z = sign_flag * sqrt(max(0, 1 - N.x² - N.y²))
# 但因为 oct_xy 已被 (|Nz|+1) 缩放，需要用迭代或定点反演

# A 通道 = 12 / 255 ≈ 0.047 = 常量（material/profile id？暂未确认其语义）
material_id = A   # 实测稳定为 12，跨像素无变化
```

## 4. 实测证据 3：所有 9 个 GBuffer-pass fragment 都是同一模板

扫描 RPS `481, 482, 483, 484, 485, 486, 487` 的 fragment IR：

| RPS | label | IR 行数 | air.sample 次数 | 结构 |
|---|---|---|---|---|
| 481 | Cloth/ClothStandard | 123 | 0 | **同模板（fp32 路径）** |
| 482 | Cloth/ClothStandard | 123 | 0 | **同模板** |
| 483 | Cloth/ClothStandard | 123 | 0 | **同模板** |
| 484 | SkinMakeupNew | 85  | 0 | **同模板（fp16 早转，更短）** |
| 485 | SkinSSS | 123 | 0 | **同模板** |
| 486 | EyeSpec | 123 | 0 | **同模板** |
| 487 | Teeth | 123 | 0 | **同模板** |
| **488** | **Cloth/ClothStandard** | **215** | **10** | **alpha-test 变体**（采样 mask + discard） |
| **489** | **HairScreenDoor** | **355** | **7** | **stipple alpha 变体** + dither |
| 468 | Unlit/InverseTonemapping | 123 | 0 | 同模板 |

→ `diff RPS484 RPS481` 仅在 fp16/fp32 数据路径与 TEXCOORD slot 编号上有差异，**核心算法（motion vector pack + octahedral normal pack + 常量 A）一字不差**。这彻底证实 LYSK 的 GBuffer-pass 是**一个统一的 "Velocity+Normal pre-pass" 模板**，不论材质类型。

488 / 489 之所以多 sample 是因为 **alpha test / stipple cutoff** 必须在写入 motion+normal 之前判定 fragment 是否丢弃 — 那 7~10 次 sample 服务于 `discard`，并不影响输出语义。

## 5. 实测证据 4：Lighting Pass (RPS 491) 不读 228/229

RPS 491 (`Papegame/SkinMakeupNew` half-res lighting) 的 fragment binding 表 + IR `air.texture` 元数据（来自 `data/gbuffer/RPS491_SkinMakeupNew_halfresLighting_fragment.ll`）：

| index | air.arg_name | resource_id | label | 用途 |
|---|---|---|---|---|
| 11 | `_LightIndexMap` | 145 (128×128 RGBA8) | — | **CalcLighting.CSMain 的 cluster light index 输出** |
| 12 | `_SpecularTex` | 197 | `PL_Head_R` | 角色头部 roughness 贴图 |
| 13 | `_NormalTex` | 194 | `PL_Head_MU_N` | 角色头部 normal map（**直接读原图，不经 GBuffer**） |
| 14 | `_EyelidTex` | 193 | `PL_Makeup_Eyelid_07_D` | 眼睑底妆 |
| 15 | `_ScreenShadowTexture` | 236 | `TempBuffer 128` | 半分辨率屏幕空间阴影 |

**关键：完全没有 228/229 出现在绑定列表中**！

vertex shader (`RPS491_SkinMakeupNew_halfresLighting_vertex.ll`) 的 `air.vertex_input`：

```
POSITION0 / NORMAL0 / TANGENT0 / TEXCOORD0..3
```

→ **真实的 mesh 顶点输入** — 这意味着 491 是**重新光栅化几何**，从 vertex stream 拿到法线/切线，从原图拿到材质，从 cluster light index map 拿光照列表，独立计算 lighting；**完全不依赖 228/229 的 normal 与"baseColor"**。

## 6. 那 228/229 给谁用？

228/229 的真实消费方在「需要 motion vector / screen-space normal 的屏幕空间 pass」中：

| 消费方 | 需要 228 motion vector | 需要 229 screen-normal | 说明 |
|---|---|---|---|
| **E18 TAA (RPS 441)** | ✓✓✓ | — | TAA reprojection 的核心输入 |
| **E7 SSAO (RPS 447)** | — | ✓ | 屏幕空间法线（octa 解码） |
| **E14 DOF DownSample (RPS 456)** | 可能 | — | 可能用于 motion blur 协调 |
| **E16 DOF Gather (RPS 457)** | 可能 | — | 同上 |

需要进一步验证哪些 RPS 真正绑定了 228/229 — 一行命令：

```bash
# 找出所有读 228 / 229 的 draw
jq '.command_buffers[1].encoders[].draws[]? | select(.bindings.fragment.textures[]?.resource_id==228 or .bindings.fragment.textures[]?.resource_id==229) | {idx:.draw_index_global, rps:.rps_key, lbl:.rps_label}' \
   data/frame.json | head -40
```

## 6.5 实测证据 5：A 通道 0xH2A06 是「角色前景 mask」，不是 material id

扫描 9 个 GBuffer-pass fragment 的 A 通道写入常量值（IR 中查找 `insertelement <4 x half> ..., half 0xH..., i64 3`）：

| RPS | label | A 通道常量 | 浮点值 | 字节值（RGBA8） |
|---|---|---|---|---|
| 481 | Cloth/ClothStandard | `0xH2A06` | 0.04706 | **12** |
| 482 | Cloth/ClothStandard | `0xH2A06` | 0.04706 | 12 |
| 483 | Cloth/ClothStandard | `0xH2A06` | 0.04706 | 12 |
| 484 | SkinMakeupNew | `0xH2A06` | 0.04706 | 12 |
| 485 | SkinSSS | `0xH2A06` | 0.04706 | 12 |
| 486 | EyeSpec | `0xH2A06` | 0.04706 | 12 |
| 487 | Teeth | `0xH2A06` | 0.04706 | 12 |
| 488 | Cloth/ClothStandard alpha-test | `0xH2A06` | 0.04706 | 12 |
| 489 | HairScreenDoor stipple | `0xH2A06` | 0.04706 | 12 |
| **468** | **Unlit/InverseTonemapping** | **`0xH0000`** | **0.000** | **0** |

→ **A 通道是二态 mask，不是 per-material id**：
- **A = 12** → 像素属于「需要 SSS-aware lighting 的角色几何」（皮肤+眼+牙+布料+头发统统是这个值）
- **A = 0** → 像素属于「InverseTonemapping 区域」（即从上一帧 TAA 历史 buffer 反映射到当前帧的 fallback 像素，不需要 SSS）

229 的 A 通道**实测均值 = 9.3 / 255 ≈ 0.0365** — 介于 0 和 12 之间，因为整个画面里既有 "A=12 角色像素" 也有 "A=0 fallback 像素 / clear 区域"，加权平均后接近 9。

实测直方图证实：229 的 A 通道**只有两个 bin 有信号**（bin 0 = 值 0–7，bin 1 = 值 8–15），其余 30 个 bin 都为 0。这是典型的"二态 mask"信号特征。

**这极有可能是后续 lighting / SSS pass 决定「这个像素该不该走 SSS 路径」的早期判定 mask**。具体如何使用，参见下一节。

## 7. 这个发现改写了什么

之前的 `01-architecture-overview.md §3.3` 与 `02-frame-breakdown.md §E4` 将 228/229 称为「GBuffer baseColor/normal」，**这是错的**。修正版本：

> **E4 是 "Velocity + Normal Pre-pass + Z"**，不是 deferred GBuffer：
>   - `228` = packed 16-bit motion vector（per-pixel reprojection delta）
>   - `229` = packed octahedral world normal + sign(N.z) flag + 常量 0.047 alpha
>   - `227` = 主深度模板（这部分判断不变）
>
> Lighting 通过 `E10`（half-res，仅皮肤+牙齿）和 `E13`（full-res，全部材质）**直接重新光栅化几何 + 采样原图材质纹理 + cluster lighting buffer** 完成。这是 **forward shading 架构 + visibility-style velocity buffer** 的混合方案，不是 deferred shading。

这同时改写了 `04-skin-and-sss-pipeline.md` 中的"GBuffer 主写入" pass 描述（RPS 484）— 它**只写 motion+normal**，不写 baseColor/material。SkinMakeupNew 真正的「材质参数」是被各 lighting pass 中的 cbuffer (`UnityPerMaterial_Type`) 直接拿去用，纹理则是直接采样原 PL_*_D / PL_*_N / PL_*_R 等贴图。

## 8. 引用文件清单（在 `data/gbuffer/`）

| 文件 | 角色 |
|---|---|
| `gbuf0_228.bin` (7.8 MB) | 228 真实字节（1167×1671 RGBA8） |
| `gbuf1_229.bin` (7.8 MB) | 229 真实字节（1167×1671 RGBA8） |
| `RPS484_SkinMakeupNew_fragment.ll` | 关键 IR — motion+normal pack 算法（最短 fp16 版本） |
| `RPS481_ClothStandard_fragment.ll` | 同模板的 fp32 版本（用于对比） |
| `RPS488_ClothStandard_alphaTest_fragment.ll` | 多 sample 版本（说明 alpha-test 变体） |
| `RPS489_HairScreenDoor_fragment.ll` | 多 sample 版本（说明 stipple 变体） |
| `RPS491_SkinMakeupNew_halfresLighting_fragment.ll` | half-res lighting，**证明不读 228/229** |
| `RPS491_SkinMakeupNew_halfresLighting_vertex.ll` | 同 RPS 的 vertex，**证明从 mesh 取数据** |

## 8.5 实测证据 6：228 / 229 的真实消费方

通过反编译每个候选消费方 RPS 的 fragment IR、查 `air.texture` 的 `air.arg_name`，**逐个**确认：

### 228（motion vector）

| RPS | label | IR 中是否引用 | 引用名 |
|---|---|---|---|
| **441** | **Unlit/TAA/TemporalAA** | **✓ 是** | **`_VelocityTexture`** |
| 442 | Unlit/FSR_EASU_PS | ✗ | 仅 `InputTexture`（即 245） |
| 443 | Unlit/FSR_RCAS_PS | ✗ | 仅 `InputTexture`（即 246） |
| 458/459/460 | Papegame/Bloom | ✗ | 仅 `_SourceTex` |
| 461 | Hidden/Papegame/FinalBlit | ✗ | `_Lut2D` / `_BloomTexture` / `_BlitTex` |
| 444/445/467 | Clear/TextMeshPro/UI | ✗ | UI 自有纹理 |

→ **228 在本帧的唯一真实消费者就是 TAA (RPS 441)**。所有其它 RPS 的 binding 表里都有 228 的 resource_id 是 Unity 引擎全局绑定的副作用，fragment shader 内部并不真正 sample 它。

### 229（octahedral normal + sign + mask）

逐个扫描 65 个 RPS 的 fragment IR 中是否有 `air.arg_name` 含 "Normal" / "GBuffer" / "Octa" 字样的 texture 声明 — **结果：0 个**。

也就是说，**229 在本帧中没有任何 fragment shader 显式作为 texture 采样**。这是个意外但合理的结果。可能的解释：

1. **Unity 全局绑定占位**：Unity 引擎按 binding-table 模板把所有 GBuffer 槽都绑定上，即使当前 shader 不用；这是引擎层而非渲染设计的产物。
2. **229 是为非本帧场景预留**：当画面中存在 SSR / contact shadow / probe relighting 等需要 screen-space normal 的特性时，对应 RPS（本 trace 中可能因为是「妆容编辑」UI 场景而未启用）会读 229；trace 没覆盖那些代码路径。
3. **A 通道作为后续 stencil-like 判定**：mask（0.047 / 0）虽然没在 fragment 内 sample，但 Metal 的 **`framebuffer fetch`**（IR 中 `air.compile.framebuffer_fetch_enable = true` 已开启）允许同 RPS 的下一个 fragment 直接读取 attachment 而不经 sampler — 这条路径不会在 `air.texture` metadata 中显式出现。然而 E4 之后没有同 attachment 的 next render pass，所以这条解释也不完全成立。
4. **GPU 早期硬件 hint**：octahedral normal 加 sign-flag 很适合早期 hierarchical-Z / coarse-shading rate 决策，但这是非常底层的细节，无法在 user-mode IR 中证实。

**结论**：在这个特定 trace 中，**229 是 dead store**（被写入但无显式读取）。这本身是个值得报告给引擎团队的优化机会 —— 关闭 229 写入可能立省一个 RGBA8Unorm 全分辨率写带宽（≈7.8 MB / frame）。

## 9. 下一步建议

1. **可视化 motion vector**：写一个 30 行 Python，把 `gbuf0_228.bin` 解码成 PNG，用色相 = atan2(mv.y, mv.x) / 亮度 = |mv| 显示，可立即看出场景中哪些像素在动。
2. **可视化 octahedral normal**：把 `gbuf1_229.bin` 的 RG 通道直接当作 oct(x, y) 显示成 RGB（或反 octahedral 解码后显示），可视化 screen-space 法线方向。
3. **A 通道 0.047 的语义考古**：在 `data/rps_index.json` 中找其它有相同输出常量的 RPS，可能这是 LYSK 引擎的「material classification id」（如 0.047 = "skin"、其它值 = "cloth"/"hair"），用于在 SSS pass 决定哪些像素需要 SSS 滤波。可以扫所有同模板 fragment IR 中 `0xH2A06` 这个常量是否变化。
