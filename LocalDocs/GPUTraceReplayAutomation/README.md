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

优先级排序：headless replay 基础执行 > 只读数据获取 > shader 替换/调试 > profiling/counters > 高级交互。

### 能力对齐进度总览

| # | 能力维度 | 状态 | 关键结论 |
|---|---------|------|---------|
| 1 | Replay 执行 | ✅ | Controller 路径 headless playAll 返回 0 |
| 2 | 纹理/Buffer 查看 | ✅ | ObjectMap → getBytes/contents 导出 |
| 3 | 帧/draw call 导航 (playTo) | ✅ | `playTo(controller, targetCallIndex)` |
| 4 | Replay 后实时资源获取 | ✅ | ObjectMap.resources → NSDictionary |
| 5 | Pipeline 查看 | ✅ | libraryDataContents/bitcodeData 导出 |
| 6 | GPU Counters | ⛔ 跳过 | 需 Apple 私有 entitlement + SIP 关闭 |
| 7 | Shader Profiler | ⛔ 跳过 | 同 entitlement 限制 |
| 8 | Derived Counters | ⛔ 跳过 | 同 entitlement 限制 |
| 9 | Shader 热替换 | ✅ | setLibrary:forKey: + rewind+playAll |
| 10 | Shader Debug | ⚠️ 部分 | instrumented debug 替代方案可行 |
| 11 | Configuration 修改 | ✅ | 调用链控制 + 全局变量 |
| 12 | 输出自动化 | ✅ | R6.1 bridge 已实现 JSON/bin 导出 |

**完成度：~83%（9/12 完成 + 3 跳过；bridge 已实现，待编译验证与高层封装）**

最终交付物：
- **统一 ObjC bridge CLI**（`Scripts/gputrace_replay_bridge.m`）：已完成 5 子命令，覆盖全部已验证能力，JSON 输出。
- **Python CLI wrapper**：对 bridge 层的高层封装，面向自动化流水线。
- **自动验证链路**：静态验证 → 动态扫描 → 最小样本测试。

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
- **两条已验证的 headless 路径**：
  - **CLI 路径**（R3）：`GTMTLReplay_CLI` — 仅做 replay 健康检查（返回 0/非 0），不产出数据。详见 `subdocs/20260520-R3-headless-replay.md`
  - **Controller 路径**（R4.2，主力）：`makeDataSource → makeController → playAll/playTo` — 完整 replay + 对象访问 + 定向 replay，无 XPC/entitlement 依赖。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法 NSObject 子类），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
  - playAll 后 `objectMap.resources` → NSDictionary（key=NSNumber 资源 ID, value=MTLTexture/MTLBuffer）
  - `[tex getBytes:bytesPerRow:fromRegion:mipmapLevel:]` / `[buf contents]` 直接导出 raw data
  - `playTo(controller, uint32_t targetCallIndex)` — 导出函数，0=成功
- **Pipeline Binary 导出**（R5.1）：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 偶数=Library，奇数=Function
- **Shader 热替换**（R5.2）：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Shader Debug**（R5.3）：Instrumented debug（替换 + playTo+读取 = "printf debug"），含无源码支持
- **Configuration**（R5.4）：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **统一 Bridge**（R6.1）：`Scripts/gputrace_replay_bridge.m` — 5 子命令（help/replay/pipeline/shader/config）已实现并验证。详见 `subdocs/20260520-R6.1-bridge-implementation.md`

### 当前卡点

无。R6.1a~e 全部完成。bridge 编译零警告零错误已实测确认（2026-05-20）。

### 下一步（当前最高优先级）

**R6.1f：编译验证 — Makefile + ad-hoc 签名 + 集成测试**

- 创建 `Scripts/Makefile`：编译 gputrace_replay_bridge.m + ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`）
- 各子命令最小样本集成测试脚本（shell script，验证退出码 + JSON 输出字段）
- 确认所有子命令在 reference trace 上通过
- 预期耗时：低，所有子命令均已独立验证通过

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
- **[DONE] R2**：产出只读 bridge 原型。
- **[DONE] R3**：headless replay 实际调用验证。
- **[DONE] R4**：数据获取等价。
- **[DONE] R5**：操作等价 — Replay 数据深度获取与交互操作。
- **[IN-PROGRESS][P0] R6**：客户端封装与可用性收尾。
  - **R6.1：统一 ObjC bridge binary** — 将所有已验证能力合并为单一多子命令 CLI，JSON 输出
    - [DONE] R6.1a：骨架搭建 — 子命令分发 + JSON 宏 + 公共初始化
    - [DONE] R6.1b：replay 子命令 — playAll/playTo + 资源枚举与导出
    - [DONE] R6.1c：pipeline 子命令 — library 枚举 + metallib/AIR 导出
    - [DONE] R6.1d：shader 子命令 — setLibrary:forKey: 替换 + 验证
    - [DONE] R6.1e：config 子命令 — 调用链控制 + validation
    - **R6.1f：编译验证** — Makefile + ad-hoc 签名 + 各子命令最小样本测试
  - R6.2：Python CLI wrapper（对 R6.1 单一二进制的高层封装）
  - R6.3：端到端自动化验证链路

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 看进程读哪些 gputrace/缓存文件
- **最高信号静态锚点**：`GPUToolsReplay`、`GPUToolsServices` 上的 `strings` / `nm -m`
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)
- **探针编译模板**：`clang -framework Foundation -framework Metal -ldl -lobjc -o <probe> <probe>.m`

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是所有后续任务的基础 | 完整调用链、偏移表、ObjectMap、playTo、Pipeline 导出 |
| `subdocs/20260520-R6.1-bridge-implementation.md` | **总是建议读取** — 已实现 bridge 的完整架构与子命令用法 | R6.1a~e 实现细节、JSON schema、验证结果 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在扩展 shader 功能时按需读取 | 替换路径对比、Xcode UI 能力缺口 |
| `subdocs/20260520-R5.3-shader-debug.md` | 在探索 IPC/debug 后续方向时按需读取 | ShaderDebug 类族、instrumented debug、IPC 探索结论 |
| `subdocs/20260520-R5.4-configuration.md` | 在扩展 config 功能时按需读取 | 13 属性映射、Service 路径 |
| `subdocs/20260520-R1.1-api-inventory.md` | 在查阅完整符号/类清单时按需读取 | GPUToolsReplay 导出符号、76 类清单、Harvester blob |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | 在实现 XPC 路径时按需读取 | Fetch/Query/Profile/ShaderDebug/Update 类族接口 |
| `subdocs/20260520-R3-headless-replay.md` | 在调试 APR/options 问题时按需读取 | APR bootstrap、Options 布局、CLI 能力边界 |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取 | R0 基线：模块/进程/符号 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取 | CLI 签名、Options 偏移表 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取 | 三层字典字段（CLI/Controller 不使用） |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取 | gputrace_bridge.py CLI schema |
