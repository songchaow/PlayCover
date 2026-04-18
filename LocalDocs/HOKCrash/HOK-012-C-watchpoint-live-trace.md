# HOK-012-C: 0x10e2146f8 watchpoint live-trace 方法论与证据口径

> 本文是 HOK-012-C 的**方法论沉淀**，不写任务状态/快照日期。任务状态以 Dashboard 为准。
> 任何"本轮结论/下一步/handoff/DONE"等字样不在本文出现；它们仅在 `LocalDocs/HOKCrash/00-Dashboard.md` 维护。
> 所有具体的 live 证据以结构化报告文件为单一来源：`build/hok-012-ngr-watchpoint-report.json`、`build/hok-012-ngr-dyld-initializers.log`、`build/hok-006-ngr-lldb-report.json`。

## 目的

承接 HOK-012-A/B 在 host/MCP/LLDB runner 三层就绪的 watchpoint 自动化，在安装了 `com.tencent.ngr` 的真实 PlayCover 环境上执行 live run，用结构化证据把 `0x10e2146f8` 的实际 writer identity 定位清楚：落到 HOK-011 提出的 H1/H2/H3 假设之一，或者得出"slot 在 live 下根本没被写"这样同样明确的结论以指向 HOK-013（runtime 侧预热 slot）。**注意**：candidate-E patch 仍是症状 workaround，不是 HOK-012 的闭合条件；HOK-012 的闭合必须基于 abort-stop 上对 `0x10e2146f8` 当前值与 writer 链 bp hit count 的直接观察。

## 口径：legacy baseline、watchpoint run 与 deferred-install 的角色分工

- **legacy baseline**：`python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install`，不传 `--watch-address`，MCP `launch_app_with_lldb` 走 HOK-006 的老路径。候选 E 仍处于 apply 状态时，此轮的意图是**确认 `0x10480df08` 原 faulting window 已被绕过、app 能跑过 index 1563**；若反而观察到 `faultingFrame = 0x10480df08` 重新出现，说明 patch 被外力回滚，必须先恢复 patch 状态再进入 watchpoint 轮。
- **watchpoint run (pre-run install)**：`python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --skip-build-install`，脚本会自动：
  - 把 `DYLD_PRINT_INITIALIZERS=1` 子进程 stderr 重定向到 `build/hok-012-ngr-dyld-initializers.log`；
  - 在 `run` 之前装好 `watchpoint set expression -s 8 -- 0x10e2146f8`；
  - 每次 watchpoint stop 后抓 backtrace 并 `continue`，允许同一轮累计多次命中；
  - 把结构化命中写入 `build/hok-012-ngr-watchpoint-report.json`，与 `build/hok-006-ngr-lldb-report.json.launch.lldb.watchpointHits` 同源。
- **watchpoint run (deferred install, HOK-012-C)**：`python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --defer-watchpoint-install --skip-build-install`；`--writer-address` 缺省为 `0x103a29b7c`（HOK-011 定位的 Meyers-singleton accessor 入口）。与 pre-run 装入的区别是：
  - 脚本**不再**在 `run` 前发 `watchpoint set expression`；
  - 脚本生成一条 `breakpoint set --address <writer> -C "watchpoint set expression -s <size> -- <addr>" -C "continue" --auto-continue true --one-shot true` 注入到 `preRunCommands`；
  - watchpoint **只在** writer 函数入口 bp 命中后才装入，避免 pre-run 装入与 child dyld 接管之间的 race；
  - 同时仍用 `process launch -e` 落 dyld log、stop→continue 循环抓 hits。
- **两轮必须背靠背执行**：baseline 不稳定或候选 E 被回滚时，watchpoint run 的 0 hit 不能被解释为"slot 已被预初始化"。deferred-install 模式在 `isWatchpointMode=true` 的同时 `deferWatchpointInstall=true`，`LaunchService` 保持 stop→continue / `parseWatchpointHits` 的 HOK-012-B 解析链路不变。

## 证据口径：watchpoint run 的 6 种语义

