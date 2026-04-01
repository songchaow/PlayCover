# T2: Render Pass 摘要

## 数据来源

Pipeline State 模式下读取的 50 个 shader pass。这些 pass 按执行顺序排列，对应每帧 26 个 Render Encoder（部分 RE 包含多个 pipeline state）。

## Shader Pass 列表（执行顺序）

| Pass# | Shader 名称 | 推断阶段 |
|-------|------------|---------|
| 0 | Hidden/Internal-HeightFog | 预处理: 高度雾初始化 |
| 1 | Dynamic Sky/Generate Weather Map | 预处理: 天气贴图生成 |
| 2 | Hidden/Internal-ErosionSectorRender | 预处理: 地形侵蚀 |
| 3 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (1/8) |
| 4 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (2/8) |
| 5 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (3/8) |
| 6 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (4/8) |
| 7 | Hidden/Internal-DepthDownSample | G-Buffer: 深度降采样 |
| 8 | Hidden/InternalClear | G-Buffer: 内部清除 |
| 9 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (5/8) |
| 10 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (6/8) |
| 11 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (7/8) |
| 12 | miHoYo/Scene/Login Base | G-Buffer: 场景几何渲染 (8/8) |
| 13 | MiHoYo/Nature/LocalWindsMapReproject | 环境: 局部风场图重投影 |
| 14 | Hidden/Internal-ScreenSpaceShadows-PCF-Specify | 光照: 屏幕空间阴影 (PCF) |
| 15 | Hidden/Internal-SSAO | 光照: 屏幕空间环境遮蔽 |
| 16 | miHoYo/Particles/UVmove_New | 粒子: UV 动画粒子 (1/2) |
| 17 | miHoYo/Particles/UVmove_New | 粒子: UV 动画粒子 (2/2) |
| 18 | miHoYo/Particles/OneChannel_New | 粒子: 单通道粒子 (1/2) |
| 19 | Dynamic Sky/Cloud Particle_Login_New | 天空: 登录场景云粒子 |
| 20 | miHoYo/Particles/OneChannel_New | 粒子: 单通道粒子 (2/2) |
| 21 | Hidden/PostProcessing/miHoYo/ToonLightBuffer | 光照: 卡通光照缓冲 |
| 22 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 光照: 高斯模糊滤波 (光照) |
| 23 | Hidden/Internal-DeferredShading | 光照: 延迟着色 (1/3) |
| 24 | Hidden/Internal-DeferredShading | 光照: 延迟着色 (2/3) |
| 25 | Hidden/Internal-DeferredShading | 光照: 延迟着色 (3/3) |
| 26 | Dynamic Sky/Atmosphere Layer | 天空: 大气层 |
| 27 | Dynamic Sky/Stars Mesh | 天空: 星空网格 |
| 28 | Dynamic Sky/Moon Layer | 天空: 月亮层 |
| 29 | Dynamic Sky/Cloud Particle | 天空: 云粒子 |
| 30 | Dynamic Sky/Cloud Layer | 天空: 云层 |
| 31 | Hidden/Internal-HeightFog | 天空: 高度雾合成 |
| 32 | miHoYo/Misc/RGBMCopy | 辅助: RGBM 拷贝 |
| 33 | Hidden/Internal-MotionVectors | 后处理: 运动矢量 (1/3) |
| 34 | Hidden/Internal-MotionVectors | 后处理: 运动矢量 (2/3) |
| 35 | Hidden/Internal-MotionVectors | 后处理: 运动矢量 (3/3) |
| 36 | Hidden/PostProcessing/TemporalAntialiasing | 后处理: 时间性抗锯齿 (TAA) |
| 37 | Hidden/PostProcessing/miHoYo/Motion Blur | 后处理: 运动模糊 (1/2) |
| 38 | Hidden/PostProcessing/miHoYo/Motion Blur | 后处理: 运动模糊 (2/2) |
| 39 | Hidden/PostProcessing/miHoYo/Bloom | 后处理: 泛光 (1/3) - 降采样 |
| 40 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 后处理: 高斯模糊滤波 (泛光) |
| 41 | Hidden/PostProcessing/miHoYo/Bloom | 后处理: 泛光 (2/3) - 中间 |
| 42 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 后处理: 高斯模糊滤波 (泛光) |
| 43 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 后处理: 高斯模糊滤波 (泛光) |
| 44 | Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 后处理: 高斯模糊滤波 (泛光) |
| 45 | Hidden/PostProcessing/miHoYo/Bloom | 后处理: 泛光 (3/3) - 合成 |
| 46 | Hidden/PostProcessing/Uber | 后处理: Uber (色调映射 + LUT) |
| 47 | Hidden/PostProcessing/Copy | 后处理: 最终拷贝 |
| 48 | Hidden/InternalClearMetal | UI: 清除 UI 目标 |
| 49 | UI/Default | UI: 界面渲染 |

