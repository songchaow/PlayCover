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
  HOK-016-C.1 尝试过在 `0x10432dd98` 入口设 BP 但 0 次命中——说明
  `0x108878534` 在更早就决定返回 0（大概率就是 `+48 ldrb [x22, #0xef0]`
  或相邻 sentinel-based check 命中 "subsystem 未就绪" 的早退分支，
  还没调到 `0x10432dd98`）。
- **"readiness A 成功 / readiness B 失败" 的分布跨 run 稳定**：HOK-016-C.1
  / C.X.1 transcript 里 `+900 tbz` 之前 `x0=0x1`、`+912 tbz` 之前
  `x0=0x0`。排除了"偶然性资源竞争"假设，指向**确定性的 sentinel /
  资源布局问题**。
- **真凶最可能在 `0x108878534` 入口 sentinel 早退分支**：`+48 ldrb
  [x22, #0xef0]`、`+52 cmp w8, #0x4`、`+56 b.lo +64`——若 `x22->0xef0
  < 4` 走 skip 分支。这个 sentinel 与 `0x108877bd0 +1364 ldrb
  [x24, #0xef0]; cmp w8, #0x2` 读的是**同一 global byte**
  (`0x10e1eeef0`)。也就是说一个全局 subsystem readiness level
  byte 决定了整条路径。HOK-016-C.2 的重点是定位**谁 bump 这个 byte**
  （在 iOS 上由什么 initializer 提前 bump 到 >=4，而在 macOS 上没有
  bump）。

## 修复方向（尚未落地；保留记录供后续决策）

HOK-016 的修复必须在 PlayTools 层 bundle-scoped、不动 NGR 二进制，可选
方案按"影响面从小到大 / 风险从低到高"排：

1. **(C.2, 当前主线) 定位 sentinel `0x10e1eeef0` 的 writer 链**：
   两处关键 readness 分支都读 `0x10e1eeef0`（
   `0x108878534 +48 ldrb [x22, #0xef0]; +52 cmp w8, #0x4; +56 b.lo
   +64` 和 `0x108877bd0 +1364 ldrb [x24, #0xef0]; +1368 cmp w8, #0x2`）。
   先用 HOK-011 的 `Scripts/hok011_ngr_common_init_chain.py`
   `--target-address 0x10e1eeef0` 离线扫 writer；若 writer 在 NGR
   自身 `__init_offsets` 上不可达（如 HOK-011 观察到的 `0x10e2146f8`
   情况），再用 LLDB watchpoint `watchpoint set expression -s 1 --
   0x10e1eeef0 + slide` 运行期追 writer。关键问题：iOS 上谁 bump 这
   个 byte 到 >= 4？（疑似某个 iOS-only framework 的 `+load` 或
   `__init_offsets` 里的 initializer。）
2. **(C.3) PlayTools 层 sentinel 预 bump**：若 C.2 证实 sentinel 在
   iOS 上由某 initializer bump 而 macOS 上缺这一步，PlayTools
   constructor 可以直接预写 `sentinel >= 4` 到 `0x10e1eeef0`（沿用
   HOK-013 的 `pt_ngr_find_main_image` + slide + bundle gate 套
   路）。**有风险**：若 sentinel 代表 "QtsFS initialization level"，
   跳过 bump 该 writer 执行的真正初始化可能让后面用到未就绪的
   QtsFS 子系统。必须配合 C.2 的 side-effect 扫描才能安全采用。
3. **(C.4) `0x108878534` 或更底层函数 symbolic interpose**：若
   C.2 证实真正的初始化步骤由某个具体函数承担（而非 sentinel
   bump），用 fishhook / dyld interpose 直接 hook 该函数让其走
   等价于 iOS 的 normal path。
4. **(C.5) PlayTools 层 path fixup**（可能已失效）：若 sentinel bump
   的 writer 本身因 syscall/NSBundle 查找失败而跳过，那 `pt_stat` /
   `pt_access` / `-[NSBundle pathForResource:ofType:]` swizzle 仍然
   是一条备选修复路径。
5. **(C.6) 降级结论**：若 C.2 证实失败必须由用户提供外部资源
   （登录后的 cooked data pack 等），则 HOK-016 升级到 HOK-009 类
   型（需要用户介入）。

已证伪路径：
- **(~~C.X, 已证伪~~) HOK-015 seed value 替换**：HOK-016-C.X.1 实
  验证明换 seed 只影响 UE4 `Project file not found` log，不影响
  `0x108878534` 的 w0 返回值（恒 0）。保留证据
  `build/hok-016cx-summary.json` + 4 份 per-seed trace。

所有方向都必须保留 HOK-013 / HOK-014 / HOK-015 作为安全网，落地之前先
在 `build/hok-016-*.json` / `build/hok-016c-*.json` /
`build/hok-016cx-*.json` 记录证据；落地后的验证口径见 Dashboard
"HOK-016-D 判据"（`hok014_ngr_alert_suppressed = 0` / 进程活跃度 /
窗口可见性 / 无新 `NGR-*.ips`）。

**下一步默认推进顺序**：C.2 sentinel writer 定位 → 根据定位结果在
C.3 / C.4 中选形式 → C.5 路径 fixup（兜底）→ C.6 降级（末选）。

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
