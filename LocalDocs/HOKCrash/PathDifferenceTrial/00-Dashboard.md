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

`PDT-001-B-revised`：在 `PDT-001-A` 已确认 `0x10432a068` fixed literal 与路径无关后，
> 路径差异假设的验证重心从"materializer 内部固定模板"转移到 **UE4 I/O 层路径转换**
> 对 `entryX1` / selected buffer 的影响。核心新证据：UE4 `FIOSPlatformFile::ConvertToPlatformPath`
> 对 `/var/` 开头路径直接透传，对 `/Users/` / `~/` / `../` 路径做 `ReplaceInline("../")`、
> `FPaths::MakePlatformFilename`、以及基于 `NSDocumentDirectory` / `NSLibraryDirectory` 的重新拼接。
> 因此 iOS 真机的 `/var/...` 与 PlayCover 的 `/Users/...` 在 UE4 层会被**不同处理**，
> 这种差异可能改变 materializer 看到的 selected buffer 内容，从而驱动 compare accumulator
> 走向不同分支。本 trial 继续推进，目标：验证或证伪这种**上层路径转换差异**是否是根因。

### 当前状态摘要

- **现象层差异仍然成立**：HOK-016-C.2.7 的自然 run 中，success / fail 的 pre-`1c8`
>  差异仍表现为 `entryX1` 字符串不同：
>   - success 链：`entryX1="../../../NGR/Content/Paks/1/1.db"`；
>   - fail 链：`entryX1="/Users/songdogwang/..."`。
- **`PDT-001-A` 结论（已收窄）**：`Scripts/pdt001_ngr_materializer_literal_extractor.py`
>  从 `0x10432a068` 提取到的 fixed literal 为 UTF-16 `"r"` / `"rb"`，确实与路径无关。
>  但这**只排除了** "materializer 内部固定模板直接做路径相关 compare" 这层假设；
>  **没有排除** 上层路径转换差异通过改变 selected buffer 内容来间接影响 compare accumulator 的可能。
- **UE4 `ConvertToPlatformPath` 新证据（关键）**：`@/Users/songdogwang/Codes/UnrealEngine/Engine/Source/Runtime/Core/Private/IOS/IOSPlatformFile.cpp`
>  第 964-1039 行显示：
>   - `Result.StartsWith(TEXT("/var/"))` → **直接原样返回**，不做任何转换；
>   - `Result.StartsWith(TEXT("~/"))` → 替换为 `[[NSBundle mainBundle] bundlePath]`；
>   - `Result.Contains(TEXT("../"))` 或 `Result.StartsWith(AdditionalRootDirectory)` →
>     经过 `ReplaceInline("../")`、`FPaths::MakePlatformFilename`、以及基于
>     `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory/NSLibraryDirectory)` 的重新拼接；
>   - 非 `/var/` 的绝对路径（如 `/Users/...`）会落入 write path 分支，被映射到
>     `NSDocumentDirectory` 或 `NSLibraryDirectory` 下。
>  这意味着：**iOS 真机上 `/var/mobile/Containers/...` 路径在 UE4 层是透传的，而 PlayCover
>  的 `/Users/...` 路径会被 UE4 重新拼接成不同的绝对路径**。这种差异可能改变：
>   - `entryX1` 在进入 materializer 前的最终字符串内容；
>   - 该字符串被复制到 selected buffer 时的长度、编码、或截断行为；
>   - compare accumulator 在逐字符比较时的演进路径。
- **natural run target 偏移的提醒**：natural run 中 `0x100122f54` 的 `x8(target)`
>  实际是 `0x100128c6c` / `0x115a5eb30`，不是 `0x10432a068`。因此 `PDT-001-A`
>  的 fixed literal 结论只适用于 dual-force 路径中的 `0x10432a068`；natural run
>  实际 target 的 compare literal 尚未提取。这是本 trial 必须继续推进的硬理由。
- **对 C.5 历史线索的重新解读**：`PlayLoader.m` 里已有 `/Users/... →
>  "../../../NGR/Content/Paks/1/1.db"` 的重定向尝试。结合 `ConvertToPlatformPath`
>  的源码，这条线索现在有了更具体的工程解释：C.5 的开发者可能观察到 `/Users/...`
>  路径在 UE4 层被转换后与 iOS 透传的 `/var/...` 不同，因此尝试把路径改回相对路径
>  `"../../../..."` 以绕过 `ConvertToPlatformPath` 的转换逻辑。这反而**加强了**
>  路径差异假设的可信度，而不是削弱它。

### 修复路线（调整后）

