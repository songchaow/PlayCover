## PathDifferenceTrial Dashboard

> **单一来源规则**：`com.tencent.ngr` 启动崩溃的 **iOS-vs-macOS 路径差异假设**
> 的优先级、主线、TODO、验证口径只在本文维护；长日志、历史推理细节、
> 一次性 live 基线、脚本/工具细节、历史子任务的踩坑和证伪过程都下沉
> 到对应子文档与附录。主文档保持可快速通读。
>
> **阅读次序建议**：
> 1. 先读本文档"最终目标 → 全局约束 → 主线任务 → 当前主线 / 卡点 / 下一步"；
> 2. 只有在需要动当前主线子任务时，才进入对应子文档；
> 3. 其它子文档按"默认必读 / 按需读取"章节的指引决定是否展开；
>    每个子文档顶部也有各自的"何时读"提示。

## 最终目标

- 验证或证伪以下假设：**iOS 与 PlayCover 之间的 app 数据路径差异**
> 是 `com.tencent.ngr` 启动期 `QtsFileSystem Create Failed!!` 崩溃的根因之一。
> - iOS 上 app 数据路径通常为 `/var/mobile/Containers/Data/Application/<UUID>/Library/...`
>   或沙盒内其它 `/var` 前缀路径；
> - PlayCover 在 macOS 上把同一路径映射为 `/Users/songdogwang/Library/Containers/io.playcover.PlayCover/...`
>   或更直接的 `/Users/songdogwang/Library/NGR/Saved/Paks` 等绝对路径；
> - 两种路径在**前缀长度、目录层级、字符串字面量**上存在显著差异。
- 若假设成立：在 PlayCover/PlayTools 层找到**最小、可逆、bundle-scoped**
> 的路径对齐或重定向方案，使 NGR 在路径解析环节看到的字符串与 iOS
> 语义一致，从而消除 materializer 因路径前缀差异导致的失败分流。
- 若假设被证伪：留下结构化证据，把路径差异从主线排查列表中剔除，
> 回到 `HOK-016-C.2.7` 的原有 materializer state 分析。
- **不允许出现用户可见的报错 / 错误对话框 / 阻塞 UI**；验证过程必须能
> 由 agent 独立完成。

## 全局约束

- 所有验证默认**按 bundle 精准生效**（`com.tencent.ngr`），不扩大为全局
> 行为改动。
- 对该 app 的默认兼容配置把 `metal capture` / `startup injection` /
> `shader replacement` / `playChain` 视为非必要能力。
- 默认优先级：**对齐 iOS 路径语义** → **PlayTools 最小 bundle-scoped 兼容改动**
> → **路径重定向 / symlink / bind mount 等 OS 层方案（仅作兜底）**。
- 不允许把"用户手工登录 / 手工点 UI / 手工看窗口表现"作为日常 gate。
- 主文档只保留当前主线、TODO、决策信息和高频复用经验；历史推理、长
> 日志、反复试错过程必须下沉到子文档。

## 主线任务

### 当前主线一句话

`PDT-001`：确认 iOS 真实设备上 `com.tencent.ngr` 的 `Library/NGR/Saved/Paks`
> 等关键目录的**绝对路径前缀**，并与 macOS/PlayCover 当前实际路径做逐
> 字节对比；评估路径长度差异是否足以解释 HOK-016-C.2.7 中
> `entryX1="../../../NGR/Content/Paks/1/1.db"`(success) vs
> `entryX1="/Users/..."`(fail) 的分流行为。

### 当前状态摘要

