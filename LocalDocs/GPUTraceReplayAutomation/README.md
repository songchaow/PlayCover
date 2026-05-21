## 最终目标

**使 CLI 模式下的 GPU 截帧 replay 在功能上尽可能等价于 Xcode GUI 窗口内的 replay 以及分析调试等操作。**

等价性定义 — Xcode GUI replay 窗口内能做的事，CLI 下均应能以编程方式完成：

| 能力维度 | CLI 等价目标 | 状态 |
|----------|-------------|------|
| Replay 执行 | headless 重放任意 .gputrace | ✅ |
| 帧/draw call 导航 | `playTo(controller, targetCallIndex)` | ✅ |
| 纹理/Buffer 查看 | ObjectMap → getBytes/contents 导出 | ✅ |
| Pipeline 查看 | libraryDataContents/bitcodeData 导出 | ✅ |
| Shader 热替换 | setLibrary:forKey: + rewind+playAll | ✅ |
| Shader Debug | instrumented debug 替代方案 | ⚠️ 部分 |
| Configuration 修改 | 调用链控制 + 全局变量 | ✅ |
| 输出自动化 | bridge JSON/bin 导出 | ✅ |
| **Encoder/Pass/Draw 时间序枚举** | `frame-list` 子命令 | ⏳ R7.3 |
| **RPS↔shader 关联** | `pipeline` 输出 vertex/fragment function/lib key + attachment | ✅ R7.2 |
| **RPS → shader IR 反查** | `shader-of-rps` 子命令（含 `--with-ir`） | ✅ R7.4 |
| **Draw call → shader IR 反查** | `shader-of-drawcall` 子命令 | ⏳ R7.6 |
| **Depth/Stencil 可视化** | bridge 内置 blit + export | ⏳ R7.5 |
| **Uniform / cbuffer 内容查看** | `dump-uniforms` 子命令 | ⏳ R7.6 |
| **Shader 反编译（IR 直接产出）** | `disasm` 子命令集成 cacheKey + llvm-dis | ⏳ R7.7 |
| GPU Counters / Profiler / Derived | 需 Apple 私有 entitlement + SIP 关闭 | ⛔ 跳过 |

**完成度**：R0~R6 已完成（基础能力 + bridge + Python wrapper + skill 打包）；R7.1 + R7.2 + R7.4 已完成（bridge 6 子命令 / 63 集成测试 / RPS↔shader 一行命令拿 IR 闭环）；R7.3/R7.5/R7.6/R7.7 为剩余主线（按依赖顺序进行）。

最终交付物：
1. **统一 ObjC bridge CLI**（`Scripts/gputrace_replay_bridge.m`）— ✅ 6 子命令，Makefile 构建，集成测试 63/63 通过
2. **Python CLI wrapper**（`Scripts/gputrace_replay_wrapper.py`）— ✅ CLI + 模块双接口，dataclass 返回值（含 R7.2 `ColorAttachment` / R7.4 `ShaderOfRpsResult`）
3. **端到端验证链路** — ✅ LYSK trace 65/65 RPS 反查通过 + `shader-of-rps --with-ir` 出 `.ll`
4. **GPU Trace 分析 skill**（`.codebuddy/skills/gpu-trace-analysis/`）— ✅ 自包含，含 SKILL.md + scripts/ + references/，从任意目录可独立运行
5. **R7：Frame-Inspection 能力补全** — ⏳ 进行中，剩余 4 个独立 chunk（R7.3/R7.5/R7.6/R7.7，详见 TODO + `subdocs/20260521-R7-frame-inspection-gap.md`）

## 全局约束

- 只做与**当前最高优先级**任务直接相关的工作；禁止顺手推进次级任务。
- 不得把用户现有未提交改动纳入 commit；提交仅包含本任务新增或必要修改文件。
- 优先使用**只读、低侵入**方法：静态扫描 > 动态观察 > 最小调用验证 > attach / 注入 / 替换。
- 未经用户确认，不做会明显干扰当前 Xcode replay 或系统稳定性的动作。
- 新增 bridge 或脚本必须优先满足：**headless、可重复执行、失败可诊断、输出 JSON**。
- 主文档保持简洁；详细发现写入子文档。

