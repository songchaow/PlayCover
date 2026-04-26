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

**路径差异假设已被证伪。** PDT-007-B 对照实验（HOK-014 auto-confirm 模式下）：有 disk patch 和无 disk patch 均 crash（overallPass=False，各产生 1 个 crash report）。`ConvertToPlatformPath` 的 `/Users/` 路径转换不是 crash 的原因。本 trial 应关闭，回到 `HOK-016-C.2.7` 的原有 materializer state 分析。

### 当前状态摘要

- **PDT-007-B 对照实验结果**：
>  | 条件 | overallPass | disconnected | crash reports |
>  |---|---|---|---|
>  | 有 disk patch + auto-confirm | False | True | 1 |
>  | 无 disk patch + auto-confirm | False | True | 1 |
>  - 产物：`build/pdt-007b-with-patch.json`、`build/pdt-007b-without-patch.json`
- **HOK-014 行为**：拦截 `UIAlertController` 的 present 调用，不展示 UI，但立即触发 alert 的确认 action handler（等效于用户瞬间点了 OK）。游戏原始的后续流程（包括 fatal→crash）照常进行，只是没有 UI 阻塞。
- **结论**：`ConvertToPlatformPath` 对 `/Users/` 路径的重新拼接**不是** `QtsFileSystem Create Failed!!` 后 crash 的原因。crash 发生在 alert 确认之后的 fatal 路径中，与路径转换无关。

### 修复路线

1. **`PDT-001-A`（DONE）**：`0x10432a068` fixed literal 为 `"r"` / `"rb"`，与路径无关。子文档：`PDT-001A-compare-literals.md`。
2. **`PDT-004`（DONE）**：natural run target `0x100128c6c` 是 dispatch stub，无 compare literal。子文档：`PDT-004-natural-target-literal.md`。
3. **`PDT-005`（DONE）**：`ConvertToPlatformPath` 在 NGR 中的地址已确定为 **`0x10463f204`**。子文档：`PDT-005-locate-convert-to-platform-path.md`。
4. **`PDT-006`（DONE，方案已证伪）**：runtime patch 因 `__TEXT` 写保护不可行。子文档：`PDT-006-convert-patch-prototype.md`。
5. **`PDT-007`（DONE）**：runtime inline hook 不可行。
6. **`PDT-007-A`（DONE）**：Disk patch 已实现并验证。子文档：`PDT-007A-disk-patch-prototype.md`。
7. **`PDT-007-B`（DONE，假设证伪）**：对照实验——有 patch / 无 patch 均 crash，路径差异不是 crash 原因。
8. **`PDT-009-A`（TODO，当前主线）**：留下结构化证据，关闭本 trial，回到 `HOK-016-C.2.7`。

### 当前兜底链路（按 PlayTools constructor 执行序）

HOK-013/015/010 兜底链路继续保留。

HOK-014 拦截 `UIAlertController` 的 present 调用：不展示 UI，但立即触发 alert 的确认 action handler（等效于用户瞬间点了 OK），游戏后续流程照常进行。诊断事件 `hok014_ngr_alert_suppressed` 含 `actionCount`、action `title`。

PDT-006 的 runtime patch 代码保留在 `PlayLoader.m` 中，日常启动时只会静默记录一次 `mprotect-failed`，不影响功能。

### 已证伪路径（高层记录）

- **路径差异假设（本 trial）**：PDT-007-B 对照实验证伪。有 disk patch / 无 disk patch 均 crash，`ConvertToPlatformPath` 路径转换不是 crash 原因。
- **"路径差异已被 HOK-016-C.2.4 证伪"**：C.2.4 的结论是两个 FString 路径
>  `../../../NGR/Content/paks` 与 `/Users/...` **只是 `0x10432dd98` 的参数**，
>  没被 `0x1001ac168` / `0x1001cd114` 实际消费。

### 当前卡点

无。本 trial 已完成，路径差异假设已被证伪。

### 下一步默认规划

