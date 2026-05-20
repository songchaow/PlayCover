## 最终目标

**使 CLI 模式下的 GPU 截帧 replay 尽可能与 Xcode GUI 窗口内 replay 等价可用。**

具体而言：
1. **Headless Replay 执行**：通过 `GTMTLReplay_CLI` 实现无 GUI 截帧重放，能对任意 `.gputrace` 样本做完整 replay。
2. **数据获取等价**：Xcode 窗口内能查看的数据（纹理、Buffer、Pipeline、GPU Counters、Shader Profiler、Derived Counters）在 CLI 下均能导出。
3. **操作等价**：Xcode 窗口内能做的 replay 交互操作（playTo 指定帧/draw call、shader 热替换、configuration 修改、shader debug）在 CLI 下均能触发。
4. **输出自动化**：所有结果以 JSON/二进制文件形式输出，便于自动化流水线消费。

优先级排序：headless replay 基础执行 > 只读数据获取 > profiling/counters > shader debug/替换 > 高级交互。

最终交付物：
- **bridge 调用层**：C/ObjC 探针 + Python CLI wrapper，提供 headless replay 全功能调用。
- **自动验证链路**：能由 agent 自主完成的静态验证、动态扫描、最小样本测试。
- **持续维护文档**：本 dashboard + 子文档体系。

## 全局约束

- 只做与**当前最高优先级**任务直接相关的工作；禁止顺手推进次级任务。
- 不得把用户现有未提交改动纳入 commit；提交仅包含本任务新增或必要修改文件。
- 优先使用**只读、低侵入**方法：静态扫描 > 动态观察 > 最小调用验证 > attach / 注入 / 替换。
- 未经用户确认，不做会明显干扰当前 Xcode replay 或系统稳定性的动作，包括但不限于：LLDB attach、代码注入、修改 Xcode 包内容、写入系统目录、关闭/重启 Xcode、替换私有 framework。
- 新增 bridge 或脚本必须优先满足：**headless、可重复执行、失败可诊断、输出 JSON**。
- 主文档保持简洁；详细发现写入子文档。

## 主线任务

### 已建立的核心知识

- **主线模块链**：`GPUDebugger.ideplugin` → `GPUToolsServices`(76 类) → XPC Services → `GPUToolsReplay.framework`(C API)
- **突破口已确认**：`GTMTLReplay_CLI` 是独立 C 函数，可 headless replay，不依赖 Xcode/GUI/XPC（详见 R1.2 子文档）
- **CLI 签名已完整逆向**：`int GTMTLReplay_CLI(const char *path, GTMTLReplayCLIOptions *options, void (*callback)(NSData*, NSURL*))` — options 结构体 ~0xC0 字节，关键偏移已标注（详见 R1.2 子文档）
- **三层字典结构已标记**：L1(启动)、L2(replayer)、L3(profiling)，但 CLI 路径不需要这些字典（详见 R1.3 子文档）
- **只读 bridge 已交付验证**：`Scripts/gputrace_bridge.py` 含 3 个子命令（scan-active-replay, scan-binaries, inspect-gputrace），纯 Python 标准库，全部通过 dry-run 与实际运行测试（详见 R2.1 子文档）
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)、`MTLREPLAYER_OVERRIDE_DEVICE_REGISTRY_ID`(GPU 覆盖)
- **XPC 传输层完整 API**：`GTMTLReplayServiceXPCProxy` 暴露 fetch/query/profile/shaderdebug/update 完整操作集 — 这定义了 Xcode GUI 所有 replay 操作的完整范围（详见 R1.1b 子文档）
- **Shader 热替换路径**：`GTReplayUpdateLibrary`(shaderSource/shaderIR/shaderURL) 直接支持运行时 shader 替换
- **GPU 硬件计数器**：`GPURawCounter.framework` 提供 `GRCCopyAllCounterSourceGroup` 低层直接访问
- **实际动态观察已验证**：完整 replay 进程链（Xcode → CompatService → AgentService → ReplayService → LLVMHelper）已通过 bridge 确认
- **GTMTLReplay_CLI 实际调用已验证**：探针 `Scripts/replay_probe.m` 证明外部进程可直接 dlopen+dlsym 调用，无需 entitlement/Xcode（详见 R3.1 子文档）
- **APR Bootstrap 方案已确认**：GPUToolsReplay 内部静态链接 APR，需在调用 CLI 前通过 GT_ENV-0x30 偏移手动构造 global pool + allocator（详见 R3.1 子文档）

### 当前卡点

- 已证明 `GTMTLReplay_CLI` 可被直接调用（APR 初始化已解决），但测试样本为 Git LFS 指针（未拉取），无法验证完整 replay 流程
- **下一步需要**：`git lfs pull` 获取真实 .gputrace 样本，或手动用 Xcode capture 一个最小样本

### 下一步（当前最高优先级）

- **R3.2**：用真实 .gputrace 样本验证完整 replay 流程，探索 completionCallback 返回数据。
- **目标**：获得 completionCallback 实际数据（NSData 内容 + NSURL），证明 headless replay 可产出有意义的输出。
- **前置**：需要 `git lfs pull` 获取真实 .gputrace 样本，或从 Xcode 手动 capture。
- **R3.2 实施要点**：
  1. 获取真实 .gputrace（`git lfs pull` 或 Xcode capture）
  2. 用 `replay_probe` 传入真实样本，观察 completionCallback 返回
  3. 尝试设置 options.profilingFlags 和 gpuStateLevel
  4. 解析 callback 中的 NSData（可能是 profiling 结果/JSON/plist）