## 主线任务

### 已建立的核心知识

- **主线模块链**：`GPUDebugger.ideplugin` → `GPUToolsServices`(76 类) → XPC Services → `GPUToolsReplay.framework`(C API)
- **主力路径 — Controller 路径**（R4.2）：`makeDataSource → makeController → playAll/playTo` — 完整 replay + 对象访问 + 定向 replay，无 XPC/entitlement 依赖。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
- **Pipeline Binary 导出**：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 偶数=Library，奇数=Function，规则：`library_key = function_key - 1`
- **Shader 热替换**：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Configuration**：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **Call-index 边界**（R7.1）：`*(uint32_t *)(controller + 0x5810)` = last played call index；`playAll` 完成后即 trace 总 call 数；bridge 已加 `--bounds` / OOR 结构化错误（exit 12） / SIGSEGV 兜底；texture/buffer 元数据全补齐。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.1
- **RPS↔shader 内置关联**（R7.2）：bridge 在 `replay_context_init` 之前装 method swizzling（`MTLDevice newRenderPipelineStateWithDescriptor:[options:reflection:]error:` 三个变体），把每对 (descriptor, RPS) 落到 `g_rps_captured[]`；`pipeline` dump 时给每个 RPS 加 `vertex/fragment function key` / `library key (= fn-1)` / `color_attachments[]` / `depth_format` / `stencil_format` / `raster_sample_count`。`rps_correlated_count` / `rps_captured_count` 是 swizzle 健康度指标，0 或不匹配表示 swizzle 失效。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.2
- **`shader-of-rps` 子命令**（R7.4）：一行命令从 RPS_key 拿 fragment/vertex 的 metallib + AIR + `cache_key_metallib`；`--with-ir` 自动调 `llvm-dis` 产出 `.ll`。失败结构化（rps_not_found / descriptor_not_captured / stage_function_absent / no_air_bitcode / llvm_dis_not_found），exit 11 但 JSON 完整保留。AIR 覆盖率较低（LYSK 96 lib 中仅 3 个有 `bitcodeData`）— R7.7 通过 SDI module.bc 路径补足。详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.4
- **统一 Bridge**（R6.1+）：`Scripts/gputrace_replay_bridge.m` — 6 子命令（help/replay/pipeline/shader/shader-of-rps/config），Makefile 构建 + ad-hoc 签名 + 集成测试 63/63 通过。详见 `subdocs/20260520-R6.1-bridge-implementation.md`
- **Python wrapper + skill 打包**（R6.2）：`Scripts/gputrace_replay_wrapper.py` + `.codebuddy/skills/gpu-trace-analysis/`。详见 `subdocs/20260521-R6.2-wrapper-and-skill.md`
- **R7 缺口诊断**：`pipeline` 缺 RPS↔shader 关联（→ ✅ R7.2）；无 encoder/draw 时间序（→ ⏳ R7.3 swizzle-first，同时附带 draw→RPS 映射）；depth/stencil 不能 export（→ ⏳ R7.5）；7 段 draw→IR 反查链已 6/7 通过，剩段 1 与 R7.3 同 chunk 解决。详见 `subdocs/20260521-R7-frame-inspection-gap.md`

### 当前卡点

无。R7.2 + R7.4 完成（2026-05-21）。

### 下一步（当前最高优先级）

**R7.3：`frame-list` 子命令（swizzle-first 路径）**—— 同时打通 encoder 列表 + draw→RPS 映射

优先级理由（2026-05-21 重新评估，与原计划相比方向有调整）：
1. R7.2 + R7.4 已通：`pipeline` 一行命令出 RPS↔shader 全表，`shader-of-rps --with-ir` 一行从 RPS_key 拿 IR；从 RPS 视角的"语义级反查"闭环完整。
2. 距离用户最终目标（draw call → IR）只剩"段 1：draw → RPS_key"未通。原方案把这段拆成 R7.3（反射 controller.commandBuffers）+ R7.6 段 1（swizzle setRenderPipelineState/draw\*），但 **bridge 已有的 `rps_install_swizzles` 基础设施完全可以一次同时安装这两组 swizzle**，让一次 `playAll` 同时收集 encoder 列表与 draw→RPS 映射 — 比反射 controller 内部布局更安全（公开 API，无未导出符号风险）、工时更短（合并为同一冲刺 1.5–2 天）、并直接附带 R7.6 段 1 的产出。
3. R7.3 完成后副产品：① `--playto` 从盲扫升级为定向跳转（`encoder.first_call_index`）；② R7.6 子项 C `shader-of-drawcall` 退化为薄封装（用 R7.3 输出的 `draw_to_rps_map` 转发到 `shader-of-rps`）；③ compute encoder 与 R7.5 子项 B 顺手解决（同一 swizzle 集合）。

