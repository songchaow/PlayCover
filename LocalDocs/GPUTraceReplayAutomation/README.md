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
| 1 | Replay 执行 | ✅ | R3: CLI 路径 headless 返回 0 |
| 2 | 纹理/Buffer 离线查看（存量资源） | ✅ | R4.1: Harvester 4 函数 blob 解析 |
| 3 | 帧/draw call 导航 (playTo) | ✅ | R4.3: `playTo(controller, targetCallIndex)` 验证成功 |
| 4 | Replay 后实时资源获取（render target） | ✅ | R4.3: ObjectMap → NSDictionary, getBytes/contents 导出 |
| 5 | Pipeline 查看 | ✅ | R5.1: libraryDataContents/bitcodeData 导出 metallib + AIR |
| 6 | GPU Counters（硬件计数器） | ⛔ 跳过 | R4.4: 需 Apple 私有 entitlement + SIP 关闭；host timing 可替代 |
| 7 | Shader Profiler（per-line 耗时） | ⛔ 跳过 | 同 R4.4 entitlement 限制 |
| 8 | Derived Counters（派生指标） | ⛔ 跳过 | 同 R4.4 entitlement 限制 |
| 9 | Shader 热替换 | ✅ | R5.2: objectMap.setLibrary:forKey: + rewind+playAll；shaderIR(metallib binary)无需源码 |
| 10 | Shader Debug | ⚠️ 部分 | R5.3: 原生路径受限(需GTLLVMHelper IPC)；instrumented debug 替代方案完全可行含无源码支持 |
| 11 | Configuration 修改 | ✅ | R5.4: 调用链控制(optimizeRestores/populateUnused) + 全局变量(g_runningValidationCI) + Service.update 路径 |
| 12 | 输出自动化（标准化 JSON/bin 导出） | 🔄 部分 | R6 |

**完成度：~75%（8/12 完成 + 1 部分 + 3 跳过；仅输出自动化待实现）**

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
- **两条已验证的 headless 路径**：
  - **CLI 路径**（R3）：`GTMTLReplay_CLI` — 仅做 replay 健康检查（返回 0/非 0），不产出数据。详见 `subdocs/20260520-R3-headless-replay.md`
  - **Controller 路径**（R4.2，主力）：`makeDataSource → makeController → playAll/playTo` — 完整 replay + 对象访问 + 定向 replay，无 XPC/entitlement 依赖。详见 `subdocs/20260520-R4.2-controller-path.md`
- **数据获取核心**：`GTMTLReplayObjectMap`（302 方法 NSObject 子类），replay 后通过 `resources`/`bufferForKey:`/`textureForKey:` 直接读取 GPU 数据
  - playAll 后 `objectMap.resources` → NSDictionary（key=NSNumber 资源 ID, value=MTLTexture/MTLBuffer）
  - `[tex getBytes:bytesPerRow:fromRegion:mipmapLevel:]` / `[buf contents]` 直接导出 raw data
  - `playTo(controller, uint32_t targetCallIndex)` — 导出函数，0=成功；resources count 随 target 变化证明定向控制有效
- **离线数据提取**：`GTHarvester*` 4 个纯 blob 解析器，可在无 replay 情况下提取 .gputrace 中已存储的纹理/buffer
- **XPC 操作全集已清点**：`GTMTLReplayServiceXPCProxy` 定义了 Xcode GUI 所有 replay 操作范围（fetch/query/profile/shaderdebug/update），为后续能力对齐提供完整参照。详见 `subdocs/20260520-R1.1b-transport-rawcounter-api.md`
- **GPU Counters 能力边界**（R4.4）：GPURawCounter 需 `com.apple.private.agx.performance-spi`（Apple 签名 + SIP 关闭）；host timing via `mach_absolute_time` + playTo per-segment 可替代
- **Pipeline Binary 导出**（R5.1）：
  - ObjectMap 的所有 `ForKey:` 方法接受 **uint64_t** 参数（type encoding `Q`），非 NSObject
  - `libraryForKey:(uint64_t)` → `_MTLLibrary`（MTLLibrary 协议）
  - `_MTLLibrary.libraryDataContents` → NSData（metallib binary，magic 0x424C544D "BLTM"）
  - `_MTLLibrary.bitcodeData` → NSData（AIR/LLVM bitcode，magic 0x0B17C0DE）
  - Key 空间模式：library key = function key - 1（偶数/奇数交替）
