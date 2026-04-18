## HOKCrash Dashboard

> **单一来源规则**：`com.tencent.ngr`（`王者荣耀世界`）启动崩溃问题的优先级、主线、TODO、验证口径只在本文维护；长日志、单轮实验细节和大段崩溃分析下沉到子文档，主文档始终保持可快速通读。

## 最终目标

- 让 `com.tencent.ngr` 在 PlayCover 中**稳定启动并持续存活**，不再出现当前这类启动期秒崩。
- 当前**不要求**为该 app 保留 `metal capture` 与 `shader source replacement`；兼容启动优先于截帧能力。
- 默认先走**最小、可逆、app-scoped** 的 PlayCover/PlayTools 兼容修复；只有这条线证伪后，才升级到 app 二进制意图分析与可逆 patch。
- 日常构建、验证、证据收集必须能由 agent 独立完成；若某一步确实需要用户介入，必须先得到用户确认。

## 全局约束

- 对 `com.tencent.ngr` 的修复默认应为**按 bundle 精准生效**，不扩大为全局行为改动，除非后续证据证明全局改动安全且必要。
- 对该 app 的默认兼容配置应把 `metal capture`、`startup injection`、`shader replacement` 视为**非必要能力**；它们不是日常 gate。
- 默认优先级：**兼容配置 / 运行时最小化副作用** → **延迟或分层关闭早期 bootstrap** → **LLDB / faulting instruction 归因** → **app 二进制 patch**。
- 不允许把"用户手工登录、手工点 UI、手工看窗口表现"作为日常验证 gate；这些只能作为例外步骤，且需先确认。
- 主文档只保留决策信息、默认执行路径和高频复用经验；历史细节、长日志、反复试错过程必须下沉到子文档。

## 主线任务

- **当前结论**：`HOK-004`、`HOK-005A`、`HOK-005B`、`HOK-005C`、`HOK-005D`、`HOK-006`、`HOK-007A`、`HOK-007B` 均已完成。候选 E（`ldr x8,[x19]` → `b 0x10480df24`，4 字节可逆）已把原 dyld-era null deref 从 `0x10480df08` / `far=0x0` 绕开，app 已经可以跑到**游戏自己的 UI 层**，并弹出 `Message: QtsFileSystem Create Failed!!` 提示框；用户点 OK 后 app 退出，伴随新 `.ips`（`NGR-2026-04-18-154541.ips`，`far=0x30`）。`QtsFileSystem` 来自 `Frameworks/GCloud.framework`（见 `GCloudQtsPufferInterface.h`），是腾讯 GCloud 的文件系统子模块，它的创建失败几乎可以肯定是**当前强制把 `rootWorkDir=false`** 导致的——iOS 版 NGR 假设 cwd 是 `/`，而最小兼容 gate 当前显式保留了 macOS container 下的 cwd。
- **当前已知事实**：
  - `PlaySettings.swift` 中有 `@objc lazy var rootWorkDir = disableForMinimalStartupCompat(settingsData.rootWorkDir)`，`appliesMinimalStartupCompat` 对 `com.tencent.ngr` 恒为 true，因此 host 侧无论如何设置，runtime 都会看到 `rootWorkDir=false`。
  - `PlayCover.swift` 在 `rootWorkDir=false` 分支只发 `playcover_working_directory_preserved` 事件，**不会** `chdir("/")`；在 `rootWorkDir=true` 分支才会 `FileManager.default.changeCurrentDirectoryPath("/")` 并发 `playcover_working_directory_changed`。
  - `hok007b_ngr_patch_runner.py` 应用状态：`currentBytesHex=07000014`，`build/hok-007b-backups/hok-007b-b0e109d761a3eefb.bin` 存在，可用 `--revert` 回滚；不建议在 HOK-010 验证前回滚。
  - 最新 `.ips`：`NGR-2026-04-18-154537.ips`（`pc=0x10915b114` / `far=0x50`）、`NGR-2026-04-18-154541.ips`（`far=0x30`），两者都明显不在原 `0x10480df08` / `far=0x0` 窗口。
