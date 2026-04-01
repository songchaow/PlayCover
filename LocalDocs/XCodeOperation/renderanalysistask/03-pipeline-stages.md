# T3: 原神渲染管线阶段划分

## 总览

原神 (Login Base 场景) 的单帧渲染管线分为 **7 个主要阶段**，共 50 个 shader pass，26 个 Render Encoder。

```
┌─────────────────────────────────────────────────────────────────┐
│ Stage 1: 预处理 (Pass 0-2)                                      │
│   HeightFog Init → Weather Map → Erosion Sector                 │
├─────────────────────────────────────────────────────────────────┤
│ Stage 2: G-Buffer / 几何渲染 (Pass 3-12)                         │
│   Login Base ×4 → DepthDownSample → Clear → Login Base ×4       │
├─────────────────────────────────────────────────────────────────┤
│ Stage 3: 光照计算 (Pass 13-25)                                   │
│   WindMap → SS-Shadows → SSAO → Particles → ToonLight →         │
│   GaussBlur → DeferredShading ×3                                │
├─────────────────────────────────────────────────────────────────┤
│ Stage 4: 天空渲染 (Pass 26-31)                                   │
│   Atmosphere → Stars → Moon → Cloud Particle → Cloud Layer →    │
│   HeightFog Composite                                           │
├─────────────────────────────────────────────────────────────────┤
│ Stage 5: 运动矢量 (Pass 32-35)                                   │
│   RGBMCopy → MotionVectors ×3                                   │
├─────────────────────────────────────────────────────────────────┤
│ Stage 6: 后处理链 (Pass 36-47)                                   │
│   TAA → Motion Blur ×2 → Bloom/Gauss 多级 → Uber → Copy         │
├─────────────────────────────────────────────────────────────────┤
│ Stage 7: UI (Pass 48-49)                                        │
│   ClearMetal → UI/Default                                       │
└─────────────────────────────────────────────────────────────────┘
                            ↓
                      presentDrawable
```

## 详细阶段分析

### Stage 1: 预处理 (Pass 0-2, RE 0-2)

| Pass | Shader | 用途 |
|------|--------|------|
| 0 | Hidden/Internal-HeightFog | 初始化高度雾参数/lookup |
| 1 | Dynamic Sky/Generate Weather Map | 生成天气图纹理（用于后续云层、大气） |
| 2 | Hidden/Internal-ErosionSectorRender | 地形侵蚀扇区渲染（地形 LOD/程序化细节） |

**说明**: 这些 pass 生成后续渲染需要的辅助数据纹理。

### Stage 2: G-Buffer / 几何渲染 (Pass 3-12, RE 3-12)

| Pass | Shader | 用途 |
|------|--------|------|
| 3-6 | miHoYo/Scene/Login Base ×4 | 主场景几何渲染第一组（可能按材质/距离分 sub-pass） |
| 7 | Hidden/Internal-DepthDownSample | 全分辨率深度降采样为半/四分之一分辨率（供 SSAO/SSR 使用） |
| 8 | Hidden/InternalClear | 清除某个 RT（可能是光照缓冲） |
| 9-12 | miHoYo/Scene/Login Base ×4 | 主场景几何渲染第二组 |

**说明**: Login Base shader 出现 8 次，分两组中间插入 DepthDownSample 和 Clear。推测第一组渲染不透明物体写入 G-Buffer，DepthDownSample 后第二组可能渲染半透明/decal/细节物体。

### Stage 3: 光照计算 (Pass 13-25, RE 13-25)

| Pass | Shader | 用途 |
|------|--------|------|
| 13 | MiHoYo/Nature/LocalWindsMapReproject | 风场图重投影（用于草/植物动画） |
| 14 | Hidden/Internal-ScreenSpaceShadows-PCF-Specify | 屏幕空间阴影（PCF 软阴影） |
| 15 | Hidden/Internal-SSAO | 屏幕空间环境遮蔽 |
| 16-17 | miHoYo/Particles/UVmove_New ×2 | UV 滚动动画粒子 |
| 18 | miHoYo/Particles/OneChannel_New | 单通道粒子效果 |
| 19 | Dynamic Sky/Cloud Particle_Login_New | 登录场景特效云粒子 |
| 20 | miHoYo/Particles/OneChannel_New | 单通道粒子效果 |
| 21 | Hidden/PostProcessing/miHoYo/ToonLightBuffer | **卡通光照缓冲**（原神标志性的 cel-shading） |
| 22 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 光照高斯模糊（可能是 bloom 预处理或软光照） |
| 23-25 | Hidden/Internal-DeferredShading ×3 | 延迟着色（多 pass 可能对应不同光源类型：方向光/点光/探针） |

