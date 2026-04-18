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
- 默认优先级：**对齐 iOS 环境 / 让 iOS 预置的 framework/ObjC/static ctor 链在 macOS 下也能跑起来** → **PlayTools 最小 bundle-scoped 兼容改动** → **LLDB / faulting instruction 归因** → **app 二进制可逆 patch（作为兜底）**。
- 不允许把"用户手工登录、手工点 UI、手工看窗口表现"作为日常验证 gate；这些只能作为例外步骤，且需先确认。
- 主文档只保留决策信息、默认执行路径和高频复用经验；历史细节、长日志、反复试错过程必须下沉到子文档。

## 主线任务

- **当前结论**：`HOK-004`、`HOK-005A`、`HOK-005B`、`HOK-005C`、`HOK-005D`、`HOK-006`、`HOK-007A`、`HOK-007B`、`HOK-011`（静态分析阶段）均已完成。经过 HOK-011 的深度静态分析，之前在 HOK-007B 做的"候选 E = 在 faulting `ldr x8, [x19]` 处无条件跳 epilogue"已被重新认识为**掩盖症状的 workaround**，而真正的根因是 `com.tencent.ngr` 的 dyld static initializer 链在 macOS/PlayCover 下**没按 iOS 上应有的顺序运行**：faulting caller（`__init_offsets[1563]` / `0x10460e2c0`）直接 `ldr x0, [0x10e2146f8]`，假设该槽位已被更早的代码填好；但静态分析（`Scripts/hok011_ngr_common_init_chain.py` + 全二进制逆向 call graph）证明**NGR 自己的 `__init_offsets` 链路中没有任何入口能传递调用到写该槽位的 lazy accessor `0x103a29b7c`**，因此该槽位只可能由外部机制（embedded Framework initializer / ObjC `+load` / 跨 dylib 静态构造链）预先填充。
- **当前已知事实**：
  - faulting PC `0x10480df08`，`x19 = 0`，语义是从未被初始化的空指针 deref；直接由 caller `ldr x0, [0x10e2146f8]` 把 null 传进来。
  - `0x10e2146f8` 位于 `__DATA,__common`，dyld 只做零初始化；`dyld_info -fixups` 没有 bind/rebase 条目。
  - NGR 全二进制对该地址**只有 1 个 store 点**：`0x103a29f7c: str x0, [x8, #0x6f8]`，位于函数 `0x103a29b7c` 内，该函数是 `__cxa_guard` 保护的 Meyers-singleton accessor，只被 `0x107e5df10`（Logger accessor）这 1 个函数调用，`0x107e5df10` 在全二进制中只有 1 个调用点，且其调用者**不属于 __init_offsets**。
  - 反向 BFS 调用图（仅在 NGR 自身 __text 内的 `bl` 边上）从 `0x107e5df10` 出发**无法到达任何 __init_offsets 入口**——该 slot 的 writer 在 NGR 自身 initializer 链中不可达。
  - `DYLD_PRINT_INITIALIZERS=1` 直接裸跑 NGR 主二进制时，dyld 输出同时伴随 **ObjC 重复类警告**：`PxFrameworkLoader`、`AReachability`、`PxDyLibFrameworkLoader` 分别在两个 image 中同时声明；iOS vs macOS 对重复类的挑选顺序不同，是 iOS 行为差异的一个非常强的候选。
  - `Scripts/hok007b_ngr_patch_runner.py` 当前状态：已 re-apply 候选 E（`currentBytesHex=07000014`），backup `build/hok-007b-backups/hok-007b-b0e109d761a3eefb.bin` 保留；HOK-012 期间先保留 patch，确保 app 能跑过 index 1563 从而观察到下游 writer 真的被谁触发。
  - 结构化证据：`build/hok-007-ngr-callsite-report.json`（HOK-007A 一致性）、`build/hok-007b-ngr-patch-report.json`（HOK-007B apply 状态）、`build/hok-011-ngr-common-init-chain-report.json`（HOK-011 扫描报告）、`build/hok-011-analysis-notes.json`（HOK-011 深度静态分析 hand-off）。
