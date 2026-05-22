# 01 — 架构总览

## 1. 双缓冲布局：4 个 CommandBuffer 的角色

`frame-list` 的 4 个 CB 按时间顺序：

| CB | calls | encoder | 角色 |
|---|---|---|---|
| **CB0** | 1（call 16） | 1 × blit | **frame N-1 收尾 blit** — 把上一帧 history texture 推进 / present helper |
| **CB1** | 117–1663 | 1 compute + 28 render + 1 blit = 30 | **frame N 主工作**（122 draws） |
| **CB2** | 1（call 1722） | 1 × blit | **frame N 收尾 blit** — 同 CB0 |
| **CB3** | 1823–3369 | 1 compute + 28 render + 1 blit = 30 | **frame N+1 主工作**（122 draws） |

**CB1 与 CB3 完全镜像**：encoder 数、类型顺序、draws 数、RPS 集合一一对应；唯二差异是

1. **TAA 历史 ping-pong**：CB1 写入 `239 CameraColor2_0`、读出 `247 LastFrameTexture0`；CB3 反过来。
2. **Swapchain drawable**：CB1 写 `147 CAMetalLayer Display Drawable`、CB3 写 `160 CAMetalLayer Display Drawable`。

→ 因此**整篇分析以 CB1 为模板**；`data/cb3_summary.json` 已落盘可对照验证镜像性。

## 2. 渲染管线 9 个阶段（CB1）

```
A. Pre-frame & Shadow                   (E1–E3)
B. Velocity + Normal Pre-pass + Z       (E4)             ← 不是传统 deferred GBuffer
C. Half-res Screen-Space Effects        (E5–E10)
D. Separable Subsurface Scattering      (E11–E12)
E. Full-res HDR Forward Compose + Sky   (E13)            ← 重新光栅化几何 + 直接采样原图
F. Depth of Field                       (E14–E16)
G. Eyes / Hair / Effect 收尾            (E17)
H. TAA + Bloom 5 级金字塔               (E18–E27)
I. Tonemap / FSR / UI / Present         (E28–E30)
```

每段的 RT、产物、消费方在 `02-frame-breakdown.md` 中逐 encoder 给出。

## 3. 关键设计判断

### 3.1 半分辨率延迟着色（**核心策略**）

`1167×1671 / 2 = 583×835`。所有 `583×835` 的 TempBuffer（122–130，即 230–238）都是**半分辨率管线工序**的中间产物：

- `230 R8` — 1/16 area 粗 ScreenSpaceShadowMap
- `231 D32S8` — 半分辨率深度（DepthResolve 输出）
- `232 RG11B10F` — **半分辨率 lighting buffer**（皮肤光照 → SSS 输入）
- `233 R32F` — DepthResolve 标量深度
- `234 R8` — SSAO + SSS-mask 复用通道
- `235 R8` — SSAOBlur
- `236 RGBA8` — 半分辨率 ScreenSpaceShadowMap composite
- `237 RG11B10F` — SSS 水平模糊中间结果
- `238 RGBA16F` — DOF 半分辨率

**为什么这个 GPU、这个分辨率还要做半分辨率延迟？**因为 1167×1671 ≈ 1.95 MP，主光 + cluster local lights 全分辨率算太重；策略上把 **lighting + SSS + AO** 都放到 1/4 像素数（583×835）做，最终在 E13 全分辨率 compose 时再上采样混合。

### 3.2 三级阴影

| 级别 | 在哪生成 | RT | 谁消费 |
|---|---|---|---|
| **主光定向阴影 atlas (3 cascade)** | E2，30 draws | `225 DirectionalShadowDepth 3072×1024 D32F` | E10（半分辨率 lighting）、E13（全分辨率 compose）、E9（屏幕空间阴影合成） |
| **局部光阴影 atlas** | E3，10 draws | `226 LocalShadowmapAtlas 1024×1024 D32F` | E10、E13 |
| **半分辨率 ScreenSpaceShadowMap** | E5（粗 1/4）+ E9（精 1/2） | `230 R8` / `236 RGBA8` | E10（半分辨率 lighting）、E13（全分辨率 compose） |