1. **`PDT-001-A`（已完成，结论已收窄）**：`0x10432a068` fixed literal 为 `"r"` / `"rb"`，
>    与路径无关。结构化证据：`build/pdt-001a-compare-literals.json`；
>    细节：`PDT-001A-compare-literals.md`。
2. **`PDT-001-B-revised`（当前主线）**：验证 UE4 `ConvertToPlatformPath` 差异是否是根因。
>    - **目标**：在 PlayTools 层对 `NSBundle` / `NSSearchPathForDirectoriesInDomains`
>      做临时 swizzle，让 NGR 构造出的路径前缀从 `/Users/...` 变成 `/var/...`，
>      观察 `entryX1` 是否随之改变，以及 `hok014_ngr_alert_suppressed` 是否归零。
>    - **关键验证点**：`ConvertToPlatformPath` 对 `/var/` 透传、对 `/Users/` 转换；
>      若把 PlayCover 的路径前缀伪装成 `/var/`，UE4 是否会直接透传而不做转换，
>      从而使 materializer 看到的 selected buffer 与 iOS 真机一致。
>    - **产物**：`build/pdt-001b-revised-path-redirect-report.json`。
3. **`PDT-002`（TODO）**：若 `PDT-001-B-revised` 证实路径转换差异是根因，设计 PlayTools 层
>    bundle-scoped 最小路径伪装方案（如 `ngrPathRedirectEnabled` 选项，统一把
>    `NSDocumentDirectory` / `NSLibraryDirectory` 返回路径前缀改为 `/var/mobile/Containers/...`）。
4. **`PDT-003`（TODO）**：若 `PDT-001-B-revised` 证伪，留下结构化证据，关闭本 trial。
5. **`PDT-004`（TODO，硬前置）**：提取 natural run 实际 target `0x100128c6c` 的 compare literal，
>    确认其是否与 `0x10432a068` 的 `"r"` / `"rb"` 一致。若不一致，需重新评估
>    `PDT-001-A` 结论对 natural run 的适用性。

### 当前兜底链路（按 PlayTools constructor 执行序）

路径差异 trial 当前**不改动**既有 HOK-013/014/015/010 兜底链路；这些 hook
> 继续保留，用于维持 NGR 能稳定走到 HOK-016 的 failure window。它们不是
> 本 trial 的污染源。
>
> 唯一需要单独注意的是 HOK-016-C.5：
> - `PlayLoader.m` 已存在 `/Users/... → "../../../NGR/Content/Paks/1/1.db"`
>   的 materializer 重定向尝试；
> - 但该方案依赖 vtable patch，因 `__DATA_CONST` 写保护与 natural-run target
>   偏移而未在 natural run 中生效；
> - 因此本 trial 后续实验应**绕开 C.5 的 patch 落点**，改在更上层 API 做
>   swizzle / interpose，失败时可立即回退。
>
> 唯一新增依赖：
> - 若 PDT-001-A / PDT-001-B 需要 live trace `0x10432a068` 内部的 compare literal
>   或 `0x100122f54` 的返回值，使用 HOK-012 已固化的 LLDB 工具链
>   （`Scripts/hok006_ngr_lldb_runner.py`）。

### 已证伪路径（高层记录）

- **"路径差异已被 HOK-016-C.2.4 证伪"**：C.2.4 的结论是两个 FString 路径
>  `../../../NGR/Content/paks` 与 `/Users/...` **只是 `0x10432dd98` 的参数**，
>  没被 `0x1001ac168` / `0x1001cd114` 实际消费。但这**只证伪了 readiness B
>  dispatcher 层的路径消费**，并未证伪更深层的 materializer（`0x10432a068`）
>  内部是否在做路径相关的字符串比较。路径差异假设关注的是后者，因此
>  C.2.4 的证伪结论不直接覆盖本 trial。

> 每条证伪的具体实验、寄存器值、脚本产物都在对应子文档里。

### 当前卡点

1. **`PDT-001-A` 结论的适用范围限制**：`PDT-001-A` 的结论只适用于 `0x10432a068`；
>   natural run 实际 target `0x100128c6c` 的 compare literal 尚未提取。在
>   `PDT-004` 完成前，不能断言 natural run 的 materializer 也使用与路径无关的 fixed literal。
2. **`PDT-001-B-revised` 的精确落点未验证**：UE4 `ConvertToPlatformPath` 的源码
>   已确认 `/var/` 透传、`/Users/` 转换，但 NGR 在 PlayCover 中实际构造出的
>   `entryX1="/Users/..."` 是否确实经过了这个转换、以及转换后的结果是什么，
>   还需要 live trace 或静态定位来确认。
3. **路径伪装方案的副作用未知**：若强行把 `NSDocumentDirectory` / `NSLibraryDirectory`
>   返回路径前缀改为 `/var/mobile/Containers/...`，可能影响 UE4 的实际文件 I/O
>   落盘位置（因为 `/var/mobile/Containers/...` 在 macOS 上不是真实路径）。
>   `PDT-001-B-revised` 必须设计成**临时、可开关、可回退**的实验，不能默认 apply。

