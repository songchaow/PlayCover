# 原神 (Genshin Impact) 单帧渲染流程

## 概述

- **游戏**: 原神 (com.miHoYo.Yuanshen) — 登录大厅场景
- **捕获**: `capture_20260401_011127.gputrace` (23 帧多帧捕获)
- **每帧结构**: 26 Render Encoder + 1 presentDrawable
- **每帧 Draw Call**: ~5,300
- **渲染管线**: **延迟渲染 + 卡通着色混合** (Deferred + Toon Hybrid)

---

## 渲染管线总览

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                      STAGE 1: 预处理 (RE 0-2)                          │
 │  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────────────┐  │
 │  │ RE 0         │  │ RE 1             │  │ RE 2                     │  │
 │  │ HeightFog LUT│  │ Weather Map      │  │ Erosion Sector           │  │
 │  │ 128×128      │  │ 128×128          │  │ 256×256 (2 RT)           │  │
 │  └──────────────┘  └──────────────────┘  └──────────────────────────┘  │
 ├─────────────────────────────────────────────────────────────────────────┤
 │                    STAGE 2: G-Buffer (RE 3-8)                          │
 │  ┌─────────────────────────────────────────────────┐                   │
 │  │ RE 3: Login Base — 主 G-Buffer 写入              │                   │
 │  │ → Color 0/1/2 + Depth + Stencil                 │                   │
 │  │ → InnerTarget of LoginCamera(Clone)              │                   │
 │  │ (含 8 个 Login Base shader sub-pass)              │                   │
 │  └─────────────────────────────────────────────────┘                   │
 │  ┌──────────────┐  ┌────────────────┐  ┌──────────────────────────┐   │
 │  │ RE 4         │  │ RE 5           │  │ RE 6-8                   │   │
 │  │ SS-Shadow/AO │  │ Shadow Map     │  │ 补充几何渲染              │   │
 │  │ 1146×644     │  │ 2048×2048      │  │ 1146×644                 │   │
 │  │ (Depth only) │  │ (Depth only)   │  │                          │   │
 │  └──────────────┘  └────────────────┘  └──────────────────────────┘   │
 ├─────────────────────────────────────────────────────────────────────────┤
 │                    STAGE 3: 光照 (RE 9-12)                             │
 │  ┌──────────────────┐ ┌────────────────┐ ┌──────────────────────────┐ │
 │  │ RE 9-11          │ │ RE 12          │ │ Inputs:                  │ │
 │  │ Wind/Particles   │ │ Deferred       │ │ • G-Buffer (InnerTarget) │ │
 │  │ SS-Shadow, SSAO  │ │ Shading        │ │ • Shadow Map (2048²)     │ │
 │  │ ToonLightBuffer  │ │ → InnerTarget  │ │ • SSAO / SS-Shadow       │ │
 │  │ GaussBlur        │ │ + TempBuffer28 │ │ • ToonLightBuffer        │ │
 │  │ 76×76 / 1146×644 │ │ 2292×1288      │ │                          │ │
 │  └──────────────────┘ └────────────────┘ └──────────────────────────┘ │
 ├─────────────────────────────────────────────────────────────────────────┤
 │                    STAGE 4: 天空 + 雾 (RE 13)                          │
 │  ┌─────────────────────────────────────────────────────────────────┐   │
 │  │ Atmosphere → Stars → Moon → Cloud Particle → Cloud Layer → Fog │   │
 │  │ → 写入 InnerTarget Color 0，读取 Depth 做远近排序              │   │
 │  └─────────────────────────────────────────────────────────────────┘   │
 ├─────────────────────────────────────────────────────────────────────────┤
 │                 STAGE 5: 后处理链 (RE 14-24)                           │
 │                                                                        │
 │  RE 14: TAA ──→ TAART1 + TAAHistRT1                                   │
 │    ↓                                                                    │
 │  RE 15-16: Motion Blur ──→ Half Color/Alpha Buffer                     │
 │    ↓                                                                    │
 │  RE 17-23: Bloom 级联                                                   │
 │    ┌─ RE 17: Downsample (573×322) ─→ TempBuffer 31                    │
 │    ├─ RE 18: GaussBlur ─→ TempBuffer 32                               │
 │    ├─ RE 19: Mid ─→ TempBuffer 31                                     │
 │    ├─ RE 20: GaussBlur (152×158) ─→ TempBuffer 34                     │
 │    ├─ RE 21-22: GaussBlur ping-pong ─→ TempBuffer 34/35               │
 │    └─ RE 23: Composite ─→ _MHYBloomTex                                │
 │    ↓                                                                    │
 │  RE 24: Uber (Tonemapping + Color Grading + LUT)                       │
 │                                                                        │
 ├─────────────────────────────────────────────────────────────────────────┤
 │                    STAGE 6: UI (RE 25)                                  │
 │  ┌─────────────────────────────────────────────┐                       │
 │  │ UI/Default → 最终 backbuffer + Depth/Stencil │                       │
 │  └─────────────────────────────────────────────┘                       │
 │                          ↓                                              │
 │                   presentDrawable                                       │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

## 详细流程

### Stage 1: 预处理 (RE 0-2)