E2 用 30 draws / E3 用 10 draws 对**同一组 9 个角色 RPS（472–480）×3 cascade slice / ×1 atlas slice** 渲染（draw 列表表现为 `RPS 472–480` 重复 3 次写到 atlas 三段 viewport）。

### 3.3 E4 是 Velocity + Normal Pre-pass，不是 deferred GBuffer（**详见 `06-gbuffer-truth.md`**）

E4 的 MRT 是 `RGBA8Unorm × 2 + D32S8`：

- **MRT0 (228)**：**packed 16-bit motion vector**（per-pixel reprojection delta，每分量 2 字节）→ 唯一消费方是 **TAA (RPS 441 `_VelocityTexture`)**
- **MRT1 (229)**：**octahedral-encoded world normal (RG) + sign(N.z) flag (B) + 角色前景 mask (A: 0.047 角色 / 0 InverseTonemap)** → 本帧无 fragment 显式 sample（引擎全局 binding 占位 / 为非本帧场景预留）
- **227 D32S8**：主深度+模板

**LYSK 的实际 lighting 架构是 Forward + Visibility-Style Velocity Buffer**：lighting **不**通过解码 GBuffer 完成，而是在 **E10**（half-res，仅皮肤+牙齿）和 **E13**（full-res，全部材质）**重新光栅化几何**，并直接采样原始材质纹理（`PL_Head_MU_N`、`PL_Head_R`、`PL_Makeup_*` 等）+ cluster lighting buffer 来计算光照。

→ 这是非常激进的「**Velocity Pre-pass + 全场景两次 Forward 重光栅化（half-res + full-res）**」方案，区别于经典 deferred 的「GBuffer 写一次 + lighting 解码一次」。代价是几何被画 6 次（3 cascade shadow + 1 local shadow + 1 velocity-prepass + 1 half-res lighting + 1 full-res compose），收益是：
- 不需要厚 GBuffer，省带宽（只有 RGBA8×2 = 8 字节/像素）；
- Lighting 直接在 forward 域算，可以无损 SSS / 复杂材质参数（不被 GBuffer 通道数限制）；
- TAA 拥有专门的 motion vector buffer，独立于 lighting 决策。

### 3.4 角色材质的「四变体 / 五阶段」组合

LYSK 的核心角色材质（皮肤、眼球、牙齿、头发、布料）每种都按**渲染阶段**展开成独立 RPS：

| 阶段 | 输出格式 | RPS 范围 | 数量 |
|---|---|---|---|
| Z-Prepass / Shadow Caster（color#=0, D32F） | depth-only | 472–480 | 9 |
| GBuffer 主写入（RGBA8×2 + D32S8） | MRT | 481–489 | 9 |
| **Half-res lighting branch**（RG11B10F + R8 + D32S8） | half-res | 490–492 | 3（仅皮肤/牙齿） |
| Full-res HDR Compose（RGBA16F + D32S8） | full-res | 493–500 | 8 |
| Eyes/Hair/Transparent 收尾（RGBA16F + D32S8） | full-res | 501–504 | 4 |

→ 一个「皮肤 SkinMakeupNew」会出现 **5 次**：`476 (Z-prepass) → 484 (GBuffer) → 491 (Half-res lighting) → 496 (Full-res compose) → ?`，详见 `04-skin-and-sss-pipeline.md`。

### 3.5 时域抗锯齿（TAA）+ FSR 1.0 上采样的组合

抗锯齿/上采样链：

```
HDR scene buffer 224 (1167×1671 RGBA16F)
       │
       ▼
E18 TAA: 224 + 247_prev → 239_now (1167×1671 RGBA16F)   // CB1 写 239；CB3 写 247
       │
       ▼
E28 FinalBlit/Tonemap: HDR → 245 (1167×1671 RGBA8)      // 同时混入 244 Bloom 顶
       │
       ▼
E29 FSR EASU: 245 → 246 (1668×2388 RGBA8)               // 1.43× 边缘自适应放大
       │
       ▼
E30 RCAS sharpen + UI overlay → 147/160 swapchain (1668×2388 BGRA8)
```

