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

- **当前结论**：`HOK-004`、`HOK-005A`、`HOK-005B`、`HOK-005C`、`HOK-005D`、`HOK-006`、`HOK-007A`、`HOK-007B` 均已完成。最新离线+live 结果已证明：候选 E（`ldr x8,[x19]` → `b 0x10480df24`，只改 4 字节、可逆、可重签）已经成功把原 faulting window 从 `0x10480df08` / `far=0x0` 推开；HOK-004 baseline 10s settle 内 session 不再秒断、也没有新 `.ips`，HOK-006 LLDB 交叉运行在更长存活时间里观察到的新崩溃 `NGR-2026-04-18-154537.ips` 已迁移到 `pc=0x10915b114` / `imageOffset=0x4839d14` / `far=0x50`，与原 callsite 不同。
- **当前已知事实**：2026-04-18 执行 `python3 Scripts/hok007b_ngr_patch_runner.py --apply` 成功将 NGR 的磁盘 sha256 从 `b0e109d7...` 改到 `7f6ae20c...`，`0x480df08` 处字节由 `680240f9` 改为 `07000014`，`llvm-objdump` 复核反汇编为 `b 0x10480df24`，`codesign -dvv` 继续为 `adhoc`。随后 `python3 Scripts/hok004_ngr_startup_runner.py --skip-build-install` 报告 `createSessionSucceeded=true`、`readyObservedDuringSettleWindow=true`、`disconnectedObservedDuringSettleWindow=false`、`newCrashReportsDetected=false`、`overallPass=true`。`python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install` 报告 `lldbStopObserved=false`、`faultingInstruction=None`，同轮出现的新 `.ips` 不再落在 `0x10480df08`。结构化产物：`build/hok-007b-ngr-patch-report.json`、`build/hok-007b-post-patch-hok004.json`、`build/hok-007b-post-patch-hok006.json`、`build/hok-007b-backups/hok-007b-b0e109d761a3eefb.bin`。
- **当前主线**：继续保留已落地的 `com.tencent.ngr` 最小兼容启动 gate、`AKInterface` 延迟补丁，把 `Scripts/hok004_ngr_startup_runner.py` 作为 baseline live 入口，把 `Scripts/hok006_ngr_lldb_runner.py` 作为 faulting instruction / backtrace 入口，把 `Scripts/hok007b_ngr_patch_runner.py` 作为"当前已应用哪一层可逆 patch"的单一来源。主线已从 `HOK-007B` 推到 `HOK-007C`：围绕新出现的 downstream crash `0x10915b114` / `far=0x50` 再跑一轮 HOK-007A 风格的离线映射 + HOK-007B 风格的最小可逆 patch，而不是直接跳到 `HOK-008`。
- **当前卡点**：候选 E 已经解决原 callsite，但下游 `0x10915b114` 依然是 null-ish 的 `far=0x50` 解引用；仍缺少对该新 callsite 的 `LLDB` / `.ips` / Mach-O / 磁盘字节一致性证据，以及对应的最小可逆 patch 设计。不应在无新映射证据前再叠加 patch 或放弃候选 E。
- **下一步默认规划**：
  1. 执行 `HOK-007C`：复用 `Scripts/hok007_ngr_callsite_mapper.py` 的口径，把最新 `NGR-2026-04-18-154537.ips`（或后续复现时更新的 `.ips`）对齐到 `Scripts/hok006_ngr_lldb_runner.py` 输出，产出 `pc=0x10915b114` / `imageOffset=0x4839d14` / `far=0x50` 的新离线一致性报告。
  2. 只有在新离线报告 `overallPass=true` 之后，才基于 `Scripts/hok007b_ngr_patch_runner.py` 的设计思路去加一个针对新 callsite 的最小可逆 patch 候选；候选 E 不回滚、`--revert` 仅在排障需要时使用。
  3. 每次只再做一层变动后，重新跑一轮"构建 → 启动 → session → launch diagnostics → LLDB report → `.ips`"闭环，对比 faulting window 是否再次移动；不要同时改多层。
  4. 若新 callsite 属于完全不同的模块或调用者，再复盘是否需要升级到 `HOK-008` 的脚本链整合；否则继续保留当前主线。

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

- 默认把 `metalCaptureEnabled=false`、`injectMetalCaptureEnvironment=false`、`shaderSourceReplacementEnabled=false`、`rootWorkDir=false`、`playChain=false` 视为 `com.tencent.ngr` 的优先隔离态；当前这些关键开关都应可通过现有 MCP 接口稳定写入 / 读取，但仍要把 host/plist 原始值与 runtime compat gate 压低后的实际生效值分开解读。
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
| HOK-007B | DONE | 已应用候选 E（`ldr x8,[x19]` → `b 0x10480df24`，4 字节可逆）并通过 HOK-004 baseline + HOK-006 交叉验证，faulting window 已从 `0x10480df08` / `far=0x0` 迁移到 `0x10915b114` / `far=0x50` | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-007C | TODO | 为新出现的 downstream crash（`pc=0x10915b114` / `imageOffset=0x4839d14` / `far=0x50`）复刻 HOK-007A 离线一致性映射 + HOK-007B 最小可逆 patch | 待建（默认复用 `HOK-007-二进制意图分析与callsite映射.md` 作为入口，必要时再拆子文档） |
| HOK-008 | TODO | 将构建、配置、启动、证据收集、结论汇总收敛成可重复的自动化脚本链路 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号/手工 UI 的后续验证（若未来必须验证"进入游戏后"行为） | 暂不执行；执行前必须先得到用户确认 |

## 踩坑与经验

- `playcover_launch_complete` **不等于** app 已安全启动；`com.tencent.ngr` 当前就是在该事件之后很快崩溃。
- `metal capture` 关闭并不自动等于"没有启动期 Metal / library hook 副作用"；对该 app 需要显式做 per-app 最小化处理。
- `shaderSourceReplacementEnabled` 在 host/runtime 默认值里都偏向开启思路，不能想当然地把它当作"默认无影响"。
- 现在可以通过 MCP 稳定写入 / 读取 `shaderSourceReplacementEnabled`，但这只代表 raw settings 已可自动化表达；是否真正命中 `com.tencent.ngr` 的最小兼容 gate，仍应优先看 `launch-events.jsonl`。
- `session briefly ready -> disconnected`，以及像本轮这样 `runtime-* = disconnected` + `pending-* = starting` 持续停留的组合，都是比"窗口看起来闪退"更稳定的自动化判定信号。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved` 是本轮之后判断 `com.tencent.ngr` 最小兼容 gate 是否真正命中的首选证据；不要再只看 plist 里的原始布尔值。
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

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：当前 `HOK-005` 分层最小化子任务与每层 live 结论。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：`HOK-006` 的自动化入口、证据口径与后续 live handoff。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：`HOK-007A` 的离线 callsite 映射入口、`HOK-007B` 候选 E 的 patch 设计 / live 验证结论，以及 `HOK-007C` handoff。
- `Scripts/hok007b_ngr_patch_runner.py`：当前已应用到 NGR 上的"候选 E"最小可逆 patch 的单一来源；`--apply` / `--revert` / `--dry-run` 与 `build/hok-007b-backups/` 备份、`build/hok-007b-ngr-patch-report.json` 报告都走同一口径。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`：仅在需要借鉴 dashboard 维护方式时参考。
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard-Archive.md`：历史归档；不作为当前 HOK 主线入口。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
