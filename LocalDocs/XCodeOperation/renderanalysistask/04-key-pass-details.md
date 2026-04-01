# T4: 关键 Pass 绑定详情 + T5: Attachment 依赖链

## 完整 Render Encoder Attachment 映射

以下数据来自步进遍历一帧（CB 5 ~ CB 6）的所有 26 个 RE，在每个 RE 的 encoder 创建命令处读取 attachments。

| RE# | Shader Pass | Attachments | 分辨率 | 备注 |
|-----|------------|-------------|--------|------|
| 0 | HeightFog (init) | Color 0: TempBuffer 15 | 128×128 | 高度雾 LUT |
| 1 | Weather Map | Color 0: TempBuffer 4 | 128×128 | 天气贴图 |
| 2 | ErosionSectorRender | Color 0: TempBuffer 18, Color 1: TempBuffer 19 | 256×256 | 地形侵蚀（双 RT） |
| 3 | Login Base (G-Buffer) | Color 0/1/2 + Depth + Stencil → InnerTarget | 全分辨率 | **主 G-Buffer 写入** |
| 4 | Login Base (sub-pass) | Color 0/1: TempBuffer 23/24, Depth/Stencil: TempBuffer 23 | 1146×644 | SS-Shadow/AO 辅助 |
| 5 | Shadow Map | Depth: TempBuffer 25 | 2048×2048 | **级联阴影图**（仅深度） |
| 6 | DepthDownSample / Clear | Color 0: TempBuffer 16 | 512×512 | 降采样深度 |
| 7 | Login Base (sub-pass) | Color 0: TempBuffer 26 | 1146×644 | |
| 8 | Login Base (G-Buffer 2) | Color 0: TempBuffer 27, Depth/Stencil: TempBuffer 23 | 1146×644 | 第二组几何渲染 |
| 9 | WindMap/Particles | Color 0: TempBuffer 30 | 76×76 | 小分辨率辅助 |
| 10 | Particles | Color 0: TempBuffer 29 | 76×76 | |
| 11 | Particles | Color 0: TempBuffer 30 | 76×76 | |
| 12 | DeferredShading | Color 0: InnerTarget, Color 1: TempBuffer 28, Depth/Stencil: InnerTarget | 2292×1288 | **主延迟着色**（读 G-Buffer） |
| 13 | Sky / HeightFog | Color 0: Texture, Depth/Stencil: InnerTarget | | 天空+雾合成 |
| 14 | TAA | Color 0: TAART1, Color 1: TAAHistRT1 | | 时间性抗锯齿（读写历史缓冲） |
| 15 | Motion Blur (1) | Color 0: TempBuffer 27 | 1146×644 | |
| 16 | Motion Blur (2) | Color 0: Half Color Buffer, Color 1: Half Alpha Buffer | 半分辨率 | 运动模糊混合 |
| 17 | Bloom (downsample 1) | Color 0: TempBuffer 31 | 573×322 | 1/4 分辨率 |
| 18 | GaussBlur (1) | Color 0: TempBuffer 32 | 573×322 | |
| 19 | Bloom (mid) | Color 0: TempBuffer 31 | 573×322 | |
| 20 | GaussBlur (2) | Color 0: TempBuffer 34 | 152×158 | 1/16 分辨率 |
| 21 | GaussBlur (3) | Color 0: TempBuffer 35 | 152×158 | |
| 22 | GaussBlur (4) | Color 0: TempBuffer 34 | 152×158 | |
| 23 | Bloom (composite) | Color 0: _MHYBloomTex | | 泛光合成 |
| 24 | Uber (Tonemapping) | Color 0: Texture | | 最终色调映射 |
| 25 | UI | Color 0: Texture, Depth, Stencil | | UI 渲染到最终 backbuffer |

## Attachment 依赖链

### 主渲染目标 (InnerTarget of LoginCamera(Clone))

```
RE 3 (G-Buffer) ──写入──→ InnerTarget Color 0/1/2 + Depth + Stencil
                                     │
RE 12 (DeferredShading) ──读取 G-Buffer，写入 InnerTarget Color 0──→
                                     │
RE 13 (Sky + HeightFog) ──写入 InnerTarget Color 0，读取 Depth──→
                                     │
RE 14 (TAA) ──读取 InnerTarget，写入 TAART1 + TAAHistRT1──→
```

### TempBuffer 23 (Shadow/AO 深度)

```
RE 4 ──写入 TempBuffer 23 (Depth/Stencil)──→ RE 8 ──读取 Depth/Stencil
```

### Bloom 级联

```
RE 17 (573×322) ──→ TempBuffer 31 ──→ RE 18 (GaussBlur) ──→ TempBuffer 32
                                      RE 19 ──→ TempBuffer 31
RE 20 (152×158) ──→ TempBuffer 34 ──→ RE 21 ──→ TempBuffer 35
                                      RE 22 ──→ TempBuffer 34
RE 23 ──→ _MHYBloomTex ──→ RE 24 (Uber 读取)
```

### 分辨率层级

| 层级 | 分辨率 | 用途 |
|------|--------|------|
| 全分辨率 | 2292×1288 | InnerTarget, DeferredShading |
| 应用分辨率 | 1146×644 | Shadow/AO, MotionBlur, TAA |
| 1/4 | 573×322 | Bloom 第一级 |
| 1/16 | 152×158 | Bloom 第二级 |
| 辅助 | 128×128 | HeightFog LUT, WeatherMap |
| 辅助 | 256×256 | ErosionSector |
| 辅助 | 76×76 | WindMap, Particles |
| 阴影 | 2048×2048 | 级联阴影图 |

## 关键观察

1. **InnerTarget 是核心渲染目标**：G-Buffer → DeferredShading → Sky → TAA 都围绕它
2. **TempBuffer 23 跨 RE 复用**：作为 Depth/Stencil 在 RE 4 和 RE 8 间共享
3. **Bloom 使用乒乓缓冲**：TempBuffer 31/32（1/4 分辨率）和 34/35（1/16 分辨率）交替读写
4. **2048×2048 阴影图**：RE 5 是唯一的纯深度 pass，用于级联阴影
5. **分辨率梯度清晰**：全分辨率 → 1/2 → 1/4 → 1/16，典型的移动端优化策略