| 证据形态 | 触发条件 | 语义 |
|---|---|---|
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 **NGR framework 内** | writer 是 embedded framework 的 C++ ctor / `+load` / framework init callback | H3（跨 dylib static ctor 链）或 H1（framework init 回调） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 **libobjc + `+load`** | writer 来自 ObjC `+load` | H2（ObjC 类挑选顺序差异） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 `0x103a29f7c`（NGR 自身 writer） | writer 函数本身被触达 | 说明 `__cxa_guard` first-initialization 分支在本轮被走到；结合 `__init_offsets` 可达性重新评估 HOK-011 |
| **`watchpointHitCount == 0` + pre-run 模式** + `didStop=true` 且 stop 指向下游 reader | watchpoint 装好前 slot 已被写，或 store 在 LLDB detach/attach 窗口外 | 切换到 deferred-install 模式重跑；这正是 HOK-012-B → HOK-012-C 的触发条件 |
| **`watchpointHitCount == 0` + deferred-install 模式 + `--writer-address 0x103a29b7c`** + `lldbStopObserved=False`（bp 也未命中，transcript 里有 `Breakpoint 1: address = 0x103a29b7c` 但没有 `Breakpoint 1.*hit` 行） | writer 函数**在 LLDB 捕获窗口内**未被调用。注意：`.ips` 里的 `procLaunch → procExitAbsTime` 不是 app 的自然生命周期，而是用户点 Apple 崩溃对话框的时刻；app 默认会被 `abort()` 挂在对话框上。不能通过"延长 `--lldb-timeout`"来解决，必须按下一节 "deferred-install 模式下 bp 未命中的正确读法" 让 LLDB 拦 SIGABRT，把 abort 停在 LLDB 层，然后读 `0x10e2146f8` 当前值 + `breakpoint list` 的 hit count 下结论 | 不要直接宣告 HOK-011 被证伪 |
| `watchpointHitCount == 0` + `didStop=false`（超时） | 进程根本没跑到 reader | 检查 `dyldInitializersLogPath` 文件大小与 PlayTools diag 是否写全；可能是 `posix_spawn` 再拉起导致子进程环境没继承 |

## deferred-install 模式下"bp 未命中"的正确读法

HOK-012-C.3-a live run 观察到的模式是：
- transcript 明确出现 `Breakpoint 1: address = 0x0000000103a29b7c`（说明 LLDB 成功把 bp 装到 writer 函数入口）；
- `process launch -e` 成功拉起 child（有 `Process <pid> launched`、LANDSCAPE banner、PlayTools 的 `playcover_*` 事件、`[GPM] cpp constructor call`、ObjC 重复类警告，以及后续 `SceneExtension hook_frame` 循环）；
- 但在 5s / 20s 两档 `--lldb-timeout` 里 transcript 都**没有**出现 `Breakpoint 1.*hit` 或任何 `stop reason =` 行；
- 超时后 `process interrupt` + `thread backtrace all` 在 2s 收尾窗口里来不及返回完整 backtrace。

这类 run 的正确解读 **不是** "writer 函数在 app 生命周期内从未被调用"，而是 "writer 函数在 **LLDB 捕获窗口** 内未被调用"；同时需要警惕："`NGR-*.ips` 里 `procLaunch → procExitAbsTime ≈ 32s`" **不是** app 的自然生命周期——UE4 `abort()` 弹出的 Apple 崩溃对话框会把进程挂在 signal handler 里等用户点 "Reopen / Close"，用户点击之前进程不会退出、也不会写 `.ips`；因此 `.ips` 里的"32s"其实就是用户点击时刻。不点 = UI 线程阻塞，app 永远不会自然崩溃，任何"延长 `--lldb-timeout`"的策略都抓不到 abort 现场。

正确的后续动作不是退出 `0x103a29b7c`，也不是等对话框，而是：

1. **让 LLDB 抢在 Apple 崩溃对话框之前拦住 abort**：在 `preRunCommands` 里追加 `process handle -s true -n true -p false SIGABRT`。被拦住后对话框不会出现，LLDB 就有完全受控的 stop 现场。这是 b.1 的**唯一关键动作**，不做等于白做。
2. **在 abort stop 上一次性取满需要的事实**：`thread backtrace all` + `memory read -s 8 -c 1 0x10e2146f8` + `breakpoint list`（看 `0x103a29b7c` / `0x107e5df10` 的 hit count）+ `watchpoint list`（看 slot 写入是否曾触发过 watchpoint）。`0x10e2146f8` 的当前值决定下一步分流：`0x0` 走 HOK-013（提前 touch Logger accessor）；非 0 指针走 b.4（多 writer bp fallback）；坏指针走"反查坏写入"。
3. **把 `--lldb-timeout` 给到保守大值**（60s 够用）容纳 launch → abort 段。不需要与 `.ips` 的"32s"挂钩——那个数字依赖用户点击时刻。
4. **把 `runLLDBHeadless` 的收尾 2s 窗口参数化**（HOK-012-C.3-b.2）：abort stop 需要发的命令比 watchpoint stop 多，2s 大概率不够；先放到 5–10s。
5. **给 writer bp 加 fallback 地址**：除了 `0x103a29b7c` 本身，再对 `0x107e5df10`（HOK-011 里 writer 的唯一 caller，Logger accessor）同时下 bp；任何一方先命中都能装 watchpoint。
6. **必要时才复核 HOK-011 静态假设**：只有当 1–5 全部跑完、writer 与其唯一 caller 两个 bp 在 abort stop 时 hit count 都是 0、但 `0x10e2146f8` 的当前值**非 0**，才需要回到 `Scripts/hok011_ngr_common_init_chain.py` 放宽扫描形式（`str` / `stp` / `sturh` / ARM64 memcpy helper 的间接 store）或补扫 NGR 主二进制的非 `__TEXT,__text` 段。