- **当前主线**：切换到 **`HOK-012`：基于 HOK-011 的静态结论做 live-trace**——在候选 E patch 仍 apply 的前提下，让 NGR 真跑起来，用 `DYLD_PRINT_INITIALIZERS=1` + LLDB watchpoint（watch `0x10e2146f8`）观察**到底是哪个 image 的哪个 initializer 触发了 writer**。拿到这个信息后才能从 3 个已分类的假设（H1 framework init 回调 NGR、H2 ObjC `+load`、H3 跨 dylib static ctor 链）中锁定真相，并决定是**对齐 iOS 行为**（例如在 PlayTools 里强制提前调一次 Logger accessor，或调整 ObjC 重复类挑选顺序）还是**接受候选 E 作为长期 workaround**。
- **当前卡点**：
  - NGR 需要 iOS framework 链接才能正常启动；裸跑 `DYLD_PRINT_INITIALIZERS=1 NGR` 只能看到系统 dylib 的一小段初始化序列，跑不到目标 caller。必须通过 PlayCover 正常启动流程才能观察到完整链。
  - PlayCover 目前没有"按 bundle 注入诊断环境变量"的现成入口；HOK-012 第一步需要在 `PlayApp.swift` 加一个临时的 minimalStartupCompat-bundle-scoped `DYLD_PRINT_INITIALIZERS` 注入点（改 1~2 行 Swift），并通过 `BuildScripts/build_and_install.sh` 重新安装 PlayCover。
  - `hok006_ngr_lldb_runner.py` 当前在 capture 到 fault 就停；HOK-012 需要让 LLDB 运行**前置 watchpoint + continue**，直到 watchpoint 触发或 process 退出；需要扩展该 runner（不改现有行为，新增 `--watch-address` / `--no-stop-on-fault`）。
- **下一步默认规划**：
  1. 执行 `HOK-012-A`：在 `PlayCover/Model/PlayApp.swift` 的 `effectiveLaunchEnvironment()` 下增加 "minimalStartupCompat 下自动注入 `DYLD_PRINT_INITIALIZERS=1`、`DYLD_PRINT_APIS=0`（只开 initializer 一项以限制输出）"，只对 `com.tencent.ngr` 生效；重建安装后跑一次 `Scripts/hok004_ngr_startup_runner.py`，把 NGR 进程的 stderr（通过 `os_log` 或 `launchctl print` 等现有机制）抓成离线产物。
  2. 执行 `HOK-012-B`：扩展 `Scripts/hok006_ngr_lldb_runner.py`，支持在 `launch_app_with_lldb` 之前下一个 `watchpoint set expression -- 0x10e2146f8`（8 字节写）；确认 watchpoint 被哪个 image 的哪段代码命中，把命中的 image / 函数入口 / caller 写入结构化报告。
  3. 根据 HOK-012-A/B 拿到的真实 writer，判断是：
     - **H1**：某个 framework initializer 有 NGR 内部函数调用回 NGR（通过 dlsym 或直接链接）→ HOK-013 方向变成"在 PlayTools 里手动预触发同一个函数"。
     - **H2**：某个 ObjC `+load` → HOK-013 方向是"确认 iOS ObjC 类挑选策略，看是否需要 PlayTools 在注入时把 `PxDyLibFrameworkLoader` 等重复类的挑选顺序对齐 iOS"。
     - **H3**：framework 的 C++ static ctor → HOK-013 方向是"让 dyld 初始化顺序把该 framework 在 NGR `__init_offsets[1563]` 之前 load（例如通过 `DYLD_INSERT_LIBRARIES` 提前 dlopen）"。
  4. 若 HOK-012-A/B 拿到的结果无法支持 H1/H2/H3 任一假设，则候选 E 成为长期方案，主线回到 QtsFileSystem + `rootWorkDir` 路径（HOK-010），不再继续追 `0x10e2146f8`。

## 构建与验证的方法

### 日常默认方法（必须可由 agent 独立完成）

