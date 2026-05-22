# ScreenSpaceShadow Shader 分析

> **Trace**: `capture_20260518_110050.gputrace`  
> **最终合成目标**: rid 236 · `_ScreenShadowTexture` · 583×835 · RGBA8Unorm

本文档记录了 Screen-Space Shadow 合成管线的完整分析结果，涵盖 4 个 shader pass 如何协作生成
`_ScreenShadowTexture` 的四通道内容（方向光阴影、聚光灯阴影、SSAO）。

---

## 概览：rid 236 四通道语义

最终 `_ScreenShadowTexture` 各通道的含义与数据来源：

| 通道 | 语义 | 数据来源 | 下游消费方式 |
|:----:|------|----------|-------------|
| **R** | 主灯方向光阴影 (5×5 PCF²) | rid 225 `DirectionalShadowDepth` (3072×1024, 3-cascade) | `charShadow = lerp(1, screenShadow.r, _CharShadowIntensity)` 控制主灯镜面反射 + sparkle |
| **G** | Spot Light 0 阴影 | rid 226 `LocalShadowmapAtlas` (1024×1024) | `_AdditionalLightShadowWeight = (0,1,0,0)` → `shadowRaw = dot(1-ss, sw)` |
| **B** | 空闲 (恒 1.0) | — | 预留通道，当前无灯使用 |
| **A** | SSAO（环境遮蔽） | rid 234 (583×835 R8Unorm, `Unlit/SSAOBlur` 输出) | `charSpecular * screenShadow.a`（AO 衰减镜面高光）|

> **注意**：R 通道的值经过 `(pcf_sum / 25)²` 处理（先归一化再平方），使阴影边缘过渡更柔和。  
> A 通道携带的是 **SSAO** 而非阴影信息。

---

## 执行流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│  E5 (draw 52, RPS 462) — Penumbra Mask 生成                            │
│                                                                         │
│  输入: rid 225 (DirShadowDepth 3072×1024) + rid 227 (CameraDepth)      │
│  输出: rid 230 (R8Unorm 291×417, quarter-res)                           │
│  算法: cascade 选择 + dithered 边界混合 + 5×5 PCF box (9 Gather) + sq  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  E8 (draw 55, RPS 448) — SSAO Blur                                     │
│                                                                         │
│  输入: rid 235 (R8Unorm 583×835, SSAO raw) + rid 227 (CameraDepth)     │
│  输出: rid 234 (R8Unorm 583×835, half-res SSAO blurred)                 │
└────────────────────────────────────┬────────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  E9 (draw 56, RPS 449) — Simple Fallback  ⚠️ 被 draw 57 覆写           │
│                                                                         │
│  输入: rid 230 (penumbra, slot 1) + rid 234 (SSAO, slot 0)             │
│  输出: rid 236 RGBA = (Gather4Avg(penumbra), 1, 1, SSAO)               │
│  特殊: if (sum > 0.04 && avg < _PenumbraBias) discard                  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  E9 (draw 57, RPS 463) — Full PCF  ★ 最终主灯结果                      │
│                                                                         │
│  输入: rid 225 (DirShadow, slot 0) + rid 227 (Depth, slot 1)           │
│        + rid 234 (SSAO, slot 2)                                         │
│  输出: rid 236 RGBA = (PCF_shadow², 1, 1, SSAO) ← 完全覆写 draw 56     │
│  算法: 世界坐标重建 → CloseUp 判断 → cascade 选择 + dither              │
│        → 5×5 PCF box (9 Gather) → square                                │
└────────────────────────────────────┬────────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  E9 (draw 58, RPS 450) — Spot Shadow 叠加                              │
│                                                                         │
│  输入: rid 226 (LocalShadowAtlas, slot 0) + rid 227 (Depth, slot 1)    │
│  输出: rid 236 **G only** (writeMask=G, blending=true)                  │
│  算法: 随机旋转 Poisson disk → 4 Gather (16 depth comparisons) → avg   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Shader 文件清单

### IR 源文件

| 文件 | RPS | Draw | Label |
|------|:---:|:----:|-------|
| `rps462_…_penumbra_frag_lib330.ll` | 462 | 52 (E5) | `Hidden/Papegame/ScreenSpaceShadowMap` |
| `rps449_…_simple_frag_lib298.ll` | 449 | 56 (E9) | `Hidden/Papegame/ScreenSpaceShadowMap` |
| `rps463_…_full_frag_lib332.ll` | 463 | 57 (E9) | `Hidden/Papegame/ScreenSpaceShadowMap` |
| `rps450_SpotShadow_frag_lib302.ll` | 450 | 58 (E9) | `Unlit/Papegame/SpotShadow` |