- **Shader 热替换**（R5.2）：
  - 路径 A（推荐）：`objectMap.setLibrary:forKey:` → `rewind` → `playAll` — 直接替换，无需 XPC
  - **shaderSource**：编译 MSL → MTLLibrary → 替换 ✅
  - **shaderIR**：加载 metallib binary → MTLLibrary → 替换（**无需源码**）✅
  - **Xcode UI 缺口**：GUI 只暴露 Edit Source；shaderIR binary 注入是 API-only 能力
  - 详见 `subdocs/20260520-R5.2-shader-hot-replace.md`
- **Shader Debug 架构**（R5.3）：
  - 原生路径：GTMTLReplayService.shaderdebug → GTLLVMHelper IPC → 受限（需 flatbuffers 协议逆向）
  - **替代方案**（推荐）：Instrumented shader debugging — 组合 R5.2(替换) + R4.3(playTo+读取) = "printf debug"
  - 无源码调试：metallib→反汇编→修改IR→重编译→注入→对比输出 ✅
  - IPC 连接层已打通（connect+ACK），协议层需 flatbuffers 逆向（后续增强方向，不阻塞主线）
  - 详见 `subdocs/20260520-R5.3-shader-debug.md`
- **Configuration 动态修改**（R5.4）：
  - GTReplayConfiguration 13 BOOL 属性全可实例化/读写 ✅
  - **Controller 路径映射**（3 个核心属性已验证）：
    - `disableOptimizeRestores` → 跳过 `GTMTLReplayController_optimizeRestores`（CLI+0x96c）— 168–188% 性能差异
    - `forceLoadUnusedResources` → 调用 `populateUnusedResources(ds, om)`
    - `enableValidation` → 全局变量 `g_runningValidationCI`（导出符号）— 3.7–21.6% overhead
  - **Service 路径**：`GTMTLReplayService.update:(GTReplayUpdateConfiguration)` — 需完整 GTMTLReplayClient context
  - GTMTLReplayClient 结构体含 4 个 config bitfield（通过 initWithContext: type encoding 确认）
  - 详见 `executions/20260520-R5.4-configuration.md`
- **工具链已就绪**（均在 `Scripts/` 目录下）：
  - `gputrace_bridge.py` — 只读 bridge（scan-active-replay / scan-binaries / inspect-gputrace）
  - `replay_probe.m` — CLI 路径探针
  - `controller_probe.m` — Controller 路径探针
  - `harvester_probe.m` — 离线数据提取探针
  - `objectmap_probe.m` — ObjectMap 数据提取 + playTo 探针
  - `counter_probe.m` — 计数器能力枚举 + timing 探针
  - `pipeline_probe.m` — Pipeline/Library binary 导出探针
  - `update_library_probe.m` / `update_library_probe2.m` / `update_library_probe3.m` — Shader 替换探针
  - `shader_debug_probe.m` ~ `shader_debug_probe3.m` — Shader Debug 探针
  - `shader_debug_ipc_probe.m` ~ `shader_debug_ipc_probe4.m` — IPC 协议探针
  - `config_probe.m` / `config_probe2.m` — Configuration 动态修改探针

### 当前卡点

无。R5.4 已完成。

### 下一步（当前最高优先级）

**R6.1：统一 ObjC bridge binary**

将所有已验证能力（controller/objectMap/pipeline/shader-replace/config）合并为一个多子命令 CLI 工具，JSON 输出。

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
  - CLI 路径仅做 replay 验证；completionCallback 为 dead code；能力边界已明确。
- **[DONE] R4**：数据获取等价。
  - R4.1：Harvester 离线 blob 解析器验证。
  - R4.2：Controller 路径验证（makeDataSource+makeController+playAll+objectMap）。
  - R4.3：ObjectMap 数据提取 + playTo 定向 replay 验证。
  - R4.4：GPU Counters — host timing 可用，HW counters 被 entitlement 阻塞（跳过）。
  - R4.5：Shader Profiler — 同 R4.4 限制（跳过）。