1. **执行 `PDT-009-A`**：关闭本 trial，回流结论到母 Dashboard `HOK-016`。
2. 收尾执行 `git commit`。

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
| PDT-001-A | DONE | `0x10432a068` compare literal 为 UTF-16 `"r"` / `"rb"`，与路径无关 | `PDT-001A-compare-literals.md` |
| PDT-004 | DONE | natural run target `0x100128c6c` 是 dispatch stub，无 compare literal | `PDT-004-natural-target-literal.md` |
| PDT-005 | DONE | `ConvertToPlatformPath` 地址 `0x10463f204`（边界 `..0x10463ff48`） | `PDT-005-locate-convert-to-platform-path.md` |
| PDT-006 | DONE（方案已证伪） | runtime patch 因 `__TEXT` 写保护不可行 | `PDT-006-convert-patch-prototype.md` |
| PDT-007 | DONE | runtime inline hook 不可行 | — |
| PDT-007-A | DONE | Disk patch 已实现，`/Users/` 路径透传 | `PDT-007A-disk-patch-prototype.md` |
| PDT-007-B | DONE（假设证伪） | 对照实验：有 patch / 无 patch 均 crash → 路径差异不是 crash 原因 | — |
| PDT-009-A | TODO（当前主线） | 关闭本 trial，回流结论到母 Dashboard `HOK-016` | — |

## 高频复用经验（当前仍适用的）