## 构建与验证的方法

- **默认验证顺序**：
  - **V1 静态扫描**：`find`、`strings`、`nm -m`、`plutil -p`、`grep`，面向 Xcode 私有模块。
  - **V2 动态观察**：`pgrep`、`ps`、`lsof`、`sample 1 1`，面向运行中的 replay 进程。
  - **V3 bridge 干跑**：新增 bridge 提供 `--json`、`--dry-run`；先语法检查，再对活动 replay 或离线样本执行最小查询。
  - **V4 最小样本测试**：验证只读输出是否稳定、字段是否可复现。
- **平时的构建/验证原则**：
  - 优先利用**当前正在 replay 的 Xcode**做动态观察。
  - 没有活动 replay 时，退回静态扫描和离线样本。
  - Python 脚本优先 `python3 -m py_compile`；Swift/ObjC 优先 `swiftc -typecheck`。
- **必须先得到用户确认的情况**：
  - 写 workspace 外目录 / attach / 注入 / 提权 / 修改系统文件 / 需要 UI 手操。

## agent的工作流程介绍
1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。手头所有工作都搁置，不要进行收尾、git commit。等待用户指示
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的executions文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

- **[DONE][P0] R0**：建立 dashboard、基线扫描。
- **[DONE][P0] R1**：提取 replay 通路最小对象图与参数面。
  - **[DONE] R1.1**：导出 GPUToolsServices / GPUToolsReplay 的完整类/selector/ivar/property 清单。
  - **[DONE] R1.1b**：补充 GPUToolsTransport（120+ 类）+ GPURawCounter API 清单。
  - **[DONE] R1.2**：探索 `GTMTLReplay_CLI` 参数签名，确认 headless replay 可行性。
  - **[DONE] R1.3**：标记三层字典结构（finalLaunch/replayerLaunch/traceConfiguration）字段。
- **[DONE][P1] R2**：产出只读 bridge 原型。
  - **[DONE] R2.1**：设计 CLI / JSON schema（3 个子命令）。
  - **[DONE] R2.2**：实现最小只读 bridge（`Scripts/gputrace_bridge.py`），V4 实际运行验证通过。
  - **[DONE] R2.3**：9 项稳定性测试全部通过，metadata 解析已修复。
- **[TODO][P0] R3**：headless replay 实际调用验证 — 证明 CLI 路径可行。
  - **[DONE][P0] R3.1**：编写最小 C/ObjC 探针（dlopen + dlsym GTMTLReplay_CLI），实际调用验证通过。APR bootstrap 问题已解决。
  - **[TODO][P1] R3.2**：探索 completionCallback 返回数据内容 + profilingFlags 配置注入。
  - **[TODO][P1] R3.3**：验证 GPU counters / shader profiler 数据获取。
- **[TODO][P2] R4**：数据获取等价 — 实现 Xcode GUI 中各类数据的 CLI 导出。
  - R4.1：Fetch 类族调用（Texture / Buffer / PipelineBinaries / PostVertex）
  - R4.2：Query 类族调用（Configuration / DerivedCounters / DeviceCapabilities）
  - R4.3：Profile 类族调用（Timeline / DerivedCounters / BatchFilteredCounters）
- **[TODO][P3] R5**：操作等价 — 实现 Xcode GUI 中各类交互操作的 CLI 触发。
  - R5.1：Replay 控制（playTo 指定帧/draw call、pause/resume/rewind）
  - R5.2：Shader 热替换（GTReplayUpdateLibrary）
  - R5.3：Shader Debug（fragment/vertex/kernel/mesh/object shader 调试）
  - R5.4：Configuration 动态修改（GTReplayUpdateConfiguration）
- **[TODO][P4] R6**：客户端封装与可用性收尾。

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 直接看进程读哪些 gputrace/缓存文件。
- **最高信号静态锚点**：`GPUDebugger`、`GPUToolsServices`、`GPUToolsReplayService`、`GPUToolsShaderProfiler` 上的 `strings` / `nm -m`。
- **已确认缓存路径**：`/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/...`
- **Instruments schema 对齐**：`GPU.instrdst` (com.apple.gpu-tracing), `GPUCounters.instrdst` (com.apple.gpu-counters)

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260520-replay-entry-scan.md` | **总是建议读取** | 已确认模块/进程/符号/文件访问关系（基线参考） |
| `subdocs/20260520-R1.1-api-inventory.md` | 在执行 R3+ 时按需读取 | GPUToolsReplay 导出符号、GPUToolsServices 76 类、关键 ivar/selector、对象图 |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | **在执行 R3/R4/R5 时必须读取** | XPC 代理完整接口、Fetch/Query/Profile/ShaderDebug/Update 类族（定义了 Xcode GUI 全操作集）、GPURawCounter API |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | **在执行 R3 时必须读取** | GTMTLReplay_CLI 签名、Options 结构体偏移、执行流程、headless 最小调用条件 |
| `executions/20260520-R3.1-replay-probe-verification.md` | **在执行 R3.2+ 时必须读取** | APR bootstrap 方案、allocator/pool 结构体布局、偏移量验证、调用验证结果 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取（仅在需要 XPC 路径时参考） | 三层字典完整字段；CLI 路径不使用这些字典 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（bridge 已完成） | CLI 入口结构、子命令 JSON schema、分类规则 |
