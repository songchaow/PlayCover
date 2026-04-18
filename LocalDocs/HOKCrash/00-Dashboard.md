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
- **当前主线**：`HOK-012-C.3-b`——把 UE4 `abort()` 拦在 Apple 崩溃对话框之前，用 LLDB 的 SIGABRT 接管让 app 在 abort 瞬间停住而**不是**被对话框挂在 UI 线程；然后在被停住的 app 上一次性采集"所有线程 backtrace + `0x10e2146f8` 当前值 + `0x103a29b7c` / `0x107e5df10` 两个 bp 的 hit count + watchpoint 是否触发过"。**关于 app 生命周期口径的修正**：之前把 `.ips` 里 `procLaunch → procExitAbsTime ≈ 32s` 误读成"app 自然生命周期"是错的——UE4 `abort()` 弹出的 Apple 崩溃对话框会把进程挂在 signal handler 里等用户点 "Reopen / Close"，**用户点击之前进程不会退出，也不会生成 `.ips`**；`.ips` 里的 32s 实际上只是用户点对话框的时刻。因此 `--lldb-timeout` 不需要和"生命周期"挂钩，只需要**够长以覆盖 launch → abort 的这一段**（经验值 60s 即可），关键是必须让 LLDB 在 abort 发生时优先接管，而不是等 app 到崩。
- **当前卡点**：
  - UE4 `abort()` 弹出的 Apple 崩溃对话框是**进程终点本身**——不点就 UI 线程阻塞、LLDB 观察到的"仍在运行"其实是"在 signal handler 里挂机"。默认行为下 LLDB 对 SIGABRT 是 pass 的，所以"不告诉 LLDB 拦 SIGABRT"=="等对话框出现 + 用户点击"。必须显式 `process handle -s true -n true -p false SIGABRT`，abort 才会在 LLDB 层停住、对话框不会出现。
  - 现有 `runLLDBHeadless` 的 `process interrupt` 收尾 2s 在上一轮 20s run 里不够写完 `thread backtrace all` + `register read`；这个问题在 SIGABRT 拦截之后会更严重（stop 发生时我们要发的命令远比超时收尾多：backtrace / `breakpoint list` / `memory read 0x10e2146f8` / `watchpoint list`）。
  - deferred-install 模式的 `--writer-address` 默认 `0x103a29b7c`，若 writer 真的在 launch → abort 窗口内被调用，bp 应该会先于 abort 命中；若 abort 时 bp 的 hit count 仍为 0，说明 writer **真的没在 launch → abort 之间被调用**——但此时我们已经把 abort 抓在手里，可以直接检查 `0x10e2146f8` 的**当前值**：若为 0，说明 slot 一直是 dyld 零填、HOK-011 假设的 writer 路径没执行；若非 0，说明 writer 路径曾跑过但我们没拦到（需放宽 HOK-011 的静态扫描）。
  - `QtsFileSystem Create failed.` 与 Thread #10 `0x1047862bc`（`address=0x30`）是 UE4 层 fatal，可能是 `0x10e2146f8` reader 下游的连锁反应，也可能是独立问题；HOK-012-C.3-b 在 abort 上 stop 住之后，通过查看 `0x10e2146f8` 当前值 + 检查 reader 链的 caller `0x10460e2c0` 下游是否指向 `QtsFileSystem` 代码路径即可判明。
