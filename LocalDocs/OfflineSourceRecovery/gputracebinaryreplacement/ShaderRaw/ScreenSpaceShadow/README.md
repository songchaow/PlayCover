# ScreenSpaceShadow Shader IR 集合

> trace: `capture_20260518_110050.gputrace`
> 目标 RT: rid 236 `_ScreenShadowTexture` (583×835 RGBA8Unorm)

---

## 文件列表

| 文件 | RPS | Label | 作用 | 写入通道 |
|------|-----|-------|------|----------|
| `rps462_ScreenSpaceShadowMap_penumbra_frag_lib330.ll` | 462 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E5**: 从主灯 cascade shadow map (rid 225, 3072×1024 Depth32F) 生成半分辨率 penumbra mask → 输出到 **rid 234** (R8Unorm 583×835) | 单独 RT (R8Unorm)，非 rid 236 |
| `rps449_ScreenSpaceShadowMap_simple_frag_lib298.ll` | 449 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E9 draw 56**: 简单采样，将 penumbra (rid 234) 和 char light mask (rid 230) 合成到 rid 236 | **R** = 主灯阴影, **A** = CharLight 阴影, G=B=1.0 |
| `rps463_ScreenSpaceShadowMap_full_frag_lib332.ll` | 463 | `Hidden/Papegame/ScreenSpaceShadowMap` | **E9 draw 57**: 完整 PCSS 软阴影 — 直接从 cascade depth (rid 225) 做多次采样 + penumbra (rid 234) → **覆写** draw 56 的结果 | **R** = 主灯方向光 PCSS 阴影, **A** = CharLight 阴影, G=B=1.0 |
| `rps450_SpotShadow_frag_lib302.ll` | 450 | `Unlit/Papegame/SpotShadow` | **E9 draw 58**: 从 spot light shadow atlas (rid 226, 1024×1024 Depth32F) 投射 spot 阴影 | **G only** (writeMask=G, blending=true) |

---

## rid 236 四通道最终语义

| 通道 | 内容 | 对应 Shadow Map 来源 | 消费者 |
|------|------|---------------------|--------|
| **R** | 主灯方向光阴影 | rid 225 `DirectionalShadowDepth` 3072×1024 (3-cascade) | `charShadow = lerp(1, screenShadow.r, _CharShadowIntensity)` → 控制主灯镜面+sparkle |
| **G** | Spot Light 0 阴影 | rid 226 `LocalShadowmapAtlas` 1024×1024 | Light 0 `_AdditionalLightShadowWeight = (0,1,0,0)` → `shadowRaw = dot(1-ss, sw)` |
| **B** | 空闲 (恒 1.0) | 无 | 无灯使用 (预留通道) |
| **A** | Char Light 阴影 | rid 230 (291×417 R8Unorm, 半分辨率 penumbra mask) | `charSpecular * screenShadow.a` 直接使用 |

---

## E5 → E9 执行流程

```
E5 (draw 52, RPS 462):
  读: rid 225 (DirShadowDepth 3072×1024) + rid 227 (CameraDepth)
  写: rid 234 (R8Unorm 583×835 penumbra mask)
  ↓
E9 (draw 56, RPS 449):  [被 draw 57 覆写，实际无效果]
  读: rid 234 (penumbra) + rid 230 (char light mask)
  写: rid 236 RGBA = (mainShadow, 1, 1, charLightShadow)
  ↓
E9 (draw 57, RPS 463):  [最终主灯 + char light 结果]
  读: rid 225 (DirShadowDepth) + rid 227 (CameraDepth) + rid 234 (penumbra)
  写: rid 236 RGBA = (mainShadow_PCSS, 1, 1, charLightShadow)  ← 覆写 draw 56
  ↓
E9 (draw 58, RPS 450):  [Spot shadow 叠加]
  读: rid 226 (LocalShadowmapAtlas 1024×1024) + rid 227 (CameraDepth)
  写: rid 236 G only (blend) = spotShadow
```

---

## 备注

- draw 56 (RPS 449) 和 draw 57 (RPS 463) 都写 RGBA 且 blending=false，所以 **draw 57 完全覆盖 draw 56**。draw 56 可能是低质量 fallback path（从预计算 penumbra 直接采样），draw 57 才是最终的 PCSS 完整版本。在有 draw 57 的帧里，draw 56 的结果不可见。
- draw 58 (RPS 450) writeMask=G + blending=true，**只动 G 通道**，不影响 R/B/A。
- 所有 shadow 都是物理正确的 depth-compare 投射，只是通过 4 通道 RGBA 打包分发给不同灯。

---

## Analyzed/ — 翻译后的 Unity ShaderLab

Metal IR → Unity ShaderLab 翻译结果，已通过 Unity Editor 编译验证。

| 翻译后文件 | 对应 IR 源 | 说明 |
|------------|-----------|------|
| `Analyzed/ScreenSpaceShadowMap_Simple.shader` | `rps449_ScreenSpaceShadowMap_simple_frag_lib298.ll` | 简单采样 penumbra + char light 合成 |
| `Analyzed/ScreenSpaceShadowMap_Penumbra.shader` | `rps462_ScreenSpaceShadowMap_penumbra_frag_lib330.ll` | 半分辨率 penumbra mask 生成 |
| `Analyzed/ScreenSpaceShadowMap.shader` | `rps463_ScreenSpaceShadowMap_full_frag_lib332.ll` | 完整 PCSS 软阴影 |
| `Analyzed/SpotShadow.shader` | `rps450_SpotShadow_frag_lib302.ll` | Spot light 阴影投射 |

所有翻译均已通过语义等价性人工复核 + Unity shader 编译验证。