### 下一步默认规划

1. **执行 `PDT-004`**：提取 natural run 实际 target `0x100128c6c` 的 compare literal，
>    确认其是否与 `0x10432a068` 的 `"r"` / `"rb"` 一致。
>    - 若一致：`PDT-001-A` 结论适用范围扩大，继续推进 `PDT-001-B-revised`。
>    - 若不一致：重新评估 `PDT-001-A` 结论，可能需要重新提取 natural run target 的 literal。
>    - 产物：`build/pdt-004-natural-target-literal.json`。
2. **执行 `PDT-001-B-revised`**：在 PlayTools 层对 `NSBundle` / `NSSearchPathForDirectoriesInDomains`
>    做临时 swizzle，让 NGR 构造出的路径前缀从 `/Users/...` 变成 `/var/...`，
>    观察 `entryX1` 是否改变、`hok014_ngr_alert_suppressed` 是否归零。
>    - 产物：`build/pdt-001b-revised-path-redirect-report.json`。
3. **若 `PDT-001-B-revised` 证实路径转换差异是根因**：进入 `PDT-002`，设计最小可落地方案。
4. **若 `PDT-001-B-revised` 证伪**：更新 Dashboard TODO，关闭本 trial，回到 `HOK-016-C.2.7`。
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
| PDT-001-A | DONE（结论已收窄） | 已离线提取 `0x10432a068` compare literal；结果为 UTF-16 `"r"` / `"rb"`，与路径/文件名无关。但此结论只适用于 `0x10432a068`，natural run 实际 target `0x100128c6c` 的 literal 尚未提取 | `PDT-001A-compare-literals.md` |
| PDT-001-B-revised | TODO（当前主线） | 验证 UE4 `ConvertToPlatformPath` 差异是否是根因：对 `NSBundle` / `NSSearchPath...` 做临时 swizzle，让路径前缀从 `/Users/...` 变成 `/var/...`，观察 `entryX1` 与 `hok014_ngr_alert_suppressed` 是否收敛 | 待建 `PDT-001B-revised-path-redirect-live.md` |
| PDT-002 | TODO | 若 `PDT-001-B-revised` 证实路径转换差异是根因，设计 PlayTools 层最小可落地 bundle-scoped 路径伪装方案 | 待建 |
| PDT-003 | TODO | 若 `PDT-001-B-revised` 证伪，留下结构化证据并关闭本 trial | 待建 |
| PDT-004 | TODO（硬前置） | 提取 natural run 实际 target `0x100128c6c` 的 compare literal，确认是否与 `0x10432a068` 的 `"r"` / `"rb"` 一致 | 待建 |

## 高频复用经验（当前仍适用的）

以下经验跨任务复用概率高，写在主文档便于 agent 日常直接记住；更长的
> 分类细节见对应子文档。

- **"路径差异假设的边界"**：HOK-016-C.2.4 已证伪 `0x10432dd98` 入口处的
>  FString 路径消费；本轮 `PDT-001-A` 证实 `0x10432a068` 的 fixed literal
>  只是 UTF-16 `"r"` / `"rb"`，**不是路径模板**。因此 "materializer fixed literal
>  直接做路径相关 compare" 这层假设已被排除。但 UE4 `ConvertToPlatformPath` 的
>  源码显示 `/var/` 透传、`/Users/` 转换，这意味着**上层路径转换差异可能通过
>  改变 selected buffer 内容来间接影响 compare accumulator**，这一层尚未被排除。
>  本 trial 当前主线正是验证这一层。
- **materializer 分流的关键不在 pointer 而在 compare accumulator**：
>  C27 §14 已指出 success / fail 的 post-`1c8` pair 相同，分流由 pre-`1c8`
>  state 驱动。任何路径修复方案的目标不是改变 `x21/x22`，而是改变
>  compare accumulator 的演进，使 `0x10432a224` 不再被选中。
- **既有 HOK hook 对本 trial 的影响边界要分清**：HOK-013 / HOK-014 /
>  HOK-015 / HOK-010 不会直接改写 materializer 的路径输入；它们不是本
>  trial 的污染源。唯一与路径直接相关的是 HOK-016-C.5，但 C.5 因
>  `__DATA_CONST` 写保护与 natural-run target 偏移而**未在 natural run 中生效**，
>  因此当前观察到的 `entryX1="/Users/..."` 仍可视为未修正的原始现象。
- **C.5 更像先验线索，不是当前执行路径**：`PlayLoader.m` 里已有
>  `/Users/... → "../../../NGR/Content/Paks/1/1.db"` 的重定向尝试，说明
>  路径差异假设有历史依据；但后续实验应避开 vtable patch，优先选上层 API
>  swizzle 作为新的验证入口。
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
