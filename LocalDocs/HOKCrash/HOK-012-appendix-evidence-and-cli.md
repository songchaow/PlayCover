# HOK-012 附录：watchpoint 证据口径与 CLI 清单

> 本文是 `HOK-012-工具链与方法论归档.md` 的附录，沉淀 watchpoint run
> 的 6 种命中语义、标准 CLI、dyld log 对齐规则、secondary fault 解读。
>
> **何时读**：需要真正跑一轮 watchpoint live-trace、或需要解读 watchpoint
> 命中 / timeout / secondary fault 的证据归属时读；日常阅读 HOK-012 主文档
> 不必进入本文。

## 证据口径：watchpoint run 的 6 种语义

| 证据形态 | 触发条件 | 语义 |
|---|---|---|
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 NGR framework 内 | writer 是 embedded framework 的 C++ ctor / `+load` / framework init 回调 | H3（跨 dylib static ctor 链）或 H1（framework init 回调） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 `libobjc + +load` | writer 来自 ObjC `+load` | H2（ObjC 类挑选顺序差异） |
| `watchpointHitCount >= 1` + `hit.backtrace` 指向 `0x103a29f7c` | writer 函数本身被触达 | `__cxa_guard` first-init 分支被走到；复审 HOK-011 可达性 |
| `watchpointHitCount == 0` + pre-run 模式 + `didStop=true` 指向下游 reader | watchpoint 装好前 slot 已被写，或 store 在 LLDB detach/attach 窗口外 | 改走 deferred-install 模式 |
| `watchpointHitCount == 0` + deferred-install + `lldbStopObserved=False` | writer 函数在 LLDB 捕获窗口内未被调用（不代表 app 生命周期内未被调用，见对话框污染 gate） | 不要直接宣告 HOK-011 被证伪 |
| `watchpointHitCount == 0` + `didStop=false`（超时） | 进程根本没跑到 reader | 检查 dyld log 文件大小与 PlayTools diag 是否写全；可能 `posix_spawn` 子进程环境未继承 |

## 关键 CLI 清单

```
# legacy baseline
python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install

# pre-run watchpoint
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --skip-build-install

# deferred-install watchpoint
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --skip-build-install

# deferred-install + SIGABRT 拦截 + sheet modal 拦截（b.3 默认形态）
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --lldb-timeout 60 --settle-seconds 65 \
  --skip-build-install \
  --pre-run-command 'breakpoint set --name "-[NSApplication runModalForWindow:]"' \
  --pre-run-command 'breakpoint set --name "-[NSWindow orderFront:]"' \
  --pre-run-command 'breakpoint set --name CGSOrderWindow' \
  --output build/hok-012-c-3-b-3-report.json \
  --watchpoint-report build/hok-012-c-3-b-3-watchpoint.json \
  --dyld-log build/hok-012-c-3-b-3-dyld.log
```

## dyld log 交叉对齐规则

- `build/hok-012-ngr-dyld-initializers.log` 的时间戳与 `hits[i].backtrace`
  所在命中时刻的 `processIdentifier` 同属一个子进程（
  `process launch -e <path>` 重定向）。
- 对齐方法：
  1. 从 `build/hok-006-ngr-lldb-report.json` 读
     `launch.launchRequestedAt` 与 `launch.lldb.processIdentifier`。
  2. 在 dyld log 里 grep `NGR[<pid>:`，第一行即子进程 stderr 开始
     时间。
  3. watchpoint 命中的 wall clock 不直接出现在 transcript 里，但
     `backtrace` 里的系统层帧（`Foundation` / `libsystem_pthread.dylib`
     / `libobjc` / `dyld`）可唯一标识所处阶段（ObjC `+load` vs C++ ctor
     vs NSThread start）。
- 若 `dyldInitializersLog` 文件存在且 `initializerLineCount == 0`，
  但 ObjC 重复类警告已出现：说明 dyld 的 `initializer` 日志行格式
  在当前 macOS 版本变了；此时以 ObjC 重复类警告 + app 自研
  `[GPM] cpp constructor call` 等 log 作为"已进入 static init"的判据。

## 解读 "Thread #10 fault at address=0x30" 这类 secondary fault

watchpoint run 里若同时观察到：

- `faultingFrame` 指向 `___lldb_unnamed_symbol271xxx` 家族
  （`0x10478xxxx` / `0x10477xxxx` 区段，不在 HOK-007A 的 `0x10480df08`
  附近）；
- fault 发生在**非 #0 主线程**，backtrace 里有
  `Foundation.__NSThread__start__` / `libsystem_pthread.dylib._pthread_start`；
- dyld log 尾部已出现 `[UE4] Fatal error ... QtsFileSystem Create
  failed.` 或 `ICU data directory was not discovered`；

则属于 **HOK-010 / HOK-007C 方向的下游崩溃**，不是 `0x10e2146f8`
reader path 的原始 fault。HOK-012 的闭合判据仍是 `0x10e2146f8` 的
writer identity，不是"下游有无二次崩"。

## 与 HOK-011 静态结论的交叉校验

HOK-011 离线结论：`0x10e2146f8` 的唯一 store 是 `0x103a29f7c`（在函
数 `0x103a29b7c` 内），NGR 自身 `__init_offsets` 反向 BFS 不可达。这条
结论**骨干仍成立**；但 HOK-013 落地过程中**修正**了一点：真正的 writer
函数入口是 `0x103a29c60`（`0x103a29b7c` 是相邻的另一个 Logger dispatch
wrapper）。这个修正不影响"writer 不可达 NGR 自身 init_offsets"，但说明
`hok011_ngr_common_init_chain.py` 的 store-site 扫描要与函数 prologue
对齐，才能得到正确的函数入口。

live 组合语义（在 abort stop 上同时读 `memory read 0x10e2146f8` 与
`breakpoint list` 里 `0x103a29c60`/`0x107e5df10`/`0x107e5c964` 的 hit
count）：

- slot=非零 + 任一 bp hit>=1 → writer 链 live 成立，按 H1/H2/H3 分流；
- slot=非零 + 所有 bp hit=0 → writer 被走了但不经过这三个地址，复审
  `hok011_ngr_common_init_chain.py` 是否漏了别的 store 形式；
- slot=0 → 进入 HOK-013（PlayTools 侧预写 slot）。HOK-013 落地之后这
  条路径已关闭。
