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
| GPU Counters / Profiler / Derived | 需 Apple 私有 entitlement + SIP 关闭 | ⛔ 跳过 |

**完成度：~83%（9/12 维度完成或跳过）**

最终交付物：
1. **统一 ObjC bridge CLI**（`Scripts/gputrace_replay_bridge.m`）— ✅ 已完成，5 子命令，Makefile 构建，集成测试 17/17 通过
2. **Python CLI wrapper** — 对 bridge 的高层封装，面向自动化流水线
3. **端到端验证链路** — 用真实 .gputrace 跑通全部子命令

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
- **Pipeline Binary 导出**：`libraryForKey:(uint64_t)` → `libraryDataContents`(metallib) / `bitcodeData`(AIR)。Key 偶数=Library，奇数=Function
- **Shader 热替换**：`objectMap.setLibrary:forKey:` → rewind → playAll。shaderIR(metallib binary) 可无源码替换
- **Configuration**：调用链控制（disableOptimizeRestores/forceLoadUnusedResources）+ 全局变量（g_runningValidationCI）
- **统一 Bridge**（R6.1）：`Scripts/gputrace_replay_bridge.m` — 5 子命令（help/replay/pipeline/shader/config），Makefile 构建 + ad-hoc 签名 + 集成测试 17/17 通过。详见 `subdocs/20260520-R6.1-bridge-implementation.md`

### 当前卡点

无。R6.2a 全部完成（2026-05-21）。

### 下一步（当前最高优先级）

**R6.2b：Python CLI wrapper**

优先级理由：R6.2a 已确认 bridge 全部子命令在真实 trace 上功能正确，可安全封装。

1. **R6.2b Python CLI wrapper**（最高优先）：
   - 封装 bridge 5 子命令为 Python 结构化接口
   - 输入参数校验 + JSON 输出解析
   - 错误处理：退出码映射 + stderr 捕获
   - 验收标准：Python 接口能驱动全部子命令、返回 dict/dataclass

## 构建与验证的方法

- **构建**：`cd Scripts/ && make`（编译 + ad-hoc 签名）；`make test`（集成测试 17 项）；`make clean`
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
- **[IN-PROGRESS][P0] R6**：客户端封装与可用性收尾
  - **[DONE] R6.1**：统一 ObjC bridge binary — 5 子命令 + Makefile + 集成测试 17/17
  - **[DONE] R6.2a**：端到端动态验证（2 样本 × 5 子命令，29/29 集成测试通过）
  - **R6.2b**：Python CLI wrapper（基于验证结果封装）
  - **R6.3**：自动化流水线集成（CI/CD 集成、样本库管理）

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
| `subdocs/20260520-R6.1-bridge-implementation.md` | **总是建议读取** — 已实现 bridge 的完整架构与子命令用法 | 5 子命令实现、JSON schema、构建方法、测试覆盖 |
| `executions/20260521-R6.2a-e2e-dynamic-validation.md` | 在检查验证结果时按需读取 | 2 样本 × 5 子命令端到端验证详情、文件格式确认 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在扩展 shader 功能时按需读取 | 替换路径对比、Xcode UI 能力缺口 |
| `subdocs/20260520-R5.3-shader-debug.md` | 在探索 IPC/debug 后续方向时按需读取 | ShaderDebug 类族、instrumented debug、IPC 探索结论 |
| `subdocs/20260520-R5.4-configuration.md` | 在扩展 config 功能时按需读取 | 13 属性映射、Service 路径 |
| `subdocs/20260520-R1.1-api-inventory.md` | 在查阅完整符号/类清单时按需读取 | GPUToolsReplay 导出符号、76 类清单、Harvester blob |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | 一般无需读取（XPC 路径当前不使用） | Fetch/Query/Profile/ShaderDebug/Update 类族接口 |
| `subdocs/20260520-R3-headless-replay.md` | 在调试 APR/options 问题时按需读取 | APR bootstrap、Options 布局、CLI 能力边界 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（已被 R6.1 ObjC bridge 取代） | 早期 Python bridge CLI schema |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取 | R0 基线：模块/进程/符号 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取（完整信息已在 R3 子文档中） | CLI 签名、Options 偏移表 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取 | 三层字典字段（CLI/Controller 不使用） |