- **构建 PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- **涉及主 app / 注入 / 安装链路时**：`./BuildScripts/build_and_install.sh`
- **读取 / 固化目标 app 配置**：优先使用 `get_app_settings` / `update_app_settings`，目标是让 `com.tencent.ngr` 处于最小兼容模式；若某个关键开关当前还无法经现有 MCP 稳定写入，则应先补自动化写入路径，而不是退回手工 GUI 点选。
- **运行时验证**：`launch_app` → 固定等待 → `create_session` / `list_sessions`。默认 pass 条件是：session 不再秒断、进程在 settle window 内持续存活、且没有新的同类 `NGR-*.ips` 崩溃报告。
- **证据收集**：每轮都要对照读取
  - `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  - `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- **需要更细粒度定位时**：使用 `launch_app_with_lldb` 做同一轮自动化复现，抓 faulting instruction / backtrace / watchpoint；这仍属于 agent 可独立完成的默认升级路径。
- **需要离线二进制层分析时**：
  - `Scripts/hok007_ngr_callsite_mapper.py`：faulting callsite 一致性映射。
  - `Scripts/hok011_ngr_common_init_chain.py`：基于 `__init_offsets` 的 initializer store-site 扫描，默认目标地址 `0x10e2146f8`；可通过 `--target-address` 推广到其他 `__common` 槽位。

### 当前建议的最小兼容验证口径

- 默认把 `metalCaptureEnabled=false`、`injectMetalCaptureEnvironment=false`、`shaderSourceReplacementEnabled=false`、`playChain=false` 视为 `com.tencent.ngr` 的优先隔离态。**`rootWorkDir` 当前保持 `disableForMinimalStartupCompat(...)` 强制关闭**，HOK-010 未被重启；候选 E 仍处于 apply 状态，负责把原 null deref 压成 no-op 以便 app 跑到更下游。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped` 仍然是判断兼容 gate 真正命中的首选证据；**`playcover_working_directory_preserved` 仅说明最小兼容 gate 命中了 cwd 分支，不代表 app 一定能正常使用 `QtsFileSystem`**；该问题已下沉到 HOK-010，HOK-012 完成后再重新评估是否要 reopen。
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
| HOK-004 | DONE | 已固化 `com.tencent.ngr` 的自动化启动闭环、`10s settle window` 口径与失败非零退出语义；live 确认最小兼容 gate 命中 | `LocalDocs/HOKCrash/HOK-004-启动验证与settle-window.md` |
| HOK-005A | DONE | `DiscordIPC` app-scoped skip；live 证明 Discord 不是首个推动 faulting window 移动的 bootstrap 层 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005B | DONE | `PlayInput.shared.initialize()` app-scoped skip；live 证明 `PlayInput` 不是首个 faulting mover | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005C | DONE | `PlayScreen.shared.initialize()` app-scoped skip；live 证明 `PlayScreen` 不是首个 faulting mover | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005D | DONE | `AKInterface.initialize()` `1.0s` app-scoped 延迟；live 证明 crash 发生在 `AKInterface` 实际初始化之前 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-006 | DONE | LLDB 自动化入口 + 结构化证据链（含 31 帧 backtrace）；崩点稳定固定在 `NGR` early initializer 路径 | `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md` |
| HOK-007A | DONE | `0x10480df08` faulting callsite 的 `LLDB` / `.ips` / `instructionByteStream` / file bytes / `__TEXT,__text` file offset 一致性映射 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-007B | DONE | 候选 E（`ldr x8,[x19]` → `b 0x10480df24`，4 字节可逆）已 apply；app 能跨过原 faulting window 抵达游戏 UI 层；候选 E 被重新标记为**症状 workaround**，不是根因修复 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-011 | DONE | 离线定位 `0x10e2146f8` 的 writer/reader 关系；**证明 NGR 自身 `__init_offsets` 链无法 prime 该 slot**，真正的 prime 必来自外部 framework/ObjC/跨 dylib 路径；顺带发现 3 组 ObjC 重复类警告 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`（本轮新增） |
| HOK-012 | TODO | 基于 HOK-011 的静态结论做 live-trace：bundle-scoped `DYLD_PRINT_INITIALIZERS=1` 注入 + LLDB watchpoint `0x10e2146f8`，定位真正写该 slot 的 image/函数，区分 H1/H2/H3 假设 | 待建（默认直接在 `HOK-011-静态初始化链分析.md` 里续写 "live-trace handoff" 小节，证据收敛后再拆独立子文档） |
| HOK-010 | DEFERRED | 把 `rootWorkDir` 从 `PlaySettings.disableForMinimalStartupCompat(...)` 摘除以消除 `QtsFileSystem Create Failed!!`；**暂缓**，等 HOK-012 的结果出来再评估 | 暂无 |
| HOK-007C | DEFERRED | 为下游 crash（`0x10915b114` / `far=0x50`）做 HOK-007A 离线映射 + HOK-007B 风格最小可逆 patch；**暂缓**，等 HOK-012 / HOK-010 结果 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-008 | TODO | 将构建、配置、启动、证据收集、结论汇总收敛成可重复的自动化脚本链路 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号/手工 UI 的后续验证（若未来必须验证"进入游戏后"行为） | 暂不执行；执行前必须先得到用户确认 |

