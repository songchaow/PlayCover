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

## 已知真因判定

- **不是 cmdline 内容问题**：reporter 的 x2 参数是 CmdLine buffer 没
  错，但这条字符串只是 UE_LOG 的 format context，QtsFS 的 fail/success
  不由 cmdline 内容决定。
- **不是 HOK-015 preseed 做错**：HOK-015 `bInitializedBefore=0 →
  bInitializedAfter=1` 在每一轮 `launch-events.jsonl` 都稳定出现；frame 5
  的 FCommandLine inline guard `ldrb 0x103a227bc; tbz 0x103a227c0, +588`
  也顺利 fall-through 到 normal path。
- **真正的判定点是 `0x108877bd0` 函数的返回值**：reporter `+176 bl
  0x108877bd0; +180 tbz w0, #0, +364`。w0==0 时走 "Create Failed!!"
  分支，最终通过 `0x10432f490` 构造 UIAlertController 并 present 到主
  VC（被 HOK-014 swizzle 压到 UI 外，但 reporter 本身仍走完 fatal 流、
  最终把 `QtsFileSystem::Init` 的 w0 改成 0 返给 frame 4；frame 4 `cbnz w0, +32` 走 tail-call fatal 路径，GameThread 退出）。

## 修复方向（尚未落地；保留记录供后续决策）

HOK-016 的修复必须在 PlayTools 层 bundle-scoped、不动 NGR 二进制，可选
方案按"影响面从小到大"排：

1. **(C.2) 静态深入 `0x108877bd0`**：继续反汇编 + LLDB BP 逐条扫它内部
   的 syscall / dylib 调用（`stat` / `open` / `access` / `fopen` /
   `NSFileManager`），确认它到底在检查什么——最可能是 **iOS-only 的
   sandbox 路径或 iOS-only 的 NSBundle 资源键**；
2. **(C.3) PlayTools 层 path fixup**：若 C.2 证实它调某条 syscall 查
   iOS sandbox 路径，则在 PlayTools 的 `pt_stat` / `pt_access` filename
   映射层对 `com.tencent.ngr` 追加 NGR 特定路径映射（沿用现有
   `rootWorkDir` 透传的同一套体制），让同一 syscall 返回合法值；
3. **(C.4) symbolic `0x108877bd0` swizzle**（兜底）：若 C.2 证实失败
   由 C++ 内部检查（非 syscall）驱动，用 fishhook/dyld interpose 在
   `0x108877bd0` 的入口注入 `return 1`。这等价于 HOK-007B 的二进制
   patch 但以 PlayTools 运行期形式体现——**有 app 稳定性风险**（可能
   让 NGR 之后用到未初始化 的 QtsFS 内部状态），需要同时扫 C.2 的静态
   side-effect 才能安全采用；
4. **(C.5) 降级结论**：若 C.2 证实失败是必须由用户提供外部资源（例如
   登录后的 cooked data pack），则 HOK-016 升级到 HOK-009 类型（需要
   用户介入）。

所有方向都必须保留 HOK-013 / HOK-014 / HOK-015 作为安全网，落地之前先
在 `build/hok-016-*.json` 记录证据；落地后的验证口径见 Dashboard
"HOK-016-D 判据"（`hok014_ngr_alert_suppressed = 0` / 进程活跃度 / 窗
口可见性 / 无新 `NGR-*.ips`）。

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
