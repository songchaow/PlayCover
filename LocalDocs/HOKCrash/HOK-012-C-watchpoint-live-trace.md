# HOK-012-C: 0x10e2146f8 watchpoint live-trace 方法论与证据口径

> 本文是 HOK-012-C 的**方法论沉淀**，不写任务状态/快照日期。任务状态以 Dashboard 为准。
> 任何"本轮结论/下一步/handoff/DONE"等字样不在本文出现；它们仅在 `LocalDocs/HOKCrash/00-Dashboard.md` 维护。
> 所有具体的 live 证据以结构化报告文件为单一来源：`build/hok-012-ngr-watchpoint-report.json`、`build/hok-012-ngr-dyld-initializers.log`、`build/hok-006-ngr-lldb-report.json`。

## 目的

承接 HOK-012-A/B 在 host/MCP/LLDB runner 三层就绪的 watchpoint 自动化，在安装了 `com.tencent.ngr` 的真实 PlayCover 环境上执行 live run，用结构化证据为 HOK-011 提出的 H1/H2/H3 假设挑选依据——或者证伪它们从而把候选 E patch 提升为长期方案。

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
| **`watchpointHitCount == 0` + deferred-install 模式 + `--writer-address 0x103a29b7c`** + `lldbStopObserved=False`（bp 也未命中，transcript 里有 `Breakpoint 1: address = 0x103a29b7c` 但没有 `Breakpoint 1.*hit` 行） | writer 函数**在 LLDB 捕获窗口内**未被调用。判定它是否在 **app 真实生命周期** 内也没被调用，必须先把 `--lldb-timeout` 拉到覆盖 `NGR-*.ips` 里 `procLaunch → procExitAbsTime` 的完整时长（NGR 实测 ≈32s），再看 bp 是否命中。若完整 capture window 下仍 0 hit，才需要复核 HOK-011 的 "唯一 store 假设" | 先按"deferred-install 模式下 bp 未命中的正确读法"一节的 5 步推进，不要直接宣告 HOK-011 被证伪 |
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

# deferred-install 覆盖到 UE4 abort 现场（HOK-012-C.3-b.3 的默认命令，依赖 b.1 把 SIGABRT 拦截写进 defer-mode 的 preRunCommands）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --lldb-timeout 60 --settle-seconds 65 \
  --skip-build-install
# 注意：`--lldb-timeout` 是保守大值，不是"app 生命周期"。abort 被 LLDB 拦住
# 后，后续一切推进都发生在 LLDB stop 现场，不需要等用户点对话框；不拦
# SIGABRT 则 app 会被 Apple 崩溃对话框挂住 UI 线程、直到用户点击才真正退出。

# deferred-install 时显式关闭 writer 自动 bp（完全由 --pre-run-command 控制）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install --writer-address "" \
  --pre-run-command 'breakpoint set --shlib GCloudCore --name load -C "watchpoint set expression -s 8 -- 0x10e2146f8" -C "continue" --auto-continue true --one-shot true' \
  --skip-build-install
```

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
- dyld log 尾部已出现 `UE4 Fatal: QtsFileSystem Create failed.` 或 `ICU data directory was not discovered`；

则该 fault 属于 **HOK-010 方向的下游崩溃**（`QtsFileSystem` / `rootWorkDir` 分支触发的二级崩溃），**不能被当成 `0x10e2146f8` reader path 的原始 fault**。在这种情况下：
- watchpoint 没命中 ≠ slot 未被写；只能推断"本轮 writer 未落在 watchpoint 生效窗口之内"；
- 不应在 HOK-012 里处理这个 secondary fault，它属于 HOK-010 / HOK-007C 的领地；HOK-012 的闭合判据仍然是 `0x10e2146f8` 的 writer identity，与下游 fault 无关。

## 与 HOK-011 静态结论的交叉校验

HOK-011 离线证明 NGR 自身 `__init_offsets` **无法**到达 writer `0x103a29f7c`。live run 若观察到：
- `backtraceHead` 里出现 **`0x103a29b7c` 或 `0x103a29fb0`**（writer 所在函数及其偏移）但 watchpoint 未命中：
  - 解释 A：accessor 走 `__cxa_guard` 已初始化分支（slot 已被更早 store，不落入本次 watchpoint 窗口）；
  - 解释 B：watchpoint 在 `target create` 之后设置，但 `process launch --stop-at-entry` 时机与 dyld 对该 slot 的预写存在 race；
- 不论 A/B，都**不构成对 HOK-011 的反例**——静态可达性结论是"NGR 自身 `__init_offsets` 不可达"，没有说 writer 函数本身不会被任何其他路径触达。

## 脚本与工具链单一来源

- `Scripts/hok006_ngr_lldb_runner.py`：唯一的 CLI 入口，默认写 `build/hok-012-ngr-watchpoint-report.json` + `build/hok-012-ngr-dyld-initializers.log`；不要另起 shell 一步一步手动组 LLDB 命令。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：
  - `LLDBRunOptions`：`watchAddress` / `watchSize` / `preRunCommands` / `dyldInitializersLogPath`；
  - `parseWatchpointHits`：把 transcript 里的多段 `stop reason = watchpoint …` 切成带 `oldValue`/`newValue`/`frame #0`/`backtrace` 的结构化 hit；
  - `parseLLDBEvidence`：watchpoint 模式下**优先挑选非 watchpoint stop 作为 fault 字段**，避免把 watchpoint stop 误当成崩溃。
- `PlayCover/Model/PlayApp.swift` / `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：
  - 两处 `minimalStartupCompatDiagnosticEnvironment` 必须保持同值；任何对 `DYLD_PRINT_INITIALIZERS` / `DYLD_PRINT_APIS` 的改动都要两侧对齐，否则 `launch_app` 与 `launch_app_with_lldb` 会写出不同环境的子进程 stderr。

## 参考

- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：H1/H2/H3 假设分类、反向 BFS 方法论。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：候选 E patch 的 apply/revert 口径。
- `Scripts/hok011_ngr_common_init_chain.py`：writer 扫描器；用 `--target-address` 推广到其他 `__common` 槽位。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/`：embedded framework 集合，watchpoint 命中后用于识别 writer 所属 image。