## 踩坑与经验

- `playcover_launch_complete` **不等于** app 已安全启动；`com.tencent.ngr` 会在该事件之后崩溃。
- `metal capture` 关闭并不自动等于"没有启动期 Metal / library hook 副作用"；对该 app 需要显式做 per-app 最小化处理。
- `shaderSourceReplacementEnabled` 在 host/runtime 默认值里都偏向开启思路，不能想当然地把它当作"默认无影响"。
- 现在可以通过 MCP 稳定写入 / 读取 `shaderSourceReplacementEnabled`，但这只代表 raw settings 已可自动化表达；是否真正命中 `com.tencent.ngr` 的最小兼容 gate，仍应优先看 `launch-events.jsonl`。
- `session briefly ready -> disconnected`、`runtime-* = disconnected` + `pending-* = starting` 持续停留，比"窗口看起来闪退"更稳定，是自动化判定的首选信号。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped` 是判断最小兼容 gate 真正命中的首选证据；`playcover_working_directory_preserved` 仅代表走了 cwd 保留分支，不代表 app 一定能工作。
- `playcover_input_skipped` / `playcover_screen_skipped` 的出现（且对应 initialized 事件缺席）是 `HOK-005B/C` 真正命中的首选证据；不要再用"猜测"替代 launch diagnostics。
- GUI HTTP MCP 的 `tools/call` 在真实运行中可能返回 `text/event-stream` 包裹的 JSON，不是裸 JSON；HTTP runner 不能按单一内容类型解析。
- 对 `GUI HTTP MCP` 的长调用不要默认套 `5s` HTTP 超时；`create_session(timeout=10)`、`launch_app_with_lldb(timeoutSeconds=5)` 必须让 HTTP request timeout 与 tool 自身 timeout 对齐。
- `launch_app_with_lldb` 在 headless 模式下会返回结构化 LLDB 证据；消费 `lldb.stopReason` / `lldb.faultingFrame` / `lldb.faultingInstruction` / `lldb.backtrace` / `lldb.transcriptTail`，不要把完整 transcript 仅当人工阅读日志。
- `launch_app_with_lldb` 返回 `timedOut=true` 不等于"没抓到崩溃"；只要同一轮同时有 `didStop=true`、`faultingFrame`、`faultingInstruction` 与 `backtrace`，就说明 capture window 到期前已拿到 LLDB 归因证据。
- `.ips` 的 `usedImage.base`、triggered thread `frames[0].imageOffset` 与 LLDB `faultPc` 可交叉验证 callsite 是否收敛到稳定 image offset；三者一致时优先围绕 image offset / file offset 做 patch 设计。
- `.ips instructionByteStream` 记录的是磁盘小端字节序；`llvm-objdump` 行内的 `f9400268` 展示串和它顺序不同。字节级 patch 必须以 `instructionByteStream` / 实际 binary bytes 为准。
- 设计 ARM64 最小可逆 patch 时，必须沿反汇编窗口追到 `b`/`b.cc`/`cbz` 的跳转目标——faulting 函数里某些分支会把控制流送回原 faulting 指令，只改条件跳转是空操作。
- 对 `NGR` 这类巨型 mach-o 做字节级 patch，`codesign -f -s -` 即可重签，`codesign -dvv` 仍报 `adhoc` 说明签名有效。
- `Scripts/hok007b_ngr_patch_runner.py` 的 `--apply` / `--revert` / `--dry-run` 是"当前磁盘 NGR 处于哪一代 patch"的唯一来源；不要另起手工流程。
- **"应用层崩溃" ≠ "没修好"**：候选 E apply 后 app 能跑到游戏 UI 层并弹 `QtsFileSystem Create Failed!!` / 新 `.ips`；这代表 patch 正确，只是 NGR 自身还有后续依赖未满足。
- **小 `__common` 槽位没 fixup 不意味着没被谁写**：`0x10e2146f8` 没有 bind/rebase 条目，初值是 dyld 零填；NGR 里**有且仅有 1 个 store 指令**写它（`0x103a29f7c`），但该 store 所在函数 `0x103a29b7c` 属于 `__cxa_guard` 保护的 Meyers-singleton accessor，只能被一条调用链到达；若该链本身不会被 `__init_offsets` 任何入口触发，那这个 slot 在 faulting 前必然为 0。
- **"full disasm + 反向 call graph + init_offsets 比对"** 是 NGR 这种 3000+ initializer 二进制里**定位 static-init ordering 问题**的默认手段；`Scripts/hok011_ngr_common_init_chain.py` 解决第一步（找 store-site），全二进制反向 BFS 解决第二步（找可达性）。
- `dyld_info -inits` 才是官方的 initializer 列表来源；手工 parse `__init_offsets` 必须和它对齐数量才算解析正确。
- `DYLD_PRINT_INITIALIZERS=1` 直接裸跑 NGR 主二进制只会看到系统 dylib 的前几段初始化序列就退出，但**伴随的 ObjC 重复类警告**（`PxFrameworkLoader`、`AReachability`、`PxDyLibFrameworkLoader`）是"iOS vs macOS 类挑选策略差异"这个问题域的首次强证据，不要忽略。
- ObjC 重复类在 macOS vs iOS 上的**挑选规则不同**（主要是 dylib 加载顺序影响 `objc_registerClassPair` 的胜者）；这是 HOK-012 live-trace 必须显式观察的点。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑；`effectiveLaunchEnvironment()` 是 `HOK-012-A` 注入 `DYLD_PRINT_INITIALIZERS=1` 的目标点。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值；`disableForMinimalStartupCompat(...)` / `minimalStartupCompatBundleIds` 是 `HOK-010` 的主改点，`HOK-012` 暂不触发。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：`HOK-005` 分层最小化子任务与每层 live 结论。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：`HOK-006` 的自动化入口、证据口径与 31 帧 backtrace。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：`HOK-007A` 一致性映射、`HOK-007B` 候选 E（现在定位为 workaround）、`HOK-007C` handoff。
- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：`HOK-011` 的扫描器设计、反向 call graph 方法论、`0x10e2146f8` writer 不可达结论、ObjC 重复类警告与 `HOK-012` handoff。
- `Scripts/hok007b_ngr_patch_runner.py`：候选 E 最小可逆 patch 的单一来源；当前状态 `applied`。
- `Scripts/hok011_ngr_common_init_chain.py` + `Scripts/test_hok011_ngr_common_init_chain.py`：`__common` slot writer 扫描器与单元测试。
- `build/hok-011-analysis-notes.json`：HOK-011 的完整证据结构化文件（含 caller/reader/writer 地址表、反向 BFS 结论、ObjC 重复类列表、HOK-012 hand-off 建议）。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/`：20+ 个嵌入 framework 的集合；`HOK-012` 的 watchpoint 很可能命中其中某一个（`GCloud`、`PixUI_PXPlugin`、`PxKit3`、`BqCCS` 等）。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`：与本主线无关，除非需要借鉴 dashboard 维护方式。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
