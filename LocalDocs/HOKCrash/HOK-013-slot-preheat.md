# HOK-013: PlayTools 侧预热 `com.tencent.ngr` 的 `__common` slot `0x10e2146f8`

> 本文只沉淀 HOK-013 的**设计依据、实现口径、验证口径**。任务状态以
> `LocalDocs/HOKCrash/00-Dashboard.md` 为准；本文不出现 "DONE / TODO /
> 已落地 / 下一步" 等字样，也不写日期快照。

## 目的

让 `com.tencent.ngr` 在 PlayCover 下的 `__DATA,__common` 槽位
`0x10e2146f8` 在 NGR 主 image 的 dyld initializer `__init_offsets[1563]`
（reader `0x1047e83f4` → faulting callsite `0x10480df08`）跑起来之前被
预写入一个**合法**的对象指针；这样 reader 原 faulting 指令
`ldr x8, [x19]` 读到合法 vtable、`ldr x8, [x8, #0x10]; blr x8` 命中
no-op 虚函数，安全返回。**HOK-013 落地后，HOK-007B 的候选 E（磁盘字节
patch）可以从安全网降级为反向对照**。

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

HOK-013 单独兜住的 live 验证必须在 Dashboard 明确允许后进行；在那之
前候选 E 是默认安全网。revert 流程由 `Scripts/hok007b_ngr_patch_runner.py
--revert` 管，HOK-013 本身不碰磁盘 patch。

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

## 验证口径

### 第一轮：确认 preheat 真正触发、slot 被写成 stub 地址

前置：候选 E **保持 apply 状态**（防止 preheat 一旦失败就卡在原
faulting callsite；同时为 stub 写入的"不会被 deref"提供基线）。

```
# 重建 PlayTools xcframework
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh

# 重新 build & install PlayCover
./BuildScripts/build_and_install.sh

# deferred-install + SIGABRT 拦截的标准 live trace
python3 Scripts/hok006_ngr_lldb_runner.py \
  --watch-address 0x10e2146f8 --watch-size 8 \
  --defer-watchpoint-install \
  --lldb-timeout 60 --settle-seconds 65 \
  --skip-build-install \
  --pre-run-command 'breakpoint set --name "-[NSApplication runModalForWindow:]"' \
  --pre-run-command 'breakpoint set --name "-[NSWindow orderFront:]"' \
  --pre-run-command 'breakpoint set --name CGSOrderWindow' \
  --output build/hok-013-run1-report.json \
  --watchpoint-report build/hok-013-run1-watchpoint.json \
  --dyld-log build/hok-013-run1-dyld.log
```

判定：

- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/
  com.tencent.ngr/launch-events.jsonl` 里出现一条
  `event=hok013_ngr_slot_preheat`、`phase=write`、`status=primed`、
  `stubObject == slotAfter` 的事件；
- abort-stop transcript 里 `memory read -fx -s 8 -c 1 0x10e2146f8` 显示
  slot 值等于 stub object 的运行时地址（与事件 `slotAfter` 字段一致）；
- b.0 对话框 gate 不降级：`blockingDialogs=0`、`residualPIDsKilled=0`。

这一轮**允许** `faultingFrame` 指向候选 E 之后的下游 `.ips`
（如 `QtsFileSystem`）或 HOK-010 方向的 secondary fault——HOK-013 本身
不负责解决这些。

### 第二轮：确认 preheat 能独立兜住 reader（revert 候选 E）

```
python3 Scripts/hok007b_ngr_patch_runner.py --revert
python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install \
  --output build/hok-013-run2-baseline.json
```

判定：

- `faultingFrame` 不再指向 `0x10480df08` / `___lldb_unnamed_symbol272374`
  家族；
- `launch-events.jsonl` 里 HOK-013 的 `status=primed` 事件依然存在；
- HOK-004 指标保持通过（`session` 在 settle window 内持续存活、无新
  `NGR-*.ips` 针对 `0x10480df08`）。

若第二轮通过，HOK-013 在技术上已替代候选 E。运营上是否永久 revert 候选
E 由 Dashboard 统一决策。若第二轮失败（app 在 `0x10480df08` 再次崩溃），
立刻 re-apply 候选 E（`--apply`）恢复安全网，再回来复盘 stub 写入是否
真的落到了 slot（读 `launch-events.jsonl` 的 `slotAfter` 字段）。

### 第三轮：确认 bundle-scoped gate 不影响其它 bundle

选一个已安装的非 NGR bundle，跑一次 `launch_app`。要求：

- 该 bundle 的 `launch-events.jsonl` **不出现** `hok013_ngr_slot_preheat`
  事件；
- 该 bundle 的启动 / UI / 生命周期行为与 HOK-013 之前完全一致。

如果环境里没有方便的其它 bundle，至少通过：

```
grep -l hok013_ngr_slot_preheat \
  ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/*/launch-events.jsonl
```

确认只有 `com.tencent.ngr` 的子目录里出现过该事件。

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

### A: 调用 NGR Logger accessor（`0x107e5df10` / `0x107e5c964`）

设计灵感来自 "对齐 iOS 行为"——iOS 下某条外部 framework init 路径触达
`0x107e5c964` thunk → `0x103a29c60` writer → `str x0, [x8, #0x6f8]`，
把真 Logger singleton 指针写到 slot。

否决理由（live 证伪）：

- writer `0x103a29c60` 在 `+0x3c` 处 `bl 0x10481d7a8`，目标函数 `+0x8`
  处 `ldrh w9, [x0]`；writer 把自己的 `x0`（caller 传入的 this 指针）
  直接透传给子调用。
- 我们从 PlayTools constructor 调用这条链时，`x0` 保留任意残留值
  （观察到 `x0=0x1`），`ldrh w9, [x0]` 因 `x0=0x1` 不可读而 EXC_BAD_ACCESS。
- 要修复这条路径，必须伪造一个合法的 "category name" 对象或 config
  object 让 writer 的 deep-callee 消费——这比直接写 stub 复杂得多，
  而且 stub 的 reader 兜底已经足够。

## 参考

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
- `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`：deferred-install
  + SIGABRT 拦截 + sheet modal 拦截 + b.0 对话框 gate 的标准 live trace
  口径。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：HOK-013 的
  implementation single source（`pt_ngr_stub_*` 符号 + `pt_ngr_preheat_slot_once`
  及相关 helper）。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：HOK-013 的
  Swift 诊断入口 `recordHOK013PreheatDiagnostic(details:)`。
