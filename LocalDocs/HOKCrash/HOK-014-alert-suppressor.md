# HOK-014: PlayTools 侧压制 `com.tencent.ngr` 启动期 UIAlertController sheet

> 本文只沉淀 HOK-014（顺带 HOK-010）的**设计依据、实现口径、验证口径**。
> 任务状态以 `LocalDocs/HOKCrash/00-Dashboard.md` 为准；本文不出现
> "DONE / TODO / 已落地 / 下一步" 等字样，也不写日期快照。

## 目的

在 HOK-013 让 NGR reader `ldr x8, [x19]` 安全跑过之后，app 能进入主循
环，但 UE4 的 iOS bootstrap 会弹出 `UIAlertController` → UIKitMac
bridge → `NSAlert` sheet modal，把 UI 线程挂在 sheet 上阻塞可见表
现。HOK-014 的目标是**在只改动 PlayCover/PlayTools 层的前提下，让这
个 alert 不出现**，从而让 app 保持主游戏窗口可见、不崩溃。

## 背景：为什么 HOK-013 之后还会弹 alert

观察 `build/hok-013-run8-dyld.log` 可以看到 UE4 在进入主循环之前会打
出 3 条连续的 fatal log：

```
[UE4] Fatal error: [File:Unknown] [Line: 34]
Attempting to get the command line but it hasn't been initialized yet.
```

这不是真正的进程终止——UE4 iOS 在这条 fatal 路径上走的是 **"log fatal
+ show dialog + continue"** 模式，随后 `Checking for command line in
.../ue4commandline.txt... FOUND!` 正常完成 command line 的 lazy init。
真正让用户看到的阻塞是 fatal 背后 UE4 iOS 代码调用的
`UIAlertController`：

- 构造点：`NGR + 0x103a215a0`，在 `+[UIAlertController
  alertControllerWithTitle:message:preferredStyle:]` 出现在 backtrace
  frame #0。
- 内容：`title="Message"` / `message="QtsFileSystem Create Failed!!"`
  （本轮 live `hok014_ngr_alert_suppressed` 事件直接读出的）。
- Present：通过 `-[UIViewController presentViewController:animated:
  completion:]` 投递到主 VC；UIKitMac bridge 把它转换成 `NSAlert`
  sheet modal、`-[NSWindow orderFront:]` 订到主 parent window。

sheet 一旦 order front，UI 线程进入 sheet modal session 直到用户点
"OK / Close"。在 automation 场景下 LLDB 捕获窗口结束时会看到
`blockingDialogs=2`（sheet + parent window）、`residualPIDsKilled=1`。

### 为什么 HOK-010 把 `rootWorkDir` 打开并不够

HOK-010 的原假设是："把 `rootWorkDir` 从 `disableForMinimalStartupCompat(...)`
摘除、让 NGR 进程的 cwd 改回 `/`、UE4 `QtsFileSystem` 的相对路径就能
解析成功、fatal 就不会触发"。live 测试结果证伪这条假设：

- 在 HOK-010 生效、plist `rootWorkDir=1`、NGR 进程 cwd 实际为 `/` 的
  情况下，UE4 仍然会打 3 条 `Fatal error ... Attempting to get the
  command line but it hasn't been initialized yet.`，随后弹
  `QtsFileSystem Create Failed!!` alert。
- 原因：`Attempting to get the command line` fatal 是 UE4 iOS bootstrap
  里 command-line 被提前 read 的**顺序错误**，与 cwd **无关**；
  `QtsFileSystem` fatal 也与 cwd 无关，而与 UE4 一些 platform 查表项
  （base-dir-type / bytes search path 等）在 iOS 设定下的 fallback
  行为有关。改 cwd 不会改变这两条 fatal 的触发条件。

HOK-010 仍然是必要的、但作用不在于消除 fatal——它的作用是让 UE4 在主
循环里的**其它**相对路径解析（cooked data / uproject / TP 目录 /
bytes search path）能按 iOS 语义工作，否则主游戏窗口后续的逻辑会
hit 更多 fallback 分支。因此 HOK-010 与 HOK-014 是 **两条正交的修
复**，联合使用才能让 app 启动到主游戏窗口。