### 翻译后 Unity ShaderLab（`Analyzed/` 目录）

| 文件 | 对应 IR | 功能 |
|------|---------|------|
| `ScreenSpaceShadowMap_Simple.shader` | lib298 (RPS 449) | Gather penumbra + SSAO 合成 (fallback) |
| `ScreenSpaceShadowMap_Penumbra.shader` | lib330 (RPS 462) | Quarter-res penumbra mask 生成 |
| `ScreenSpaceShadowMap.shader` | lib332 (RPS 463) | 完整 5×5 PCF 软阴影 + SSAO |
| `SpotShadow.shader` | lib302 (RPS 450) | Spot light 16-tap Poisson disk 阴影 |

> 所有翻译均已通过：语义等价性人工复核 + Unity shader 编译验证 + GPU trace 运行时绑定交叉验证。

---

## 关键资源

| rid | Label | 格式 | 尺寸 | 用途 |
|:---:|-------|------|:----:|------|
| 225 | `DirectionalShadowDepth` | Depth32Float | 3072×1024 | 主灯 3-cascade shadow map |
| 226 | `LocalShadowmapAtlas` | Depth32Float | 1024×1024 | Spot light shadow atlas |
| 227 | `TempBuffer 119` | Depth32Float_Stencil8 | 1167×1671 | Camera depth (full-res) |
| 230 | `TempBuffer 122` | R8Unorm | 291×417 | Penumbra mask (E5 输出, quarter-res) |
| 234 | `TempBuffer 126` | R8Unorm | 583×835 | SSAO blurred (E8 输出, half-res) |
| 236 | `TempBuffer 128` | RGBA8Unorm | 583×835 | **`_ScreenShadowTexture`** 最终合成目标 |

---

## 阴影算法详解

### 算法 A：Cascaded 5×5 PCF Box（RPS 462 / RPS 463 共用）

RPS 462（penumbra pass）和 RPS 463（full pass）使用相同的核心算法，区别仅在于输出目标和
是否附带 SSAO 采样。

**步骤总览：**

```
深度采样 → 世界坐标重建 → CloseUp 局部光判断 → Cascade 选择
→ Dithered 边界混合 → Shadow 空间投影 → 5×5 PCF Box → 平方
```

#### 1. 深度采样与世界坐标重建

```hlsl
// 带 0.3 texel 偏移的深度采样（减少 self-shadowing aliasing）
float2 depthUV = _CameraDepthTexture_TexelSize.xy * 0.3 + uv;
float depth = tex2D(_CameraDepthTexture, depthUV).r;

// 通过 InvViewProjMatrix 从 NDC + depth 重建世界坐标
float4 clipH = depth.xxxx * InvVP[2] + InvVP[3];
clipH += ndcY.xxxx * InvVP[1];
clipH += ndcX.xxxx * InvVP[0];
float3 worldPos = clipH.xyz / clipH.w;  // camera-relative world position
```

#### 2. CloseUp 局部光覆盖判断

将世界坐标投影到 CloseUp shadow 矩阵空间，若 NDC 坐标落在 ±0.99 范围内，
则该像素由局部光 shadow atlas 覆盖（`localShadowFlag = 1`），跳过方向光 cascade。

```hlsl
float2 cuv = CloseUpWorldToShadow * worldPos;
bool inLocal = abs(cuv * 2 - 1) < 0.99;  // 两轴均在范围内
```

#### 3. Cascade 选择（3-cascade + sphere distance）

使用 3 个分割球体的距离平方判定 cascade 归属：

```hlsl
float3 dists = float3(dot(wp - sphere0), dot(wp - sphere1), dot(wp - sphere2));
bool3 inside = dists < _DirShadowSplitSphereRadii.xyz;
```

通过差分编码 `half4(local, c0-local, c1-c0, c2-c1)` 和加权 `dot(..., half4(1,4,3,2))`
将 cascade 索引打包为单个半精度标量，再经 `4 - packedSum` 反解为 0~3 索引。

#### 4. Dithered Cascade 边界混合

在 cascade 边界处使用 4×4 dither pattern 避免硬切换：

