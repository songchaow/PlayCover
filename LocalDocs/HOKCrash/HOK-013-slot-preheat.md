# HOK-013: PlayTools 侧预热 `com.tencent.ngr` 的 `__common` slot `0x10e2146f8`

> 本文只沉淀 HOK-013 的**设计依据、实现口径、验证口径**。任务状态以
> `00-Dashboard.md` 为准；本文不出现 "DONE / TODO /
> 已落地 / 下一步" 等字样，也不写日期快照。
>
> **何时读**：修改 HOK-013 相关代码、或怀疑 preheat 没落地 / bundle
> gate 溢出时读；当前候选 E 已 revert，HOK-013 单独兜住
> `0x10e2146f8` reader，是 HOK-016 的必要前提之一。
>
> **相关文档**：
>
> - 验证口径与已否决方案：`HOK-013-appendix-verification.md`（按需读）；
> - writer 识别与反向 BFS 方法论：`HOK-011-静态初始化链分析.md`；
> - 候选 E 的 apply/revert 口径：`HOK-007-二进制意图分析与callsite映射.md`；
> - LLDB watchpoint / b.0 gate 工具链：`HOK-012-工具链与方法论归档.md`；
> - HOK-016 frame 3 与 slot writer 的关系：`HOK-016-qts-fs-create-failed.md`。

## 目的

让 `com.tencent.ngr` 在 PlayCover 下的 `__DATA,__common` 槽位
`0x10e2146f8` 在 NGR 主 image 的 dyld initializer `__init_offsets[1563]`
（reader `0x1047e83f4` → faulting callsite `0x10480df08`）跑起来之前被
预写入一个**合法**的对象指针；这样 reader 原 faulting 指令
`ldr x8, [x19]` 读到合法 vtable、`ldr x8, [x8, #0x10]; blr x8` 命中
no-op 虚函数，安全返回。HOK-013 落地后候选 E（磁盘字节 patch）从"安全
网"降级为"磁盘备份 + 反向对照"，默认 `state=original`。

HOK-013 的成功判据：

1. NGR 进程在 PlayTools constructor 返回后，`0x10e2146f8` 的当前值 **非 0**
   且指向 PlayTools 持有的 stub object；
2. Revert 候选 E 后，原 faulting callsite `0x10480df08` 不再触发
   `EXC_BAD_ACCESS`；
3. 其它 bundle 完全不受影响（bundle-scoped gate 生效）。

## 设计决策

### D1：写什么值

**写一个 PlayTools 持有的 stub object 地址**，而不是尝试调用 NGR 内部的
Logger accessor。

理由：

- **尝试调 `0x107e5df10` / `0x103a29c60` / `0x107e5c964` 等 accessor 被
  live 证伪**。这些函数的 calling convention 不是"无参数"的——即使
  `0x107e5c964` 看起来是一个裸 thunk（`stp x29,x30 + bl writer + epilogue`），
  它直接 pass-through `x0` 给 writer `0x103a29c60`；writer 内部在
  `+0x40` 处 `bl 0x10481d7a8`，目标函数 `+0x8` 处 `ldrh w9, [x0]` 要求
  `x0` 是一个有效的 16 位可读地址；我们调用时 `x0` 保留 PlayTools
  constructor 里残留的任意值（观察到 `x0=0x1`），直接 EXC_BAD_ACCESS。
- **stub object 方案的信息需求最小**：reader 全二进制扫描表明
  `0x10e2146f8` 只有**一个** reader（`0x1047e83f4`），且它只消费 vtable
  offset `+0x10` 上的一个虚函数指针；因此只需一个 8 字节 vtable 指针 +
  一个 no-op 虚函数，就能让 reader 安全跑过。
- **stub 方案不依赖 iOS 行为的逆向假设**。HOK-011 的 "外部 framework
  initializer 间接触达 accessor" 只是一个假设；stub 方案是一条
  iOS/macOS 行为不对齐时仍然能让 reader 工作的兜底路径。

### D2：在何时写

**在 PlayTools 的 `__attribute__((constructor))` 入口最早处调用，早于
`[PlayCover launch]`**。

dyld 初始化顺序：所有依赖 dylib 的 initializer（含 PlayTools framework
的 constructor）→ 主 image `NGR` 的 `__init_offsets`。PlayTools 作为
`DYLD_INSERT_LIBRARIES` 预加载，其 constructor 执行时 NGR 主 image 已
mapping 完成（runtime 地址可算），但它自己的 `__init_offsets` 还没开始
跑（reader 还没读 slot）。这是唯一一个"NGR image 可见 + reader 未执行"
的窗口。

不需要把 preheat 推迟到 `+load` 之后——`+load` 与 constructor 都在同一
initializer 阶段，顺序由 dyld 按 image 加载顺序决定，PlayTools 在 NGR
主 image 之前必跑一次。

