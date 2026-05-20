## 最终目标

**使 CLI 模式下的 GPU 截帧 replay 在功能上尽可能等价于 Xcode GUI 窗口内的 replay 以及分析调试等操作。**

等价性定义 — 以下 Xcode GUI replay 窗口内能做的事，CLI 下均应能以编程方式完成：

| 能力维度 | Xcode GUI 行为 | CLI 等价目标 |
|----------|---------------|-------------|
| **Replay 执行** | 打开 .gputrace → replay 重放 | `GTMTLReplay_CLI` headless 重放任意 .gputrace |
| **帧/draw call 导航** | playTo 指定帧/encoder/draw call | playTo API 或 options 控制 |
| **纹理/Buffer 查看** | 点击资源 → 预览数据 | Fetch 类族 CLI 导出（JSON/二进制） |
| **Pipeline 查看** | 查看编译后 pipeline | FetchPipelineBinaries 导出 |
| **GPU Counters** | Performance → 硬件计数器 | Profile 类族 + GPURawCounter 采集 |
| **Shader Profiler** | per-line 耗时分析 | ProfileTimeline.shaderProfiling |
| **Derived Counters** | Insights → 派生指标 | QueryDerivedCounters / gpuStateLevel |
| **Shader 热替换** | Edit shader → reload | UpdateLibrary (shaderSource/shaderIR/shaderURL) |
| **Shader Debug** | 选像素/顶点 → step through | ShaderDebug 类族 |
| **Configuration 修改** | Replay Options 面板 | UpdateConfiguration |
| **输出自动化** | 手动截图/导出 | 所有结果 JSON/二进制文件输出 |

优先级排序：headless replay 基础执行 > 只读数据获取 > profiling/counters > shader debug/替换 > 高级交互。

最终交付物：
- **C/ObjC bridge 层**：探针 + 结构化调用接口，提供 headless replay 全功能调用能力。
- **Python CLI wrapper**：对 bridge 层的高层封装，面向自动化流水线。
- **自动验证链路**：静态验证 → 动态扫描 → 最小样本测试。
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
- **突破口**：`GTMTLReplay_CLI` 是独立 C 函数，可 headless replay，不依赖 Xcode/GUI/XPC — 这是 Apple CI 路径
- **CLI 签名已完整逆向**：`int GTMTLReplay_CLI(const char *path, GTMTLReplayCLIOptions *options, void (*callback)(NSData*, NSURL*))` — options ≥0x320 字节
- **XPC 完整操作集已清点**：`GTMTLReplayServiceXPCProxy` 暴露 fetch/query/profile/shaderdebug/update — 定义了 Xcode GUI 所有 replay 操作的完整范围
- **Headless replay 完整成功**：options +0x28(errorLogPath) +0x30(saveDestination) 必须非 NULL，填入后 GTMTLReplay_CLI 返回 0（样本：恋与深空 ~368MB）
- **CLI 路径能力边界已明确**：CLI 仅做 replay 验证（返回 0/非 0）；completionCallback 为 dead code（从未被 BLR 调用）；profilingFlags/gpuStateLevel 在函数中不被访问。数据获取需通过其他 API
- **数据获取候选路径**：① `GTHarvester*` 系列导出函数（同进程空间，最直接）② `GTMTLReplayHost_*` C API ③ XPC proxy
- **只读 bridge 已交付**：`Scripts/gputrace_bridge.py` 3 个子命令全部验证通过
- **APR Bootstrap 已解决**：通过 GT_ENV-0x30 偏移手动构造 global pool + allocator
- **实际调用已验证**：探针 `Scripts/replay_probe.m` 证明 dlopen+dlsym 可行，无需 entitlement

### 当前卡点

无。R3 headless replay 路径已完全探明边界。

### 下一步（当前最高优先级）

**R4.1：在 replay 成功后通过 Harvester / Host API 获取资源数据**

背景：R3.3 证明 CLI 路径不产出数据。需探索框架内导出的数据获取 API。

实施策略（按优先级尝试）：
1. **Harvester 路径**（最优先）：`GTHarvesterGetData`/`GTHarvesterGetMetadata`/`GTHarvesterGetTexturePlane`/`GTHarvesterGetTexturePlaneCount` — 这些是 GPUToolsReplay.framework 的直接导出符号，与 `GTMTLReplay_CLI` 同一框架，极可能可在 replay 完成后同进程调用
2. **Host 路径**：`GTMTLReplayHost_generateDerivedDataPayload` — 已知导出符号
3. **Controller 路径**：`GTMTLReplayController_playTo` — 支持帧导航后再提取

