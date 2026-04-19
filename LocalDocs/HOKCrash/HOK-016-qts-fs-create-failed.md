# HOK-016：消除 `com.tencent.ngr` 启动期 `QtsFileSystem Create Failed!!` 僵尸态

> 本文只沉淀 HOK-016 的**设计依据、静态结论、LLDB 证据、已知真因定位**。
> 任务状态以 `LocalDocs/HOKCrash/00-Dashboard.md` 为准；本文不出现
> "DONE / TODO / 已落地 / 下一步" 等字样，也不写日期快照。

## 目的

HOK-015 `FCommandLine` preseed 落地（`bInitializedAfter=1` /
`cmdlinePreview="../../../NGR/NGR.uproject"` / `slide=0x44f0000`，`launch-events.jsonl`
已稳定观测 `hok015_ngr_cmdline_preseed status=primed`）之后，
`com.tencent.ngr` 进程不再秒崩，但 **UE4 GameThread 并没有真正进入主循
环**：`%CPU` 峰值到 ~59% 之后迅速掉到 0.2% 以下、RSS 停在 ≈332MB、线程
数 11、主窗口在屏幕外、`launch-events.jsonl` 仍稳定出现 1 条
`hok014_ngr_alert_suppressed title="Message" message="QtsFileSystem Create Failed!!"`。

HOK-016 的目标是 **定位并消除** 这条 `QtsFileSystem Create Failed!!` 路径
的根因，让 `hok014_ngr_alert_suppressed` 事件归零、进程真正活着（
`%CPU ≥ 5%` 持续 ≥ 30s、RSS ≥ 800MB、线程 ≥ 20、主窗口与主屏有非空交集）。
Dashboard 定义的硬约束依旧：**bundle-scoped、PlayTools 层、不动 NGR 二
进制、失败时无副作用**。

## 证据归纳（静态 + LLDB 双源交叉）

### 字符串家族（HOK-016-A / `Scripts/hok016_ngr_qts_locator.py`）

NGR 主 image `__TEXT,__ustring` 里，`QtsFileSystem` 前缀共 **3 条
UTF-16-LE TCHAR 字面量**，每一条都有 **恰好 1 条 ADRP+ADD xref**：

| value | 字符串 vmaddr | 唯一 xref |
|---|---|---|
| `QtsFileSystem init Failed!!` | `0x10c09d00a` | `0x108879248` |
| `QtsFileSystem Create Failed!!` | `0x10c09d070` | `0x1088792d4` |
| `QtsFileSystem Create failed.` | `0x10c09d0ac` | `0x10432f4b0` |

前两个 xref（`0x108879248` 和 `0x1088792d4`）**同属一个函数**
`0x108879164`（`___lldb_unnamed_symbol1166747`，walk-back 同时匹配
`stp`-prologue anchor 和 两个 marker 的 xref）。第三条 xref
`0x10432f4b0` 属于另一个函数 `0x10432f490`（`___lldb_unnamed_symbol258694`），
是独立业务路径。

离线分析脚本 `Scripts/hok016_ngr_qts_locator.py`：零副作用、复用
HOK-015 的 Mach-O parser 与 ARM64 decoder、支持 ASCII + UTF-16-LE 双编
码扫描、支持 family prefix 参数化（默认 `QtsFileSystem`）、输出
`build/hok-016-qts-fs-static.json`。

### LLDB 反汇编：reporter 函数 `0x108879164` 的分支结构

reporter 是一个**虚函数**，由 Meyers-singleton accessor `0x103a29b7c` 的
第二次 `vtable[0x30]` 调用进入。关键分支：

```
+144 bl  0x107c0ab8c                    ; 返回 w0 = "parse option 成功/失败"
+148 tbz w0, #0, +224                   ; w0==0 → "QtsFileSystem init Failed!!"
…
+172 mov x0, x19                        ; this
+176 bl  0x108877bd0                    ; returns w0 = "Create 成功/失败"
+180 tbz w0, #0, +364                   ; w0==0 → "QtsFileSystem Create Failed!!"
…
+224 adrp+add x1, 0x10c09d00a  → "QtsFileSystem init Failed!!"
…
+364 adrp+add x1, 0x10c09d070  → "QtsFileSystem Create Failed!!"
+420 bl  0x10432f490                    ; ← 就是第三条 "Create failed." 的调用者
```

即 **`0x108877bd0` 决定了 "Create Failed" 是否触发**。它是一个大函数（`sub sp,sp,#0x220` = 544 字节栈），语义推测为 "**QtsFileSystem 的资源根目录/VFS 可用性初始化**"，典型动作是 FString 构造（+56/+128/+140）、manager 查询（+160）、虚函数分派（+204）。

### LLDB 运行期 backtrace（HOK-016-B / `Scripts/hok016_ngr_qts_reporter_trace.py`）

以 `--shlib NGR --address <unslid>` 格式对 reporter 入口 + 家族三条 xref
设 breakpoint（**绝对 VA 格式 `breakpoint set --address` 由于 ASLR slide
会 mismatch、命中 0 次；module-relative 格式命中稳定 — 已验证**），抓取
命中瞬间的 `thread backtrace` + `register read x0..x8`：

完整调用链（**非主线程**、典型 NSThread workder #17/#19/#21）：

