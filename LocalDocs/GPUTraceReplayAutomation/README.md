## 最终目标

- 在**不依赖 Xcode GUI 手工点按**的前提下，尽量分析并暴露截帧 replay 分析所需的各种 API 接口。
- 优先拿到**只读、低风险、可自动化**的接口；再逐步推进到 replay 触发、counter 配置、shader profiler 数据获取。
- 最终交付物固定为三类：
  - **bridge 调用层**：提供给客户端稳定调用，优先 CLI/脚本/JSON 输出。
  - **自动验证链路**：能由 agent 自主完成的静态验证、动态扫描、最小样本测试。
  - **持续维护文档**：本 dashboard、必要子文档。

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
- **三层字典结构已标记**：L1(启动)、L2(replayer)、L3(profiling)，但 CLI 路径不需要这些字典（详见 R1.3 子文档）
- **CLI schema 已设计**：`gputrace_bridge.py` 含 3 个子命令（scan-active-replay, scan-binaries, inspect-gputrace），纯 Python 标准库（详见 R2.1 子文档）
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)、`MTLREPLAYER_OVERRIDE_DEVICE_REGISTRY_ID`(GPU 覆盖)

### 当前卡点

- 还未对 `GTMTLReplay_CLI` 做过实际最小调用验证（属于 R3 范畴）

### 下一步（当前最高优先级）

- **R2.2**：实现最小只读 bridge（`Scripts/gputrace_bridge.py`），不触发 replay。
- **策略依据**：R2.1 schema 设计完成，可直接编码实现。

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
  - **[DONE][P0] R1.1**：导出 GPUToolsServices / GPUToolsReplay 的完整类/selector/ivar/property 清单。
  - **[DONE][P0] R1.2**：探索 `GTMTLReplay_CLI` 参数签名，确认 headless replay 可行性。
  - **[DONE][P1] R1.3**：标记三层字典结构（finalLaunch/replayerLaunch/traceConfiguration）字段。
- **[WIP][P1] R2**：产出只读 bridge 原型。
  - **[DONE][P1] R2.1**：设计 CLI / JSON schema（3 个子命令）。
  - **[TODO][P1] R2.2**：实现最小只读 bridge，不触发 replay。
  - **[TODO][P1] R2.3**：完成 dry-run 与样本输出稳定性测试。
- **[TODO][P2] R3**：验证 headless replay 实际可行性。
  - **[TODO][P2] R3.1**：编写最小 C/ObjC 探针（dlopen + dlsym GTMTLReplay_CLI），用已有 .gputrace 样本做实际调用验证。
  - **[TODO][P2] R3.2**：若 R3.1 成功，探索 completionCallback 返回数据内容 + profiling 配置注入。
  - **[TODO][P2] R3.3**：验证是否能获取 GPU counters / shader profiler 数据。
- **[TODO][P3] R4**：客户端可用性收尾。

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 直接看进程读哪些 gputrace/缓存文件。
- **最高信号静态锚点**：`GPUDebugger`、`GPUToolsServices`、`GPUToolsReplayService`、`GPUToolsShaderProfiler` 上的 `strings` / `nm -m`。
- **已确认缓存路径**：`/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/...`
- **Instruments schema 对齐**：`GPU.instrdst` (com.apple.gpu-tracing), `GPUCounters.instrdst` (com.apple.gpu-counters)

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260520-replay-entry-scan.md` | **总是建议读取** | 已确认模块/进程/符号/文件访问关系 |
| `subdocs/20260520-R1.1-api-inventory.md` | 在执行 R2/R3 时按需读取 | GPUToolsReplay 导出符号、GPUToolsServices 76 类、关键 ivar/selector、对象图 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 在执行 R3 时按需读取 | GTMTLReplay_CLI 签名、Options 结构体、执行流程、headless 可行性 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 在执行 R3 时按需读取 | 三层字典完整字段、hardwareCountersConfiguration、环境变量控制键 |
| `subdocs/20260520-R2.1-CLI-schema.md` | **在执行 R2.2 时必须读取** | CLI 入口结构、子命令 JSON schema、分类规则、实现约束 |
