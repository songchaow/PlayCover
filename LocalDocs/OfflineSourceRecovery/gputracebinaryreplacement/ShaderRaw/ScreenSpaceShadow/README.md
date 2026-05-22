# ScreenSpaceShadow Shader IR 集合

> trace: `capture_20260518_110050.gputrace`
> 目标 RT: rid 236 `_ScreenShadowTexture` (583×835 RGBA8Unorm)

---

## 文件列表

| 文件 | RPS | Label | 作用 | 写入通道 |
|------|-----|-------|------|----------|
| `rps462_ScreenSpaceShadowMap_penumbra_frag_lib330.ll` | 462 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E5**: 从主灯 cascade shadow map (rid 225, 3072×1024 Depth32F) 生成 quarter-res penumbra mask → 输出到 **rid 230** (R8Unorm 291×417) | 单独 RT (R8Unorm)，非 rid 236 |
| `rps449_ScreenSpaceShadowMap_simple_frag_lib298.ll` | 449 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E9 draw 56**: Gather 采样 penumbra (rid 230) 取均值作为主灯阴影，采样 SSAO (rid 234) 写入 A 通道 | **R** = 主灯阴影, **A** = SSAO, G=B=1.0 |
| `rps463_ScreenSpaceShadowMap_full_frag_lib332.ll` | 463 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E9 draw 57**: 完整 PCSS 软阴影 — 直接从 cascade depth (rid 225) 做 5×5 PCF tent + square，采样 SSAO (rid 234) 写入 A → **覆写** draw 56 | **R** = 主灯方向光 PCSS 阴影², **A** = SSAO, G=B=1.0 |
| `rps450_SpotShadow_frag_lib302.ll` | 450 | `Unlit/Papegame/SpotShadow` | **E9 draw 58**: 从 spot light shadow atlas (rid 226, 1024×1024 Depth32F) 做 16-tap rotated Poisson disk 投射 spot 阴影 | **G only** (writeMask=G, blending=true) |

---

## 关键资源目录

| rid | Label | 格式 | 尺寸 | 用途 |
|-----|-------|------|------|------|
| 225 | `DirectionalShadowDepth` | Depth32Float | 3072×1024 | 主灯 3-cascade shadow map |
| 226 | `LocalShadowmapAtlas` | Depth32Float | 1024×1024 | Spot light shadow atlas |
| 227 | `TempBuffer 119` | Depth32Float_Stencil8 | 1167×1671 | Camera depth (full-res) |
| 230 | `TempBuffer 122` | R8Unorm | 291×417 | Penumbra mask (E5 输出, quarter-res) |
| 234 | `TempBuffer 126` | R8Unorm | 583×835 | SSAO blurred (E8 `Unlit/SSAOBlur` 输出, half-res) |
| 236 | `TempBuffer 128` | RGBA8Unorm | 583×835 | `_ScreenShadowTexture` 最终合成目标 |

---

## rid 236 四通道最终语义

| 通道 | 内容 | 来源 | 消费者 |
|------|------|------|--------|
| **R** | 主灯方向光阴影 (PCSS²) | rid 225 `DirectionalShadowDepth` 3072×1024 (3-cascade) | `charShadow = lerp(1, screenShadow.r, _CharShadowIntensity)` → 控制主灯镜面+sparkle |
| **G** | Spot Light 0 阴影 | rid 226 `LocalShadowmapAtlas` 1024×1024 | Light 0 `_AdditionalLightShadowWeight = (0,1,0,0)` → `shadowRaw = dot(1-ss, sw)` |
| **B** | 空闲 (恒 1.0) | 无 | 无灯使用 (预留通道) |
| **A** | SSAO (环境遮蔽) | rid 234 (583×835 R8Unorm, `Unlit/SSAOBlur` 产出) | `charSpecular * screenShadow.a` (AO 衰减镜面高光) |

---

## E5 → E8 → E9 执行流程