## HOK-012-C 的 CLI 最小参照

```
# baseline
python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install

# pre-run watchpoint（HOK-012-B）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --skip-build-install

# deferred-install watchpoint（HOK-012-C.3-a，默认 writer = 0x103a29b7c）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --skip-build-install

# deferred-install + SIGABRT 拦截 + 参数化 teardown（HOK-012-C.3-b 的默认形态）
# `--intercept-sigabrt` 在 defer 模式下默认 ON；`--teardown-timeout` 在 defer 模式下默认 6.0s。
# 下面的写法等价于"纯 defer + 60s lldb-timeout + 65s settle"，abort 被 LLDB 拦住
# 后，后续一切推进都发生在 LLDB stop 现场，不需要等用户点对话框；不拦 SIGABRT 则
# app 会被 Apple 崩溃对话框挂住 UI 线程、直到用户点击才真正退出。
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --lldb-timeout 60 --settle-seconds 65 \
  --skip-build-install

# 如果需要显式关闭 SIGABRT 拦截（不推荐，仅用于回归 defer-without-intercept 的旧形态）：
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install --no-intercept-sigabrt \
  --skip-build-install

# deferred-install 时显式关闭 writer 自动 bp（完全由 --pre-run-command 控制）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install --writer-address "" \
  --pre-run-command 'breakpoint set --shlib GCloudCore --name load -C "watchpoint set expression -s 8 -- 0x10e2146f8" -C "continue" --auto-continue true --one-shot true' \
  --skip-build-install
```

## 对话框污染 gate（所有 live run 的强制前置条件）

`com.tencent.ngr` 启动后会**自主弹出一个 modal 对话框**（结构是普通 `NSWindow` + 自管 modal event loop，`windowLayer=0`，不是 `NSAlert`），弹出之后 UI 线程陷入 app 自己的 modal loop，其他线程继续跑但永不前进——典型表现是 `SceneExtension hook_frame` 被稳态循环打印，transcript 完全空转 60s 都不出现 `stop reason = `，一切看起来"健康"其实是冻结。**在这种冻结状态下从 LLDB 取到的任何 `memory read` / `breakpoint list` / `watchpoint list` 都是快照而不是 live 行为**，不能用来证实或反驳 HOK-011 的静态结论。因此 HOK-012 的每一轮 watchpoint live run，退出前必须强制走一次对话框检测 + 残留进程强杀，并把"检测到对话框"当成本轮证据全部作废的 hard-fail。

实现层面（`LaunchService.runLLDBHeadless` 收尾阶段）：

1. 解析 transcript 得到 child 直接 inferior PID（`parseProcessIdentifier` 现成）；
2. `/bin/ps -axo pid=,ppid=` 遍历全系统进程，从 root PID 做闭包得到**子进程孙进程**全集（NGR 会派生 helper XPC 服务，光看直接 child 不够）；
3. `CGWindowListCopyWindowInfo(.optionOnScreenOnly | .excludeDesktopElements, kCGNullWindowID)` 枚举所有 on-screen 窗口，按 `kCGWindowOwnerPID ∈ descendants` + `alpha ≥ 0.05` 过滤，得到 `BlockingDialogInfo` 列表（含 `ownerName` / `windowName` / `windowLayer` / `bounds`）；
4. 对 descendants 里每一个仍 alive 的 PID 调 `kill(pid, SIGKILL)`，记录实际被 signal 的 PID 到 `residualProcessesKilled`；
5. `LLDBLaunchEvidence` 新增两个字段暴露结果；`launch_app_with_lldb` JSON response 透出；Python runner 侧 `determine_overall_pass` 在 `blockingDialogDetected=True` 时强制 `overallPass=False`、exit 非零；summary 行含 `blockingDialogs=…` / `residualPIDsKilled=…` 供目视识别。

