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
| **R** | 主灯方向光 PCSS 阴影 | rid 225 `DirectionalShadowDepth` (3072×1024, 3-cascade) | `charShadow = lerp(1, screenShadow.r, _CharShadowIntensity)` 控制主灯镜面反射 + sparkle |
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
│  算法: cascade 选择 + dithered 边界混合 + 5×5 PCF tent (9 Gather) + sq  │
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
│  E9 (draw 57, RPS 463) — Full PCSS  ★ 最终主灯结果                     │
│                                                                         │
│  输入: rid 225 (DirShadow, slot 0) + rid 227 (Depth, slot 1)           │
│        + rid 234 (SSAO, slot 2)                                         │
│  输出: rid 236 RGBA = (PCSS_shadow², 1, 1, SSAO) ← 完全覆写 draw 56    │
│  算法: 世界坐标重建 → CloseUp 判断 → cascade 选择 + dither              │
│        → 5×5 PCF tent (9 Gather) → square                               │
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
| `ScreenSpaceShadowMap.shader` | lib332 (RPS 463) | 完整 PCSS 软阴影 + SSAO |
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

## 技术要点

### Draw 56 vs Draw 57 的覆写关系

Draw 56 (RPS 449) 和 draw 57 (RPS 463) 均以 `writeMask=RGBA` + `blending=false` 写入 rid 236，
因此 **draw 57 完全覆盖 draw 56 的输出**。

- **Draw 56** 是低质量 fallback path：从 E5 预计算的 penumbra mask (rid 230) 直接 Gather4 取均值
- **Draw 57** 是完整 PCSS 版本：直接从 cascade depth map 实时计算 5×5 PCF

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