- **假设来源**：HOK-016-C.2.7 materialization trace 中，success / fail 的
> 关键 pre-`1c8` 差异是 `entryX1` 的字符串内容：
>   - success 链：`entryX1="../../../NGR/Content/Paks/1/1.db"`（相对路径，iOS 风格）
>   - fail 链：`entryX1="/Users/songdogwang/..."`（绝对路径，macOS 风格）
> - 同一 materializer target `0x10432a068` 在 post-`1c8` pair 相同的情况下，
>   仅因 pre-`1c8` entry tuple 差异就分流到 `0x10432a2c8/0x10432a2e0`(success)
>   vs `0x10432a224`(fail)。C27 §14 已指出：真正驱动分流的是"compare
>   accumulators / selected buffer state"，而不是 `x21/x22` 这对指针本身。
> - 已知 materializer 内部在做"逐字符比较"（对临时 UTF-16 buffer 与固定
>   literal 做 case-fold compare）。路径字符串前缀不同，极可能改变 compare
>   accumulator 的演进，从而导致不同的分支决策。
> - **尚未确认的事实**：
>   1. 真实 iOS 设备上，NGR 的沙盒路径前缀到底是什么？（是 `/var/mobile/...`？
>      还是 iOS 15+ 的 `/private/var/mobile/...`？长度多少？）
>   2. materializer 内部比较的"固定 literal"到底是什么？是否包含路径前缀？
>   3. 若把 macOS 上的绝对路径重定向为 iOS 风格前缀，materializer 是否还会
>      走 `0x10432a224` fail 分支？

### 修复路线（优先级从高到低）

1. **`PDT-001`（当前主线）**：
>    - (a) 通过静态反汇编或已有 live trace，确认 `0x10432a068` 内部做 compare
>      的固定 literal 内容；判断这些 literal 是否包含路径前缀或路径相关字符串。
>    - (b) 搜集 iOS 真实设备上 `com.tencent.ngr` 的 `Library/NGR/Saved/Paks`
>      等关键目录的绝对路径样本（可通过公开资料、测试设备、或已有 ipa
>      安装日志推断），与 macOS 路径做长度和层级对比。
>    - (c) 若 literal 确实与路径前缀相关，设计最小验证实验：在 PlayTools
>      constructor 中对相关路径 API 做 swizzle / interpose，让 NGR 读取到的
>      路径前缀临时返回 iOS 风格值，观察 `0x10432a224` 是否仍被命中。
2. **`PDT-002`**：若 PDT-001 证实路径差异是根因，设计 PlayTools 层
>    bundle-scoped 路径重定向方案（如 `NSBundle` / `NSURL` swizzle、
>   `fopen`/`stat` interpose、或基于 PlayCover container 结构的 symlink）。
3. **`PDT-003`**：若 PDT-001 证伪路径假设，留下结构化证据，关闭本 trial，
>    回到 `HOK-016-C.2.7` 原有分析线。

### 当前兜底链路（按 PlayTools constructor 执行序）

路径差异 trial 当前**不改动**既有 HOK-013/014/015/010 兜底链路；所有验证
> 实验在独立的 PlayTools 分支或 runtime hook 中进行，失败时可立即回退。
> 唯一新增依赖：
> - 若 PDT-001(c) 需要 live trace `0x10432a068` 内部的 compare literal，
>   使用 HOK-012 已固化的 LLDB 工具链（`Scripts/hok006_ngr_lldb_runner.py`）。

### 已证伪路径（高层记录）

- **"路径差异已被 HOK-016-C.2.4 证伪"**：C.2.4 的结论是两个 FString 路径
>  `../../../NGR/Content/paks` 与 `/Users/...` **只是 `0x10432dd98` 的参数**，
>  没被 `0x1001ac168` / `0x1001cd114` 实际消费。但这**只证伪了 readiness B
>  dispatcher 层的路径消费**，并未证伪更深层的 materializer（`0x10432a068`）
>  内部是否在做路径相关的字符串比较。路径差异假设关注的是后者，因此
>  C.2.4 的证伪结论不直接覆盖本 trial。

> 每条证伪的具体实验、寄存器值、脚本产物都在对应子文档里。

### 当前卡点

- **iOS 真实路径前缀尚未确认**：当前没有真实 iOS 设备上的 NGR 运行日志，
>  无法确定 iOS 侧的沙盒绝对路径样本。
- **materializer 内部 compare literal 尚未提取**：`0x10432a068` 内部的
>  `x23` 与 `x23+0xca6` 固定 literal 到底是什么字符串，还需要一轮静态反汇编
>  或 LLDB memory dump 才能确认。
- **路径重定向的副作用范围未知**：若强行把 macOS 路径改成 iOS 前缀，
>  可能影响 UE4 的 I/O 实际落盘位置，需要验证文件读写是否仍能正确映射到
>  PlayCover container。