**不要**把"检测到的窗口一定是对话框"当成前提。实测 b.0 的端到端验证里一轮 capture 同时看到 2 个 NGR 窗口：一个 260×204 小窗（极可能是对话框）和一个 1478×859 主窗。两者都不应该在 LLDB capture 窗口结束时还处于"被 LLDB 看着仍 running"状态——任何 NGR 窗口残留在屏幕上，本身就意味着 LLDB 没把 app 停在期望的 stop 点上，本轮证据都不可信。因此当前判据"属于 NGR PID + onscreen + alpha≥0.05"就是最保守正确的，不要继续细分 modal vs 普通窗口。

检测到对话框后的正确动作**不是**重跑 live run（重跑还是会污染），而是往前走 b.3 的"对话框弹出前拦截 bp"设计：在 `preRunCommands` 里补 `-[NSApplication runModalForWindow:]` / `-[NSWindow orderFront:]` / `CGSOrderWindow` 等候选 symbol 的 bp，让 LLDB 在对话框动手 order window front 之前就把 app 停下来，由 b.1 的 abort-stop handler 一次性取 slot / bp / watchpoint 证据；捕获到后如果 `lldbBlockingDialogDetected=False`，才是一轮合法 live 证据。

## SIGABRT 拦截下 abort-stop 的自动证据采集

`runLLDBHeadless` 在 watchpoint 模式下对每一次新出现的 `stop reason =` 行都做一次分流：

- 行内含 `"watchpoint "` 字样：继续走 HOK-012-B 的 legacy 序列 `thread backtrace` + `frame variable` + `continue`，把 stop 当成普通 writer 命中、不打断采集。
- 行内**不含** `"watchpoint "` 字样（典型是 `signal SIGABRT` 被 `process handle -s true -n true -p false SIGABRT` 拦住）：改发 `thread backtrace all` + `frame variable` + `memory read -s 8 -c 1 <watchAddress>`（仅当 `watchAddress` 非空时）+ `breakpoint list` + `watchpoint list` + `continue`。

这一改动保持 watchpoint-hit 的采集逻辑与 HOK-012-B 完全一致，只在"非 watchpoint 的 stop"——也就是被 SIGABRT 拦截的 abort 现场——上附加 slot 读取与 bp / watchpoint 汇总，使 abort 一次停住就能同时回答"slot 当前值多少"、"writer bp 命中几次"、"watchpoint 曾否触发"。整套序列的执行时间会超过 HOK-012-B 原硬编码的 2.0s 收尾窗口，因此必须配合 HOK-012-C.3-b.2 的 `LLDBRunOptions.teardownTimeoutSeconds` 放大（默认 2.0 保持 legacy，defer 模式由 `hok006_ngr_lldb_runner.py` 自动拉到 6.0s）。

## dyld log 交叉对齐规则

- `build/hok-012-ngr-dyld-initializers.log` 的时间戳与 `hits[i].backtrace` 所在命中时刻的 `processIdentifier` 同属一个子进程（`process launch -e <path>` 重定向）。
- 对齐方法：
  1. 从 `build/hok-006-ngr-lldb-report.json` 读取 `launch.launchRequestedAt` 与 `launch.lldb.processIdentifier`。
  2. 在 dyld log 里 grep `NGR[<pid>:`，第一行即为子进程 stderr 开始时间。
  3. watchpoint 命中的 wall clock 不直接出现在 transcript 里，但 `backtrace` 中的 `Foundation` / `libsystem_pthread.dylib` / `libobjc` / `dyld` 系统层帧可唯一标识所处阶段（ObjC `+load` vs C++ ctor vs NSThread start）。
- 如果 `dyldInitializersLog` 文件存在且 `initializerLineCount == 0`，但 ObjC 重复类警告已出现，说明 dyld 的 `initializer` 日志行格式已从 `dyld[pid]: initializer …` 变成只有 `dyld[pid]:` 或 app 直接打印的 `[GPM] cpp constructor call` 之类自研日志——此时应以 ObjC 重复类警告 + app 自研 log 作为"已进入 static init"的判据，而不是依赖 dyld 原生 initializer 行。

## 解读"Thread #10 fault at `address=0x30`" 这类 secondary fault

