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

- **当前结论**：`HOK-004`、`HOK-005A`、`HOK-005B`、`HOK-005C`、`HOK-005D`、`HOK-006`、`HOK-007A`、`HOK-007B`、`HOK-011`（静态分析阶段）、`HOK-012-A`（bundle-scoped `DYLD_PRINT_INITIALIZERS=1` 注入）、`HOK-012-B`（pre-run watchpoint + dyld-log 自动化）、`HOK-012-C.1`（legacy 基线 live 确认候选 E 有效）、`HOK-012-C.2`（首轮 pre-run watchpoint live run，`0x10e2146f8` 0 hit + secondary fault 指向 HOK-010）、`HOK-012-C.3-a`（deferred-install watchpoint 自动化：`LLDBRunOptions.deferWatchpointInstall` 贯穿 Swift/LLDB/MCP/Python 四层 + `--writer-address` 默认 `0x103a29b7c` 的 writer-entry bp 自动注入）均已完成。**HOK-012-C.3 的 live 解读被用户现场观察纠正**：之前两轮 defer-install run 的 "bp 未命中 / watchpointHits=0" **不等于** "writer 函数未被调用"——对照 `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl` 与 `~/Library/Logs/DiagnosticReports/NGR-*.ips`，两轮 app 实际 procLaunch → 崩点都是约 32 秒（`NGR-2026-04-18-174129.ips` pid 75314 活 ~32s，`NGR-2026-04-18-174158.ips` pid 77665 活 ~32s），而 `--lldb-timeout 5 / 20` 分别只覆盖了生命周期的前 16% / 63%；LLDB 到点后发出 `process terminate` 但 **app 因为 UE4 fatal 弹出的 Apple 崩溃对话框被挂在前台**，直到用户点对话框才真正退出。因此 C.3-a 只证明 "writer 函数在 LLDB 捕获窗口内未被命中"，不能证伪 HOK-011 的 "writer = `0x103a29f7c` / 唯一入口 = `0x103a29b7c`" 静态结论；HOK-011 假设仍然成立，`0x10e2146f8` 这条主线**不进入 DEFER**。候选 E 仍 apply 并负责把原 `0x10480df08` 压成 no-op；HOK-012-A/B/C 的自动化栈保持可用，作为所有 `__common` slot 追查的默认工具（host 侧 `PlayApp` 与 MCP `LaunchService` 两处 `effectiveLaunchEnvironment` 的 bundle-scoped `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 注入、headless LLDB runner + `launch_app_with_lldb` MCP 工具 + `hok006_ngr_lldb_runner.py` 脚本四层同步扩展的 `watchAddress` / `watchSize` / `preRunCommands` / `dyldInitializersLogPath` / `deferWatchpointInstall`、`process launch -e` stderr 重定向、stop→continue 多命中循环、default `0x10e2146f8` / size 8 / log `build/hok-012-ngr-dyld-initializers.log` / report `build/hok-012-ngr-watchpoint-report.json`，legacy 行为通过 `LLDBRunOptions.default` / 缺省 MCP 字段保持 100% 兼容，`LaunchServiceTests` 26 个用例全部通过，`BuildScripts/build_and_install.sh` 成功）。
- **当前已知事实**：
  - faulting PC `0x10480df08`，`x19 = 0`，语义是从未被初始化的空指针 deref；直接由 caller `ldr x0, [0x10e2146f8]` 把 null 传进来。
  - `0x10e2146f8` 位于 `__DATA,__common`，dyld 只做零初始化；`dyld_info -fixups` 没有 bind/rebase 条目。
  - NGR 全二进制对该地址**只有 1 个 store 点**：`0x103a29f7c: str x0, [x8, #0x6f8]`，位于函数 `0x103a29b7c` 内，该函数是 `__cxa_guard` 保护的 Meyers-singleton accessor，只被 `0x107e5df10`（Logger accessor）这 1 个函数调用，`0x107e5df10` 在全二进制中只有 1 个调用点，且其调用者**不属于 __init_offsets**。
  - 反向 BFS 调用图（仅在 NGR 自身 __text 内的 `bl` 边上）从 `0x107e5df10` 出发**无法到达任何 __init_offsets 入口**——该 slot 的 writer 在 NGR 自身 initializer 链中不可达。
  - `DYLD_PRINT_INITIALIZERS=1` 直接裸跑 NGR 主二进制时，dyld 输出同时伴随 **ObjC 重复类警告**：`PxFrameworkLoader`、`AReachability`、`PxDyLibFrameworkLoader` 分别在两个 image 中同时声明；iOS vs macOS 对重复类的挑选顺序不同，是 iOS 行为差异的一个非常强的候选。
  - `Scripts/hok007b_ngr_patch_runner.py` 当前状态：已 re-apply 候选 E（`currentBytesHex=07000014`），backup `build/hok-007b-backups/hok-007b-b0e109d761a3eefb.bin` 保留；HOK-012 期间先保留 patch，确保 app 能跑过 index 1563 从而观察到下游 writer 真的被谁触发。
  - HOK-012-A 已落地：host 侧 `PlayApp.minimalStartupCompatDiagnosticEnvironment` / MCP 侧 `LaunchService.minimalStartupCompatDiagnosticEnvironment` 都是 `{"DYLD_PRINT_INITIALIZERS": "1", "DYLD_PRINT_APIS": "0"}`；`launch_app` 与 `launch_app_with_lldb` 两条启动路径共用同一套注入语义，单元测试（`LaunchServiceTests` 覆盖 inject/non-inject 分支）。
  - HOK-012-B 已落地：新增 `LLDBRunOptions` 类型（`watchAddress`/`watchSize`/`preRunCommands`/`dyldInitializersLogPath`）贯穿 `LaunchService.launchAppWithLLDB` → `runLLDBHeadless` → `launch_app_with_lldb` MCP schema → `hok006_ngr_lldb_runner.py` CLI；watchpoint 模式下 `parseLLDBEvidence` 改为优先挑选**非 watchpoint** 的 stop 作为 fault 字段，同时新增 `parseWatchpointHits` 把每一段 `stop reason = watchpoint …` 切成带 `oldValue`/`newValue`/`frame #0`/`backtrace` 的结构化 `WatchpointHit`；`LaunchServiceTests` 追加 5 个单元测试（默认 options 兼容、非空地址触发、hit 切片、非 watchpoint stop 优先、options 透传），23 个测试全部通过。
  - 结构化证据：`build/hok-007-ngr-callsite-report.json`（HOK-007A 一致性）、`build/hok-007b-ngr-patch-report.json`（HOK-007B apply 状态）、`build/hok-011-ngr-common-init-chain-report.json`（HOK-011 扫描报告）、`build/hok-011-analysis-notes.json`（HOK-011 深度静态分析 hand-off）、`build/hok-012-ngr-watchpoint-report.json`（HOK-012-B watchpoint 命中清单，脚本 `--watch-address` 启用后生成）、`build/hok-012-ngr-dyld-initializers.log`（HOK-012-B 子进程 stderr 重定向，与上者同轮产生、可交叉对齐时间戳）。
- **当前主线**：`HOK-012-C.3-b`——把 LLDB 捕获窗口从 5s/20s 拉到覆盖完整 app 生命周期（约 32s，procLaunch → UE4 fatal `.ips` 生成），同时用 `process interrupt` 收尾窗口配合把 bp / watchpoint 在**用户无需点对话框**的前提下真正观察完毕。**基线命令**：`python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --defer-watchpoint-install --lldb-timeout 45 --settle-seconds 50 --skip-build-install`。若 45s 内仍未触达 `0x103a29b7c` bp 且 `.ips` 显示进程已崩，则需要：(1) 给 `runLLDBHeadless` 的 `process interrupt` 收尾窗口（当前固定 `2.0`）参数化，支持 `--lldb-teardown-timeout`；(2) 在 `preRunCommands` 里追加 `process handle -s true -n true -p false SIGABRT`，让 UE4 `abort()` 时 LLDB 能先抓到一次 stop 而不是被 Apple crash dialog 抢先；(3) 并行给 `writer-address` 加兜底，打到 `0x107e5df10`（Logger accessor，writer 的唯一 caller）的 bp 作为更前置的触达点，同时保留 `0x103a29b7c` 本身的 bp 以便任选较早命中者装 watchpoint。如果这一轮命中了 writer bp + 拿到了 watchpoint hit，就按 HOK-011 的 H1/H2/H3 分类继续；如果仍未命中但在 `abort` 时拿到了**完整的主线程 backtrace 且看到 `0x10e2146f8` 的读取路径**，则直接跳到 HOK-013（PlayTools 里提前 touch Logger accessor 以预热 slot）。
- **当前卡点**：
  - `--lldb-timeout` 默认 5s / C.3-a 尝试的 20s 都**不足以覆盖 app 真实生命周期**。`.ips` 里 `procLaunch` → `procExitAbsTime` 约 32s，且用户观察到 app 在 UE4 fatal 后被 Apple 崩溃对话框挂住，要真正观察到 writer / reader 被触达，LLDB timeout 至少要 45s 并且要配合 `SIGABRT` 预设让 LLDB 在 UE4 `abort()` 时优先拦截一次 stop。
  - `runLLDBHeadless` 里 `process interrupt` 之后的收尾窗口（`completion.wait(timeout: .now() + 2.0)`）当前固定为 2 秒，这对长 `thread backtrace all` 抓取不够，曾在 C.3 的 20s run 里导致 transcript 只留下 bp armed 行而没有任何 stop 证据；HOK-012-C.3-b 要么把这个常量改成可配置（`--lldb-teardown-timeout`），要么在 watchpoint 模式的 capture handler 里只发 `thread backtrace` 而不发 `all`，以降低收尾窗口压力。
  - deferred-install 模式的 `--writer-address` 默认落在 `0x103a29b7c`。live 尚未证实该函数在 app 生命周期内是否真的被调用——HOK-011 静态路径是 `reader (init_offsets[1563]) ← ldr x0, [0x10e2146f8] ← (要求之前某处) str x0, [0x10e2146f8] = 0x103a29f7c in 0x103a29b7c`，这要求 writer 至少被触达**一次**。C.3-b 若仍然拿不到 bp 命中，需要回到 `Scripts/hok011_ngr_common_init_chain.py` 核对 "唯一 store 假设" 是否漏扫了 NGR 的 `__DATA,__data` / 其他 section 的 store 形式。
  - `QtsFileSystem Create failed.` 与 Thread #10 `0x1047862bc`（`address=0x30`）是 UE4 层 fatal，可能是 `0x10e2146f8` reader 下游的连锁反应，也可能是独立问题；HOK-012-C.3-b 的 live 证据必须先确认这一点再决定要不要单独起 HOK-007C。
- **下一步默认规划**：
  1. `HOK-012-C.3-b.1`：先以最小代码改动跑一轮 `python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --defer-watchpoint-install --lldb-timeout 45 --settle-seconds 50 --skip-build-install`，仅调整 CLI 参数覆盖完整的 ~32s 生命周期；目的是先验证"LLDB 能否活到 UE4 fatal 发生那一刻"以及 bp 是否会在对话框出现前被命中。配合自动收集本轮前后的 `NGR-*.ips` diff 与 `launch-events.jsonl` 尾段。
  2. 若 C.3-b.1 结束后 transcript 仍缺失 stop 证据但 `.ips` 生成正常，说明问题是 `runLLDBHeadless` 的收尾 2s 窗口太短。`HOK-012-C.3-b.2`：把 `runLLDBHeadless` 的 teardown 超时参数化（新增 `LLDBRunOptions.teardownTimeoutSeconds: TimeInterval`，默认 `2.0`），并在 `launch_app_with_lldb` MCP schema、`hok006_ngr_lldb_runner.py` CLI 上添加透传；`LaunchServiceTests` 补 1 个用例覆盖默认值兼容。
  3. `HOK-012-C.3-b.3`：给 `preRunCommands` 追加 `process handle -s true -n true -p false SIGABRT`（放在自动生成的 writer bp 行之前），让 LLDB 在 UE4 `abort()` 时先停下来抓 backtrace，避免 Apple 崩溃对话框抢先把进程 halt 在 signal handler 外。Python runner 在 defer 模式下无条件追加这一行，并在 report 的 `configuration.preRunCommands` 里原样记录。
  4. `HOK-012-C.3-b.4`：把 `--writer-address` 从单值扩成"多地址 fallback 列表"（`--writer-addresses 0x103a29b7c,0x107e5df10`），脚本为每个地址各自注入一条 `breakpoint set --address <addr> -C "watchpoint set expression …" -C "continue" --auto-continue true --one-shot true`；两者任一命中都能装上 watchpoint。
  5. 若 C.3-b.1/2/3/4 全部跑完仍拿不到 watchpoint hit 也拿不到 writer bp 命中，才把主线切到 HOK-011 的"唯一 store 假设"复核：重跑 `Scripts/hok011_ngr_common_init_chain.py` 时放宽 store 形式（`str` / `stp` / `sturh` / ARM64 memcpy helper 的间接 store），并扫描 NGR 主二进制里所有 section（不仅 `__TEXT,__text`）的 `bl 0x107e5df10` / `bl 0x103a29b7c` 调用边。

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
2. 按优先级从高到低选取未完成任务执行；**每次可以做一个或多个任务**——只要每一项都能按"构建/验证/证据闭环"独立收尾、并且改动不互相冲突，可以在同一轮内连续推进多条 TODO。但若某几项之间存在明显耦合（例如共用同一份磁盘二进制 patch 状态、或需要共同的 live 证据复用），则必须把它们合并成一个更大的变更单元完成，不要半路切换。
3. 若某个任务已阻塞（如需人工或外部协助），跳过它、继续做其它未阻塞的高优先级任务；严禁把"阻塞任务"与"无关任务"混在同一轮里试图绕过阻塞。
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再按正常优先级顺序推进；拆出的子任务可以在同一轮内连续完成，也可以下一轮再来，视变更面积决定。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 执行完毕后必须整理本文档：删除过时信息，更新 主线 / TODO / 踩坑 / 优先级变化，并把真正高频复用的手工流程收敛成脚本；主文档保持简洁，不能只追加不整理，也不能改变本文档章节结构。
   - **主文档 vs 子文档的分工**：不重要的信息、过于局部/细节的推导过程、大段日志、方法论细节一律下沉到对应子文档；主文档只保留当前主线、TODO、决策信息与高频复用经验。
   - **任务状态只在本文档维护**：子文档**不允许**出现 "DONE / TODO / DEFERRED / BLOCKED / 已完成 / 已落地 / 待执行 / 下一步 / 结论 / handoff" 这类**任务状态或进度描述**；子文档只沉淀**方法、口径、设计依据、结构化证据与可复用脚本**，对应任务的状态以 Dashboard TODO 表格为唯一来源。
   - **子文档不写时间戳快照**：子文档不保留"某月某日的 live 结果基线"这类瞬态快照；若确需引用某次 live run，改为指向 `build/` 下的结构化报告文件名，把解释文字留给 Dashboard。
7. 复盘当前技术路线；除最终目标不能改变外，中间方案可根据新发现随时调整。
8. 收尾后执行 `git commit`。一轮内若完成多条 TODO，commit 信息必须把每条的证据指向清楚列出，不要合成一行。

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
| HOK-011 | DONE | 离线定位 `0x10e2146f8` 的 writer/reader 关系；**证明 NGR 自身 `__init_offsets` 链无法 prime 该 slot**，真正的 prime 必来自外部 framework/ObjC/跨 dylib 路径；顺带发现 3 组 ObjC 重复类警告 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md` |
| HOK-012-A | DONE | 在 `PlayApp.effectiveLaunchEnvironment()` 与 MCP `LaunchService.effectiveLaunchEnvironment()` 两侧落地 bundle-scoped `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 注入；两处共用 `minimalStartupCompatDiagnosticEnvironment` 语义，仅对 `minimalStartupCompatBundleIdentifiers` 生效；`LaunchServiceTests` 新增 2 个单元测试覆盖 inject/non-inject 分支，18 个测试全过；`BuildScripts/build_and_install.sh` 构建+安装+ad-hoc 签名成功 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`（`HOK-012 live-trace 方法论` 小节） |
| HOK-012-B | DONE | 扩展 `launch_app_with_lldb` + headless LLDB runner 支持 `watchAddress` / `watchSize` / `preRunCommands` / `dyldInitializersLogPath`，watchpoint 模式下 stop→`continue` 循环、并用 `process launch -e` 把子进程 stderr 重定向到独立文件；扩展 `Scripts/hok006_ngr_lldb_runner.py` 新增 `--watch-address` / `--watch-size` / `--pre-run-command` / `--dyld-log` / `--watchpoint-report`，watchpoint 模式下默认写 `build/hok-012-ngr-watchpoint-report.json` + `build/hok-012-ngr-dyld-initializers.log`；`LaunchServiceTests` 23 个全过（新增 5 个用例覆盖 default options、watchpoint 模式判定、hit 切片、fault-vs-watchpoint 优先级、options 透传）；`BuildScripts/build_and_install.sh` 构建+安装+ad-hoc 签名成功 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`（`HOK-012 live-trace 方法论` 小节） |
| HOK-012-C.1 | DONE | 在真实 NGR 环境跑 legacy 基线 `python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install`，确认候选 E apply 状态下 `0x10480df08` 原 fault 已被绕过（`faultingFrame=None`、`lldbStopObserved=False`、5s 窗口内 session 保持 ready、无新 `NGR-*.ips`、PlayTools compat 事件齐全） | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（legacy baseline 口径） |
| HOK-012-C.2 | DONE | 首轮 watchpoint live run：`--watch-address 0x10e2146f8 --watch-size 8 --skip-build-install`。结果 `watchpointHits=0` 但 `didStop=true`、`backtraceDepth=254`，且 `backtrace` 已触达 writer 函数内偏移（`0x103a29fb0` = `0x103a29b7c + 0x434`），secondary fault 指向 HOK-010 方向（`QtsFileSystem Create failed.` + Thread #10 `0x1047862bc` `address=0x30`）；`build/hok-012-ngr-dyld-initializers.log` 97933 字节，含 3 条 ObjC 重复类警告与 `[GPM] cpp constructor call` 等 C++ static ctor 证据；证明 writer 函数被触达但 first-initialization store 未落入 watchpoint 生效窗口 | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（证据口径 5 种语义 + Thread #10 secondary fault 分层） |
| HOK-012-C.3-a | DONE | 落地 deferred-install watchpoint 自动化：`LLDBRunOptions.deferWatchpointInstall` 贯穿 `LaunchService` / `runLLDBHeadless` / `launch_app_with_lldb` MCP schema / `hok006_ngr_lldb_runner.py --defer-watchpoint-install + --writer-address`（默认 `0x103a29b7c`）四层，Python runner 在 defer 模式下自动注入 `breakpoint set --address 0x103a29b7c -C "watchpoint set expression -s 8 -- 0x10e2146f8" -C "continue" --auto-continue true --one-shot true` 到 `preRunCommands`。`LaunchServiceTests` 新增 2 个用例，26 个测试全过；`BuildScripts/build_and_install.sh` 构建 + 安装 + ad-hoc 签名成功 | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（deferred-install 证据口径 + CLI 最小参照） |
| HOK-012-C.3-b | TODO | 把 LLDB 捕获窗口从 5s/20s 拉到覆盖完整 ~32s app 生命周期（以 `NGR-*.ips` 里 `procLaunch`→`procExitAbsTime` 差 ≈32s 为口径），必要时分层落 `--lldb-teardown-timeout` / `SIGABRT` 预设 / `--writer-addresses` 多地址 fallback，直到在 UE4 fatal 发生前后真正抓到 `0x103a29b7c` / `0x107e5df10` 任一入口 bp + `0x10e2146f8` 的 watchpoint hit，或确认 writer 在整个生命周期内都没被调用（复核 HOK-011 的"唯一 store 假设"）。详细步骤 1/2/3/4/5 见"下一步默认规划" | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（待补充 "lldb-timeout 与 app 生命周期对齐" 章节） |
| HOK-010 | DEFERRED | 把 `rootWorkDir` 从 `PlaySettings.disableForMinimalStartupCompat(...)` 摘除以消除 `QtsFileSystem Create Failed!!`；HOK-012-C.2/C.3-a 的 live 已复现该 UE4 fatal 与 Thread #10 `0x1047862bc` secondary fault，但在 HOK-012 主线未收敛前不要重启 HOK-010，以免同时动摇 root cause 分析与 cwd 语义 | 暂无 |
| HOK-007C | DEFERRED | 为下游 crash（`0x10915b114` / `far=0x50`、以及 HOK-012-C.2 观察到的 Thread #10 `0x1047862bc` / `address=0x30`）做 HOK-007A 离线映射 + HOK-007B 风格最小可逆 patch；暂缓，等 HOK-012-C.3-b 的 live 结论明确后再评估这些下游 fault 是 `0x10e2146f8` 的连锁反应还是独立问题 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
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
- `effectiveLaunchEnvironment` 在 host 侧存在**两份实现**：`PlayCover/Model/PlayApp.swift`（GUI 启动路径）和 `PlayCoverMCP/HostServices/Launch/LaunchService.swift`（MCP `launch_app` / `launch_app_with_lldb` 路径）。对 `minimalStartupCompatBundleIdentifiers` 的任何 env 改动**必须同时写到两份**，否则 `launch_app` 和 `launch_app_with_lldb` 的行为会偏离；HOK-012-A 已把 `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 两侧对齐，并用 `LaunchServiceTests` 覆盖 inject/non-inject 两条分支。
- 给 `minimalStartupCompat` bundle 打开 `DYLD_PRINT_INITIALIZERS=1` 时，**同时显式置 `DYLD_PRINT_APIS=0`** 是必要的——否则若父终端之前 export 过 `DYLD_PRINT_APIS=1`，子进程会被 dyld API 的洪水淹没，initializer 日志就读不到了。这个技巧在 HOK-012-B 的 stderr 抓取里必须保留。
- HOK-012-C live 证明："**backtrace 里已经出现 writer 函数内某个偏移** ≠ **watchpoint 命中**"。这两件事在 arm64 + LLDB + dyld 早期阶段并不等价：writer 函数的 first-initialization 分支可能在 `target create` → `run` 之间、或 watchpoint 真正 armed 之前就完成了 store。排查 `0x10e2146f8` 这类 `__common` slot 的 writer 时，必须把 watchpoint 装入时机下推到"writer 函数自身 bp 命中之后"，而不是依赖 `run` 之前的预装。
- watchpoint 模式下 `didStop=true` + `watchpointHitCount=0` 是一种合法状态：表示 capture window 内发生了**其他** stop（典型是下游 UE4 fatal + Thread #10 `EXC_BAD_ACCESS`）。`LaunchService.parseLLDBEvidence` 已把这种情况的 fault 字段优先挑选到非 watchpoint stop 上，**不要**再把 `faultingFrame` 当成原 `0x10480df08` 那一层的证据使用；它可能指向 HOK-010 / HOK-007C 的下游 fault。
- HOK-012-C.3 用户现场纠正的关键教训：**`--lldb-timeout` 不等于 app 的真实生命周期**。`runLLDBHeadless` 到点后发 `process interrupt` + `quit` 是在"LLDB 这一侧"撤回，但如果 app 在此之前已经触发了 UE4 `abort()` + Apple 标准崩溃对话框，子进程会被挂在前台等用户点击，**直到用户点了对话框才真正退出**——此时 LLDB 早已 detach，bp / watchpoint 全部失效，transcript 看起来"没命中"只是因为已经离开了 LLDB 的观察窗口。**判定 app 真实生命周期的唯一口径是 `NGR-*.ips` 里的 `procLaunch` 与 `procExitAbsTime` 之差**，不是 LLDB transcript 的时间戳；C.3-a 两轮的 app 生命周期都是约 32s，远超 LLDB 的 5s/20s timeout。
- 承上一条的推论：**"backtrace 里出现 writer 函数内偏移"仍然等价于"writer 函数刚被调用（栈上）"**（这是 HOK-012-C.2 里 `frame #4: 0x103a29fb0` 的正确读法）；C.3-a 的 "bp 未命中" 只能说明 **writer 在 LLDB 捕获窗口内未被调用**，不能扩展解释成"writer 在 app 整个生命周期内未被调用"。上一轮 Dashboard 误把这个结论当成 HOK-011 的证伪，本轮已撤回。
- `build/hok-012-ngr-dyld-initializers.log` 里 dyld 原生 `dyld[pid]: initializer …` 行在当前 macOS 版本可能不会出现；但 **ObjC 重复类警告**（`PxFrameworkLoader` / `AReachability` / `PxDyLibFrameworkLoader`）、app 自研 `[GPM] [EVENT] [launch_time] cpp constructor call` 与 `CAppLifecycleLaunch::CAppLifecycleLaunch` 等构造 log 是同一阶段的可靠替代判据。`hok006_ngr_lldb_runner.py` 的 `initializerLineCount` 字段若为 0，不代表 dyld static init 没跑——必须结合 `byteCount` 与 `tail` 文本判断。
- 在 `launch_app_with_lldb` 的 deferred-install 模式下，MCP 端 `request_timeout` 与 Python runner 的 `--lldb-timeout` 必须协同：runner 把 `request_timeout` 设置为 `lldb_timeout + 15s`，但如果后续要覆盖 C.2 里 "5s 才到 UE4 fatal" 之外的更晚阶段，`runLLDBHeadless` 的 `process interrupt` 收尾窗口（固定 2s）也必须跟着加大，否则 `thread backtrace all` 来不及返回完整 254 帧就会被 `process terminate` 切断，transcript 里只留下 bp armed 行而没有任何 stop 证据。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑；`effectiveLaunchEnvironment()` 是 `HOK-012-A` 注入 `DYLD_PRINT_INITIALIZERS=1` 的目标点（已落地，见 `minimalStartupCompatDiagnosticEnvironment`）。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 侧 `launch_app` / `launch_app_with_lldb` 的启动环境组装入口；同步维护着 `minimalStartupCompatDiagnosticEnvironment` 常量、`LLDBRunOptions` 定义（HOK-012-B: watchpoint/preRunCommands/stderr 重定向 + HOK-012-C: `deferWatchpointInstall`）与 `parseWatchpointHits` 解析器；`hok006_ngr_lldb_runner.py` 的 deferred-install 模式直接消费这里的 `launch_app_with_lldb` 扩展 schema。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值；`disableForMinimalStartupCompat(...)` / `minimalStartupCompatBundleIds` 是 `HOK-010` 的主改点，`HOK-012` 暂不触发。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：`HOK-005` 分层最小化子任务与每层 live 结论。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：`HOK-006` 的自动化入口、证据口径与 31 帧 backtrace。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：`HOK-007A` 离线 callsite mapper、`HOK-007B` 候选 E（branch-to-epilogue）patch 设计与回滚口径、以及候选 E 在 HOK-011 之后被定位为 workaround 的技术依据。
- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：`HOK-011` 的扫描器设计、反向 call graph 方法论、`0x10e2146f8` writer 不可达的离线结论、ObjC 重复类警告，以及 HOK-012 live-trace 的工具链、标准命令与 H1/H2/H3 假设分类。
- `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`：HOK-012-C 的方法论沉淀——legacy baseline vs watchpoint run 的角色分工、watchpoint run 的 5 种语义、dyld log 交叉对齐规则、secondary fault 的分层解读、与 HOK-011 静态结论的交叉校验。
- `Scripts/hok007b_ngr_patch_runner.py`：候选 E 最小可逆 patch 的单一来源；当前状态 `applied`。
- `Scripts/hok011_ngr_common_init_chain.py` + `Scripts/test_hok011_ngr_common_init_chain.py`：`__common` slot writer 扫描器与单元测试。
- `build/hok-011-analysis-notes.json`：HOK-011 的完整证据结构化文件（含 caller/reader/writer 地址表、反向 BFS 结论、ObjC 重复类列表、HOK-012 hand-off 建议）。
- `build/hok-012-ngr-watchpoint-report.json`：HOK-012-B watchpoint 命中清单；由 `Scripts/hok006_ngr_lldb_runner.py --watch-address …` 生成，字段定义见 `LaunchService.parseWatchpointHits`。
- `build/hok-012-ngr-dyld-initializers.log`：HOK-012-B 子进程 stderr 重定向文件；由 `Scripts/hok006_ngr_lldb_runner.py` 在 watchpoint 模式下自动写入，`DYLD_PRINT_INITIALIZERS=1` 的所有 `dyld[pid]: …` 输出都会落到这里，供与 watchpoint 命中时间戳交叉对齐。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/`：20+ 个嵌入 framework 的集合；`HOK-012` 的 watchpoint 很可能命中其中某一个（`GCloud`、`PixUI_PXPlugin`、`PxKit3`、`BqCCS` 等）。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`：与本主线无关，除非需要借鉴 dashboard 维护方式。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