R7.3 具体内容（详见 `subdocs/20260521-R7-frame-inspection-gap.md` §5.3）：
- 在 `replay_context_init` 之前同时安装：`MTLCommandQueue.commandBuffer*` / `MTLCommandBuffer.{render,compute,blit}CommandEncoder*` / `MTLRenderCommandEncoder.{setRenderPipelineState:, drawPrimitives:*, drawIndexedPrimitives:*, endEncoding}`
- 数据结构：`g_cb_captured[256]` / `g_encoder_captured[1024]` / `g_draws_captured[16384]`（与 R7.2 同样的进程级单例）
- `first/last_call_index` 实时读 `*(uint32_t *)(controller + 0x5810)`（R7.1 已确认）
- 顶层输出 `command_buffers[].encoders[].draws[]` 树 + 扁平化 `draw_to_rps_map[]` 视图
- `--with-timing`：`MTLCommandBuffer.GPU{Start,End}Time`；`--with-draws` 默认开启；`--with-bindings` 留给 R7.6 子项 A

## 构建与验证的方法

- **构建**：`cd Scripts/ && make`（编译 + ad-hoc 签名）；`make test`（集成测试 63 项）；`make clean`
- **验证分级**：V1 静态扫描 → V2 动态观察 → V3 bridge 干跑 → V4 最小样本测试
- **平时原则**：优先利用当前正在 replay 的 Xcode 做动态观察；无活动 replay 时退回静态/离线样本
- **须用户确认**：写 workspace 外目录 / attach / 注入 / 提权 / 修改系统文件 / 需要 UI 手操

## agent的工作流程介绍
1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。手头所有工作都搁置，不要进行收尾、git commit。等待用户指示
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的executions文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

- **[DONE] R0~R5**：基线扫描 → API 提取 → bridge 原型 → headless replay → 数据获取 → 操作等价
- **[DONE] R6**：客户端封装与可用性收尾
  - **[DONE] R6.1**：统一 ObjC bridge binary — 5 子命令 + Makefile + 集成测试 17/17
  - **[DONE] R6.2a**：端到端动态验证（2 样本 × 5 子命令，29/29 集成测试通过）
  - **[DONE] R6.2b**：Python CLI wrapper（CLI + 模块双接口，dataclass 返回值）
  - **[DONE] R6.2c**：skill 打包（`.codebuddy/skills/gpu-trace-analysis/`，自包含 + 17/17 通过）
- **[CANCELLED] R6.3**：自动化流水线集成（CI/CD + 样本库管理）— 不做
- **[IN-PROGRESS][P0] R7**：Frame-Inspection 能力补全（详见 `subdocs/20260521-R7-frame-inspection-gap.md`）
  - **[DONE] R7.1**：bridge 越界保护 + 资源元数据补齐 — `total_call_count` / `last_call_index` / `--bounds` / `playto_out_of_range`(exit 12) / SIGSEGV 兜底 / texture+buffer storageMode/usage/hazardTracking 等
  - **[DONE] R7.2**：`pipeline` 输出加 RPS↔shader 关联（vertex/fragment function/library key + attachment 摘要 + raster sample count，bridge 内置 swizzle）。LYSK 65/65 RPS 反查通过
  - **[DONE] R7.4**：`shader-of-rps` 子命令（语义级反查 + `--with-ir` 调 `llvm-dis` 直出 `.ll` + `cache_key_metallib`），与 R7.2 同冲刺完成
  - **[P1] R7.3（swizzle-first）**：`frame-list` 子命令 — encoder 列表 + draw→RPS 映射 + per-encoder timing 一次冲刺打通；包含 compute/blit encoder。1.5–2 天，低风险（全公开 API + 复用 R7.2 swizzle 框架）。**当前最高优先级**
  - **[P1] R7.5**：depth/stencil export（bridge 内置 blit）— 0.5 天。compute encoder 部分已并入 R7.3
  - **[P1] R7.6（范围收窄）**：`frame-list --with-bindings` + `dump-uniforms` + `shader-of-drawcall`（薄封装 — 直接复用 R7.3 输出的 `draw_to_rps_map` 转发到 R7.4 内部逻辑）— 3 天合计
  - **[P2] R7.7**：`disasm` 子命令（直接读 SDI module.bc，覆盖无 AIR 的 library）— 1.5 天，低风险，**skill 自包含最后一公里**