```
E5 (draw 52, RPS 462):
  读: rid 225 (DirShadowDepth 3072×1024) + rid 227 (CameraDepth)
  写: rid 230 (R8Unorm 291×417, quarter-res penumbra mask)
  算法: cascade 选择 + dithered 边界混合 + 5×5 PCF tent (9 Gather) + square
  ↓
E8 (draw 55, RPS 448 'Unlit/SSAOBlur'):
  写: rid 234 (R8Unorm 583×835, half-res SSAO blurred)
  ↓
E9 (draw 56, RPS 449):  [被 draw 57 覆写，实际无效果]
  读: rid 230 (penumbra, slot 1 '_PenumbraMask') + rid 234 (SSAO, slot 0 '_SSAOTexture')
  写: rid 236 RGBA = (Gather4Avg(penumbra), 1, 1, SSAO)
  附加逻辑: if (sum > 0.04 && avg < _PenumbraBias) discard
  ↓
E9 (draw 57, RPS 463):  [最终主灯结果]
  读: rid 225 (DirShadowDepth, slot 0) + rid 227 (CameraDepth, slot 1) + rid 234 (SSAO, slot 2 '_SSAOTexture')
  写: rid 236 RGBA = (PCSS_shadow², 1, 1, SSAO)  ← 覆写 draw 56
  算法: 世界坐标重建 → CloseUp local 判断 → cascade 选择 + dither → 5×5 PCF tent → square
  ↓
E9 (draw 58, RPS 450):  [Spot shadow 叠加]
  读: rid 226 (LocalShadowmapAtlas 1024×1024, slot 0) + rid 227 (CameraDepth, slot 1)
  写: rid 236 G only (blend) = spotShadow
  算法: 随机旋转 Poisson disk, 4 Gather (16 depth comparisons), average
```

---

## 备注

- draw 56 (RPS 449) 和 draw 57 (RPS 463) 都写 RGBA 且 blending=false，所以 **draw 57 完全覆盖 draw 56**。draw 56 是低质量 fallback path（从预计算 penumbra 直接 Gather4 取均值），draw 57 是完整 PCSS 版本。在有 draw 57 的帧里，draw 56 的结果不可见。
- draw 58 (RPS 450) writeMask=G + blending=true，**只动 G 通道**，不影响 R/B/A。
- R 通道的 shadow 值经过 `(pcf_sum / 25)²` 处理——先归一化再平方，使阴影边缘过渡更柔和。
- A 通道携带 **SSAO**（环境遮蔽），不是阴影信息。IR 中变量名为 `_SSAOTexture`，运行时绑定确认为 E8 `Unlit/SSAOBlur` pass 的输出 (rid 234)。

---

## Analyzed/ — 翻译后的 Unity ShaderLab

Metal IR → Unity ShaderLab 翻译结果，已通过 Unity Editor 编译验证。

| 翻译后文件 | 对应 IR 源 | 说明 |
|------------|-----------|------|
| `Analyzed/ScreenSpaceShadowMap_Simple.shader` | `rps449_ScreenSpaceShadowMap_simple_frag_lib298.ll` | Gather penumbra + SSAO 合成 (fallback) |
| `Analyzed/ScreenSpaceShadowMap_Penumbra.shader` | `rps462_ScreenSpaceShadowMap_penumbra_frag_lib330.ll` | Quarter-res penumbra mask 生成 |
| `Analyzed/ScreenSpaceShadowMap.shader` | `rps463_ScreenSpaceShadowMap_full_frag_lib332.ll` | 完整 PCSS 软阴影 + SSAO |
| `Analyzed/SpotShadow.shader` | `rps450_SpotShadow_frag_lib302.ll` | Spot light 16-tap Poisson disk 阴影 |

所有翻译均已通过语义等价性人工复核 + Unity shader 编译验证 + GPU trace 运行时绑定交叉验证。