## 设计决策

### D1：干预层次

**选 PlayTools 层 swizzle** `-[UIViewController presentViewController:
animated:completion:]`，而不是：

- ❌ swizzle `+[UIAlertController alertControllerWithTitle:message:
  preferredStyle:]`：返回 nil 会让 caller 对 nil 调方法崩，也要处理
  后续 `addAction:` 等。
- ❌ swizzle `-[NSAlert runModal]` / `-[NSAlert
  beginSheetModalForWindow:completionHandler:]`：这是 UIKitMac
  bridge 之后的 AppKit 层，swizzle 点更深但对 bundle 的影响面更
  大（可能误伤 PlayCover host 自己的 sheet）；而且 UIKitMac 内部
  实现细节（`UINSAlert`）不稳定、可能随 macOS 版本变化。
- ❌ 直接 NOP 掉 UE4 在 `0x103a215a0` 那个函数的入口：这是 **app
  二进制 patch**，违反"只动 PlayCover/PlayTools 层"的约束。
- ❌ hook UE4 `FIOSPlatformMisc::MessageBox` 等 UE 层 symbol：NGR
  这个二进制是 stripped release 版，UE symbol 全部 anonymous，hook
  不到稳定名字。

UIKit 的 `presentViewController:` 是 **iOS 原生 API、ABI 稳定、语义
明确**：iOS / macOS UIKitMac 都保证"present 一个 VC 一定经过这个 SEL"。
swizzle 它对 UIAlertController 做特例处理、对其它 VC 透传，语义上
等价于 "每次弹 UIAlertController 都被秒 dismiss"，不影响其它 VC 的
正常 present。

### D2：compensation — 调 completion

iOS 约定：`presentViewController:animated:completion:` 的
`completion` block 在 present 完成后被调用。我们跳过实际 present，
但为了不破坏 caller 的期望（有些代码会在 completion 里做清理），仍然
同步调一次 `completion(nil)`（如果非 nil）。

UE4 的 alert caller（`NGR + 0x103a215a0`）看起来 **没有传 completion
block**（只调 present + 返回），所以 completion 即使是 nil 也不影响
其逻辑。

### D3：bundle-scoped gate

复用 HOK-013 的 `pt_ngr_should_preheat_slot()`，保证 swizzle 只对
`com.tencent.ngr` 安装。其它 bundle 完全不走 swizzle 路径、原 IMP
保持不变。

`dispatch_once` 保证安装是幂等的；即使 PlayTools constructor 被某种
奇怪的机制触发两次（实际不会），也只 swizzle 一次。

### D4：保留 swizzle 出错的 fallback

`class_getInstanceMethod` / `method_getImplementation` / `method_setImplementation`
理论上都会成功，但写保守代码仍然有回退：

- `NSClassFromString(@"UIViewController") == Nil` → `NSLog` + return，
  不 abort；原 `presentViewController:` 行为保持。
- `Method == NULL` → 同上，return。
- swizzle 成功后，`pt_ngr_original_presentViewController_IMP` 记录原
  IMP，swizzled 函数内部对非 UIAlertController 的 VC 透传原 IMP。

### D5：诊断事件

- `hok014_ngr_alert_suppressor_installed`：swizzle 安装成功。
- `hok014_ngr_alert_suppressed`：每次压制一个 UIAlertController
  present，details 含 `className` / `title` / `message` / `animated`。

两者都通过 `PlayCover.swift` 的 `@objc static func
recordHOK014*Diagnostic(details:)` 落到
`~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/
com.tencent.ngr/launch-events.jsonl`，供事后 audit。

### D6：plist 与 PlayCover GUI 内存一致性约束

HOK-010 把 `rootWorkDir` 从 compat 强制关闭摘除之后，runtime 端读
`rootWorkDir` 等于 plist 值。但 PlayCover GUI host 端也持有一个
内存中的 `AppSettingsData`；**GUI 在启动 app 时会调
`settings.sync()`，触发 `didSet → encode()` 把 host 内存回写 plist**。
因此操作顺序很重要：