- **路径差异假设已证伪**：PDT-007-B 对照实验证实 `ConvertToPlatformPath` 对 `/Users/` 路径的重新拼接不是 crash 原因。有 disk patch / 无 disk patch 均 crash。crash 发生在 `QtsFileSystem Create Failed!!` alert 确认之后的 fatal 路径中。
- **macOS `__TEXT` 段 runtime 不可写**：PDT-006 已证实 `mprotect`、`vm_protect`（max+current）、`vm_write` 均无法修改 code-signed NGR binary 的 `__TEXT` 段。disk patch（修改文件 + 重新签名）是唯一可行路径。
- **HOK-014 行为**：拦截 `UIAlertController` present，不展示 UI，立即触发确认 action handler（等效用户瞬间点 OK）。游戏后续流程照常，只是没有 UI 阻塞。
- **`playcover_launch_complete` ≠ app 已安全启动**：NGR 会在该事件之后进入 UE4 bootstrap、可能进入 fatal 路径。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/00-Dashboard.md`：母 Dashboard；路径差异 trial 的结果最终需要回流到母 Dashboard 的 HOK-016 主线。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：当前母线 HOK-016 的目的、核心证据、根因链、修复方向。**阅读建议：只要路径差异假设与 HOK-016-C.2.7 相关就总是读取。**

### UE4 C++ 源码参考（与当前主线直接相关）

> **阅读建议**：任何涉及路径转换、I/O 层行为、或 `FIOSPlatformFile` 相关排查时，都应结合 UE4 源码一起看，而不是只依赖二进制反汇编推断。

- `/Users/songdogwang/Codes/UnrealEngine/Engine/Source/Runtime/Core/Private/IOS/IOSPlatformFile.cpp`
>  - `FIOSPlatformFile::ConvertToPlatformPath()`（第 964-1039 行）：核心路径转换函数。
>    - `/var/` 开头 → **直接透传**，不做任何转换；
>    - `~/` 开头 → 替换为 `[[NSBundle mainBundle] bundlePath]`；
>    - `../` 或匹配 `AdditionalRootDirectory` → 经过 `ReplaceInline("../")`、`FPaths::MakePlatformFilename`、以及基于 `NSSearchPathForDirectoriesInDomains` 的重新拼接；
>    - 非 `/var/` 的绝对路径（如 `/Users/...`）→ 落入 write path 分支，被映射到 `NSDocumentDirectory` 或 `NSLibraryDirectory` 下。
>  - 这意味着 iOS 真机的 `/var/mobile/Containers/...` 路径在 UE4 层是**透传的**，而 PlayCover 的 `/Users/...` 路径会被 UE4 **重新拼接成不同的绝对路径**。这是 PathDifferenceTrial 当前主线的核心工程依据。

### 当前兜底链路（修改这些代码/文件需要同步更新本 Dashboard）

代码/文件改动路径：

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：PlayTools 启动顺序、compat 诊断事件。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime settings 读取。
- `PlayCover/Model/PlayApp.swift`：GUI 启动环境、`effectiveLaunchEnvironment()`。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 启动环境、`minimalStartupCompatDiagnosticEnvironment`。

### 按需读取（与当前主线无直接关系，出问题再翻）

> 下列文档日常不展开；只在具体排查内容涉及时按建议展开。每份文档顶部都标了自己的"阅读建议"。

- `LocalDocs/HOKCrash/HOK-016-appendix-C23-C24.md`：readiness B 内部控制流。**阅读建议：需要复核 C.2.4 "路径只是参数"结论的适用范围时按需读取。**
- `LocalDocs/HOKCrash/HOK-016-appendix-C25-C26.md`：rootB / mainChunk 缺口。**阅读建议：需要理解 rootB lazy-init 时按需读取。**
- `LocalDocs/HOKCrash/HOK-016-appendix-C27.md`：HOK-016-C.2.7 完整证据。**阅读建议：需要复盘 materializer compare logic 或 pre-`1c8` state 分流机制时总是读取；优先看 §14。**
- `LocalDocs/HOKCrash/HOK-012-工具链与方法论归档.md`：LLDB 工具链。**阅读建议：需要新增 LLDB probe 或复用 Python callback helper 时按需读取。**

### 代码 / 脚本速查

脚本详细说明统一沉淀在对应子文档与附录里，主文档只保留"名字 → 干什么 → 想读细节看哪里"的索引：

- `Scripts/hok004_ngr_startup_runner.py`：10s settle window 启动 baseline runner。→ `HOK-004-启动验证与settle-window.md`
- `Scripts/hok006_ngr_lldb_runner.py`：LLDB 自动化入口。→ `HOK-006-LLDB归因与crash-window压缩.md`
- `Scripts/hok016c27_*`：HOK-016-C.2.7 系列 locator / watchpoint / trace 脚本；复用其 probe 模式时参考 `HOK-016-appendix-tooling.md`。
- `Scripts/pdt001_ngr_materializer_literal_extractor.py`：提取 `0x10432a068` 内部 compare literal 的离线扫描器。→ `PDT-001A-compare-literals.md`
- `Scripts/pdt005_ngr_convert_to_platform_path_locator.py`：定位 `ConvertToPlatformPath` 实现地址。→ `PDT-005-locate-convert-to-platform-path.md`
- `Scripts/pdt007a_disk_patch_ngr.py`：NGR binary disk patch 工具（patch / restore / codesign）。→ `PDT-007A-disk-patch-prototype.md`

### 所有子文档阅读建议速查

| 子文档 | 阅读建议 |
|---|---|
| `PDT-001A-compare-literals.md` | 在需要复核 `0x10432a068` compare literal 离线证据时按需读取。 |
| `PDT-004-natural-target-literal.md` | 在需要复核 natural run target `0x100128c6c` 结构、或对比 dual-force / natural run 差异时按需读取。 |
| `PDT-005-locate-convert-to-platform-path.md` | 在需要复核 `ConvertToPlatformPath` 地址定位证据、或确认 patch 锚点时按需读取。 |
| `PDT-006-convert-patch-prototype.md` | 在需要审计 runtime patch 实现细节、或确认"runtime inline hook 不可行"的历史证据时按需读取。 |
| `PDT-007A-disk-patch-prototype.md` | 在需要实现或审计 disk patch 技术细节时读取；当前主线子文档，执行 A1~A6 前建议先读。 |

### 不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`、`LocalDocs/MCPFinal/*`：与本 trial 无关。
- 未来若本目录新增 `PDT-xxx-*.md`，默认规则：**只有本 Dashboard 明确点名的当前主线子文档才需要随手读取**。
