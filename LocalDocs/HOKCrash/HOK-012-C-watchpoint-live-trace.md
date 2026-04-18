# HOK-012-C: 0x10e2146f8 watchpoint live-trace 方法论与证据口径

> 本文是 HOK-012-C 的**方法论沉淀**，不写任务状态/快照日期。任务状态以 Dashboard 为准。
> 任何"本轮结论/下一步/handoff/DONE"等字样不在本文出现；它们仅在 `LocalDocs/HOKCrash/00-Dashboard.md` 维护。
> 所有具体的 live 证据以结构化报告文件为单一来源：`build/hok-012-ngr-watchpoint-report.json`、`build/hok-012-ngr-dyld-initializers.log`、`build/hok-006-ngr-lldb-report.json`。

## 目的

承接 HOK-012-A/B 在 host/MCP/LLDB runner 三层就绪的 watchpoint 自动化，在安装了 `com.tencent.ngr` 的真实 PlayCover 环境上执行 live run，用结构化证据为 HOK-011 提出的 H1/H2/H3 假设挑选依据——或者证伪它们从而把候选 E patch 提升为长期方案。

## 口径：legacy baseline 与 watchpoint run 的角色分工

- **legacy baseline**：`python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install`，不传 `--watch-address`，MCP `launch_app_with_lldb` 走 HOK-006 的老路径。候选 E 仍处于 apply 状态时，此轮的意图是**确认 `0x10480df08` 原 faulting window 已被绕过、app 能跑过 index 1563**；若反而观察到 `faultingFrame = 0x10480df08` 重新出现，说明 patch 被外力回滚，必须先恢复 patch 状态再进入 watchpoint 轮。
- **watchpoint run**：`python3 Scripts/hok006_ngr_lldb_runner.py --watch-address 0x10e2146f8 --watch-size 8 --skip-build-install`，脚本会自动：
  - 把 `DYLD_PRINT_INITIALIZERS=1` 子进程 stderr 重定向到 `build/hok-012-ngr-dyld-initializers.log`；
  - 在 `run` 之前装好 `watchpoint set expression -s 8 -- 0x10e2146f8`；
  - 每次 watchpoint stop 后抓 backtrace 并 `continue`，允许同一轮累计多次命中；
  - 把结构化命中写入 `build/hok-012-ngr-watchpoint-report.json`，与 `build/hok-006-ngr-lldb-report.json.launch.lldb.watchpointHits` 同源。
- **两轮必须背靠背执行**：baseline 不稳定或候选 E 被回滚时，watchpoint run 的 0 hit 不能被解释为"slot 已被预初始化"。

## 证据口径：watchpoint run 的 5 种语义

| 证据形态 | 触发条件 | 语义 |
|---|---|---|
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 **NGR framework 内** | writer 是 embedded framework 的 C++ ctor / `+load` / framework init callback | H3（跨 dylib static ctor 链）或 H1（framework init 回调） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 **libobjc + `+load`** | writer 来自 ObjC `+load` | H2（ObjC 类挑选顺序差异） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 `0x103a29f7c`（NGR 自身 writer） | writer 函数本身被触达 | 说明 `__cxa_guard` first-initialization 分支在本轮被走到；结合 `__init_offsets` 可达性重新评估 HOK-011 |
| `watchpointHitCount == 0` + `didStop=true` 且 stop 指向下游 reader | watchpoint 装好前 slot 已被写，或 store 在 LLDB detach/attach 窗口外 | 考虑（1）early `DYLD_INSERT_LIBRARIES` 在 PlayTools 内先触 accessor，(2) 在 `target create` 之后 immediately `process launch --stop-at-entry` + watchpoint 再 `continue` 的顺序 |
| `watchpointHitCount == 0` + `didStop=false`（超时） | 进程根本没跑到 reader | 检查 `dyldInitializersLogPath` 文件大小与 PlayTools diag 是否写全；可能是 `posix_spawn` 再拉起导致子进程环境没继承 |

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
