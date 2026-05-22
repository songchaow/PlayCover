# LYSK GPU Trace 渲染管线分析

> **样本**：`~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/capture_20260518_110050.gputrace`
> **应用**：恋与深空（`com.papegames.lysk`，Unity + Asuka/Papegame 自研渲染框架）
> **设备**：Apple Silicon（M 系列 / `AGXG16XFamilyComputePipeline`）
> **分析时间**：2026-05-21
> **分析工具**：`.codebuddy/skills/gpu-trace-analysis/`（headless replay bridge / R7.7）

## 这份文档的目的

把 `capture_20260518_110050.gputrace` 这一帧（其实是两帧，双缓冲）里的整体渲染设计、每个 pass 的用途、产物、以及产物在下游的消费关系**全部摸清并固化下来**，作为后续：

- 调试 `Papegame/SkinMakeupNew` / `SeparableSubsurfaceScatter` 等具体 pass（`OfflineSourceRecovery/`）的全局坐标系；
- 评估「在哪一段动手」的最小代价路径；
- 跨多个 trace 做差分对比时的基线模板。

## 一句话结论

> 这是一段 **Unity URP-like 自研管线 + Papegame 后处理栈** 的双帧捕获：
> **`Z-Prepass → Cascade/Local Shadows → "Velocity + Normal" Pre-pass (1167×1671 RGBA8×2 + D32S8) → Half-res SSAO/SSS-Lighting → Separable SSS → Full-res HDR Forward Compose + Sky + FX (1167×1671 RGBA16F) → DOF → TAA (双历史 ping-pong) → Bloom (5 级金字塔) → Tonemap → FSR EASU (1167×1671 → 1668×2388) → FSR RCAS + UI 叠加 → Present`**，外加一个 `CalcLighting.CSMain` compute pass 做 cluster lighting。
>
> **架构要点**：E4 (228/229) 是 **Velocity + Normal Pre-pass**（不是 deferred GBuffer，详见 `06-gbuffer-truth.md`）。LYSK 是 **forward shading**，lighting 通过重新光栅化几何 + 直接采样原始材质纹理完成，不是从 228/229 解码。

## 规模一览

| 维度 | 数 |
|---|---|
| Metal 调用总数 | 3425 |
| CommandBuffer | 4（CB0/CB2 各 1 个 blit；CB1/CB3 各 30 个 encoder，互为镜像 = 双缓冲两帧） |
| Encoder | 62（含 1 compute / 4 blit / 57 render） |
| Draw call | 244 |
| Library / RPS / CPS | 96 / 65 / 1 |
| 资源 | 247（含 swapchain×2、HDR scene buffer、影子 atlas、半分辨率/Bloom 金字塔等 Temp Buffer） |
| 渲染分辨率 → 显示 | 1167×1671 → 1668×2388（FSR 1.0） |

## 文档结构

| 文件 | 说明 |
|---|---|
| `README.md` | 本文 — 顶层入口 + 设计要点 |
| `01-architecture-overview.md` | 整体设计：双缓冲布局、9 个流水线阶段、关键数据流 DAG |
| `02-frame-breakdown.md` | CB1 一帧 30 个 encoder 的逐项 breakdown：calls / draws / RT / RPS / 用途 / 产物去向 |
| `03-rps-and-textures.md` | 65 个 RPS（label、vf/fragment、attachments）+ 关键 attachment 纹理表 |
| `04-skin-and-sss-pipeline.md` | SkinMakeupNew / SkinSSS / SeparableSubsurfaceScatter 在帧内的 5 个变体定位（与 `OfflineSourceRecovery/` 抓出的 `.ll` 文件一一对应） |
| **`06-gbuffer-truth.md`** | **重要** — 通过纹理字节统计 + fragment IR 反编译，证明 228/229 不是传统 deferred GBuffer 而是 **velocity buffer + octahedral normal mask**；LYSK 是 forward shading 不是 deferred |
| **`07-skin-forward-lighting.md`** | **重要** — 把 RPS 496 的 forward 受光剖析到字段级：每一项贡献来自哪个 cbuffer / 哪张纹理、各占多少。结论：①漫反射 ≈ 80% 由上游 SSS pass 提供（不在 RPS 496 自己算）；②主灯颜色由 cb4 `_CharMainLightColor` 提供，URP `_MainLightColor` 是引擎残留 slot 不参与渲染；③环境镜面 ≈ 0（cubemap 全黑）；④附加光走 LightIndexMap 路径仅 2 盏活跃，鼻尖/唇高光区可见 ~3–6% 冷蓝点缀；⑤本帧 sparkle 字段全 0，不贡献 |
| **`08-rps496-binding-truth.md`** | **重要** — RPS 496 / draw 69 完整 binding 真值表（vertex 10 buffer + 1 texture，fragment 7 cbuffer + 16 texture），每个 slot 给出 resource_id / 资源标签 / 大小 / pixelFormat / IR `air.arg_name` 一一对应；7 个 fragment cbuffer 的全字段实测值（cb0..cb6）。本文不分析 lighting 公式，只描述"绑了什么"——任何 lighting 语义讨论见 07。 |
| `05-reproduction.md` | 复现命令、工作目录、所用工具版本、输出 schema 速查 |
| `data/` | 原始 JSON（直接来自 bridge 输出）：`bounds / replay / pipelines / frame / cb1_summary / cb3_summary / rps_index / textures_index` |

阅读顺序建议：先 `01` 抓全局，然后 `02` 看每个 encoder 在干什么，按需跳到 `03` 查具体 RPS / 纹理，针对皮肤 SSS 工作直接跳 `04`。`05` 是工程化 / 复现入口。

## 已知盲区（不在本次结论里）

继承自当前 R7.7 的 bridge 能力边界（详见 `LocalDocs/GPUTraceReplayAutomation/subdocs/20260521-R7-frame-inspection-gap.md`）：

- **`CalcLighting.CSMain` 的 dispatch 网格大小 / threadgroup size 未捕获**（compute swizzle 子项 B 未实装）— 只能确认它存在并跑过，但 cluster cell 切分参数、tile 尺寸需另行加 swizzle 才能拿到。
- **`loadAction / storeAction` 没出现在 `frame-list` 输出里** — 本文中所有「Load=Load / Store=Store」推断都是基于「下一个 encoder 复用同一 attachment ⇒ 上游 Store + 下游 Load」的常规假设；若要严格判断 tile-based 优化是否在用 `MTLStoreActionDontCare`，还需要补 swizzle。
- **GPU 时间** — `frame-list --with-timing` 在该 trace 上 GPUStart/EndTime 为空（已知 R7 backlog）；本文不提供任何 GPU 计时结论，仅给 host-side 的 8.87ms replay 总时长作参考。

如要进一步深挖（例如把 `E1 CalcLighting.CSMain` 的 IR 拉出来，或对 CB1/CB3 做 byte-level 双缓冲对称性校验），见 `05-reproduction.md` 末尾的「extension hooks」。