1. 先 `osascript -e 'tell application "PlayCover" to quit'` 退出 GUI；
2. `plutil -replace rootWorkDir -bool YES ...` 修正 plist；
3. 重启 PlayCover，让它以"plist 为准"重新 decode。

否则 step 2 会被 GUI 的 stale 内存在 step 3（或下一次启动 app）时覆盖。

推荐做法：把"设置 `rootWorkDir=true`"这件事改成走 MCP
`update_app_settings` 工具（它会同步更新 GUI 内存 + plist），或
在 host `AppSettingsData` 里加一个 minimal-compat-specific 的
post-decode 规则确保 NGR 的 `rootWorkDir` 永远是 true。本轮暂用
"重启 PlayCover" 的轻量方案。

## 实现位置

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：
  - `pt_ngr_original_presentViewController_IMP`（静态 IMP 指针）
  - `pt_ngr_present_imp_t`（原 IMP 的类型别名）
  - `pt_ngr_swizzled_presentViewController(self, _cmd, vc, animated, completion)`：
    检测 `[vc isKindOfClass:UIAlertController]`，命中则调
    `completion(nil)` + 记录事件 + return；否则透传原 IMP。
  - `pt_ngr_install_alert_suppressor_once()`：bundle gate +
    `method_setImplementation` swizzle + 记录 install 事件。
  - constructor `initialize(void)` 的第二行（紧跟 HOK-013 preheat）
    调用 `pt_ngr_install_alert_suppressor_once();`。
  - 新增 `#import <objc/runtime.h>`。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：
  - `@objc static public func recordHOK014InstallDiagnostic(details:)`。
  - `@objc static public func recordHOK014AlertSuppressed(details:)`。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：
  - `@objc lazy var rootWorkDir = settingsData.rootWorkDir`（HOK-010：
    摘出 `disableForMinimalStartupCompat(...)`）。

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

## 非目标 / 边界

- HOK-014 **只**压制 `UIAlertController`。其它 modal presentation
  形式（比如 `UIActivityViewController`、`UIPrintInteractionController`）
  **不**被压制——NGR 启动期没有这类 modal。
- HOK-014 **不替代** HOK-013。HOK-013 仍然负责让 reader `ldr x8,
  [x19]` 本身不崩；HOK-014 只解决 reader 安全穿越之后、主循环里 UE4
  构造 alert 的 UI 表现问题。
- HOK-014 **不模拟** UIAlertController 的 UI 交互。被压制的 alert
  不会弹任何替代 UI；用户感知是"啥都没有、游戏直接跑"。如果将来发现
  某个 alert 实际需要用户回应（例如"是否同意协议"），需要在 swizzle
  里按 title/message 加白名单特例。
- HOK-014 **不影响** PlayCover GUI 自己的 UIAlertController。
  PlayCover GUI 运行在 PlayCover host 进程里，不会加载 PlayTools；
  swizzle 只在 NGR 进程内生效。

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

## 参考

- `LocalDocs/HOKCrash/HOK-013-slot-preheat.md`：HOK-013 的实现口径、
  bundle gate 的复用入口、stub object 布局。
- `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`：b.0 对话框
  检测 + 残留进程强杀 + 污染 gate 的标准 live trace 口径；HOK-014
  的 live 验证重用其中的 `blockingDialogWindows` 字段但对其语义作
  窗口大小判定以区分"sheet vs 主游戏窗口"。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：HOK-013 +
  HOK-014 的实现 single source。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：
  HOK-010 的 `rootWorkDir = settingsData.rootWorkDir` 改动。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：三个
  `@objc static func recordHOK013*/HOK014*Diagnostic(details:)`。
- `Scripts/hok007b_ngr_patch_runner.py`：候选 E 的 apply/revert 单一
  来源；HOK-014 落地后默认状态是 `--revert` / `state=original`。
