# HOK-013 附录：验证口径与已否决方案

> 本文是 `HOK-013-slot-preheat.md` 的附录，沉淀三轮验证的具体命令 / 判定、
> 以及曾被考虑但被 live 证伪的替代方案。
>
> **何时读**：
>
> - 需要重新跑 HOK-013 验证（例如 PlayTools 改动后回归、怀疑 preheat
>   没落地、或要确认 bundle gate 未溢出到其它 app）时读；
> - 需要回顾"为什么不直接调 NGR 自己的 Logger accessor"以避免重蹈
>   覆辙时读；
> - 日常阅读 HOK-013 主文档不必进入本文。
>
> **相关文档**：
>
> - 主文档：`HOK-013-slot-preheat.md`；
> - LLDB watchpoint / b.0 gate 工具链：`HOK-012-工具链与方法论归档.md`；
> - 候选 E apply/revert 口径：`HOK-007-二进制意图分析与callsite映射.md`。

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