- **[DONE] R5**：操作等价 — Replay 数据深度获取与交互操作。
  - [DONE] R5.1：Pipeline 查看（libraryForKey:uint64→libraryDataContents/bitcodeData 导出 metallib+AIR）
  - [DONE] R5.2：Shader 热替换（objectMap.setLibrary:forKey: + shaderIR/shaderSource；Xcode UI 未暴露的 shaderIR 注入已验证）
  - [DONE] R5.3：Shader Debug（原生路径受 GTLLVMHelper IPC 限制；instrumented debug 替代方案完全可行，含无源码支持）
  - [DONE] R5.4：Configuration 动态修改（调用链控制 + g_runningValidationCI 全局变量 + Service.update 路径确认）
- **[IN-PROGRESS][P0] R6**：客户端封装与可用性收尾。
  - R6.1：**统一 ObjC bridge binary**（将 controller/objectMap/pipeline/shader-replace/config 所有已验证能力合并为一个多子命令 CLI 工具，JSON 输出）
  - R6.2：Python CLI wrapper（对 R6.1 单一二进制的高层封装）
  - R6.3：端到端自动化验证链路
  - 策略注：当前 16 个独立探针仅用于验证阶段；R6.1 将其整合为可复用的生产级工具，是最终交付物的核心

## 高频复用经验

- **动态确认 replay 是否在跑**：`pgrep -fl 'Xcode|GPUTools|Instruments|GTLLVMHelper'`
- **最高信号动态命令**：`lsof -p <pid>` — 看进程读哪些 gputrace/缓存文件
- **最高信号静态锚点**：`GPUToolsReplay`、`GPUToolsServices` 上的 `strings` / `nm -m`
- **关键环境变量**：`ATF_RESULTSDIRECTORY`(输出目录)、`GPUMTLOverrideDeviceFamily`(设备覆盖)
- **探针编译模板**：`clang -framework Foundation -framework Metal -ldl -lobjc -o <probe> <probe>.m`

## 参考信息

| 子文档 | 阅读建议 | 内容概述 |
|--------|---------|---------|
| `subdocs/20260520-R4.2-controller-path.md` | **总是建议读取** — Controller 路径是所有后续任务的基础 | 完整调用链、内部函数偏移表、ObjectMap 302 方法、playAll/playTo、Pipeline binary 导出（R5.1） |
| `subdocs/20260520-R1.1b-transport-rawcounter-api.md` | **在执行 R5 时必须读取** — 包含 Update/ShaderDebug 类族接口 | XPC Fetch/Query/Profile/ShaderDebug/Update 类族完整接口 |
| `subdocs/20260520-R5.2-shader-hot-replace.md` | 在需要 shader 替换细节时按需读取 | R5.2 调用流程、路径对比、Xcode UI 能力缺口 |
| `subdocs/20260520-R5.3-shader-debug.md` | 在需要 shader debug 架构细节或 IPC 后续方向时按需读取 | R5.3 类族、能力边界、instrumented debug 替代方案、IPC 探索结论与后续增强方向评估 |
| `executions/20260520-R5.4-configuration.md` | 在需要 Configuration 属性映射细节时按需读取 | R5.4 Configuration 13 属性→Controller 路径映射、GTMTLReplayClient 结构体、验证数据 |
| `subdocs/20260520-R1.1-api-inventory.md` | 在需要查阅完整符号/类清单时按需读取 | GPUToolsReplay 导出符号、Harvester blob 格式、GPUToolsServices 76 类 |
| `subdocs/20260520-R3-headless-replay.md` | 在调试 APR/options 问题时按需读取 | APR bootstrap、options 完整布局、CLI 能力边界 |
| `subdocs/20260520-replay-entry-scan.md` | 一般无需读取（基础信息已整合至主文档） | R0 基线：模块/进程/符号/文件访问 |
| `subdocs/20260520-R1.2-GTMTLReplay_CLI-signature.md` | 一般无需读取（核心信息已整合） | CLI 签名、Options 偏移表、执行流程 |
| `subdocs/20260520-R1.3-dictionary-fields.md` | 一般无需读取（CLI/Controller 路径不使用字典） | 三层字典字段；仅在需要 XPC 路径时参考 |
| `subdocs/20260520-R2.1-CLI-schema.md` | 一般无需读取（bridge 已完成） | CLI schema 设计、R2.2/R2.3 实现与测试总结 |
