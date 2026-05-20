## 最终目标

- 在**不依赖 Xcode GUI 手工点按**的前提下，尽量分析并暴露截帧 replay 分析所需的各种 API 接口。
- 优先拿到**只读、低风险、可自动化**的接口；再逐步推进到 replay 触发、counter 配置、shader profiler 数据获取。
- 最终交付物固定为三类：
  - **bridge 调用层**：提供给客户端稳定调用，优先 CLI/脚本/JSON 输出。
  - **自动验证链路**：能由 agent 自主完成的静态验证、动态扫描、最小样本测试。
  - **持续维护文档**：本 dashboard、execution 记录、必要子文档。

## 全局约束

- 只做与**当前最高优先级**任务直接相关的工作；禁止顺手推进次级任务。
- 不得把用户现有未提交改动纳入 commit；提交仅包含本任务新增或必要修改文件。
- 优先使用**只读、低侵入**方法：静态扫描 > 动态观察 > 最小调用验证 > attach / 注入 / 替换。
- 未经用户确认，不做会明显干扰当前 Xcode replay 或系统稳定性的动作，包括但不限于：LLDB attach、代码注入、修改 Xcode 包内容、写入系统目录、关闭/重启 Xcode、替换私有 framework。
- 新增 bridge 或脚本必须优先满足：**headless、可重复执行、失败可诊断、输出 JSON**。
- 主文档保持简洁；详细发现、命令摘要、实验记录写入子文档或 `executions/`。

## 主线任务

- **当前最新进展**：
  - 已确认主线模块：`GPUDebugger.ideplugin`、`GPUToolsServices`、`GPUToolsShaderProfiler`、`GPU.instrdst`、`GPUCounters.instrdst`。
  - 已动态确认当前 replay 相关进程：`GPUToolsCompatService`、`GPUToolsAgentService`、`GPUToolsReplayService.xpc`。
  - 已确认关键锚点：`com.apple.gputools.MTLReplayer`、`com.apple.gputools.replay`、`-[DYCaptureSession _activateWithSession:serial:invalidationCompletion:initiatedByInferior:replayerLaunchDictionary:]`、`-[DYGuestAppSession hardwareCountersConfiguration]`、`-[DYDevice needsGPUToolsServiceBeforePlayback]`。
  - 已确认 `GPUToolsReplayService` 会直接读取 `.gputrace/store0`，并使用 `com.apple.gputools.GPUToolsReplayService/com.apple.metal/...` 下的 `functions.list`、`functions.data`、`libraries.list`、`libraries.data` 缓存文件。
  - **[R1.1 完成]** 已导出 `GPUToolsServices`（76 类、完整 ivar/selector）与 `GPUToolsReplay`（C API + ObjC 类）的完整清单。关键发现：`GPUToolsReplayService.xpc` 只是 thin stub，所有逻辑在 `GPUToolsReplay.framework`；后者暴露了 `GTMTLReplayController_{init,playAll,playTo,rewind}` 控制面 + `GTMTLReplay_CLI` CLI 入口 + `GTHarvesterGet*` 数据提取函数。
- **当前判断**：
  - replay 通路更像是**ObjC 私有对象模型 + XPC service + GPU/Instruments package**，而不是单一公开 C ABI。
- **当前卡点/阻塞**：
  - 还未拿到稳定、可复用的最小调用序列。
  - 还未明确 `replayerLaunchDictionary` 的最小字段集合。
  - 还未确认客户端 bridge 应优先复用 ObjC API、XPC service，还是先做只读扫描代理。
- **下一步该做什么**：
  - `R1.1` 已完成。下一步最高优先级为 `R1.2`：复原 Xcode → `GPUDebugger` → `GPUToolsCompatService` / `GPUToolsAgentService` / `GPUToolsReplayService` 的职责链。
  - 特别关注 `GTMTLReplay_CLI` 符号（可能是 headless replay 入口）和 `GTHarvesterGet*` 系列（只读数据提取）。
  - `R1.2` 完成前，严禁跳去做 bridge 实现或触发式 replay 实验。

## 构建与验证的方法

- **默认验证顺序**：
  - **V1 静态扫描**：`find`、`strings`、`nm -m`、`plutil -p`、`grep`，面向 Xcode 私有模块、package、plist、文档资源。
  - **V2 动态观察**：`pgrep`、`ps`、`lsof`、`sample 1 1`，面向当前运行中的 Xcode / replay 相关进程。
  - **V3 bridge 干跑**：新增 bridge 后，必须先提供 `--json`、`--dry-run` 或等效只读模式；先做语法检查，再对活动 replay 或离线样本执行最小查询。
  - **V4 最小样本测试**：优先验证只读输出是否稳定、字段是否可复现；能不触发新 replay 就不触发。