### D3：slide 处理

- NGR 主 image 的 `__TEXT.vmaddr` 在 Mach-O header 里硬编码为
  `0x100000000`，runtime 实际 mapped 地址 = `(uintptr_t)mh`（由
  `_dyld_get_image_header(i)` 返回）。
- `slide = (uintptr_t)mh - unslidTextVMAddr`。
- `slotRuntimeAddr = 0x10e2146f8 + slide`。
- **安全阀**：若 `unslidTextVMAddr != 0x100000000`（NGR 被重链接、unslid
  base 变了），硬编码的 unslid slot vmaddr 不能再安全加到 slide 上——
  直接放弃 preheat，让候选 E 兜住，并在 `launch-events.jsonl` 写
  `status=unexpected-text-vmaddr` 的诊断事件。

### D4：bundle-scoped gate

`pt_ngr_should_preheat_slot()` 读 `CFBundleGetIdentifier(
CFBundleGetMainBundle())`，精确字符串比较 `"com.tencent.ngr"`。不匹配
直接 return。刻意不经 `[PlaySettings shared]`、不经
`Bundle.main.bundleIdentifier`（Swift 入口）——这两条路径涉及更重的
初始化，而 HOK-013 的目标是在 constructor 最早时刻执行。

### D5：stub 对象布局

- `pt_ngr_stub_vfunc_noop`：naked 函数，单条汇编 `mov x0, #0; ret`。命中
  reader 的 `blr x8` 后立即返回 0，不修改任何状态。
- `pt_ngr_stub_vtable[8]`：8 个 slot，全部指向 `pt_ngr_stub_vfunc_noop`。
  reader 只用 `+0x10`，但保留额外 slot 作为保守上限，防御将来其它
  reader 也落到同一 slot 的情况。
- `pt_ngr_stub_object`：16-byte aligned 静态对象，第 0 字节是
  `pt_ngr_stub_vtable` 指针，后跟 56 字节 padding（让对象 size = 64 B，
  避免任何理论上的越界读落入 PlayTools 内部 BSS 的其它符号）。

### D6：幂等与故障安全

- `dispatch_once_t` 保证整个进程生命周期内只写一次 slot。
- 写入前先读 slot：若已非 0（例如未来某条外部 framework init 路径在
  PlayTools constructor 之前就跑过了），写 `status=already-primed` 并
  return，避免覆盖已存在的合法对象。
- 写入后读回验证：`slotValueAfter == stubAddr` 才标 `status=primed`，否
  则标 `status=write-verify-failed`（理论不应出现，作为内存屏障保险丝）。
- 每条 preheat 日志写到 `launch-events.jsonl`：
  `event=hok013_ngr_slot_preheat`，`details` 含 `phase`（
  `locate` / `probe` / `write`）、`status`、`stubObject`、`slotAddr`、
  `slotBefore`、`slotAfter`、`slide`。

### D7：与候选 E（HOK-007B）的关系

HOK-013 落地后**不要立即自动 revert 候选 E**；两者并存时的语义：

- 候选 E 仍 apply：reader 的 `0x10480df08` 已被 `b 0x10480df24` 替换，
  原本 `ldr x8, [x19]` 不执行，根本不会 deref 我们写入 slot 的 stub
  对象。HOK-013 预写入无用但无害，并证明 "PlayTools 能正常把 stub 写到
  NGR slot" 的基础能力。
- Revert 候选 E：reader 恢复 `ldr x8, [x19]`，会读取 slot → 读 vtable
  → `blr x8` no-op。整个路径由 HOK-013 单独兜住。

**当前状态**：HOK-013 单独兜住已通过验证，候选 E 已经执行
`Scripts/hok007b_ngr_patch_runner.py --revert`，磁盘 `state=original`，
备份保留在 `build/hok-007b-backups/*.bin`。revert 流程统一由
`hok007b_ngr_patch_runner.py` 管理，HOK-013 本身不碰磁盘 patch。

## 实现位置

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：
  - 宏 `NGRSLOT_PREHEAT_SLOT_ADDR` / `NGRSLOT_PREHEAT_TEXT_VMADDR` /
    `NGRSLOT_PREHEAT_BUNDLE_ID`。
  - `pt_ngr_stub_vfunc_noop`：naked `mov x0, #0; ret`。
  - `pt_ngr_stub_vtable[8]` + `pt_ngr_stub_object`：静态常量 +
    16-byte-aligned 对象。
  - `pt_ngr_find_main_image(...)`：遍历 `_dyld_image_count` 找
    `MH_EXECUTE`。
  - `pt_ngr_should_preheat_slot()`：bundle-scoped gate。
  - `pt_ngr_log_preheat_event(...)`：回调 Swift
    `PlayCover.recordHOK013PreheatDiagnosticWithDetails:`。
  - `pt_ngr_preheat_slot_once()`：`dispatch_once`；主流程 `locate →
    probe → write`。
  - constructor `initialize(void)` 第一行 `pt_ngr_preheat_slot_once();`。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：
  - `@objc static public func recordHOK013PreheatDiagnostic(details:)`：
    把 C 侧传过来的 details dict 包装成 `RuntimeLaunchDiagnostics.record(
    event:"hok013_ngr_slot_preheat", ...)` 事件。