- **下一步默认规划**（顺序与上一版不同——SIGABRT 拦截必须先上，因为 abort 不被拦住=对话框阻塞=LLDB 空转）：
  1. `HOK-012-C.3-b.1`：给 Python runner 在 defer 模式下**无条件预置** `process handle -s true -n true -p false SIGABRT`（放在自动生成的 writer bp 行之前，用 `--pre-run-command` 相同管道注入），让 UE4 `abort()` 在进入 Apple 崩溃对话框之前就被 LLDB 停住。同时在"stop handler"里除了发 `thread backtrace` / `frame variable` / `continue` 这一组，还追加 `memory read -s 8 -c 1 0x10e2146f8` / `breakpoint list` / `watchpoint list`（只在 abort 形态的 stop 上发，不影响 watchpoint-hit 形态）。本步只改 `Scripts/hok006_ngr_lldb_runner.py` + 可能扩 `LaunchService.runLLDBHeadless` 的 stop-handler 路径，不引入新 MCP schema。
  2. `HOK-012-C.3-b.2`：把 `runLLDBHeadless` 的 `process interrupt` 收尾窗口（当前硬编码 `2.0`）参数化为 `LLDBRunOptions.teardownTimeoutSeconds`，并在 `launch_app_with_lldb` MCP schema + `hok006_ngr_lldb_runner.py` CLI 上透传；`LaunchServiceTests` 补 1 个用例覆盖默认值兼容。b.1 的 abort 形态 stop 需要发的命令更多，2s 窗口很可能不够；把它拉到 5–10s。
  3. `HOK-012-C.3-b.3`：跑一轮 `python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --defer-watchpoint-install --lldb-timeout 60 --settle-seconds 65 --skip-build-install`（`--lldb-timeout 60` 是经验保守值，launch → abort 通常 < 30s，但留够冗余以免 app 启动比预期慢）。预期观察：(a) transcript 里出现 `stop reason = signal SIGABRT`；(b) 在 stop 上发的 `memory read 0x10e2146f8` 给出当前值；(c) `breakpoint list` 给出 `0x103a29b7c` bp 的 hit count；(d) 若 watchpoint 曾装上，`watchpoint list` 给出命中次数。**本步不需要用户做任何手工操作**——SIGABRT 被 LLDB 拦截后 Apple 对话框不会出现。
  4. `HOK-012-C.3-b.4`：根据 b.3 的 `memory read 0x10e2146f8` 结果分流：
     - slot 值为 **0x0**：HOK-011 假设的 writer 路径在 live 下确实没跑过，reader 读到 null 触发 fault；下一步是 HOK-013（在 PlayTools 里提前 touch Logger accessor `0x107e5df10` 预热 slot）。
     - slot 值为 **非 0 指针**（落在 NGR text 段或 heap）：writer 路径跑过但我们没拦到；扩 `--writer-addresses` 为多地址 fallback（`0x103a29b7c,0x107e5df10`），脚本为每个地址注入一条"bp hit → 装 watchpoint → continue"的 one-shot bp。
     - slot 值是个 **坏指针**（未映射 / 小整数）：slot 被某个 bug 写坏了；沿这个值反查 writer。
  5. 若 b.1/b.2/b.3/b.4 跑完仍然无法在 abort stop 上稳定取得 `0x10e2146f8` 的值，或取到了但和 HOK-011 静态结论无法对齐，才回到 `Scripts/hok011_ngr_common_init_chain.py` 放宽 store 形式（`str` / `stp` / `sturh` / ARM64 memcpy helper 的间接 store）并扫描非 `__TEXT,__text` 段里的 `bl 0x107e5df10` / `bl 0x103a29b7c` 调用边。

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
| HOK-012-C.3-b | TODO | 让 LLDB 抢在 Apple 崩溃对话框之前拦住 UE4 `abort()`：先给 Python runner 在 defer 模式下无条件预置 `process handle -s true -n true -p false SIGABRT`（b.1），再把 `runLLDBHeadless` 硬编码的 2s `process interrupt` 收尾窗口参数化（b.2），然后跑 `--lldb-timeout 60` 的 live run（b.3）在 abort stop 上一次性取到所有线程 backtrace + `memory read 0x10e2146f8` + `breakpoint list` / `watchpoint list`，按 slot 当前值分流（b.4）；只有前四步都没拿到可解释证据才复核 HOK-011 静态假设（b.5）。顺序关键：SIGABRT 拦截必须先上，不做这一步任何"延长 timeout"都会被 app 被 Apple 崩溃对话框挂死 UI 线程吃掉 | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（"deferred-install 模式下 bp 未命中 的正确读法" 6 步） |
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
- HOK-012-C.3 用户现场纠正的关键教训：**`--lldb-timeout` 不等于 app 的真实生命周期，而 `.ips` 里 `procLaunch → procExitAbsTime` 也不等于 app 的自然生命周期**。UE4 `abort()` 弹出的 Apple 崩溃对话框会把进程**挂在 signal handler**里等用户点 "Reopen / Close"——用户点击之前进程不会退出，也不会生成 `.ips`，`.ips` 里的"32s 生命周期"其实就是用户点对话框的时刻。LLDB 默认对 SIGABRT 是 pass 的，所以 LLDB 会"看到 app 还在运行"但实际上 UI 线程已被 Apple 对话框挂机，同时 LLDB 自身的 timeout 还在倒数，于是 bp / watchpoint 在"对话框弹出之后"就彻底失效。**唯一可靠的观察窗口构造是：让 LLDB 显式拦截 SIGABRT（`process handle -s true -n true -p false SIGABRT`），这样 `abort()` 会在 Apple 对话框出现之前就在 LLDB 层 stop，随后可以一次性抓 backtrace / `memory read 0x10e2146f8` / `breakpoint list` / `watchpoint list`**。`--lldb-timeout` 在这套接管下只需要给一个保守大值（60s）容纳 launch → abort 段即可，不需要和所谓"生命周期"挂钩。
- 承上一条的推论：**"backtrace 里出现 writer 函数内偏移"仍然等价于"writer 函数刚被调用（栈上）"**（这是 HOK-012-C.2 里 `frame #4: 0x103a29fb0` 的正确读法）；C.3-a 的 "bp 未命中" 只能说明 **writer 在 LLDB 捕获窗口内未被调用**，不能扩展解释成"writer 在 app 整个生命周期内未被调用"。上一轮 Dashboard 误把这个结论当成 HOK-011 的证伪，本轮已撤回。
- 不要把"不点对话框"当成延长观察窗口的手段。不点 = UI 线程阻塞在 signal handler，**app 永远不会自然崩溃、`.ips` 永远不会生成**。要获得完整的 abort 现场证据，唯一正确做法是让 LLDB 在对话框出现**之前**就拦住 `abort()`；对话框出现后再去干预已经晚了。
- `build/hok-012-ngr-dyld-initializers.log` 里 dyld 原生 `dyld[pid]: initializer …` 行在当前 macOS 版本可能不会出现；但 **ObjC 重复类警告**（`PxFrameworkLoader` / `AReachability` / `PxDyLibFrameworkLoader`）、app 自研 `[GPM] [EVENT] [launch_time] cpp constructor call` 与 `CAppLifecycleLaunch::CAppLifecycleLaunch` 等构造 log 是同一阶段的可靠替代判据。`hok006_ngr_lldb_runner.py` 的 `initializerLineCount` 字段若为 0，不代表 dyld static init 没跑——必须结合 `byteCount` 与 `tail` 文本判断。
- 在 `launch_app_with_lldb` 的 deferred-install 模式下，MCP 端 `request_timeout` 与 Python runner 的 `--lldb-timeout` 必须协同：runner 把 `request_timeout` 设置为 `lldb_timeout + 15s`，但如果后续要在 `abort()` stop 上多发几条命令（`memory read 0x10e2146f8` / `breakpoint list` / `watchpoint list`），`runLLDBHeadless` 的 `process interrupt` 收尾窗口（固定 2s）也必须跟着加大，否则 `thread backtrace all` 来不及返回完整 254 帧就会被 `process terminate` 切断，transcript 里只留下 bp armed 行而没有任何 stop 证据。

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