### 下一步默认规划

1. **补全 PDT-001(a)**：静态反汇编 `0x10432a068` 中 `0x10432a17c..0x10432a224`
>    的 compare ladder，提取 `x23` 与 `x23+0xca6` 指向的 literal 字符串内容。
>    产物：`build/pdt-001-compare-literals.json`。
2. **补全 PDT-001(b)**：通过以下任一方式获取 iOS 路径样本：
>    - 检查现有 `NGR-*.ips` 或 `launch-events.jsonl` 中是否已有 iOS 路径残留；
>    - 搜索 NGR ipa 包内的 `Info.plist` 或配置文件中对路径前缀的引用；
>    - 参考公开 iOS 沙盒路径规范，构造典型路径模板
>      `/var/mobile/Containers/Data/Application/<UUID>/Library/NGR/Saved/Paks`。
3. **若 literal 与路径无关**：直接关闭路径差异假设，记录证伪证据，回到
>    HOK-016-C.2.7。
4. **若 literal 与路径有关**：设计最小 live 实验（PDT-001(c)），在 PlayTools
>    中对 `-[NSBundle bundlePath]` / `NSSearchPathForDirectoriesInDomains` /
>    或特定 UE4 `FPaths::` 系列 API 做临时 swizzle，观察 materializer 分支
>    是否收敛。
5. 收尾执行 `git commit`。

## 构建与验证

### 日常默认方法