watchpoint run 里如果同时观察到：
- `faultingFrame` 指向 `___lldb_unnamed_symbol271xxx` 家族（`0x10478xxxx` / `0x10477xxxx` 区段，**NGR `__TEXT,__text` 尾部，不在 HOK-007A 的 `0x10480df08` 附近**）；
- fault 发生在 **非 #0 主线程**，backtrace 里出现 `Foundation`__NSThread__start__` / `libsystem_pthread.dylib`_pthread_start`；
- dyld log 尾部已出现 `[UE4] Fatal error ... QtsFileSystem Create failed.` 或 `ICU data directory was not discovered`；

则该 fault 属于 **HOK-010 / HOK-007C 方向的下游崩溃**（`QtsFileSystem` / `rootWorkDir` 触发的二级崩溃），**不是** `0x10e2146f8` reader path 的原始 fault。HOK-012 的闭合判据仍然是 `0x10e2146f8` 的 writer identity，**判定 slot 是否被写必须看 abort-stop 上的 `memory read 0x10e2146f8` 当前值，不是看 watchpoint 是否命中**——watchpoint 没命中只代表 LLDB 捕获窗口内没捕获到 store，不构成"slot 未被写"的直接证据。

## 与 HOK-011 静态结论的交叉校验

HOK-011 离线结论：`0x10e2146f8` 的唯一 store 是 `0x103a29f7c`（在函数 `0x103a29b7c` 内），该函数的唯一 caller 是 `0x107e5df10`；NGR 自身 `__init_offsets` 反向 BFS 无法到达 `0x107e5df10`，因此 slot 的 prime 必须来自 NGR **外部**（embedded framework initializer / ObjC `+load` / 跨 dylib ctor）。这条结论仍然成立。

live run 与该结论的合法对齐形态：
- 走 SIGABRT 拦截路径在 `abort()` 上 stop 后，必须同时检查两项证据：
  - `memory read -s 8 -c 1 0x10e2146f8` 的当前值；
  - `breakpoint list` 里 `0x103a29b7c` / `0x107e5df10` 的 hit count。
- 组合语义：
  - slot=非零且 bp hit≥1 → HOK-011 的 writer 链 live 成立，按 H1/H2/H3 继续分流；
  - slot=非零但 bp hit=0 → writer 被走了但不经过 `0x103a29b7c`，复核 HOK-011 扫描器是否漏了别的 store 形式；
  - slot=0 → reader 读到 null 是由 dyld 零填导致，不再追 writer，走 HOK-013（让 PlayTools 在 runtime 预写/预热 slot）。
- backtrace 里出现 `0x103a29b7c` 或 `0x103a29fb0`（writer 所在函数及其偏移）等价于"writer 函数当时在栈上"，这是 live 上触达 writer 的直接证据之一，但它不替代 bp hit count 作为"调用次数"的判据。

## 脚本与工具链单一来源

- `Scripts/hok006_ngr_lldb_runner.py`：唯一的 CLI 入口，默认写 `build/hok-012-ngr-watchpoint-report.json` + `build/hok-012-ngr-dyld-initializers.log`；不要另起 shell 一步一步手动组 LLDB 命令。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：
  - `LLDBRunOptions`：`watchAddress` / `watchSize` / `preRunCommands` / `dyldInitializersLogPath` / `deferWatchpointInstall`；
  - `parseWatchpointHits`：把 transcript 里的多段 `stop reason = watchpoint …` 切成带 `oldValue`/`newValue`/`frame #0`/`backtrace` 的结构化 hit；
  - `parseLLDBEvidence`：watchpoint 模式下**优先挑选非 watchpoint stop 作为 fault 字段**，避免把 watchpoint stop 误当成崩溃。
- `PlayCover/Model/PlayApp.swift` / `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：
  - 两处 `minimalStartupCompatDiagnosticEnvironment` 必须保持同值；任何对 `DYLD_PRINT_INITIALIZERS` / `DYLD_PRINT_APIS` 的改动都要两侧对齐，否则 `launch_app` 与 `launch_app_with_lldb` 会写出不同环境的子进程 stderr。

## 参考

- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：H1/H2/H3 假设分类、反向 BFS 方法论。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：候选 E patch 的 apply/revert 口径。
- `Scripts/hok011_ngr_common_init_chain.py`：writer 扫描器；用 `--target-address` 推广到其他 `__common` 槽位。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/`：embedded framework 集合，watchpoint 命中后用于识别 writer 所属 image。