## Shader 统计

| Shader 名称 | 出现次数 | 类别 |
|------------|---------|------|
| miHoYo/Scene/Login Base | 8 | 场景几何 |
| Hidden/PostProcessing/miHoYo/MultipleGaussPassFilter | 5 | 后处理滤波 |
| Hidden/Internal-DeferredShading | 3 | 延迟光照 |
| Hidden/Internal-MotionVectors | 3 | 运动矢量 |
| Hidden/PostProcessing/miHoYo/Bloom | 3 | 泛光 |
| Hidden/Internal-HeightFog | 2 | 高度雾 |
| miHoYo/Particles/UVmove_New | 2 | 粒子 |
| miHoYo/Particles/OneChannel_New | 2 | 粒子 |
| Hidden/PostProcessing/miHoYo/Motion Blur | 2 | 运动模糊 |
| Dynamic Sky/Generate Weather Map | 1 | 天气 |
| Hidden/Internal-ErosionSectorRender | 1 | 地形 |
| Hidden/Internal-DepthDownSample | 1 | 深度 |
| Hidden/InternalClear | 1 | 内部 |
| MiHoYo/Nature/LocalWindsMapReproject | 1 | 自然 |
| Hidden/Internal-ScreenSpaceShadows-PCF-Specify | 1 | 阴影 |
| Hidden/Internal-SSAO | 1 | AO |
| Dynamic Sky/Cloud Particle_Login_New | 1 | 天空 |
| Hidden/PostProcessing/miHoYo/ToonLightBuffer | 1 | 光照 |
| Dynamic Sky/Atmosphere Layer | 1 | 天空 |
| Dynamic Sky/Stars Mesh | 1 | 天空 |
| Dynamic Sky/Moon Layer | 1 | 天空 |
| Dynamic Sky/Cloud Particle | 1 | 天空 |
| Dynamic Sky/Cloud Layer | 1 | 天空 |
| miHoYo/Misc/RGBMCopy | 1 | 辅助 |
| Hidden/PostProcessing/TemporalAntialiasing | 1 | TAA |
| Hidden/PostProcessing/Uber | 1 | 后处理 |
| Hidden/PostProcessing/Copy | 1 | 拷贝 |
| Hidden/InternalClearMetal | 1 | 内部 |
| UI/Default | 1 | UI |

## 关键观察

1. **Login Base** shader 出现 8 次，是主要的场景几何 shader（可能是登录大厅场景）
2. **延迟渲染管线**: 使用了经典的 G-Buffer → ScreenSpaceShadows → SSAO → DeferredShading 流程
3. **天空渲染**: 独立的 5 层天空系统（大气 + 星空 + 月亮 + 云粒子 + 云层）
4. **后处理链**: TAA → Motion Blur → Bloom (多级高斯) → Uber (色调映射) → Copy
5. **Toon Light Buffer**: 卡通光照缓冲表明原神使用了卡通渲染 + 延迟着色的混合管线