- **PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1
>  ./BuildScripts/sync_playtools_xcframework.sh`。
- **主 app / 注入 / 安装链路改动**：`./BuildScripts/build_and_install.sh`。
- **目标 app 配置**：优先用 `get_app_settings` / `update_app_settings`
>  MCP；`com.tencent.ngr` 的目标状态是：`metalCaptureEnabled=false` /
>  `injectMetalCaptureEnvironment=false` /
>  `shaderSourceReplacementEnabled=false` / `playChain=false` /
>  `rootWorkDir=true`。
- **Live 启动验证**：`launch_app` → 固定等待 → `create_session` /
>  `list_sessions`。pass 条件：session 不秒断、settle window 内持续存
>  活、`launch-events.jsonl` 有完整 compat 证据、无新同类 `NGR-*.ips`。
- **需要细粒度定位时**：`launch_app_with_lldb` +
>  `Scripts/hok006_ngr_lldb_runner.py`；所有 LLDB 选项 / BP callback
>  套路 / watchpoint 证据语义都在 `HOK-012-工具链与方法论归档.md` 与
>  其附录。日常启动不需要打开。
- **离线二进制分析**：复用 `Scripts/hok007_ngr_callsite_mapper.py` 或新增
>  `Scripts/pdt001_ngr_materializer_literal_extractor.py` 提取 compare
>  literal。

### 证据收集点

- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- `build/pdt-*.json` / `build/pdt-*.log`：历史结构化 live 证据本地留存
>  （`.gitignore` 的 `build/`），Dashboard 不逐个罗列；附录在引用时
>  按文件名指向。

关键事件：`playcover_startup_compat_profile_applied` /
`playcover_*_skipped` / `playcover_working_directory_changed`
（HOK-010 后应为 `_changed` 不是 `_preserved`）/
`hok013_ngr_slot_preheat status=primed` /
`hok014_ngr_alert_suppressor_installed` /
`hok014_ngr_alert_suppressed` /
`hok015_ngr_cmdline_preseed status=primed`。

### 需要用户确认后才能继续的事项

- 任何需要用户账号、验证码、手工登录、手工进游戏或手工点击复杂 UI
>  的验证。
- 任何依赖外部下载、替换新 app 构建、或需要用户提供额外私有材料的
>  步骤。
- 任何必须由用户亲自观察窗口视觉表现、而 agent 无法以 session /
>  diagnostics / crash evidence 替代判断的步骤。

## agent 工作流程

1. 读取本文档，先理解**当前主线**与 **TODO** 最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。
4. 若任务过大，先拆子任务追加到 TODO 原位置再推进。
5. 新功能尽量靠 skills 或 MCP 做**实际测试**；受环境限制时至少做
>   模拟性 / 离线 / 最小样本测试。
6. 每轮执行完必须整理本文档：删除过时信息，更新主线 / TODO / 踩坑 /
>   优先级；**主文档保持简洁，不能只追加不整理**。
>   - **主文档 vs 子文档分工**：局部细节、大段日志、方法论细节下沉到
>     对应子文档；主文档只保留当前主线、TODO、决策信息、高频复用经验。
>   - **任务状态只在本文档维护**：子文档**不允许**出现
>     "DONE / TODO / DEFERRED / BLOCKED / 已完成 / 已落地 / 待执行 /
>     下一步 / 结论 / handoff" 这类任务状态或进度字样。
>   - **子文档不写时间戳快照**：引用某次 live run 改为指向 `build/`
>     下的结构化报告文件名。
7. 复盘技术路线；除最终目标不变，中间方案可随新发现调整。
8. 收尾执行 `git commit`；一轮多条 TODO 的 commit 信息要把每条的证据
>   指向清楚列出，不要合成一行。

## 所有任务 TODO 状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| PDT-001 | TODO（当前主线） | 提取 `0x10432a068` 内部 compare literal；确认 iOS 真实路径前缀；评估路径差异是否足以解释 materializer 分流 | 待建 `PDT-001-materializer-literal-and-ios-path.md` |
| PDT-002 | TODO | 若 PDT-001 证实路径差异是根因，设计 PlayTools 层 bundle-scoped 路径重定向方案 | 待建 |
| PDT-003 | TODO | 若 PDT-001 证伪路径假设，留下结构化证据并关闭本 trial | 待建 |

## 高频复用经验（当前仍适用的）

以下经验跨任务复用概率高，写在主文档便于 agent 日常直接记住；更长的
> 分类细节见对应子文档。

- **"路径差异假设的边界"**：HOK-016-C.2.4 已证伪 `0x10432dd98` 入口处的
>  FString 路径消费，但**未证伪**更深 materializer 内部的路径相关 compare。
>  本 trial 只负责后者；若最终证伪，必须明确区分"哪一层"被排除。
- **materializer 分流的关键不在 pointer 而在 compare accumulator**：
>  C27 §14 已指出 success / fail 的 post-`1c8` pair 相同，分流由 pre-`1c8`
>  state 驱动。任何路径修复方案的目标不是改变 `x21/x22`，而是改变
>  compare accumulator 的演进，使 `0x10432a224` 不再被选中。
- **`playcover_launch_complete` ≠ app 已安全启动**：NGR 会在该事件之
>  后进入 UE4 bootstrap、可能进入 fatal 路径。
- **`session briefly ready → disconnected`** 是比"窗口看起来闪退"更
>  稳定的 automation 判据，但不足以判定"app 活着"——需要配合 CPU / RSS
>  / 窗口可见性指标。
- **`effectiveLaunchEnvironment` 两侧对齐**：`PlayApp.swift` 与
>  `LaunchService.swift` 必须同步维护
>  `minimalStartupCompatDiagnosticEnvironment`。
- **PlayCover GUI 内存 vs plist 一致性**：`AppSettings.settings` 的
>  `didSet` 会 encode 回 plist；改 `com.tencent.ngr` 的 settings 不要
>  只用 `plutil -replace`（会被下一次 GUI launch 覆盖），要走
>  `update_app_settings` MCP 或依赖 `PlayApp.launch()` 的 self-heal。
- **`.ips` 的 image offset 交叉验证**：`usedImage.base` + triggered
>  thread `frames[0].imageOffset` + LLDB `faultPc` 三者应一致。
- **`launch_app_with_lldb` headless 结构化证据**：消费
>  `lldb.stopReason` / `lldb.faultingFrame` / `lldb.faultingInstruction`
>  / `lldb.backtrace` / `lldb.blockingDialogWindows` / `lldb.watchpointHits`，
>  不要把完整 transcript 当人工日志用。`timedOut=true` + `didStop=true`
>  + 完整 fault 字段 = 证据有效。
- **HOK-016 LLDB BP / watchpoint 踩坑**：对 NGR 主 image 内的固定地址
>  设 BP 必须用 `breakpoint set --shlib NGR --address <unslid>`；
>  `breakpoint set` **不支持** `--script-type python -F <func>`，必须
>  拆成 `breakpoint set ...` + `breakpoint command add -s python -F
>  <func>` 两步；`-C 'shell cmd'` 与 `command add -s python -F` 不能
>  同时作用于同一 BP。完整脚本清单与踩坑汇总见
>  `HOK-016-appendix-tooling.md`。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md`：本文件；唯一维护当前主线、
>  TODO 与默认验证口径。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/00-Dashboard.md`：母 Dashboard；路径差异 trial 的
>  结果最终需要回流到母 Dashboard 的 HOK-016 主线。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：当前母线 HOK-016 的
>  目的、核心证据、根因链、修复方向。**阅读建议：只要路径差异假设与
>  HOK-016-C.2.7 相关就总是读取。**

### 当前兜底链路（修改这些代码/文件需要同步更新本 Dashboard）

代码/文件改动路径：

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的
>  dyld constructor / interpose 入口；若 PDT-002 需要 runtime 路径
>  swizzle，代码落点在这里。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：PlayTools
>  启动顺序、compat 诊断事件。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：
>  runtime settings 读取。
- `PlayCover/Model/PlayApp.swift`：GUI 启动环境、
>  `effectiveLaunchEnvironment()`。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 启动环
>  境、`minimalStartupCompatDiagnosticEnvironment`。

### 按需读取（与当前主线无直接关系，出问题再翻）

> 下列文档日常不展开；只在具体排查内容涉及时按建议展开。每份文档顶部
> 都标了自己的"阅读建议"；附录开头同样有"阅读建议"。

- `LocalDocs/HOKCrash/HOK-016-appendix-C23-C24.md`：readiness B 内部控制流。
>  **阅读建议：需要复核 C.2.4 "路径只是参数"结论的适用范围时按需读取。**
- `LocalDocs/HOKCrash/HOK-016-appendix-C25-C26.md`：rootB / mainChunk 缺口。
>  **阅读建议：需要理解 rootB lazy-init 时按需读取。**
- `LocalDocs/HOKCrash/HOK-016-appendix-C27.md`：HOK-016-C.2.7 完整证据。
>  **阅读建议：需要复盘 materializer compare logic 或 pre-`1c8` state
>  分流机制时总是读取；优先看 §14。**
- `LocalDocs/HOKCrash/HOK-012-工具链与方法论归档.md`：LLDB 工具链。
>  **阅读建议：需要新增 LLDB probe 或复用 Python callback helper 时按需读取。**

### 代码 / 脚本速查

脚本详细说明统一沉淀在对应子文档与附录里，主文档只保留"名字 → 干什么
> → 想读细节看哪里"的索引：

- `Scripts/hok004_ngr_startup_runner.py`：10s settle window 启动
>  baseline runner。→ `HOK-004-启动验证与settle-window.md`
- `Scripts/hok006_ngr_lldb_runner.py`：LLDB 自动化入口。
>  → `HOK-006-LLDB归因与crash-window压缩.md`
- `Scripts/hok016c27_*`：HOK-016-C.2.7 系列 locator / watchpoint / trace
>  脚本；复用其 probe 模式时参考 `HOK-016-appendix-tooling.md`。
- `Scripts/pdt001_ngr_materializer_literal_extractor.py`（待建）：
>  提取 `0x10432a068` 内部 compare literal 的离线扫描器。

### 不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`、`LocalDocs/MCPFinal/*`：与本
>  trial 无关。
- 未来若本目录新增 `PDT-xxx-*.md`，默认规则：**只有本 Dashboard 明确
>  点名的当前主线子文档才需要随手读取**。