## 验证口径（简要）

三轮验证的完整命令与判定口径、bundle-scoped gate 回归检查命令沉淀到
`HOK-013-appendix-verification.md`。概要：

- **第一轮**（候选 E 保持 apply）：跑 deferred-install watchpoint 形态
  的 hok006 runner，确认 `launch-events.jsonl` 出现
  `hok013_ngr_slot_preheat status=primed`、`slotAfter == stubObject`、
  `blockingDialogs=0`。
- **第二轮**（revert 候选 E）：跑 legacy baseline，确认 faulting 不再
  回到 `0x10480df08`、preheat 事件仍在、settle window 不秒断。
- **第三轮**（bundle gate）：确认 HOK-013 事件只出现在
  `com.tencent.ngr` 的 `RuntimeLaunchDiagnostics/` 子目录里。

> **何时进附录**：要真正跑一轮验证、或怀疑 preheat 没落地 / gate 溢出
> 时读；日常主文档浏览不必进入。

## 非目标 / 边界

- HOK-013 **只** 解决 `0x10e2146f8` 的 reader 安全穿越问题；它不改变
  `QtsFileSystem Create Failed!!` / `rootWorkDir` / Thread #10
  `address=0x30` 等下游 secondary fault。这些仍属于 HOK-010 / HOK-007C
  方向，由 Dashboard 另行调度。
- HOK-013 **不适用于**其它 bundle。任何想把 stub preheat 推广到别的 app
  的需求，都要先走一遍 HOK-011 风格的静态分析（确认新 slot 的 reader
  数量与 vtable 消费 offset）+ 单独的 bundle-scoped gate + 独立的 stub
  vtable。
- HOK-013 **不引入新的 env 变量**。它不影响 `DYLD_PRINT_INITIALIZERS` /
  `DYLD_PRINT_APIS`（HOK-012-A 引入的 diagnostic env）、也不影响 HOK-010
  的 `rootWorkDir` 处理路径。
- HOK-013 的 stub 对象**不模拟真实 Logger 语义**；命中 stub 虚函数的
  reader 会拿到 "no-op return 0"，在部分 Logger 调用路径里相当于 "日志
  输出被静默丢弃"。这在启动兼容目标下是可接受代价；若将来需要保留真
  Logger 行为，需要专门扩展 stub（或回到 D1 被否决的 accessor 方案，
  重新解决它的 calling convention 问题）。

## 曾被考虑但否决的方案

- **A：调用 NGR Logger accessor（`0x107e5df10` / `0x107e5c964`）**：
  live 证伪——writer `0x103a29c60` 把 caller 的 `x0` 透传给子调用，
  PlayTools constructor 里 `x0` 为残留值（观察到 `0x1`），
  立刻 EXC_BAD_ACCESS。详细分析见 `HOK-013-appendix-verification.md`。

## 参考

- `LocalDocs/HOKCrash/HOK-013-appendix-verification.md`：三轮验证命令与
  判定、已否决方案的完整证伪证据。
- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：`0x10e2146f8` 的
  writer 识别、反向 BFS 结论（NGR 自身 init 链不可达 writer）。注意
  HOK-011 最初报告写的 writer 函数入口是 `0x103a29b7c`；HOK-013 的 live
  验证发现真正的 writer 入口是 `0x103a29c60`（含 prologue），而
  `0x103a29b7c` 是相邻的另一个 Logger dispatch wrapper。这个差异不影响
  "writer 不可达" 的结论，但解释了为何"调 accessor" 方案会在 writer
  内部 fault。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：候选 E
  作为症状 workaround 的技术依据、`Scripts/hok007b_ngr_patch_runner.py`
  的 apply/revert 口径。
- `LocalDocs/HOKCrash/HOK-012-工具链与方法论归档.md`：deferred-install
  + SIGABRT 拦截 + sheet modal 拦截 + b.0 对话框 gate 的标准 live trace
  口径。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：HOK-013 的
  implementation single source（`pt_ngr_stub_*` 符号 + `pt_ngr_preheat_slot_once`
  及相关 helper）。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：HOK-013 的
  Swift 诊断入口 `recordHOK013PreheatDiagnostic(details:)`。