```hlsl
int ditherIdx = (pixelY % 4) * 4 + (pixelX % 4);  // 16 entry LUT
half ditherFilter = DitherFilters[ditherIdx];
// 当 blendRatio >= dither 阈值时，跳到下一个 cascade
half cascadeOffset = (blendRatio >= ditherFilter) ? selectedWeight : 0;
uint finalCascade = clamp(cascadeOffset + baseIndex, 0, 3);
```

这种 dithered 混合比逐像素双采样 blend 便宜，且在时域 TAA 下不可见。

#### 5. Shadow 空间投影

```hlsl
uint matBase = cascadeIdx * 4;
float3 shadowCoord = WorldToShadowArray[matBase+0].xyz * wp.xxx
                   + WorldToShadowArray[matBase+1].xyz * wp.yyy
                   + WorldToShadowArray[matBase+2].xyz * wp.zzz
                   + WorldToShadowArray[matBase+3].xyz;
```

#### 6. 5×5 Uniform PCF（9 Gather = 36 texels → 25 有效比较）

核心采样模式：以 `shadowCoord.xy` 为中心，在 3×3 grid（间隔 2 texel）上执行 9 次
`Texture2D.Gather()`，每次返回 2×2 邻域（4 个深度值），共覆盖 6×6 texel footprint。

```
Gather 采样布局（相对 baseUV 的 texel 偏移）:

    (-2,-2)   (0,-2)   (2,-2)     ← Row 1 (bottom)
    (-2, 0)   (0, 0)   (2, 0)     ← Row 2 (middle)
    (-2,+2)   (0,+2)   (2,+2)     ← Row 3 (top)
```

每个 Gather 返回的 4 个深度值与 `shadowCoord.z` 比较（`>= ? 1 : 0`），然后按
**子像素 fractional position** 做边缘加权累加。

**内部权重是均匀的（box filter），不是 tent：**

```
6 列物理 texel 权重（X 方向）:

  col:      -3       -2       -1        0       +1       +2
  权重:   (1-fx)     1        1         1        1       fx

  ← 左Gather →    ← 中Gather →    ← 右Gather →
```

- 中间 4 列权重全为 **1**（均匀）
- 最外两列使用 `(1-frac)` / `frac` 并非 tent 衰减，而是 **子像素定位**
- `(1-fx) + 1 + 1 + 1 + 1 + fx = 5`，行方向同理
- 总权重 = 5 × 5 = **25**

```hlsl
// 实际累加示例（一行）:
float2 row = cmpLeft.wx * (1-frac.x) + cmpLeft.zy   // 最外列: 亚像素定位
           + cmpCenter.wx + cmpCenter.zy              // 中间: 全权重 1
           + cmpRight.wx;
row += cmpRight.zy * frac.x;                          // 最外列: 亚像素定位
float pcfRow = row.x * (1-frac.y) + row.y;           // 行间: 同样是亚像素定位
```

最终 25 个等效采样点的均匀加权和除以 25 再平方：

```hlsl
float shadow = (total * 0.04) * (total * 0.04);  // (sum/25)²
```

平方使阴影边缘过渡呈现类 gamma 曲线，视觉上更柔和自然。

> **为何叫 5×5 而不是 6×6？** 物理上 9 Gather 覆盖 6×6 texel，但边缘两列通过
> `(1-frac) + frac = 1` 互补合并为等效 1 列采样，因此滤波宽度等效为 5×5 uniform box，
> 且可在子像素精度上连续滑动。

---

### 算法 B：Gather4 + Penumbra Average（RPS 449，Simple Fallback）

极简版本，直接从 E5 预计算的 quarter-res penumbra mask 上采样：

```hlsl
float4 gathered = _PenumbraMask.Gather(sampler, uv);  // 4 个相邻 texel
float avg = (gathered.x + gathered.y + gathered.z + gathered.w) * 0.25;

// 质量门控：如果采样区域几乎全亮但仍低于 bias，discard 该像素
if (sum > 0.04 && avg < _PenumbraBias)
    discard;

return float4(avg, 1.0, 1.0, SSAO.r);
```

此 pass 在当前帧中被 draw 57 完全覆写，作为低质量 fallback 存在
（可能在某些设备/质量等级下 draw 57 不执行时生效）。

---

### 算法 C：Rotated Poisson Disk 16-Tap（RPS 450，Spot Shadow）

聚光灯阴影使用随机旋转的 Poisson Disk 采样，完全不同于方向光的均匀 PCF。

**步骤总览：**