- **当前主线**：切换到 **`HOK-010`：把 `rootWorkDir` 从 `minimalStartupCompat` 的强制关闭清单里摘除**，让 `com.tencent.ngr` 继续走 `chdir("/")` 的 iOS 风格启动，以消除 `QtsFileSystem Create Failed!!`。二进制 patch 路线（`HOK-007C`：为 `0x10915b114` / `far=0x50` 再做一轮 callsite 映射与最小 patch）**暂时降优先级**，因为这个下游 null deref 几乎一定是 `QtsFileSystem` 创建失败后的 app 层空指针，修好 HOK-010 很可能直接把它一并消掉。
- **当前卡点**：
  - 未确认 `QtsFileSystem` 的具体失败原因是否 100% 等同于 cwd=`/`，还存在其它可能（如沙盒写权限、keychain、Puffer 校验），因此 HOK-010 的 live 验证必须拿 `launch-events.jsonl` 里新增的 `playcover_working_directory_changed` + 弹窗是否消失 + 新 `.ips` 是否继续减少一并判断。
  - 最小兼容 gate 此前把"`playcover_working_directory_preserved`"列为正面证据，是**错的**；之后要同步把"到底哪些 compat event 属于正面证据"校准一次。
- **下一步默认规划**：
  1. 执行 `HOK-010`：把 `rootWorkDir` 从 `PlaySettings.disableForMinimalStartupCompat(...)` 链上摘除（改成直接读 `settingsData.rootWorkDir`，或者用 `appliesMinimalStartupCompat` 专门给它返回 `true`），同步调整 `hok004_ngr_startup_runner.py` 里 `MINIMAL_COMPAT_SETTINGS` / `REQUIRED_COMPAT_EVENTS`，让默认验证口径改成"期望 `playcover_working_directory_changed`，不期望 `playcover_working_directory_preserved`"。
  2. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` + `./BuildScripts/build_and_install.sh` 后跑一次 `hok004_ngr_startup_runner.py` live 闭环，确认 `playcover_working_directory_changed` 出现、弹窗消失、session 不再 briefly ready→退出、无新同类 `.ips`。
  3. 若 HOK-010 live 验证通过，再评估是否彻底关闭 HOK-007C；若 QtsFileSystem 弹窗确实消失但仍有 `far=0x50`/`far=0x30` 崩溃，则恢复 HOK-007C 优先级并用 `hok007_ngr_callsite_mapper.py` + `hok007b_ngr_patch_runner.py` 的同一套口径继续推进。
  4. 任何情况下都**不要**先回滚候选 E；先证明 HOK-010 能独立收敛 QtsFileSystem 问题，再单独决定候选 E 的去留。

## 构建与验证的方法

### 日常默认方法（必须可由 agent 独立完成）

- **构建 PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- **涉及主 app / 注入 / 安装链路时**：`./BuildScripts/build_and_install.sh`
- **读取 / 固化目标 app 配置**：优先使用 `get_app_settings` / `update_app_settings`，目标是让 `com.tencent.ngr` 处于最小兼容模式；若某个关键开关当前还无法经现有 MCP 稳定写入，则应先补自动化写入路径，而不是退回手工 GUI 点选。
- **运行时验证**：`launch_app` → 固定等待 → `create_session` / `list_sessions`。默认 pass 条件是：session 不再秒断、进程在 settle window 内持续存活、且没有新的同类 `NGR-*.ips` 崩溃报告。
- **证据收集**：每轮都要对照读取
  - `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  - `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- **需要更细粒度定位时**：使用 `launch_app_with_lldb` 做同一轮自动化复现，抓 faulting instruction / backtrace；这仍属于 agent 可独立完成的默认升级路径。

### 当前建议的最小兼容验证口径

- 默认把 `metalCaptureEnabled=false`、`injectMetalCaptureEnvironment=false`、`shaderSourceReplacementEnabled=false`、`playChain=false` 视为 `com.tencent.ngr` 的优先隔离态。**`rootWorkDir` 不再属于"越小越好"——对 `com.tencent.ngr` 应保持 `rootWorkDir=true`**，否则 `QtsFileSystem`（`GCloud.framework`）会在 app UI 层弹 `QtsFileSystem Create Failed!!` 并退出。
- host/plist 原始值与 runtime compat gate 压低后的实际生效值仍需分开解读；`PlaySettings.disableForMinimalStartupCompat(...)` 一旦摘除 `rootWorkDir`，host 侧的 `rootWorkDir=true` 才会真正落到 runtime。
- 只要本轮改动触及启动顺序、PlayTools 注入内容、settings 默认值、per-app gate、签名/重签或 app 包内二进制，就必须重新跑一轮完整的"构建 → 启动 → session → launch diagnostics → crash report"闭环。

### 需要用户确认后才能继续的事项

- 任何需要用户账号、验证码、手工登录、手工进游戏或手工点击复杂 UI 的验证。
- 任何依赖外部下载、替换新的 app 构建、或需要用户提供额外私有材料的步骤。
- 任何必须由用户亲自观察窗口视觉表现、而 agent 无法以 session / diagnostics / crash evidence 替代判断的步骤。

## agent的工作流程介绍

1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。
4. 若任务过大，先拆出新的子任务并追加到 TODO的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 执行完毕后必须整理本文档：删除过时信息，更新 主线 /TODO / 踩坑 / 优先级变化，并把真正高频复用的手工流程收敛成脚本；主文档保持简洁，不能只追加不整理，也不能改变本文档章节结构。
7. 复盘当前技术路线；除最终目标不能改变外，中间方案可根据新发现随时调整。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| HOK-001 | DONE | 复现 `com.tencent.ngr` 启动崩溃并固定第一轮基线证据（session / launch diagnostics / `.ips`） | 暂无；证据已体现在主线结论中 |
| HOK-002 | DONE | 为 `com.tencent.ngr` 落地 app-scoped 最小兼容启动 gate；runtime 现已显式跳过 `MetalCapture` / `library hook`，显式保留 working directory，并在代码路径上压低 `PlayChain` 早期副作用 | 暂无；结果已体现在主线结论与 launch diagnostics 中 |
| HOK-003 | DONE | 已补齐 `com.tencent.ngr` 最小兼容档的 settings 自动化表达能力；MCP 现可稳定写入、读取、reset 并对照 `shaderSourceReplacementEnabled` 等关键开关，但 runtime 实际生效值仍需结合 launch diagnostics 判断 | 暂无；结果已体现在 MCP settings 覆盖与主线结论中 |
| HOK-004 | DONE | 已固化 `com.tencent.ngr` 的自动化启动闭环、`10s settle window` 口径与失败非零退出语义；最新 live 验证确认最小兼容 gate 命中，但 `create_session` 仍超时、session 很快 `disconnected`，并新增 `NGR-2026-04-18-023125.ips` | `LocalDocs/HOKCrash/HOK-004-启动验证与settle-window.md` |
| HOK-005A | DONE | 已对 `com.tencent.ngr` 落地 `DiscordIPC` 的 host/runtime app-scoped skip，并新增 `playcover_discord_skipped` 证据；live 结果表明 Discord 不是首个推动 faulting window 移动的 bootstrap 层 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005B | DONE | 已对 `PlayInput.shared.initialize()` 落地 app-scoped skip，并新增 `playcover_input_skipped` 自动化证据；live 结果表明 `PlayInput` 不是首个推动 faulting window 移动的 bootstrap 层 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005C | DONE | 已对 `PlayScreen.shared.initialize()` 落地 app-scoped skip，并新增 `playcover_screen_skipped` 自动化证据；live 结果表明 `PlayScreen` 不是首个推动 faulting window 移动的 bootstrap 层 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005D | DONE | 已对 `com.tencent.ngr` 落地 `AKInterface.initialize()` 的 `1.0s` app-scoped 延迟，并用 live 结果证明 crash 仍发生在 `AKInterface` 实际初始化之前；主线已转向 `HOK-006` | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-006 | DONE | 已补齐 LLDB 自动化入口与结构化证据链，并用 fresh live 确认崩点仍固定在同一 `NGR` early initializer 路径 | `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md` |
| HOK-007A | DONE | 已建立 `0x10480df08` faulting callsite 的 `LLDB` / `.ips` / `instructionByteStream` / file bytes / `__TEXT,__text` file offset 一致性映射，并固化离线 mapper | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-007B | DONE | 已应用候选 E（`ldr x8,[x19]` → `b 0x10480df24`，4 字节可逆）并通过 HOK-004 baseline + HOK-006 交叉验证，faulting window 已从 `0x10480df08` / `far=0x0` 迁移到 `0x10915b114` / `far=0x50`，app 已能跑到游戏 UI 层 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-010 | TODO | 把 `rootWorkDir` 从 `PlaySettings.disableForMinimalStartupCompat(...)` 摘除，让 `com.tencent.ngr` 保留 `chdir("/")`，以消除 `QtsFileSystem Create Failed!!` 弹窗；同步校准 `hok004_ngr_startup_runner.py` 的 required/forbidden compat events | 待建（默认直接在 `HOK-005-深层bootstrap分层最小化.md` 下增补一节，验证通过后再决定是否独立子文档） |
| HOK-007C | DEFERRED | 为 `0x10915b114` / `far=0x50` / `NGR-2026-04-18-154541.ips` 的下游崩溃做 HOK-007A 离线映射 + HOK-007B 风格最小可逆 patch；**暂缓**，优先看 `HOK-010` 能否把这些下游崩溃一并消除 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-008 | TODO | 将构建、配置、启动、证据收集、结论汇总收敛成可重复的自动化脚本链路 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号/手工 UI 的后续验证（若未来必须验证"进入游戏后"行为） | 暂不执行；执行前必须先得到用户确认 |

## 踩坑与经验

- `playcover_launch_complete` **不等于** app 已安全启动；`com.tencent.ngr` 当前就是在该事件之后很快崩溃。
- `metal capture` 关闭并不自动等于"没有启动期 Metal / library hook 副作用"；对该 app 需要显式做 per-app 最小化处理。
- `shaderSourceReplacementEnabled` 在 host/runtime 默认值里都偏向开启思路，不能想当然地把它当作"默认无影响"。
- 现在可以通过 MCP 稳定写入 / 读取 `shaderSourceReplacementEnabled`，但这只代表 raw settings 已可自动化表达；是否真正命中 `com.tencent.ngr` 的最小兼容 gate，仍应优先看 `launch-events.jsonl`。
- `session briefly ready -> disconnected`，以及像本轮这样 `runtime-* = disconnected` + `pending-* = starting` 持续停留的组合，都是比"窗口看起来闪退"更稳定的自动化判定信号。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped` 是判断 `com.tencent.ngr` 最小兼容 gate 是否真正命中的首选证据；不要再只看 plist 里的原始布尔值。**`playcover_working_directory_preserved` 已不再是正面证据**——对 `com.tencent.ngr` 来说，必须看到 `playcover_working_directory_changed`（即 `chdir("/")`），否则 `QtsFileSystem` 会在 app UI 层失败。
- `playcover_input_skipped` 且不存在对应 launch 的 `playcover_input_initialized`，是 `HOK-005B` 是否真正命中的首选证据；不要再用"猜测 PlayInput 应该没跑起来"替代 launch diagnostics。
- `playcover_screen_skipped` 且不存在对应 launch 的 `playcover_screen_initialized`，是 `HOK-005C` 是否真正命中的首选证据；不要再用"猜测 PlayScreen 应该没有初始化"替代 launch diagnostics。
- 当前阶段的核心不是恢复全部 PlayCover 能力，而是先证明**最小兼容运行**能不能成立；能力恢复必须放在启动稳定之后。
- 当前已没有证据表明 `PlayScreen` 或 `AKInterface` 是 `com.tencent.ngr` 秒崩的首个 faulting mover；若 `playcover_akinterface_delayed` 已出现、而同一 launch 仍未等到 `playcover_akinterface_initialize_started` / `playcover_akinterface_initialized` 就复现相同 `.ips` 签名，应直接进入 `HOK-006`，不要继续在 `HOK-005D` 上反复试时长。
- GUI HTTP MCP 的 `tools/call` 在真实运行中可能返回 `text/event-stream` 包裹的 JSON，而不是裸 JSON；后续若继续沿用 HTTP runner，不要把 POST 响应想当然地按单一内容类型解析。
- 对 `GUI HTTP MCP` 的长调用不要再默认套用固定 `5s` HTTP 超时；`create_session(timeout=10)`、`launch_app_with_lldb(timeoutSeconds=5)` 这类调用必须让 HTTP request timeout 与 tool 自身 timeout 对齐，否则拿到的只会是伪超时而不是真实运行结果。
- `launch_app_with_lldb` 现在在 headless 模式下不再只回"launched"，而会在超时可控的前提下返回结构化 LLDB 证据；后续 HOK-006/HOK-007 自动化应优先消费 `lldb.stopReason`、`lldb.faultingFrame`、`lldb.faultingInstruction`、`lldb.backtrace` 与 `lldb.transcriptTail`，不要再把完整 transcript 仅当成人工阅读日志。
- `launch_app_with_lldb` 返回里的 `timedOut=true` 不等于"没有抓到崩溃"；只要同一轮同时有 `didStop=true`、`faultingFrame`、`faultingInstruction` 与 `backtrace`，就说明 capture window 到期前已经拿到了足够的 LLDB 归因证据。
- `.ips` 的 `usedImage.base`、triggered thread `frames[0].imageOffset` 与 LLDB `faultPc` 可以直接交叉验证当前 callsite 是否已收敛到稳定 image offset；当三者一致时，后续 patch 设计应优先围绕该 image offset / file offset 展开，而不是继续只盯着 symbol 名称。
- `.ips instructionByteStream` 记录的是磁盘小端字节序；它与 `llvm-objdump` 行内展示的 `f9400268` 这类 32-bit word 展示顺序不同。后续如果要做字节级 patch，必须以 `instructionByteStream` / 实际 binary bytes 为准，不能直接拿反汇编展示串做 diff。
- 设计 ARM64 最小可逆 patch 时，不能只看 faulting PC 自己；必须沿反汇编窗口追到 `b`/`b.cc`/`cbz` 等控制流的跳转目标，确认后续基本块是否仍然会回到 faulting 指令上——`physx::PxVehicleConstraintShader::visualiseConstraint` 里 `0x10480dfa0` 路径最终 `b.ne 0x10480df00`，所以只改条件跳转是空操作。
- 在 `NGR` 这类巨型 mach-o 上做 4 字节 patch，`codesign -f -s -` 就够了；不用再去改 embedded provisioning profile 或 framework 链，本轮 `--apply` 后 `codesign -dvv` 仍报 `adhoc` 即验证通过。
- `Scripts/hok007b_ngr_patch_runner.py` 的 `--apply` / `--revert` 现在是"当前磁盘 NGR 处于哪一代 patch"的单一来源；对磁盘字节、备份目录、签名状态不要再另起手工流程，否则 dry-run 的一致性 gate 会误判。
- 在应用候选 E 之后，`Scripts/hok006_ngr_lldb_runner.py` 可能会在更长存活时间里观察到**下游新 crash**（例如 `pc=0x10915b114` / `far=0x50`），不要把这类新 `.ips` 误判为候选 E 无效——必须先看 `pc` / `imageOffset` / `far` 是否已经离开原 `0x10480df08` / `far=0x0` 窗口。
- `NGR-*.ips` 不是失败原因的唯一来源；`com.tencent.ngr` 跑到 UI 层之后会优先用**自己的 MessageBox** 弹错（如 `QtsFileSystem Create Failed!!`），伴随的 `.ips` 往往是弹窗点 OK 后的 app 内部退出链，`far=0x30`/`far=0x50` 之类的下游 null deref 其实是 app 层被迫空跑的后果，不是真正的根因。
- `QtsFileSystem` 属于 `Frameworks/GCloud.framework`（见 `GCloudQtsPufferInterface.h`）。它在 iOS 上默认按 `cwd="/"` 的假设构造路径；PlayCover 若把 `rootWorkDir` 强制关掉，这个模块会在 UI 层失败。因此 `com.tencent.ngr` 的"最小兼容"并不等于"所有 iOS 化开关都关"——`rootWorkDir=true` / `chdir("/")` 对它是**必需**的。
- `PlaySettings.disableForMinimalStartupCompat(...)` 是一个以 bundleId 为单位的"一刀切"压低器，很容易顺手把本应保留的能力（如 `rootWorkDir`）一起压掉。新增最小兼容 gate 时必须逐开关列一遍"如果这项被关，是否会触发可观察的 app 层失败"，不要集体 default false。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值；其中 `disableForMinimalStartupCompat(...)` / `minimalStartupCompatBundleIds` 是 `HOK-010` 的主改点，用来决定 `rootWorkDir` 等开关是否仍被"最小兼容 gate"强制关闭。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：当前 `HOK-005` 分层最小化子任务与每层 live 结论。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：`HOK-006` 的自动化入口、证据口径与后续 live handoff。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：`HOK-007A` 的离线 callsite 映射入口、`HOK-007B` 候选 E 的 patch 设计 / live 验证结论，以及 `HOK-007C` handoff。
- `Scripts/hok007b_ngr_patch_runner.py`：当前已应用到 NGR 上的"候选 E"最小可逆 patch 的单一来源；`--apply` / `--revert` / `--dry-run` 与 `build/hok-007b-backups/` 备份、`build/hok-007b-ngr-patch-report.json` 报告都走同一口径。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/GCloud.framework/Headers/GCloudQtsPufferInterface.h`：`QtsFileSystem Create Failed!!` 对应的腾讯 GCloud 文件系统接口定义，确认该弹窗来自 app 内 GCloud 模块而不是 PlayCover/PlayTools。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`：仅在需要借鉴 dashboard 维护方式时参考。
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard-Archive.md`：历史归档；不作为当前 HOK 主线入口。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