```
frame #0: 0x108879164 NGR`vtable[0x30] reporter              ; QtsFS log/factory
frame #1: 0x103a29bec NGR`MeyersSingleton + 112              ; vtable[0x30] blr 返回点
frame #2: 0x107e5df4c NGR`FactoryRegister + 60               ; 2 次 singleton 访问, HOK-011 记录的唯一 caller
frame #3: 0x103a29fa0 NGR`QtsFileSystem_Init + 832           ; writes __common slot 0x10e2146f8（HOK-013 关心的真 writer）
frame #4: 0x107e5c970 NGR`QtsFS_InitWrapper + 12             ; 调用 frame 3, cbnz w0 走 fatal path
frame #5: 0x103a227d0 NGR`MessagingInit + 44                 ; FCommandLine::Get inline guard 命中后传 CmdLine 给 frame 4
frame #6: 0x104a04d38 NGR`NSThreadWorker + 164
frame #7: Foundation`__NSThread__start__ + 732
frame #8: libsystem_pthread.dylib`_pthread_start + 136
```

#### 参数语义

reporter 命中时的寄存器（多次观察一致）：

| reg | value | 语义 |
|---|---|---|
| `x0` | `0x141915450` / `0x1396bd4f0` | `this`（QtsFS 实例，每次 launch 不同 slide） |
| `x1` | `0x10e2005f0` | log category / logger 指针（NGR `__common`） |
| **`x2`** | **`0x10e20107a`** | **= HOK-015 preseeded `FCommandLine::CmdLine` buffer**（低 28 位严格匹配，`x2Interpretation = "x2 is a pointer into FCommandLine::CmdLine"`） |
| `x3` | `0x0b` / `0x35` | TCHAR 长度 / flags（随 run 变化） |
| `x4` | heap ptr | format message 临时缓冲 |
| `x19` / `x26` | `0x10e20107a` | 同 x2，被 callee-saved 寄存器 mirror |
| `x20` | `0x10e2005f0` | 同 x1 |
| `x22` | `0x10e1fc8e8` | Meyers singleton guard 区 |

**结论**：reporter 把 CmdLine buffer 作为第 3 个参数接收。即这条 UE_LOG
把 cmdline 当 `%s` context 打印；**但 QtsFS 的失败**并不直接由 cmdline
决定——它由 frame 3 里 **HOK-011 的 writer `0x103a29f7c: str x0, [x8, #0x6f8]`** 之后 `+812 bl 0x1047aa8d0` 的返回值决定（进入 reporter vtable 之前），以及 reporter 内部 `+176 bl 0x108877bd0` 的返回值决定。

### 与 HOK-013 的 slot writer 关系

frame 3 `0x103a29c60 +796` 的指令 `str x0, [x8, #0x6f8]` **正是 HOK-011
全二进制扫描找到的唯一 writer**，目标 slot `0x10e2146f8`。这意味着：

- 当 NGR 实际走到 frame 3 这条路径时，HOK-013 预置的 stub 会**被真 writer 覆盖**（`slotBefore` 可能不再是 `0x0`）。
- HOK-013 的主要价值是**防卫** — 在 frame 3 还没被触发之前，所有 reader（其中也包括 HOK-007B 候选 E 阻止的那条 early reader）读到的都是 stub object 而非 null。
- frame 3 被触发时 `bInitialized=1`（HOK-015 已预置），`FCommandLine::Get()` 的 218 条 inline guard 都 fall-through 到 normal path，这是 HOK-016 的必要前提。

## 运行期工具链

### `Scripts/hok016_ngr_qts_locator.py`

静态定位器。复用 HOK-015 locator 的 Mach-O parser + ARM64 decoder；新增
能力：

1. 同时扫 `__cstring`（ASCII）与 `__ustring`（UTF-16-LE）两个 section；
2. 通过 primary marker 的 xref 走回 function prologue；
3. 枚举 family prefix 下的所有字符串并给出每条的 adrp+add xref；
4. dump reporter 入口的前 N 条指令（人读的 mnemonic hint）到 JSON。

产物：`build/hok-016-qts-fs-static.json`。

### `Scripts/hok016_ngr_qts_reporter_trace.py`

LLDB 运行期 backtrace/register 捕获器。wrapper 调用
`Scripts/hok006_ngr_lldb_runner.py`：

1. 从 `build/hok-016-qts-fs-static.json` 读取 reporter 入口 + 家族 xref 地址；
2. 生成 `breakpoint set --shlib NGR --address <unslid> -C 'thread backtrace' -C 'register read x0..x8'` 命令（**必须 `--shlib NGR`**；绝对 VA 在 ASLR 下不命中，已验证）；
3. 跑 `hok006` runner 拿 15s `lldb-timeout`；
4. 解析 transcript 抽出每次 BP hit 的线程 / 寄存器，并与 `build/hok-015-cmdline-slots.json` 做 x1/x2 低 28 位交叉比对（标注是否为 FCommandLine::CmdLine / bInitialized 指针）。

产物：`build/hok-016-qts-reporter-lldb.json`（hok006 runner 原始输出，
legacy schema）+ `build/hok-016-qts-reporter-summary.json`（HOK-016-B 专
属 summary，含 `checks.overallPass` 判定）。

### `Scripts/hok016c_ngr_qts_w0_trace.py`

HOK-016-C.1 的最小 runner。封装 `hok006` runner，在 `0x108877bd0` 的两条
`tbz w0, #0, <fail>` 判定点前设 auto-continue BP 抓 `register read x0`，
在失败 sink 设 hard-stop BP 终结 run。BP 地址完全由 HOK-016-A/B 定位
固化；**不动 NGR 二进制、不改 PlayTools 代码**。产物
`build/hok-016c-w0-trace.json`。

### `Scripts/hok016c2_ngr_sentinel_writer_scan.py`

HOK-016-C.2.2 离线全 `__text` 段扫描器。复用 HOK-015/016 的 Mach-O
parser + ARM64 decoder；新增能力：

1. 原生 ARM64 定长 32-bit decode（4 字节步长遍历整个 NGR 主 __text 段，
   169MB 仅 2s 完成），**不依赖 llvm-objdump**；
2. 覆盖 `str` / `strb` / `strh` / `str.w`（32-bit GPR store）四种"写
   入某个全局 byte/short/word" 模式——HOK-011 原脚本只扫 `str`，漏
   掉 byte-level sentinel 的 writer；
3. 跟踪 `adrp+add`/`adrp`/`mov reg`/`add` 链的 per-register
   abstract state（不限 basic block），任意 writer 命中都附最近的
   函数 prologue walk-back（复用 HOK-016 的 `find_function_entry`）。

产物：`build/hok-016c2-sentinel-writer-full-text.json`。当前对
`0x10e1eeef0` 命中 **0 writer**——与运行期 probe 一起证实 "sentinel
未 bump" 假设被彻底推翻。

### `Scripts/hok016c2_lldb_sentinel_watch.py`

LLDB Python helper，供 HOK-016-C.2 系列 driver `command script import`。
提供两个 BP callback：

- `probe_sentinel_on_hit(frame, bp_loc, internal_dict)`：读 NGR main
  image 的 runtime slide → `ReadMemory(0x10e1eeef0 + slide, 1)` → 把
  byte 值 + ±8-byte window 打印到 transcript 为 `[hok016c2]
  sentinel @ <addr> = 0xNN ...`，driver 可用 regex 抓。auto-continue。
- `install_watchpoint_on_hit(frame, bp_loc, internal_dict)`：
  `target.WatchAddress(sent_addr, 1, read=False, write=True)` 装 1
  byte modify watchpoint。one-shot。

**无 PlayTools / NGR 改动**——纯 LLDB 动态 probing。

### `Scripts/hok016c2_ngr_sentinel_probe.py`

HOK-016-C.2.2 driver。在 HOK-016-C.1 的 3 个 BP（+900 / +912 /
+1364）各挂一个 `probe_sentinel_on_hit` Python callback（`--mode
probe`）；`--mode watchpoint` 则额外在 NGR `main` 入口
（unslid `0x107e5cad4`）挂 `install_watchpoint_on_hit`，arm 一个
sentinel modify watchpoint 以捕获之后的任何 writer。产物
`build/hok-016c2-sentinel-probe.json` / `build/hok-016c2-sentinel-watch.json`。

踩坑：fail-sink BP 的 `breakpoint command add -s python -F ...` 会
**替换**原 `-C '...'` shell callback list，丢失 `thread backtrace` /
`register read` 输出。因此 fail-sink BP 不挂 Python probe（让 +912
probe 那一次命中去拿 sentinel 就够了）。

### `Scripts/hok016c2_ngr_step_into_readinessB.py`

HOK-016-C.2.3 driver。在 `0x108878534 +352 bl 0x10432dd98` 前、
后、`0x10432dd98` 入口、以及 `0x108877bd0 +912 tbz` 和
`0x108878124 +1364` 失败 sink 上各挂 shell `-C 'register read ...'`
callback（全部 auto-continue 除 fail sink）。

用这一套三连 BP 证明：
1. `bl 0x10432dd98` 被命中（Dashboard 原"0 hits"判断为误读）；
2. 它输出 `w0 = 0` → `0x108878534 +360 tbz w0,#0` 进入 error path；
3. `0x108878534` 从 error path 最终返回 0 → reporter 进入 Create
   Failed。

产物 `build/hok-016c2-step-into-readinessB.json`。

### `Scripts/hok016cx_lldb_cmdline_override.py` + `Scripts/hok016cx_ngr_seed_experiment.py`

HOK-016-C.X.1 seed 替换实验。**不改任何代码**（不动 NGR、不动
PlayTools），完全在 LLDB Python callback 里动态改写
`FCommandLine::CmdLine` UTF-16-LE buffer 为候选值，然后观察
`0x108877bd0` 的 `+912 tbz` 前 w0 是否翻转为 1。

- `hok016cx_lldb_cmdline_override.py`：LLDB Python 模块；
  `rewrite_cmdline_on_hit` BP 回调 runtime 解析 NGR image slide、
  `process.WriteMemory` 写 seed UTF-16-LE + 2-byte null terminator 到
  `0x10e20107a`、并重置 `bInitialized=1 @ 0x10e201078`（幂等防御）。
- `hok016cx_ngr_seed_experiment.py`：实验 driver；4 候选 seed 顺序跑
  （`empty` / `project` = `"NGR"` / `ue4cmdfile` = `"../../../NGR/ue4commandline.txt"` /
  `uproject` = baseline `"../../../NGR/NGR.uproject"`），每个 seed
  单独跑一轮 hok006 runner、抓 `w0@+900` / `w0@+912` / UE4
  "Project file not found" 计数 / failure sink 计数，汇总到
  `build/hok-016cx-summary.json`。

关键 LLDB 语法踩坑：`breakpoint set` **不支持** `--script-type python
-F <func>` 形式（会报 `unknown or ambiguous option`）；必须拆成两
步 —— 先 `breakpoint set ...`，紧接 `breakpoint command add -s python
-F <func>`（默认对最后创建的 BP 操作，两条命令之间不能插入其它
`breakpoint set`）。

#### 实验结果（证伪 "HOK-015 seed 驱动 QtsFS 失败"）

| seed | UE4 "Project file not found" | w0@+900 | w0@+912 | failSink 命中次数 |
|---|---|---|---|---|
| `empty`      | 0 | 0x1 | **0x0** | 3 |
| `project`    | 0 | 0x1 | **0x0** | 3 |
| `ue4cmdfile` | 0 | 0x1 | **0x0** | 3 |
| `uproject`   | 1 | 0x1 | **0x0** | 3 |

关键观察：

1. **所有 4 种 seed 下 `w0@+912 = 0`**——`0x108878534` 返回 0 与
   cmdline 内容**无关**。
2. `empty` / `project` / `ue4cmdfile` 三种 seed 确实消除了 UE4 的
   `[UE4] Project file not found` log，但这**不影响** QtsFS 的失败
   路径。
3. QtsFS 的 Create Failed sink 在全部 4 种 seed 下各触发 3 次，分布
   无变化。

结论：HOK-016-C.X（换 HOK-015 seed value）**已被证伪**。下一步必须进
入 `0x108878534` 的内部深度分析（HOK-016-C.2）。

跨 run 稳定观察（transcript 采集到的关键片段）：

1. UE4 自身 stderr：`[UE4] Project file not found: ../../../NGR/NGR.uproject`
2. `(lldb)  register read x0` → `x0 = 0x0000000000000001`  ← `+900 tbz` 前：readiness A (`0x108876a94`) 返回 **1 / ok**
3. `(lldb)  register read x0` → `x0 = 0x0000000000000000`  ← `+912 tbz` 前：readiness B (`0x108878534`) 返回 **0 / fail**
4. `stop reason = breakpoint 3.1` @ `0x108878124` (+1364 failure sink)
   backtrace 与 HOK-016-B 完全一致；`x19` = QtsFS `this`、
   `x24` = `0x10e1ee000`（QtsFS 全局 subsystem readiness 表基址，
   `x24->0xef0` 是 sentinel byte）。

## 已知真因判定

- **HOK-015 seed 内容与 `0x108878534` 的返回值无关**（HOK-016-C.X.1
  已证伪）：`empty` / `project` / `ue4cmdfile` / `uproject` 4 种 seed
  下 `0x108877bd0 +912 tbz` 前 w0 **恒等于 0**，failure sink 命中
  次数恒等于 3。换 seed 能消除 UE4 `[UE4] Project file not found`
  log，但 QtsFS 的 Create Failed 路径不变。
- **reporter 的 x2 参数是 CmdLine buffer**（HOK-016-B 寄存器跨 run 稳
  定）——但这条字符串是 UE_LOG 的 format context，并不是
  `0x108877bd0` 的判定输入本身。Create Failed 的**直接根因**是
  `+908 bl 0x108878534; +912 tbz w0, #0, +1364` 里 **`0x108878534`
  返回 0**。
- **`0x108878534` 是 "QtsFileSystem readiness check B"**——入口 544 字
  节栈、`adrp x22, 22902; ldrb w8, [x22, #0xef0]` 读 subsystem
  readiness sentinel、`+352 bl 0x10432dd98` 做更深层的路径/资源比对。
  **函数实际范围只有 0x108878534..0x1088786ec（≈440 字节）**，不是
  Dashboard 早期估计的 544+。epilogue 在 `0x1088786d4 ldp x29,x30 /
  0x1088786e8 ret`。
- **"readiness A 成功 / readiness B 失败" 的分布跨 run 稳定**：HOK-016-C.1
  / C.X.1 transcript 里 `+900 tbz` 之前 `x0=0x1`、`+912 tbz` 之前
  `x0=0x0`。排除了"偶然性资源竞争"假设，指向**确定性的资源/数据布局
  问题**。

### HOK-016-C.2 新证据（sentinel 假设被证伪）

`Scripts/hok016c2_ngr_sentinel_probe.py --mode probe` 的实验在 reporter
调用链命中的 NSThread worker 线程上直接探测：

- **`0x10e1eeef0` 运行期值 = `0x05`**（非 BSS 初值 `0x00`，也非 Dashboard
  先前推测的 "macOS 下未 bump"）；window
  `[0x10e1eeee8..0x10e1eeef8] = 00 00 00 00 00 00 00 00  05 00 05 07 a7 e8 01 00`。
- `0x108878534 +48 ldrb w8, [x22, #0xef0]; +52 cmp w8, #0x4; +56 b.lo
  +8` 的 b.lo 因 `w8 = 5 >= 4` **不跳**，继续执行 `bl 0x104331a90`；
  `0x108877bd0 +1364 ldrb w8, [x24, #0xef0]; cmp w8, #0x2` 同样
  `w8 = 5 != 2`，也**不走** sentinel-based branch。
- 换言之 **sentinel 已经被写到 >= 4**；"macOS 下 sentinel 未 bump" 假设
  被直接推翻。iOS 与 macOS 在此 byte 上**没有差异**。
- **全 `__text` writer 扫描**（`Scripts/hok016c2_ngr_sentinel_writer_scan.py`，
  169MB）对 `0x10e1eeef0` 找到 **0 个 `adrp+add/str/strb/strh/strw`
  写入点**，与上一点互证：writer 要么用非常规模式（literal pool load
  等，罕见），要么 writer 在 NGR 加载的 framework 里（本扫描只扫 NGR
  主二进制）。**无论哪种，不再是治本方向**——sentinel 不是失败因。

结论：**HOK-016 Create Failed 的直接根因从"sentinel < required level" 修
正为"`0x108878534` 内部某个非-sentinel 分支返回 w0=0"。**

### HOK-016-C.2.3：`0x108878534` 内部 step-into 证据

`Scripts/hok016c2_ngr_step_into_readinessB.py` 在 `0x108878534` 的
`+352 bl 0x10432dd98` 前、后、以及 `0x10432dd98` 入口各设探针 BP，
稳定观察到：

- `+352` before bl：`x0=0x12148dc90, x1=0x1, x2=0x1708c64d8,
  x3=0x1708c64c8, x22=0x10e1ee000` —— 4 参数调用、x22 仍是 `__common`
  段基址（callee-saved）。
- **`0x10432dd98` entry：同样的 4 个寄存器值被命中**——与 Dashboard 先
  前"`0x10432dd98` BP 0 次命中"的陈述直接冲突。**Dashboard 原判定是
  误读**（HOK-016-C.1 的 BP 当时可能没用 `--shlib NGR --address`
  module-relative 格式），实际 `bl 0x10432dd98` 被稳定 call 到。
- `+356` after bl：`x0 = 0x0` —— `0x10432dd98` **返回 0**，这正是
  `0x108878534` 内部 `+360 tbz w0, #0, +84 → 0x1088786f0` 的判定输
  入；w0=0 → 走 error path → `mov x0, x20 = 0` → `0x108878534` 返
  回 0 → reporter `+912 tbz w0, #0, +1364` 进入 Create Failed。

**`0x10432dd98` 的语义**（静态分析）：

- 入口做 `FString::Printf("%d", …)` 构造一个数字字符串到 `sp+0x38`
  （`bl 0x10473a3d4`，参数 `adrp x0,<%d@0x10c09b392>`）；
- 然后执行若干 FString 构造 + 两次 Qtsk allocator 类调用
  (`bl 0x10432b734` / `bl 0x104826068`) + 一个 vtable 派发
  (`ldr x8,[x19,#0x60]; blr [x8+0x190]`);
- 最终 `+412 bl 0x10017f3c8(w0=[sp+0x14], w1=1, w2=0)`，其返回值
  经 `tbz w0,#0, error_path` 决定本函数的返回 (w19=1 = 成功 /
  w19=0 = 失败)。

`0x10017f3c8` 进入 `ChunkAllocator<Qtsk::STGlobalMemData,false,false>`
合并符号内（strip 后所有 `Qtsk::STGlobalMemData` 系 helper 都归进
这个符号名 `_FinalClean`，实际是**多组互独立**的函数，符号表边界
至 `___cxa_throw` 之前；仅按地址聚合，不是真的都来自 `_FinalClean`）。
其入口做 `adrp x8, 0x10e184000; ldr x0, [x8, #0x9f0]` 然后
`bl 0x1001ac168` 填充 stack 结构 `sp+0x60`，再 `cbz x8, fail_slot_1
(return w19=0)`、`bl 0x1001cd114(x0=@0x10e184b18, x1=x8+0x10, w2=1)`
后 `cbz x0, fail_slot_2 (return w19=0)`。也就是说**`0x10017f3c8`
本身也是一条 lookup + acquire pattern**，macOS 下在 `bl 0x1001ac168`
或 `bl 0x1001cd114` 之一的返回值上就已经失败——**这条假设在
HOK-016-C.2.4 中被修正：`0x10017f3c8` 实际上在当前 run 中不可达；
真正被调用并返回 0 的是 `0x10017f184`**。见下一节。

### HOK-016-C.2.4：真正的失败决定点是 `0x10017f184`，不是 `0x10017f3c8`

`Scripts/hok016c24_ngr_readinessB_inner_args.py` +
`Scripts/hok016c24_lldb_inner_probes.py` 分三轮实验（v2 / v3 /
v4-5）给 `0x10432dd98` 全函数装 ~30 个 Python callback BP，**把"到
底从哪条 early-exit 返回 0"彻底钉死**。

#### 完整控制流（跨 run 稳定）

```
0x10432dd98 entry
  x0 = this (QtsFS instance)
  x1 = 0x1 (mode)
  x2 = FString*("../../../NGR/Content/paks")      ← cooked 资源相对路径
  x3 = FString*("/Users/songdogwang/Library/NGR/Saved/Paks")  ← 容器内绝对路径

+0x00..0x40  FString::Printf("%d", x1=1)  →  sp+0x38 内 FString = "1"

+0x48..0x54  ldr w22, [sp,#0x40] (=2, FString "1" 的 Num incl. NUL)
             ldr w8,  [0x10f0df000 + 0xc08] (=2, "decision" global)
             cmp w22, w8  →  EQ  →  b.eq 0x10432df8c

+0x1F8 (0x10432df8c): 进入 alt-path
  cmp w22, #0x2 (=2) → NOT lt → fallthrough
  ldr x0, [sp+0x38] (= Printf 出的 FString data ptr)
  ldr x1, [0x10f0df000 + 0xc00] (=另一个 global)
  bl  0x1047482ac(x0=printf_str, x1=global_c00)  →  w0
  cbnz w0, 0x10432ddfc                           →  看 w0
    ↓ (w0 == 0 的实际观察情形；实测 w0 非零也会回到 de10)
  b   0x10432de10

+0x78..0xF8 (0x10432de10..de88): 两次 FString 包装 +
             两次 bl 0x104826068 (某个 TMap/TSet 插入或查找)

+0x11C 第一次 vtable blr  (x8 @ [x19+0x60] -> +0xf8)  →  x21 = return (=0x1)
+0x13C 第二次 vtable blr  (相同 vtable -> +0xf8)      →  x20 = return (=0x0)
+0x14C bl  0x104329c18  (构造 uint key)               →  w1 stored to [sp+0x14]
+0x154 cbnz w21, 0x10432dfac                          ←  w21=1 → jump dfac

+0x214 (0x10432dfac): cbz w20, 0x10432e06c            ←  w20=0 → jump e06c

+0x2D4 (0x10432e06c):
  mov x0, x1 (=0 here, see v4 probe at 10432e06c)
  bl 0x10017f184(x0=0)                               ←  核心 lookup 调用
  tbnz w0, #0, 0x10432dfbc                           ←  实测 bit0=0 → fallthrough

+0x2E0..0x2FC: ldr x0, [x19+0x60]; ldr x8,[x0]; blr [x8+0x190]
             再次 vtable 派发 (logging / classifier)
+0x2F8 ldrb sentinel; cmp #2; b.lo 0x10432e058 (不跳，因为 sentinel=5)
+0x30C bl  0x10432e194 (logging)
+0x310 b   0x10432e058

+0x2C0 (0x10432e058): mov w19, #0x0                   ←  **FAIL_EXIT_A 就地**
+0x2C4 b   0x10432df38 → epilogue → return 0
```

#### `0x10017f184` 内部（与 `0x10017f3c8` 同构但目标不同）

```
0x10017f184 entry
  x0 = key (int)  ; v4 实测 x0 = 0
  mov x1, x0     ; save as int-key for later lookup

+0x30   adrp x8, 0x10e184000; ldr x0, [x8, #0x9f0]   ; rootA
        add  x8, sp, #0x20                            ; out slot
+0x38   bl   0x1001ac168(x0=rootA, x1=key=0, x8=out)
+0x3C   ldr  x8, [sp, #0x20]                          ; entry ptr
+0x40   cbz  x8, 0x10017f2f0                          ; lookup A miss → fail_slot_1

+0x44..0x50 add x1, x8, #0x10   ; x1 = entry+0x10 = PascalString header
           adrp x0, 0x10e184000; add x0, x0, #0xb18 ; rootB = 0x10e184b18
           mov  w2, #0x1
+0x54   bl   0x1001cd114(x0=rootB, x1=entry+0x10, w2=1)
+0x58   mov  x19, x0                                  ; return value
+0x5C   cbz  x0, 0x10017f2bc                          ; lookup B miss → fail_slot_2
```

#### `entry+0x10` 的真实结构（PascalString，**不是 FString**）

v4-5 run 在 `0x10017f1d8` 抓的 hex48：

```
entry+0x10 hex: 04 00 00 00 00 00 00 00 | 6d 61 69 6e 00 00 00 00 | ...
                length=4                 | 'm' 'a' 'i' 'n' \0\0\0\0
entry+0x20 hex: 01 00 00 00 00 00 00 00 | 31 00 00 00 00 00 00 00
                length=1                 | '1'  \0\0\0\0\0\0\0
entry+0x30 hex: 01 01 00 00 00 00 00 00 ; flags?
```

也就是说 entry 里记着 **name = "main"**，**chunk signature = "1"**。
HOK-016-C.2.4 前的假设"x1 指向 FString" 是错的——它是一个在线
PascalString (`[length: u64][chars: N][padding]`) 结构，被 lookup B
当作字符串 key 使用。

#### rootB 状态与失败直接原因

v5 run `f184_before_bl2` 抓的 `rootB_hdr` (32 bytes @ `0x10e184b18`)：

```
10 3e 33 16 01 00 00 00 | 10 3e 33 16 01 00 00 00 |
01 00 00 00 00 00 00 00 | 00 00 00 00 00 00 00 00
```

解读：`*rootB = 0x116333e10`，`*(rootB+0x8) = 0x116333e10`（自指
sentinel），`count = 0x01`。典型的**空红黑树 sentinel 自指**结构，
count=1 通常是 nil-node 本身被计入容量或 sentinel reservation。
**运行期观察到的 bl 0x1001cd114 调用 v5 的 x0(rootB)=`0x10e184b18`**
（与静态分析一致），该容器在 lookup 到 key "main" 时**返回 0
（lookup B miss）**。

#### HOK-016-C.2.4 收尾结论

- 真因**不在** `0x10017f3c8`：`probe_inner_entry` / 其 7 个 BP 在 v3/
  v4/v5 run **0 次命中**，说明整条 HOK-016-C.2.3 里"bl 0x10432dd98 内
  部 `+412 bl 0x10017f3c8`" 路径实际上是**死代码**（该路径要求
  `0x10432df0c cbz w20, 0x10432df34` 走 success 或 `0x10432df18 bl
  0x10017faa0` 返回非零 → 跳 dfec → 再经 `b.lo sentinel` 路径返回
  success；两条都不是当前 run 的实际走向）。
- 真因**就在** `0x10017f184`：它和 `0x10017f3c8` 共享同一个 lookup
  模板（adrp → ldr root → bl 0x1001ac168 → cbz → bl 0x1001cd114 →
  cbz），但用的是 `sp+0x20` 而不是 `sp+0x60`，且入参是一个 int key
  = 0；`bl 0x1001ac168` 查 rootA 能找到 "main/1" 的 entry，但
  `bl 0x1001cd114` 拿 entry+0x10 的 PascalString "main" 去 rootB 查
  **查不到**（rootB 是一个 sentinel-self-loop 的空红黑树），于是返
  回 0。
- 这把 HOK-016-C.2.x 系列的 "readiness B 失败 = rootB 空" 的判定
  精确到了**具体 key = "main"**；**修复方向收敛为**：在
  `0x10017f184` 的 bl 0x1001cd114 **之前**让 rootB 里有 "main"
  PascalString entry，或直接拦截 `0x10017f184` / `0x10432dd98` 让
  它返回 1。
- 资源路径 FString `../../../NGR/Content/paks` 与
  `/Users/songdogwang/Library/NGR/Saved/Paks` **只是 0x10432dd98 的
  两个参数**，没有被 `bl 0x10017f184` 实际使用——它们只在更早的路径
  （b.eq 10432df8c 之前）才会被 `bl 0x10432b734` 当成 key 使用。因
  此 **HOK-016-C.5 (pt_stat / NSBundle swizzle path fixup) 不是治
  本方向**，这条线在 C.2.4 被间接证伪。

产物：`build/hok-016c24-readinessB-inner-args.json` (= v5 run 的副
本，保留完整 transcript + summary)。

### HOK-016-C.2.5：rootB writer 在 reporter 内部才发 fire，是 lazy-init 模式

C.2.4 给出的"rootB 为空"结论需要再精化——C.2.5 用两条分析路径证实：

1. **离线**（`Scripts/hok016c2_ngr_sentinel_writer_scan.py --target-address
   0x10e184b18`）：对 rootB 做全 `__text` 直接 store 扫描，**只命中 2
   条**，其中 1 条是真 writer（`0x1001cf314 str x8, [x1]`，位于
   `0x1001cf20c` 这个 static constructor——它出现在 `__init_offsets`
   可达链里，意味着 dyld 启动阶段**必然**被调用、并把 rootB 初始化为
   "sentinel self-loop" 空容器状态），另 1 条（`0x109adbcb8
   str.w wzr, [x19+0xb18]`）经交叉验证是 scanner 的 constant-propagation
   误报（`x19 = x22 + 0x9000`，与 rootB 无关）。产物
   `build/hok-016c25-rootB-writer.json`。
2. **xref 扫描**（`Scripts/hok016c25_ngr_rootB_xref_scan.py`）：枚举所
   有 `adrp+add x?, 0x10e184000, #0xb18` pattern，即"把 rootB 地址
   materialize 到某寄存器"的站点。**结果 94 个 hit，93 个 dst=x0**，
   跨 52 个不同函数。这说明 rootB 不是一个"简单 store 目标"，而是一
   个被大量 helper `find/insert/erase` **当 this 消费**的容器；真正
   的 entry insert 一定通过 helper 间接完成、不会出现在直接 store 扫
   描里。产物 `build/hok-016c25-rootB-xrefs.json`。
3. **LLDB watchpoint**（`Scripts/hok016c25_ngr_rootB_watch.py`）：在
   NGR `main` 入口装 8-byte modify watchpoint（此时 dyld static
   constructors 已执行完），确保只抓 main 之后的写。结果：
   **2 次命中**，都在同一线程同一 callchain 上，PC 均为
   `0x1001cf020`（即 `0x1001cef38` 这个 `unnamed_symbol6059`
   内的 +232，指令序列 `stp xzr,xzr,[x21]; str x23,[x21+0x10];
   str x21,[x22]; ldr x8,[x19]; ldr x8,[x8]; mov x1,x21; cbz x8; str
   x8,[x19] ← 被 watchpoint 捕获; ldr x1,[x22]`——典型的红黑树
   `insert_unique` 插入节点+更新 leftmost 路径）。
   - Hit #0：backtrace 只有 1 frame（因为 watchpoint 立即 auto-continue；
     oldValue/newValue 未捕获，但 PC 仍指向 `0x1001cf020`）。
   - Hit #1：`oldValue = 0x10E1EFCB60`，`newValue = 0x1168D82A0`
     （把 `rootB[0]` 从一个 `__common` 地址改成一个 heap 指针，即更
     新 leftmost child 指针），**backtrace 11 层明确**：
     ```
     #0 0x1001cf020 unnamed_symbol6059 +232  ; red-black insert
     #1 0x1001ccf34 unnamed_symbol6021 +108  ; inner helper
     #2 0x1001b8d3c unnamed_symbol5797 +728  ; inner helper
     #3 0x10017c1e8 unnamed_symbol5139 +232  ; inner helper
     #4 0x108877e84 = 0x108877bd0 +692       ; ← reporter 内部
     #5 0x108879214 = 0x108879164 +176       ; ← reporter vtable[0x30] 入口 +176
     #6 0x103a29bec MeyersSingleton +112
     #7 0x107e5df4c FactoryRegister +60
     #8 0x103a29fa0 QtsFileSystem_Init +832
     #9 0x107e5c970 QtsFS_InitWrapper +12
     #10 0x103a227d0 MessagingInit +44
     #11 0x104a04d38 NSThreadWorker +164
     ```

**关键洞察**：rootB 的 insert 并不是在 dyld static init 或
pre-reporter 阶段发生的，而是 **发生在 reporter 运行期间，具体是
`0x108877bd0 +692` 这个点**——这位于 `+176 bl ...` 和
`+908 bl 0x108878534`（readiness B dispatcher）之间，但**顺序上先于**
readiness B。也就是说 reporter 自己会先尝试往 rootB 插入一些 entry，
然后才做 readiness check。

然而 C.2.4 v5 run 在 reporter 内部 `0x10017f1d8 bl 0x1001cd114` 前读
rootB，header 仍是 `*rootB = *(rootB+0x8)` (两 ptr 同值 = 单 node
或空)，count=1；同时 `bl 0x1001cd114(..., "main", 1)` 返回 0。结合
C.2.5 的 2 次 watchpoint hit：**reporter 实际 insert 的是别的 key，
不是 "main"**（只插了 2 个 node、而 readiness B 需要 "main"）。

换言之，**macOS 下 iOS 预期在 reporter 之前就注册好的 "main"
chunk** 没被注册进来。reporter 的 "按需 insert" 行为只插入它自己
当下调用上下文需要的 entry（可能是当前 asset 的标识），但 "main"
这个基础 chunk 需要由 **更早期的初始化代码** 预注册——目前看这段
iOS-specific 的预注册在 macOS 下缺失。

产物：`build/hok-016c25-rootB-writer.json`（离线 direct-store scan）+
`build/hok-016c25-rootB-xrefs.json`（离线 adrp+add xref scan）+
`build/hok-016c25-rootB-watch.json`（LLDB watchpoint live trace）。

### 当前根因链（HOK-016-C.2.5 对 Dashboard 的改写）

新的真因链（最终形态，HOK-016-C.2.4+C.2.5 跨 run 稳定）：

```
NSThread worker
 → 0x103a227d0 MessagingInit
 → 0x107e5c970 QtsFS_InitWrapper            (cbnz w0, fatal)
 → 0x103a29fa0 QtsFileSystem_Init           (writes 0x10e2146f8)
 → 0x107e5df4c FactoryRegister
 → 0x103a29bec MeyersSingleton  (vtable[0x30] blr)
 → 0x108879164 reporter                     (+176 bl 0x108877bd0; tbz w0)
 → 0x108877bd0 +176..+688: 先做一些子系统/容器的动态注册
               (其中 +692 那条 call 能进到红黑树 insert
                0x1001cf020，但只插了 2 个 key，不包括 "main")
 → 0x108877bd0 +908 bl 0x108878534          (readiness B dispatcher)
 → 0x108878534 +352 bl 0x10432dd98          (readiness B data-verify)
 → 0x10432dd98 +36  FString::Printf("%d", mode=1) → "1"
 → 0x10432dd98 +54  cmp w22=2, decision_c08=2 → EQ → b.eq 0x10432df8c
 → 0x10432df8c ... → fallback 回到 0x10432de10
 → 0x10432de10 .. vtable[0x60]+0xf8 (x21=1) + 又一次 vtable[0x60]+0xf8 (x20=0)
 → 0x10432deec cbnz w21=1 → 0x10432dfac
 → 0x10432dfac cbz w20=0 → 0x10432e06c
 → 0x10432e06c mov x0,x1 (=0); bl 0x10017f184(x0=0)
   → 0x10017f184 rootA lookup for int key=0 → 命中 (entry 存在)
   → entry+0x10 = PascalString [length:u64=4]"main" (不是 FString!)
   → bl 0x1001cd114(rootB=0x10e184b18, entry+0x10 = "main", w2=1)
   → rootB 在 reporter 运行期被 insert 了 2 个 entry，但 key 不是
     "main"——它们是 reporter 当下调用上下文需要的 key（可能是
     current-asset 标识）。"main" chunk 需要由更早期的 iOS-specific
     初始化代码预注册，macOS 下该路径没被触达 → 返回 0 (lookup miss)
   → 0x10017f1e0 cbz x0 → 0x10017f2bc (fail_slot_2) → f184 返回 w0=0
 → 0x10432e074 tbnz w0,#0 不跳 → fallthrough → 0x10432e058 mov w19,#0
 → 0x10432dd98 返回 0
 → 0x108878534 readiness B fail
 → reporter "Create Failed!!"
```

**根因不在资源路径**（v5 抓到的 FString x2 = `"../../../NGR/Content/paks"` /
x3 = `"/.../Library/NGR/Saved/Paks"` 虽然出现在入口寄存器里，但
`0x10017f184` 的 lookup 用的是内部 "main" PascalString，**不是这两个
路径**）；**根因是 `0x10e184b18` 指向的 rootB red-black tree 里缺少
"main" chunk 这个 entry**——reporter 虽然在运行期 insert 了 2 个
entry（C.2.5 watchpoint 命中证实），但它们不是 "main"。"main" 需
要**由 iOS-specific 预注册代码填入**，macOS 下该路径没触达。

下一步定位——"谁应该把 'main' entry 插入 rootB"——由 HOK-016-C.2.6
处理；**该问题随后被 C.2.6 进一步改写**，见下节。

### HOK-016-C.2.6：`rootB -> "main"` 实际成功，真正缺的是 `mainChunk -> "1"`

C.2.5 的关键误差是把 rootB 的失败停在了 **第一层**名字查找。C.2.6 用
新的离线脚本 + 运行期 LLDB trace 把这条链继续往后推，结论是：

1. **离线 `"main"` literal 扫描没有找到可用的 dyld registrar**。
   `Scripts/hok016c26_ngr_main_literal_xref.py` 扫到的只有与当前主线无关的
   `__cstring main` 文本（例如普通日志字符串 / ObjC method name），**没有**
   找到与 `__init_offsets` 可达链相交的 PascalString `"main"` 预注册路径。
   这条结果本身不能给出修法，但它排除了“磁盘里就有一个明确的 static
   constructor 专门注册 `main`”这条最省事路线。产物
   `build/hok-016c26-main-literal.json`。

2. **reporter 内部第一次 insert 的 key 就是 `"main"`**。
   `Scripts/hok016c26_ngr_rootB_keys.py` +
   `Scripts/hok016c26_lldb_rootb_key_watch.py` 在 C.2.5 的 rootB watchpoint
   基础上，直接读取新 node 的 `node+0x20` PascalString，实测：

   - watchpoint hit @ `0x1001cf020`
   - `x19 = rootB = 0x10e184b18`
   - `x21 = newNode`
   - `newNode+0x20 = 04 00 00 00 00 00 00 00 6d 61 69 6e 00 00 00 00`

   即 reporter 不是“插了两个非-`main` entry”，而是**至少有一次插的就
   是 `main`**。insert 之后 rootB header 变成单节点树（两个 ptr 都指向新节点，
   count=1）。产物 `build/hok-016c26-rootB-keys.json`。

3. **`0x10017f184` 内第一层 lookup 已经成功**。
   在 `0x10017f1dc`（`bl 0x1001cd114` 返回后）设 BP，实测：

   - `x0 = 0x137027a00`（非零；每次 run 地址不同）
   - 因而 `0x10017f1e0 cbz x0` **不会**触发

   这直接推翻了 C.2.4 / C.2.5 的旧结论“`bl 0x1001cd114(rootB, "main", 1)`
   返回 0”。也就是说 **rootB 里的 `"main"` 名字查找已经闭合**。

4. **失败发生在下一层：`0x1001bd448` 内的 `0x1001ba82c(mainChunk, "1")`**。
   静态反汇编显示：

   - `0x10017f290` 调 `0x1001bd448(x0 = mainChunk, x1 = entry+0x20 = "1", x2 = sp+0x28, x3 = sp+0x10)`
   - `0x1001bd448 +0x13c` 调 `0x1001ba82c(x0 = mainChunk, x1 = "1")`
   - `0x1001bd588` 处实测 `x0 = 0`
   - 随后 `0x10017f29c` 处 `x0 = 0 / x19 = 0`
   - 最终 `0x10432e074` 看到 `0x10017f184` 返回 0

   也就是说真失败点不再是 `rootB -> "main"`，而是 **`mainChunk -> "1"`**
   这层二级查找。

5. **`mainChunk` 是个空壳对象：`obj+0x60 = 0x0` 且直到 failure 前都没人写它**。
   对 `0x10017f1dc` 处返回的 `mainChunk` 对象做快照，实测：

   - `obj+0x60 = 0x0`
   - `obj+0xe0` 有非空数组边界（说明对象本身不是空指针）

   而 `0x1001ba82c` 的静态逻辑正是：

   - `mainChunk+0x60` 取一棵内部树的 root
   - 用 key `"1"` 做 tree lookup
   - 命中则返回 `match+0x30`
   - miss 则直接返回 0

   C.2.6 在 `mainChunk+0x60` 上临时装了动态 watchpoint；从对象出现到
   readiness B failure 之间 **0 hit**。这证明 reporter 插到 rootB 里的
   `main` 对象只是一个**名字已存在、但内部 `"1"` 子项树为空**的骨架对象。

#### C.2.6 对根因链的改写

新的真因链（覆盖 C.2.5 的“rootB 缺 `main`”说法）：

```text
reporter 内部 insert main 到 rootB
  → rootB["main"] lookup succeeds
  → 得到 mainChunk object
  → mainChunk+0x60 secondary tree is NULL / never populated
  → 0x1001ba82c(mainChunk, "1") returns 0
  → 0x1001bd448 returns 0
  → 0x10017f184 returns 0
  → 0x10432dd98 returns 0
  → readiness B fail
  → "QtsFileSystem Create Failed!!"
```

因此，后续修复目标不再是“往 rootB 里补一个 `main` entry”，而是更精确的：
**让 `mainChunk` 对象下面的 `"1"` 子注册闭合**，或者在更靠后的诊断点
（`0x1001ba82c` / `0x1001bd448`）做 bundle-scoped 强制成功验证。

### HOK-016-C.2.7：`mainChunk+0x60` 在 failure window 内始终为 0，当前 run 只命中 1 次 `lookup2`

C.2.6 已把根因改写成“`mainChunk` 空壳对象缺 `"1"` 子树”；C.2.7 继续往前推，
把 live 失败窗口和静态 caller 面都收紧到足够具体的粒度：

1. **live trace 已能在 `mainChunk` 出现的第一时间稳定装上 `mainChunk+0x60` watchpoint**。
   新增 `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` +
   `Scripts/hok016c27_lldb_mainchunk_watch.py`，在 `0x10017f1dc`（`rootB["main"]`
   返回后）抓到 `mainChunk` 对象并动态装 8-byte watchpoint 到 `mainChunk+0x60`。
   这轮还顺手修正了 LLDB `watchpoint command add` 的参数顺序坑；当前 probe
   安装过程已无额外 Python callback 噪音。

2. **当前 macOS failure run 里，`lookup2` 只活跃 1 次，而且就是 dashboard
   已知的失败 wrapper**。
   `build/hok-016c27-mainchunk-subtree-trace.json` 里唯一一条
   `[hok016c27-lookup2]` 记录为：

   - `pc = 0x1001ba82c`
   - `x0(mainChunk) = 0x...`（tracked object）
   - `x1(key)` 解码恒为 PascalString `"1"`
   - `x30 = 0x1001bd588`（即 callsite = `0x1001bd584`，caller function =
     `0x1001bd464` / 当前失败链 wrapper）
   - `mainChunk+0x60 = 0x0`

   也就是说，这一轮 live run **没有**出现任何来自另外 6 个 `lookup2`
   direct caller 的 runtime hit。

3. **从 `mainChunk` 出现到现有 failure sink，`mainChunk+0x60` watchpoint 仍 0 hit**。
   失败窗口内我们持续看到：

   - `[hok016c27-mainchunk]`：`subtree-wp=id1@mainChunk+0x60`
   - `[hok016c27-lookup2]`：`tracked=true`、key = `"1"`、`mainChunk+0x60=0x0`
   - `[hok016c27-post]`：`0x1001bd588` / `0x10017f29c` / `0x10432e074`
     三处返回值都延续为 0
   - LLDB 最终仍停在既有 failure sink `0x108878124`，`watchpointHitCount = 0`

   这把 C.2.6 的结论收紧成：**当前失败 run 里，`mainChunk` 出现之后直到
   readiness-B fail，根本没有任何 runtime writer 试图填 `+0x60`。**

4. **离线 caller scan 给出了 `lookup2` / `bd448` / `rootbLookup` 的完整 static 面。**
   新增 `Scripts/hok016c27_ngr_mainchunk_callers.py`，产物
   `build/hok-016c27-mainchunk-callers.json`。当前结果：

   - `0x1001ba82c`（`lookup2`）共有 **7** 个 direct caller function：
     `0x1001822a8`、`0x1001b9c68`、`0x1001ba50c`、`0x1001bc220`、
     `0x1001bd464`、`0x1001bdde4`、`0x1001becb0`
   - `0x1001bd448` 仅 **1** 个 direct caller function：`0x10017f194`
   - `0x1001ba50c` 是唯一带 **5** 个 shallow callers 的 `lookup2` wrapper，
     当前最值得继续反推
   - 当前 run 唯一 live 命中的 `lookup2` caller 仍是 `0x1001bd464`

5. **C.2.7 对下一步的意义**。
   到目前为止，我们已经可以排除“`mainChunk` 在 reporter failure window 内晚到写入”
   这条路。后续若继续 C.2.7，优先级应改成：

   - 静态 / live 结合反推 `0x1001ba50c` 与它的 5 个 shallow callers
   - 拆 `0x1001bd464 → 0x1001ba50c → 0x1001a5014` 这条 miss 后 fallback
     builder / post-builder contract
   - 对另外 6 个未在当前 run 活跃的 `lookup2` direct caller 做按需 probe
   - 只有当这些路径都证明“注册逻辑过深、返回对象形状又无法安全伪造”时，
     再进入 C.4 诊断性强制成功方案

6. **C.2.7 新增关键更正：当前 run 并不是止步于 `lookup2` miss，而是继续走到
   `ba50c` fallback builder，但仍在 `0x1001a5014` 后归零**。
   在 `0x1001bd464` 里追加 probe 后，当前 run 观察到：

   - `0x1001ba50c` **确实被调用**，且 `tracked=true`
   - 其入参是 `(mainChunk, "../../../NGR/Content/Paks/1", "1", 0, 1)`
   - `0x1001ba50c` **返回非零对象**（`x0 = 0x...`）
   - 但 `0x1001bd888` 处（`bl 0x1001a5014` 返回后）实测 `x0 = 0`
   - 此时 builder 返回对象 `x27` 与新分配对象 `x24` 的 `+0x60` 都仍为 `0`

   这意味着：

   - `lookup2` miss 后的 fallback builder **不是完全失效**；它能构造出一份
     非零对象
   - 真正把这条 fallback 路径继续压成失败的，是后续
     `0x1001a5014` 的校验 / 组装阶段
   - 因而 C.5 的最小 shim 目标不应再停留在“让 `lookup2` 返回非零”或“单独
     调 `ba50c`”，而应改成：**让 `ba50c` 返回对象进入 `0x1001a5014` 时具备
     足够的下游契约，或直接复用一份已满足该契约的现成对象**

7. **`0x1001a5014` 进一步给出了 `+0x60` 的真实传播方向**。
   反汇编 `0x1001a5014` 后可见：

   - 它会把 `x1` / `x2` 两个字符串参数分别写进新对象 `x21+0x20` /
     `x21+0x30`
   - 它会调用一组下游 helper / vtable method；只有这些后半段检查成功时，
     才会执行：

     - `stp w23, w23, [x21, #0x48]`
     - `str x22, [x21, #0x60]`
     - `str w20, [x21, #0x50]`（带上限修正）

   - 在 `0x1001bd464` 调用点里，`x22` 正是 `x27+0x60`（即 `ba50c`
     fallback object 的 `+0x60` 字段）

   因而当前 run 的失败更精确地说是：**`ba50c` 虽然返回了非零对象，但这份
   builder object 的 `+0x60` 仍为空，导致 `0x1001a5014` 既拿不到要传播的
   `x22`，也拿不到后半段所需的 success bit。**

8. **C.2.7 进一步收紧：当前 run 既不是 path precheck fail，也不是 open-db fail，
   真正死在 storage create-table。**
   在现有 `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` /
   `Scripts/hok016c27_lldb_mainchunk_watch.py` 上继续加 probe 后，最新 run
   观察到：

   - `0x1001a50ec`（`0x1016b91c0` 返回后那个 `tbz w0` 分支点）**0 hit**。
     当前 run 直接从 `0x1001a50d4 tbnz w0` 走 fast-path 到 `0x1001a50f0`，
     即 `a5014` 的 path precheck 已通过，不是当前失败源。
   - `0x1001a5114` 处实测 `x0(db)=3`、`*dbErr=0`；随后
     `newObj+0xa8` 变成非零，说明 `0x10012b2a4` open-db 已成功，失败也
     **不是** db-handle 这一层。
   - `0x1001a522c` 处实测：`newObj+0xb0` 已挂上非零 storage 对象，
     storage vtable `slot+0x18` 归一化后是 `0x1001b3d0c`；但该调用返回
     `w0=0`，所以 `0x1001a5230..0x1001a524c` 那组 success path 赋值
     （`stp w23,w23,[x21,#0x48]` / `str x22,[x21,#0x60]` /
     `str w20,[x21,#0x50]`）根本不会执行。
   - 对 `0x1001b3d0c` / `0x1001b3d7c` 的静态反汇编可见：storage slot `+0x18`
     先调用 `0x1001b3d7c`，其内部在 `0x1001b3df0` 调
     `0x10012bb7c`，并把返回值写到 `storage+0x18`。`0x1001b3df4` live probe
     直接读到：`x0(table)=0`、`storage+0x30 = 0x9000b`，随后
     `0x1001b3ecc cset w0, ne` 把整条 storage method 压成 failure。

   这把当前 active failure 再改写成：

   ```text
   ba50c fallback object exists
     → a5014 path precheck passes
     → a5014 open-db succeeds (db handle = 3, err = 0)
     → a5014 creates storage object (newObj+0xb0)
     → storage.vtable[0x18] = 0x1001b3d0c
     → 0x1001b3d7c calls 0x10012bb7c
     → 0x10012bb7c returns null table, storage+0x30 = 0x9000b
     → storage method returns 0
     → a5014 returns 0
     → bd464 / f184 / dd98 continue returning 0
   ```

   因而 C.2.7 的下一步默认优先级又往下钻了一层：先解释
   `0x10012bb7c` 为什么在 key=`"1"` 时返回 null table，以及 `0x9000b`
   到底代表缺了哪一个前置契约；只有把这层解释清楚，才知道 C.5 应该模拟的
   是 `mainChunk+0x60` 子树本身、storage 对象的建表前置状态，还是更深一层的
   registrar / schema 初始化。

9. **C.4 诊断性双 checkpoint 已证明：old gate 能被顶开，并且 dormant writer
   path 会真的写 `mainChunk+0x60`。**
   新增 `Scripts/hok016c4_ngr_force_storage_success.py` 后，连续做了三轮实验：

   - **storage-only force**：仅在 `0x1001a522c` 把 storage method return
     强制为 1。结果：`a5014` 确实返回 1，`newObj` 的 `+0x48/+0x50` 被填上，
     但 `0x10017f184` / `0x10432dd98` 仍返回 0，说明“只让 storage create
     success”还不够。
   - **storage + ready dual force（带 watchpoint）**：在 storage force 的基础上，
     再在 `0x1001a6958` 把 `0x1001a6830` 内 SaveHeader / ready result 强制为 1。
     这轮里 `0x1001bd960`、`0x10017f29c`、`0x10432e074` 都已实测 `x0 = 1`，
     old readiness-B gate 被真正顶开；同一 run 里 `mainChunk+0x60` watchpoint
     首次在 `0x1001c6e74` 之后触发，LLDB 停在 `0x1001c6e78`。backtrace 显示
     真 writer path 是：

     ```text
     0x10432dfdc
       -> 0x10017f3c8
       -> 0x1001bc220
       -> 0x1001bc970
       -> 0x1001c6da4
       -> 0x1001c6e74 writes mainChunk+0x60
     ```

     这条链恰好落在 C.2.7 静态 caller scan 里原先**未在 natural run 活跃**的
     `lookup2` direct caller `0x1001bc220` 上。
   - **storage + ready dual force（无 watchpoint）**：为了避免 probe 自己拦停
     进程，再跑了一轮 `--skip-mainchunk-watchpoint`。结果表明：虽然当前这轮
     `0x10432dd98 -> 0x10017f184` 已被推成 success，但进程后续仍会重新回落到
     旧 failure sink `0x108878124` 并 disconnect。说明双 checkpoint 足以暴露
     真 writer path，却**仍不足以**直接达到稳定启动。

   当前对主线的含义是：

   - `mainChunk+0x60` 的 writer 已不再是假设，而是已经拿到真实 dynamic chain；
   - natural run 缺的不是“根本不存在 writer”，而是**没有满足这条 dormant
     writer path 的一项或多项 gating condition**；
   - 下一步最值钱的工作，不再是盲猜 `+0x60` 应该长什么样，而是解释：
     为什么只有在 storage success + ready bit 都被强推后，
     `0x10432dfdc -> 0x10017f3c8 -> 0x1001bc220 -> 0x1001bc970 -> 0x1001c6da4`
     才会活过来，以及 natural run 里到底缺了哪个 prerequisite。

10. **C.2.7 再次收紧：writer 命中已经从“停在 watchpoint”升级成“拿到真实
    tracked-dst 写入”，而且 writer 后还有第二次 `f3c8` 回落。**
    在 `Scripts/hok016c4_ngr_force_storage_success.py --force-ready-to-use
    --skip-mainchunk-watchpoint --trace-dormant-writer` 这轮结构化 run 里：

   - `0x1001c6e78` callback 直接打印：`x23(dst) = tracked mainChunk+0x60`，
     `trackedDst=true`；同一命中还读到 `dstBefore = 0x125d95d20`，并在 helper
     的 tracked-chunk extra 中同步看到 `mainChunk+0x60 = 0x125d95d20`。这说明
     dormant path 已经不是“疑似附近写入”，而是**真的把当前 tracked mainChunk
     的 subtree root 挂上了非零对象**——但这里的“真的”仍限定在 dual-force
     诊断条件下。
   - 写入对象 `x22(src)` 的首 0x40 bytes 也被抓下来：里面能看到
     `0x12603ae60`（即 tracked `mainChunk+0x60` 自身）以及若干状态位，说明这份
     writer object 至少已经带了与目标 subtree root 绑定的内部指针 / metadata。
   - 同一 run 还抓到一条新的后续事实：`0x10432dfdc` 那次 `f3c8` 成功之后，
     在更早的 sibling branch `0x10432def0..0x10432df30` 里，
     `0x10017f3c8` 会被**再次**调用（`LR = 0x10432df30`），而那第二次命中
     返回 `x0 = 0`。继续加 `0x10017faa0` 的 return probe 后，又能看到：

     - 第一轮 `0x10432dfbc -> 0x10017faa0` 的 return site `0x10017fb44`
       在真正 `mov x0, x19` 之前，`x19 = 0`；
     - 第二轮 `0x10432df10 -> 0x10017faa0` 的 return site `0x10017fb44`
       同样是 `x19 = 0`；

     再往里加 `0x1001be550` 的 probe 后，又能把这两次失败拆成不同形状。结合
     `0x1001be61c` 的静态语义（成功时返回树节点 `+0x30` 上挂着的 entry/payload
     object，而不是树 node 本体），当前动态结果应理解成：

     - **第一轮**（`flag=0`）时，`0x1001be584` 处 `x0=0`。也就是 writer
       path 触发前，`mainChunk+0x60` subtree 里**连目标 entry/payload object
       都不存在**；
  - **第二轮**（`flag=1`）时，`0x1001be584` 处已经能拿到非零 override object；
    但新增的 stage-correlation probe（`build/hok-016c4-force-storage-ready-stage-correlation.json`）
    证明：**“首轮 `0x1001a53a0(..., 1)` 失败”与“`bb73c(..., 0)` 产出 hollow wrapper”并不是同一条直线控制流，而是同一轮 dual-force run 里的两个 sibling branch**。
    关键证据如下：
    - `0x1001bae8c` 这次首轮 `bl 0x1001a53a0(..., w3=1)` 的 return site，来自
      `LR = 0x10432df30` 这支 sibling branch；它虽然看到 `ctx+0x40` 已经是
      nonzero candidate，但在 `0x1001a53dc` 内部的第一个 gate
      `0x1001a55b8`（`bl 0x1001a588c` 返回后）就已经观测到 `w0 = 0`，且没有同分支的
      `0x1001a55c8` 命中。这说明首轮失败的具体位置不是泛化的“override contract 不闭合”，
      而是 **`0x1001a588c` / OpenNodeStorage 这一级直接返回 0**；静态 failure 文案
      `0x1001a5730` 也对应 `"QtsfPackage OpenNodeStorage failed! package=%s"`。
    - `0x1001bb73c(..., 0)` 则来自另一支 `LR = 0x10432dfdc`。这支里真正被调用的是
      `0x1001baf80` 处的 **第二轮** `0x1001a53a0(..., w3=0)`；它在
      `0x1001a55b8` / `0x1001a55c8` 两个 gate 上都实测 `w0 = 1`，并在
      `0x1001baf84` 返回 `w0 = 1`。也就是说，`w3=0` 这轮 package load 本身**成功**。
    - 紧接着 `0x1001bafa8` 处直接读到 `ctx+0x38 = 0`；而新增的
      `build/hok-016c4-force-storage-ready-context-init.json` 进一步把这个 producer
      锁定到上游 `0x1001ba720` context-builder：
      - 在 `LR = 0x10432df30` 这支里，`0x1001ba7a8` 的 lookup return 是 nonzero
        `0x120eb04f0`，随后 `0x1001ba7c0` 直接观测到 `ctx+0x38 = 0x120eb04f0`；
      - 在 `LR = 0x10432dfdc` 这支里，同一个 `0x1001ba7a8` lookup return 变成 `0`，
        `0x1001ba7c0` 也随之把 `ctx+0x38` 初始化成 `0`。
      再结合对 `0x1001ba940..0x1001bb120` 的静态反汇编筛选——`ba940` 一带对
      `[x19,#0x38]` 只有多处 `ldr`、**没有任何 `str` 写入**——可以确认：
      `bb73c(..., 0)` 被选中，不是因为“首轮 `a53a0(..., 1)` 失败后直接跌落到这里”，
      而是因为当前这支路径在进入 `ba940` 之前，`ba720(key="1")` 自己就已经把
      `ctx+0x38` 初始化成了 0。
    - `0x1001bafbc` 的静态反汇编同时坐实：传给 `0x1001bb73c` 的 `w3 = 0`
      是函数内的硬编码 `mov w3, #0`，而 `0x1001bb73c` 自身在 `0x1001bb798` 对
      `w22/x3` 做 `cbz`；当 `x3 == 0` 时直接跳过 `0x1001bc970` 的 child / payload
      路径。
    - `0x1001bafc4` 处 `bb73c` 返回对象已经是 hollow wrapper 形状：首 qword 与第二
      qword 都还是 `0`，`+0x48 = 0`、`+0x50 = 0xffffffff`；随后
      `0x1001bb844` 的静态反汇编 + live probe 进一步证实：它只做
      `str x19, [x20]`，也就是把 final entry 回写到 wrapper 首 qword 里形成 backref；
      **不会**补 child / payload。`0x1001bb014` 处 `str x22, [x8, #0x8]` 确实执行，
      final entry 的 `slot1` 也确实从 `0` 变成了这份 wrapper。

    把这些证据合起来，当前口径应修正为：**dual-force run 里至少有两支 sibling path**——
    一支在 `0x10432df30` 上把 `0x1001a53a0(..., 1)` 卡死在 `0x1001a588c`
    / OpenNodeStorage gate；另一支在 `0x10432dfdc` 上让 `0x1001a53a0(..., 0)`
    顺利通过，但因为上游 `ba720(key="1")` lookup 自己就返回 0、把 `ctx+0x38`
    初始化成了 0，于是被迫走硬编码 `w3=0` 的 `bb73c` 路径，最终把
    `backref-to-entry + null-child` 的 hollow wrapper 写进 `slot1`；
    `0x1001be550(flag=1)` 看到它时自然继续把 return 压回 `0`。

    因而当前 sequence 应写成：

    ```text
    dual-force pushes first writer branch alive
      -> first 0x10017faa0 still returns 0, so sibling branch A reaches 0x10432df30
      -> branch A calls ba940 first-stage 0x1001a53a0(..., 1)
      -> inside 0x1001a53dc, gate#1 (0x1001a588c / OpenNodeStorage) already returns 0
      -> branch A returns 0 without producing a usable override object
      -> sibling branch B at 0x10432dfdc activates the dormant writer path and writes tracked mainChunk+0x60
      -> branch B enters ba940 second-stage 0x1001a53a0(..., 0)
      -> gate#1 + gate#2 both return 1, so second-stage package load itself succeeds
      -> ba940 then reads ctx+0x38 and still gets 0
      -> code executes hardcoded 0x1001bb73c(..., "1", 1, 0)
      -> because x3 == 0, bb73c skips 0x1001bc970 and returns a hollow wrapper
      -> 0x1001bb844 only patches entry backref into that wrapper
      -> ba940 finally writes entry.slot1 = hollowWrapper
      -> second 0x10017faa0 / 0x1001be550(flag=1) reads that same wrapper
      -> second gate still returns 0
      -> sibling branch later calls 0x10017f3c8 again and the process eventually falls back to the old readiness-B sink
    ```

  这把主线目标进一步改写为两层：

   1. 先解释 **为什么 `0x10432df30` 这支里的首轮 `0x1001a53a0(..., 1)` 会在
      `0x1001a588c` / OpenNodeStorage gate 上返回 0，以及为什么 `0x10432dfdc`
      这支里的 `ba720(key="1")` lookup 只会返回 0、从而把 `ctx+0x38` 初始化成 0**；

   2. 再继续收紧 natural run 为什么过不了 `storage success + ready` 以及更高层
      mount / registrar state 这组一项或多项 prerequisite。


## 修复方向（HOK-016-C.2.7 之后重新排序）

HOK-016 的修复必须在 PlayTools 层 bundle-scoped、不动 NGR 二进制，可选
方案按"影响面从小到大 / 风险从低到高"排：

1. **(C.2.7) 定位 / 模拟 `mainChunk -> "1"` 注册路径**（当前方向）：
   - 运行：继续围绕唯一 live active path
     `0x10017f194 → 0x1001bd448 → 0x1001ba82c(mainChunk, "1")`
     扩 probe，但重点从“watch 失败窗口内有没有晚到 writer”转成
     “当前 run 之外还有哪些 constructor / registrar 路径本该被触发”，
     以及“`ba50c` 之后 `0x1001a5014` 还要求哪些对象字段 / 关联状态”。
   - 静态：优先反推 `0x1001ba50c` 及其 5 个 shallow callers，并对另外
     6 个未在当前 run 活跃的 `lookup2` direct caller 做按需 probe。
2. **(C.5) 在 PlayTools 里模拟 `mainChunk -> "1"` 的二级注册**：若
   C.2.7 能给出一个可重复的 child-registration API 签名或完整对象构造
   路径，PlayTools constructor 里按同样签名补齐该二级子树；这是新的最
   小侵入修法。
3. **(C.4) 基于 PlayTools 现有 bundle-scoped runtime hook / direct
   patch 基建做诊断性强制成功**：若 C.2.7 证实注册路径过于复杂、且
   `lookup2` 的返回对象形状又无法安全伪造，再退而求其次对
   `0x1001ba82c` / `0x1001bd448` 做 bundle-scoped 诊断性强制成功验证。
4. **(C.3) 在更外层强制 readiness-B 成功**：保留作为最后兜底，风险仍
   然最高。
5. **(C.6) 降级**：若 C.2.7 最终指向必须由用户提供外部资源/登录
   态，才把问题降级到 HOK-009（需要用户介入）。

已证伪路径：

- **(~~C.5 pt_stat/NSBundle path fixup~~，间接证伪)**：HOK-016-C.2.4
  抓到 rootB 的 lookup key 是内部 PascalString "main"（chunk 名），
  而不是 FString 路径；进 `0x10017f184` 的 x0 参数是 int(=0)；
  `0x10432dd98` 入口拿到的两个 FString 路径实际没被
  `0x1001ac168` / `0x1001cd114` 消费。pt_stat 之类 syscall 级 fixup
  不能修复"rootB 中缺 name entry"。这条方案从主线降级为备胎。
- **(~~"rootB 从头到尾是空" 推测~~，HOK-016-C.2.5 更正)**：C.2.5
  LLDB watchpoint 实测 rootB 在 reporter 运行期被 insert 过 2 次
  entry（来自 `0x1001cf020` 红黑树 insert 路径）；只是 insert 的 key
  不是 "main"。真实问题是"缺 main entry 的预注册"，不是"rootB 完
  全没人写"。
- **(~~C.X, 已证伪~~) HOK-015 seed value 替换**：HOK-016-C.X.1 实
  验证明换 seed 只影响 UE4 `Project file not found` log，不影响
  `0x108878534` 的 w0 返回值（恒 0）。保留证据
  `build/hok-016cx-summary.json` + 4 份 per-seed trace。
- **(~~C.2.1 / C.2.2, 已证伪~~) 先前假设的 "sentinel `0x10e1eeef0`
  未 bump 到 ≥ 4"**：运行期 probe 实测该 byte = `0x05`，b.lo 判定
  不走 sentinel early-exit；另外全 `__text` 扫描无 writer（writer
  要么在 framework 里、要么是 literal-pool load，但对当前修复无意
  义——反正 sentinel 已 >= 4、判定早已不走 sentinel early-exit
  了）。证据：`build/hok-016c2-sentinel-writer.json`（
  __init_offsets 扫描）+ `build/hok-016c2-sentinel-writer-full-text.json`
  （全 __text 扫描）+ `build/hok-016c2-sentinel-probe.json`（运行
  期 probe）。

所有方向都必须保留 HOK-013 / HOK-014 / HOK-015 作为安全网，落地之前先
在 `build/hok-016-*.json` / `build/hok-016c-*.json` /
`build/hok-016c2-*.json` / `build/hok-016c24-*.json` /
`build/hok-016c25-*.json` / `build/hok-016cx-*.json` 记录证据；落地
后的验证口径见 Dashboard "HOK-016-D 判据"（`hok014_ngr_alert_suppressed
= 0` / 进程活跃度 / 窗口可见性 / 无新 `NGR-*.ips`）。

**下一步默认推进顺序**：C.2.7（优先并行拆两条新收紧的分支：
一条沿 `0x10432df30 -> 0x1001bae8c -> 0x1001a55b8 -> 0x1001a588c`
解释首轮 `0x1001a53a0(..., 1)` / OpenNodeStorage gate 为什么返回 0；另一条沿
`0x10432dfdc -> 0x1001ba720(ba720) -> 0x1001ba7a8/0x1001ba7c0 -> 0x1001baf80 -> 0x1001bb73c`
解释为什么 `ba720(key="1")` lookup 只会返回 0、从而把 `ctx+0x38` 初始化成 0，并把流程推入硬编码
`x3 = 0` 的 hollow-wrapper 路径；同时保持对 natural run 主失败链
`0x1001bd464 -> 0x1001a5014 -> storage.vtable[0x18](0x1001b3d0c) -> 0x10012bb7c`
的追踪，继续解释 `0x9000b` / null table 的来源）
→ 若拿到可重复 child-registration / ready-state 契约则进 C.5；若只剩“复杂路径且无法安全伪造返回对象”
则继续扩 C.4 的 bundle-scoped 诊断性强制成功验证 → C.3（最终兜底）→ C.6 降级（末选）。

## 参考

- `HOK-011-静态初始化链分析.md`：`0x10e2146f8` 的唯一 writer = frame 3
  函数内部 `0x103a29f7c: str x0, [x8, #0x6f8]`；frame 2 = HOK-011 记录
  的 "0x107e5df10 唯一 caller"；反向 BFS 方法论。
- `HOK-013-slot-preheat.md`：HOK-013 为何在 frame 3 触发前必须把
  `0x10e2146f8` 写成 stub。
- `HOK-014-alert-suppressor.md`：UIAlertController swizzle；HOK-016 闭
  合前 HOK-014 仍承担"用户看不到 alert"的硬约束。
- `HOK-015-cmdline-preseed.md`：FCommandLine 预置；HOK-016-B 的 x2
  参数语义校验依赖 HOK-015-A 输出 `build/hok-015-cmdline-slots.json`。
