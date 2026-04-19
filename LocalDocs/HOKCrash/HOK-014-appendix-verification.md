# HOK-014 附录：验证口径与常见误区

> 本文是 `HOK-014-alert-suppressor.md` 的附录，沉淀 HOK-014 + HOK-010
> 联合生效后的 live 验证口径、bundle gate 回归检查、以及容易误判的
> `blockingDialogs` 语义。
>
> **何时读**：
>
> - 需要真正跑一轮 HOK-014 live 验证；
> - 怀疑 alert 没被压制；
> - 需要在窗口 / 尺寸 metadata 上区分 sheet vs 主游戏窗口；
> - 需要判断"其它 bundle 是否被 swizzle 误伤"；
> - 日常阅读 HOK-014 主文档不必进入本文。
>
> **相关文档**：
>
> - 主文档：`HOK-014-alert-suppressor.md`；
> - 候选 E apply/revert：`HOK-007-二进制意图分析与callsite映射.md`；
> - b.0 对话框 gate 实现细节：`HOK-012-工具链与方法论归档.md`。

## 验证口径

### 前置条件

1. `python3 Scripts/hok007b_ngr_patch_runner.py --dry-run` 报
   `state=original`（候选 E 已 revert）。
2. `plutil -p .../com.tencent.ngr.plist | grep rootWorkDir` 报
   `rootWorkDir => 1`。
3. PlayCover 是本轮构建后重新启动的（不是旧会话）。

### 基线 live

```
python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install \
  --lldb-timeout 60 --settle-seconds 65 \
  --output build/hok-014-baseline.json
```

成功判据（同时满足）：

- `lldbStopObserved=False`（LLDB 捕获窗口内没有任何 crash stop）；
- `launch-events.jsonl` 里出现：
  - `event=hok013_ngr_slot_preheat status=primed`；
  - `event=hok014_ngr_alert_suppressor_installed status=installed`；
  - 至少一条 `event=hok014_ngr_alert_suppressed className=
    UIAlertController`；
- `~/Library/Logs/DiagnosticReports/NGR-*.ips` 没出现新文件；
- `blockingDialogWindows` 如果非空，每个 window 的 `ownerName=王者
  荣耀世界` 且 `boundsWidth >= 1024 && boundsHeight >= 512` —— 这
  代表是 NGR 自己的主游戏窗口，不是 sheet（sheet 通常 260×204）。

### 回归：其它 bundle 不受影响

任选一个已安装的非 NGR bundle 跑一次 `launch_app`，要求：

- 该 bundle 的 `launch-events.jsonl` **不出现**
  `hok014_ngr_alert_suppressor_installed` / `hok014_ngr_alert_suppressed`
  事件；
- 该 bundle 启动后 UIAlertController / NSAlert 行为与 HOK-014 之前
  完全一致。

快捷检查：

```
grep -l "hok014_ngr" \
  ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/*/launch-events.jsonl
```

应只有 `com.tencent.ngr` 的子目录出现。

### 回归：候选 E re-apply 时仍然安全

虽然 HOK-013 + HOK-014 替代了候选 E，但 HOK-014 的 swizzle 不依赖
候选 E 的状态。若因为某种原因重新 apply 候选 E（
`python3 Scripts/hok007b_ngr_patch_runner.py --apply`），HOK-014
仍然应正常压制 alert、app 仍然应跑到主游戏窗口。保留这个 verification
在"需要排障时手动跑"的清单里。

## 常见误区

- **"`blockingDialogs=1` 意味着没修好"**：错。b.0 gate 检测的是"是否
  还有 NGR owner 的 onscreen window"；app 启动成功后必然有主游戏窗
  口，所以 `blockingDialogs>=1` 是预期的。真正的 fail 信号是两个之一：
  (a) `lldbStopObserved=True` 且 `stopReason` 指向 crash；(b)
  窗口是典型 sheet 尺寸（260×204 / 600×200 等）且 `windowLayer=0`
  与 parent 关联。
- **"只改 `rootWorkDir` 就能让 app 不崩"**：错。HOK-010 的 `rootWorkDir=true`
  是必要条件之一，但 UE4 的 `Attempting to get the command line`
  fatal 与 cwd 无关，仍会触发 alert；必须配合 HOK-014 才能让用户无
  感。
- **"swizzle 了 presentViewController 就会破坏游戏内部的 alert"**：
  当前观察到 NGR 启动期**只有一条** alert（`QtsFileSystem Create
  Failed!!`），且只命中一次、不 retry。如果将来游戏内有合法 alert
  需要保留，要在 swizzle 里加白名单判断（按 title/message prefix）。