**注意**：TAA 在 LDR 之前（HDR 域），FSR 在 LDR 之后（tonemap 后）。这是 FSR 1.0 的标准插入位（FSR 1.0 不接受 HDR 输入）；意味着这套管线 ≤ FSR 2.0（FSR 2.0 才会把 TAA 与上采样合并）。

### 3.6 Compute lighting 的位置

E1 = `CalcLighting.CSMain`，是这一整帧**唯一**的 compute 工作。它发生在：

- **晚于** swapchain present prep（CB0 blit 已结束）；
- **早于** Velocity-Pre-pass（E4）；
- **同帧内** 持续被 E10 / E13 / E17 等所有「读 lighting」的 fragment shader 消费 — **作为 fragment shader 中名为 `_LightIndexMap` 的 texture2d 输入**（rid 145, 128×128 RGBA8）。

→ 这是一个 cluster / tile lighting **index buffer**：把屏幕分成 128×128 grid，每个 grid cell 存「这个 cell 里影响哪些光源」的索引列表。在 491（half-res lighting）的 fragment IR 中已确认了名字 `_LightIndexMap` 的存在。具体 dispatch 大小受 R7.5 子项 B 盲区影响，仍待补 swizzle。

## 4. 帧级数据流 DAG

```
                        CSMain (E1, compute)
                            │
                            │  _LightIndexMap (rid 145, 128×128 RGBA8 cluster light index)
                            ▼
ShadowDepth(225)   "Velocity+Normal Pre-pass" (228 motion / 229 octa-norm+mask)  Depth+Stencil(227)
   E2/E3   ──────► E4
                            │
                            │  注意：228 / 229 不喂给 lighting，只 227 (depth) 被后续 pass 读。
                            │       228 仅消费方 = E18 TAA 的 _VelocityTexture
                            │       229 本帧无 fragment 显式 sample
                            ├─► E5 SSSM 1/4 (230 R8 291×417)
                            ├─► E6 DepthResolve (233 R32F + 231 D32S8)
                            ├─► E7 SSAO (235 R8) ─► E8 SSAOBlur (234 R8)
                            ├─► E9 ScreenSpaceShadows (236 RGBA8)
                            └─► E10 Half-res Forward Lighting (232 RG11B10F) + 234 SSS-mask
                                            │   ↑ 重新光栅化几何 + 直接采样 PL_*_D/N/R 原图 + _LightIndexMap
                                            ▼
                              E11 SSS H-blur (232 → 237)
                              E12 SSS V-blur (237 → 232)
                                            │
                                            ▼
              ┌─── E13 Full-res Forward Compose + Sky + FX  (224 RGBA16F 1167×1671) ─┐
              │   18 draws: Cloth/Skin/Eye/Teeth/Hair compose + Sky + EffectFresnel    │
              │   ↑ 又一次重新光栅化几何 + 采样原图 + 上采样 232 SSS lighting           │
              ▼                                                                        ▼
          E14/E16 DOF (238 → 224)                                  E17 Eyes/Hair/Dissolve (224)
              │                                                                        │
              └────────────────► E18 TAA (224 + 247_prev + 228 velocity) → 239_now ────┘
                                              │
                                E19–E23 Bloom Down (244→240→241→242→243)
                                E24–E27 Bloom Up   (243→242→241→240→244)
                                              │
                                              ▼
                                E28 FinalBlit + Tonemap → 245 (1167×1671 RGBA8)
                                              ▼
                                E29 FSR EASU → 246 (1668×2388 RGBA8)
                                              ▼
                            E30 FSR RCAS + InternalClearMetal + UI/Default×16
                                + TextMeshPro + EffectCombine2 → 147 swapchain
```

## 5. 一帧 host-side 时长

`replay --list-resources` 报告 8.87 ms（含资源元数据序列化开销）。这是 **headless replay** 的 wall-clock，**不是** GPU 时间，只能作为「这帧能跑通」的 sanity check。