**说明**: 这是整帧最核心的光照阶段。注意 **ToonLightBuffer** 在 DeferredShading 之前，说明原神先计算卡通光照，再混合到延迟着色结果中。

### Stage 4: 天空渲染 (Pass 26-31, RE 对应天空层)

| Pass | Shader | 用途 |
|------|--------|------|
| 26 | Dynamic Sky/Atmosphere Layer | 大气散射渲染 |
| 27 | Dynamic Sky/Stars Mesh | 星空（网格绘制星点） |
| 28 | Dynamic Sky/Moon Layer | 月亮渲染 |
| 29 | Dynamic Sky/Cloud Particle | 体积云粒子 |
| 30 | Dynamic Sky/Cloud Layer | 2D 云层 |
| 31 | Hidden/Internal-HeightFog | 将高度雾应用到场景上 |

**说明**: 完整的 5 层天空系统 + 高度雾合成。天空在光照之后渲染，使用深度缓冲进行正确的远近排序。

### Stage 5: 运动矢量 (Pass 32-35)

| Pass | Shader | 用途 |
|------|--------|------|
| 32 | miHoYo/Misc/RGBMCopy | RGBM 编码颜色拷贝（可能保存当前帧颜色供 TAA 使用） |
| 33-35 | Hidden/Internal-MotionVectors ×3 | 运动矢量生成（3 pass 可能对应：相机运动、骨骼动画、粒子运动） |

### Stage 6: 后处理链 (Pass 36-47)

| Pass | Shader | 用途 |
|------|--------|------|
| 36 | Hidden/PostProcessing/TemporalAntialiasing | TAA 时间性抗锯齿 |
| 37-38 | Hidden/PostProcessing/miHoYo/Motion Blur ×2 | 运动模糊（2 pass: tile max + gather） |
| 39 | Hidden/PostProcessing/miHoYo/Bloom | Bloom 降采样 / 亮度提取 |
| 40 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 高斯模糊（bloom 级联 1） |
| 41 | Hidden/PostProcessing/miHoYo/Bloom | Bloom 中间处理 |
| 42-44 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter ×3 | 高斯模糊（bloom 级联 2-4） |
| 45 | Hidden/PostProcessing/miHoYo/Bloom | Bloom 合成 / 上采样 |
| 46 | Hidden/PostProcessing/Uber | **最终色调映射** (Tonemapping + Color Grading + LUT) |
| 47 | Hidden/PostProcessing/Copy | 拷贝到 backbuffer |

**说明**: 标准的 HDR 后处理管线。Bloom 使用了多级高斯模糊（至少 4 级），符合高质量泛光效果。

### Stage 7: UI (Pass 48-49)

| Pass | Shader | 用途 |
|------|--------|------|
| 48 | Hidden/InternalClearMetal | 清除 UI 渲染目标 |
| 49 | UI/Default | UI 元素渲染 |

**说明**: UI 最后渲染，直接在后处理结果上叠加。

## Render Encoder ↔ Pipeline State 映射估算

由于 50 个 pass 对应 26 个 RE，部分 RE 包含多个 pipeline state：

- RE 0-2: 预处理 (3 pass, 3 RE) — 1:1
- RE 3-12: G-Buffer (10 pass, 10 RE) — 1:1
- RE 13-25: 光照 + 天空 + 运动矢量 (23 pass, 13 RE) — ~1.8:1
- RE 最后: 后处理 + UI (14 pass) — 需要深入验证

## 总结

原神的渲染管线是一个 **延迟渲染 + 卡通着色混合管线**，结构清晰：

1. 预处理辅助纹理（雾、天气、地形）
2. G-Buffer 几何渲染（分两组，中间插入深度降采样）
3. 光照计算（SS-Shadow → SSAO → 粒子 → ToonLight → DeferredShading）
4. 天空 5 层渲染 + 高度雾
5. 运动矢量生成
6. 后处理链（TAA → Motion Blur → Bloom → Uber → Copy）
7. UI 渲染

这种架构符合高质量移动端 3A 游戏的典型做法，结合了延迟着色的高效光照计算和卡通渲染的艺术风格控制。