- **平时的构建/验证原则**：
  - 优先利用**当前正在 replay 的 Xcode**做动态观察。
  - 没有活动 replay 时，优先退回静态扫描和离线样本，不要求用户介入。
  - 新增 Python 脚本优先用 `python3 -m py_compile`；新增 Swift/ObjC 小工具优先做 `swiftc -typecheck` 或等效最小编译检查；仅在任务确实需要时再进入功能测试。
- **必须先得到用户确认的情况**：
  - 需要写 workspace 外目录。
  - 需要 attach / 注入 / 提权 / 修改 Xcode 或系统文件。
  - 需要用户手动操作 UI 才能继续，而现有静态扫描、动态观察、离线样本都不足以推进当前最高优先级任务。

## agent的工作流程介绍
1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。手头所有工作都搁置，不要进行收尾、git commit。等待用户指示
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的executions文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

- **[DONE][P0] R0**：建立 dashboard、execution 记录与基线扫描子文档。
  - **[DONE][P0] R0.1**：确认文档目录结构与维护规则。
  - **[DONE][P0] R0.2**：完成首轮静态/动态入口扫描并整理基线结论。
- **[TODO][P0] R1**：提取 replay 通路最小对象图与参数面。
  - **[DONE][P0] R1.1**：导出 `GPUToolsServices` / `GPUToolsReplayService` 的类、selector、ivar、property 清单。详见 `executions/20260520-R1.1-class-selector-export.md`。
  - **[TODO][P1] R1.2**：复原 Xcode → `GPUDebugger` → `GPUToolsCompatService` / `GPUToolsAgentService` / `GPUToolsReplayService` 的职责链。
  - **[TODO][P1] R1.3**：标记 `replayerLaunchDictionary` / `hardwareCountersConfiguration` 的候选字段并做静态比对。
- **[TODO][P1] R2**：产出只读 bridge 原型。
  - **[TODO][P1] R2.1**：设计 CLI / JSON schema，至少覆盖 `scan-active-replay`、`scan-binaries`、`inspect-gputrace` 三类能力。
  - **[TODO][P1] R2.2**：实现最小只读 bridge，不触发 replay。
  - **[TODO][P1] R2.3**：完成 dry-run 与样本输出稳定性测试。
- **[TODO][P2] R3**：尝试最小 replay / profiler 调用。
  - **[TODO][P2] R3.1**：构造最小 `replayerLaunchDictionary` 候选。
  - **[TODO][P2] R3.2**：探索 counter / shader profiler 配置注入点。
  - **[TODO][P2] R3.3**：验证是否能产出可消费的 replay / profiler 结果。
- **[TODO][P3] R4**：客户端可用性收尾。
  - **[TODO][P3] R4.1**：稳定 bridge 接口、错误码与 JSON schema。
  - **[TODO][P3] R4.2**：补充客户端调用样例与回归样本。
  - **[TODO][P3] R4.3**：清理 dashboard 与子文档引用，形成长期维护结构。

## 高频复用经验

- **动态确认 replay 是否真的在跑**：优先看 `pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`；若出现 `GPUToolsReplayService.xpc`，说明已进入更深的 replay 通路。
- **当前最高信号的动态命令**：`lsof -p <pid>`。它能直接告诉你哪个进程在读 `.gputrace/store0`、`device-resources-*` 或 replay 缓存文件。
- **当前最高信号的静态锚点**：`GPUDebugger`、`GPUToolsServices`、`GPUToolsReplayService`、`GPUToolsShaderProfiler` 四个二进制上的 `strings` / `nm -m` 结果。
- **当前最有价值的已确认缓存路径**：`/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/...`，其中的 `functions.*` / `libraries.*` 值得持续跟踪，但路径本身可能随系统或会话变化。
- **Instruments package 文档可快速对齐 schema**：`GPU.instrdst` 对应 `com.apple.gpu-tracing`；`GPUCounters.instrdst` 对应 `com.apple.gpu-counters`，适合拿来对齐 counters 与 modeler 语义。

## 参考信息

- **必须读取**：`subdocs/20260520-replay-entry-scan.md`。这里记录了当前已确认的进程、模块、符号、缓存路径与判断依据。
- **按具体需求读取**：`../OfflineSourceRecovery/scripts/README_extract_shader_raw.md`。仅在需要把 replay 自动化与 shader/raw 提取链路对齐时阅读。