- **每个 R7 chunk 落地后必须同步**：SKILL.md（"Exploring an unknown trace's pipeline" 工作流） + `references/investigation-playbook.md`（frame-overview worked example） + `references/cli-reference.md`（新子命令 schema）

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 看进程读哪些 gputrace/缓存文件
- **最高信号静态锚点**：`GPUToolsReplay`、`GPUToolsServices` 上的 `strings` / `nm -m`
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)
- **探针编译模板**：`clang -framework Foundation -framework Metal -ldl -lobjc -o <probe> <probe>.m`
- **PSO→Function 关联拦截**：method swizzling `MTLDevice -newRenderPipelineStateWithDescriptor:[options:reflection:]error:`，必须在 `init_replay()` 之前装；类要找具体实现类（如 `AGXG16SDevice`）— 已合入 bridge 的 `rps_install_swizzles()`，`Scripts/gputrace_replay_bridge.m` 里参考实现

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260521-R7-frame-inspection-gap.md` | **总是建议读取** — R7 是当前主线，本文档是入口 | 14 处卡点（已解决/未解决标注） / 7 段 draw→IR 反查 / 改进矩阵 7 chunk（含 R7.1/R7.2/R7.4 完整交付摘要 + 端到端实测） / LYSK 65 RPS 回归基线 |
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是所有任务的基础 | 完整调用链、偏移表、ObjectMap、playTo、Pipeline 导出 |
| `subdocs/20260520-R6.1-bridge-implementation.md` | 在改 bridge 子命令实现 / 加新子命令时按需读取 | 子命令架构、JSON schema、构建方法、测试覆盖 |
| `subdocs/20260521-R6.2-wrapper-and-skill.md` | 在使用 Python wrapper / 改造 skill 时按需读取 | wrapper API、skill 目录结构、自包含验证、设计决策 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在扩展 shader 替换功能时按需读取 | 替换路径对比、Xcode UI 能力缺口 |
| `subdocs/20260520-R5.3-shader-debug.md` | 在探索 IPC/debug 后续方向时按需读取 | ShaderDebug 类族、instrumented debug、IPC 探索结论 |
| `subdocs/20260520-R5.4-configuration.md` | 在扩展 config 功能时按需读取 | 13 属性映射、Service 路径 |
| `subdocs/20260520-R1.1-api-inventory.md` | 一般无需读取（仅在查 GPUToolsReplay 导出符号 / 76 类清单时按需） | 二进制导出符号、GPUToolsServices 类清单、Harvester blob 格式 |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | 一般无需读取（XPC 路径不使用） | Fetch/Query/Profile/ShaderDebug/Update 类族接口 |
| `subdocs/20260520-R3-headless-replay.md` | 一般无需读取（已被 Controller 路径取代，仅 APR/Options 偏移表查阅时用） | APR bootstrap、Options 布局、CLI 能力边界 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取（已被 R3 取代） | CLI 函数签名 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取（headless 路径不依赖字典） | XPC 三层字典字段 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（已被 R6.1 ObjC bridge 取代） | 早期 Python bridge CLI schema |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取 | R0 基线：模块/进程/符号 |
| `LocalDocs/OfflineSourceRecovery/scripts/rps_swizzle_probe.m` | 一般无需读取（核心算法已合入 bridge）；仅在 `rps_correlated_count` 异常时作回归对照 | ~200 行 ObjC 探针，已在 LYSK trace 验证 65 RPS 反查 |