```
屏幕 UV 计算 → 伪随机旋转角生成 → 世界坐标重建
→ 光空间投影 → 4 Gather (16 比较) → 均值
```

#### 1. 伪随机旋转角

基于屏幕像素坐标生成每像素不同的旋转角，消除规则采样 pattern 的 aliasing：

```hlsl
// 两轮哈希：screenUV → hashInput → dot(sq, 3571) → frac → sq → dot(7142) → frac
float angle01 = frac(frac(dot(hashSq, 3571)) ^ 2 * 7142 - 0.5);
float angleRad = angle01 * 6.28125;  // [0, 2π)
float sinA = sin(angleRad);
float cosA = cos(angleRad);
```

#### 2. 旋转采样偏移

构造 4 个采样点，分为两组正交方向，各自绕中心旋转：

```hlsl
// 组 1: 沿 baseOffset 方向旋转
float2 tap1A = shadowCoord.xy + float2(offsetCos.x, offsetSin.x);
float2 tap1B = shadowCoord.xy + float2(offsetCos.y, offsetSin.y);

// 组 2: 沿垂直方向旋转（无 texelRatio 缩放）
float2 tap2A = shadowCoord.xy + float2(sin*(-R), cos*(+R));
float2 tap2B = shadowCoord.xy + float2(sin*(+R), cos*(-R));
```

Poisson 半径 `R ≈ 0.00196`，由 `_LocalLightShadowmapSize.w / .z` 缩放以适应 atlas 分辨率。

#### 3. 4 Gather → 16 深度比较

```hlsl
float4 g1 = _LocalShadowMapAtlas.Gather(sampler, tap1A);  // 4 depths
float4 g2 = _LocalShadowMapAtlas.Gather(sampler, tap1B);  // 4 depths
float4 g3 = _LocalShadowMapAtlas.Gather(sampler, tap2A);  // 4 depths
float4 g4 = _LocalShadowMapAtlas.Gather(sampler, tap2B);  // 4 depths

// 16 次比较，均匀权重
float shadow = (sum_of_all_16_comparisons) * 0.0625;  // 1/16

return float4(1.0, shadow, 1.0, 1.0);  // 仅 G 通道有效 (writeMask=G)
```

---

### 算法对比总结

| | 方向光 Full (RPS 463) | 方向光 Simple (RPS 449) | 聚光灯 (RPS 450) |
|---|---|---|---|
| **滤波方式** | 5×5 uniform PCF (box filter) | Gather4 average (从预计算 mask) | 16-tap rotated Poisson disk |
| **采样次数** | 9 Gather (36 texel, 25 有效) | 1 Gather (4 texel) | 4 Gather (16 texel) |
| **采样源** | cascade depth map 实时比较 | quarter-res penumbra mask | spot shadow atlas 实时比较 |
| **旋转抖动** | Dithered cascade 边界 | 无 | 每像素随机旋转 |
| **后处理** | `(sum/25)²` | 直接 average | `sum/16` |
| **输出通道** | R (+ A=SSAO) | R (+ A=SSAO) | G only |

---

## 技术要点

### Draw 56 vs Draw 57 的覆写关系

Draw 56 (RPS 449) 和 draw 57 (RPS 463) 均以 `writeMask=RGBA` + `blending=false` 写入 rid 236，
因此 **draw 57 完全覆盖 draw 56 的输出**。

- **Draw 56** 是低质量 fallback path：从 E5 预计算的 penumbra mask (rid 230) 直接 Gather4 取均值
- **Draw 57** 是完整 PCF 版本：直接从 cascade depth map 实时计算 5×5 PCF

在有 draw 57 的帧里，draw 56 的结果完全不可见。

### Spot Shadow 的通道隔离

Draw 58 (RPS 450) 配置为 `writeMask=G` + `blending=true`，**仅写入 G 通道**，不影响 R/B/A。
这保证了方向光阴影（R）和 SSAO（A）不会被聚光灯 pass 破坏。

### 阴影值的平方处理

R 通道的最终阴影值公式为：

```
shadow = (pcf_sum / 25)²
```

5×5 PCF 共 25 个采样点，归一化后平方，使阴影边缘在视觉上更平滑自然（gamma-like curve）。

### SSAO 通道

A 通道携带的是 **SSAO（环境遮蔽）**，并非阴影。IR 中对应变量名为 `_SSAOTexture`，
运行时绑定确认来源为 E8 `Unlit/SSAOBlur` pass 的输出 (rid 234)。