生成后续渲染需要的辅助纹理数据。

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 0 | Hidden/Internal-HeightFog | TempBuffer 15 (128×128) | 高度雾查找表 |
| 1 | Dynamic Sky/Generate Weather Map | TempBuffer 4 (128×128) | 程序化天气参数纹理 |
| 2 | Hidden/Internal-ErosionSectorRender | TempBuffer 18+19 (256×256) | 地形侵蚀细节 (双 RT) |

### Stage 2: G-Buffer / 几何渲染 (RE 3-8)

核心的场景几何渲染阶段。

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 3 | miHoYo/Scene/Login Base ×8 | **InnerTarget** Color 0/1/2 + Depth + Stencil | 主 G-Buffer：漫反射/法线/材质参数 |
| 4 | miHoYo/Scene/Login Base | TempBuffer 23+24 (1146×644) + Depth | 辅助几何 / Screen-space 预处理 |
| 5 | (Shadow Pass) | TempBuffer 25 (2048×2048, Depth only) | **级联阴影图** |
| 6 | Hidden/Internal-DepthDownSample | TempBuffer 16 (512×512) | 深度降采样（供 SSAO/SSR 使用） |
| 7 | miHoYo/Scene/Login Base | TempBuffer 26 (1146×644) | 补充场景渲染 |
| 8 | miHoYo/Scene/Login Base | TempBuffer 27 (1146×644) + Depth(23) | 半透明/细节物体渲染 |

### Stage 3: 光照计算 (RE 9-12)

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 9 | Nature/LocalWindsMapReproject, Particles | TempBuffer 30 (76×76) | 风场图 + 粒子 |
| 10 | SS-Shadow, SSAO, Particles | TempBuffer 29 (76×76) | 屏幕空间阴影 + 环境遮蔽 |
| 11 | ToonLightBuffer, GaussBlur | TempBuffer 30 (76×76) | **卡通光照缓冲** + 模糊 |
| 12 | **DeferredShading ×3** | **InnerTarget** + TempBuffer 28 (2292×1288) | 延迟光照合成：方向光/点光/探针 |

**核心**: RE 12 是延迟着色 pass，读取 G-Buffer + 阴影图 + SSAO + ToonLightBuffer，计算最终光照写回 InnerTarget。

### Stage 4: 天空 + 高度雾 (RE 13)

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 13 | Atmosphere + Stars + Moon + Cloud + CloudLayer + HeightFog | InnerTarget (读 Depth 做排序) | 5 层天空系统 + 高度雾合成 |

天空在光照之后渲染，利用深度缓冲正确处理远近关系。

### Stage 5: 后处理链 (RE 14-24)

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 14 | TemporalAntialiasing | TAART1 + TAAHistRT1 | TAA (读取当前帧 + 历史帧) |
| 15 | Motion Blur (pass 1) | TempBuffer 27 | 运动模糊 tile max |
| 16 | Motion Blur (pass 2) | Half Color + Half Alpha Buffer | 运动模糊 gather (半分辨率) |
| 17 | Bloom (downsample) | TempBuffer 31 (573×322) | 亮度提取 + 1/4 降采样 |
| 18 | GaussBlur | TempBuffer 32 (573×322) | 水平/垂直模糊 |
| 19 | Bloom (mid) | TempBuffer 31 | 中间处理 |
| 20-22 | GaussBlur ×3 | TempBuffer 34/35 (152×158) | 1/16 分辨率 ping-pong 模糊 |
| 23 | Bloom (composite) | _MHYBloomTex | 多级泛光合成 |
| 24 | **Uber** | Final texture | **色调映射 + 颜色分级 + LUT** |

### Stage 6: UI (RE 25)

| RE | Shader | 输出 | 说明 |
|----|--------|------|------|
| 25 | UI/Default | Backbuffer + Depth + Stencil | UI 元素叠加到最终图像 |

→ **presentDrawable** 提交到显示

---

## 技术特征总结

### 渲染架构
- **延迟渲染 + 卡通着色混合管线**
- G-Buffer 包含至少 3 个 Color attachment + Depth + Stencil
- 卡通光照 (ToonLightBuffer) 在延迟着色之前计算，混合进最终光照

### 分辨率层级
| 层级 | 分辨率 | 用途 |
|------|--------|------|
| 超采样 | 2292×1288 | DeferredShading 主输出 |
| 应用 | 1146×644 | 大部分中间渲染 |
| 1/4 | 573×322 | Bloom 第一级 |
| 1/16 | 152×158 | Bloom 第二级 |
| 阴影 | 2048×2048 | 级联阴影图 |
| 辅助 | 128×128 ~ 256×256 | LUT / 天气 / 地形 |

### 后处理管线
TAA → Motion Blur (2 pass) → Bloom (7 pass, 多级 Gauss) → Uber → Copy

### 性能特征
- 每帧 ~5,300 draw call
- 50 个独特 pipeline state
- 26 个 render pass
- 显著优化：阴影图仅深度、Bloom 使用 ping-pong 缓冲、半分辨率运动模糊

---

## 数据来源

- T1: Command Buffer 概览 → `01-command-buffer-overview.md`
- T2: Render Pass 摘要 → `02-render-pass-summary.md`
- T3: 管线阶段划分 → `03-pipeline-stages.md`
- T4+T5: 绑定详情与依赖链 → `04-key-pass-details.md`
- 原始数据: `cb_data.json`, `key_pass_details.json`