验证方法：
1. `nm -m` 确认 Harvester 函数签名（参数个数/类型推断）
2. 在 `replay_probe.m` 中 replay 成功后立即调用 Harvester API
3. 观察返回值/输出

成功标准：通过 C API 成功获取至少一种资源数据（纹理/buffer/metadata）并输出到文件。

## 构建与验证的方法

- **默认验证顺序**：
  - **V1 静态扫描**：`find`、`strings`、`nm -m`、`plutil -p`、`grep`，面向 Xcode 私有模块。
  - **V2 动态观察**：`pgrep`、`ps`、`lsof`、`sample 1 1`，面向运行中的 replay 进程。
  - **V3 bridge 干跑**：bridge 提供 `--json`、`--dry-run`；先语法检查，再对活动 replay 或离线样本执行最小查询。
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

- **[DONE] R0**：建立 dashboard、基线扫描。
- **[DONE] R1**：提取 replay 通路最小对象图与参数面。
  - R1.1：GPUToolsServices / GPUToolsReplay 完整 API 清单。
  - R1.1b：GPUToolsTransport + GPURawCounter API 清单。
  - R1.2：GTMTLReplay_CLI 签名逆向，确认 headless 可行。
  - R1.3：三层字典结构标记（CLI 路径不需要）。
- **[DONE] R2**：产出只读 bridge 原型。
  - R2.1：CLI / JSON schema 设计。
  - R2.2：实现 `Scripts/gputrace_bridge.py`，V4 验证通过。
  - R2.3：9 项稳定性测试全部通过。
- **[DONE] R3**：headless replay 实际调用验证。
  - R3.1：最小 ObjC 探针调用验证通过，APR bootstrap 已解决。
  - R3.2：修复 options NULL 字符串字段，headless replay 返回 0。
  - R3.3：[N/A] completionCallback 为 dead code，CLI 路径不产出 profiling 数据。能力边界已明确。
- **[TODO][P0] R4**：数据获取等价 — 在 headless replay 成功后提取资源数据。
  - R4.1：Harvester API 探索与验证（GTHarvesterGetData/GetMetadata/GetTexturePlane）
  - R4.2：Host API 探索（GTMTLReplayHost_generateDerivedDataPayload）
  - R4.3：Controller + Fetch 类族组合调用（playTo → fetch texture/buffer）
- **[TODO][P2] R5**：操作等价 — Replay 交互操作的 CLI 触发。
  - R5.1：Replay 控制（playTo 指定帧/draw call、pause/resume/rewind）
  - R5.2：Shader 热替换（GTReplayUpdateLibrary）
  - R5.3：Shader Debug（fragment/vertex/kernel/mesh/object）
  - R5.4：Configuration 动态修改（GTReplayUpdateConfiguration）
- **[TODO][P3] R6**：客户端封装与可用性收尾 — Python CLI wrapper + 自动化集成。

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 直接看进程读哪些 gputrace/缓存文件。
- **最高信号静态锚点**：`GPUToolsReplay`、`GPUToolsServices` 上的 `strings` / `nm -m`。
- **已确认缓存路径**：`/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/...`
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)、`MTLREPLAYER_OVERRIDE_DEVICE_REGISTRY_ID`(GPU 覆盖)
- **探针编译**：`cd Scripts/ && clang -framework Foundation -framework Metal -ldl -o replay_probe replay_probe.m`

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260520-replay-entry-scan.md` | 总是建议读取 | R0 基线：模块/进程/符号/文件访问关系 |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | **在执行 R4/R5 时必须读取** | XPC 完整接口、Fetch/Query/Profile/ShaderDebug/Update 类族、GPURawCounter |
| `subdocs/20260520-R1.1-api-inventory.md` | **在执行 R4 时必须读取** | GPUToolsReplay 导出符号（含 Harvester 系列）、GPUToolsServices 76 类、对象图 |
| `subdocs/20260520-R3-headless-replay.md` | **在执行 R4 时必须读取** | R3 全阶段技术细节：APR bootstrap、options 布局、CLI 能力边界、反汇编分析 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 在调试 options 相关问题时按需读取 | CLI 签名、Options 偏移表、执行流程 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取（CLI 路径不使用字典） | 三层字典字段；仅在需要 XPC 路径时参考 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（bridge 已完成） | CLI schema 设计、R2.2/R2.3 实现与测试总结 |
