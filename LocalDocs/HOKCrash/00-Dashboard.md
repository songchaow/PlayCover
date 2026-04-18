## HOKCrash Dashboard

> **单一来源规则**：`com.tencent.ngr`（`王者荣耀世界`）启动崩溃问题的
> 优先级、主线、TODO、验证口径只在本文维护；长日志、历史推理细节、
> 一次性 live 基线全部下沉到子文档，主文档始终保持可快速通读。

## 最终目标

- 让 `com.tencent.ngr` 在 PlayCover 中**稳定启动并持续存活**，不再出现
  当前这类启动期秒崩。
- **不允许出现用户可见的报错 / 错误对话框 / 阻塞 UI**。具体包括：
  - **没有任何**由 `UIAlertController` / `NSAlert` sheet modal 形式弹出
    的 error dialog（无论被谁最终接住——用户侧看不到即可）。
  - **没有任何** UE4 `[UE4] Fatal error: ...` 级别的事件写进 stderr /
    `launch-events.jsonl` / `.ips`；`Fatal error` / `assertion failed`
    / `crash` 等关键字出现在任何运行期日志里都是硬 fail。
  - 进程必须进入**真正的游戏主循环**（CPU ≥ 5% 持续、RSS 增长到 UE4
    典型量级、Metal frame 推进），不能停在"进程活着但 GameThread 已退
    出"的僵尸态。
- 当前**不要求**为该 app 保留 `metal capture` / `shader source replacement`；
  兼容启动优先于截帧能力。
- 默认先走**最小、可逆、app-scoped** 的 PlayCover/PlayTools 兼容修复；
  只有这条线证伪后，才考虑升级到 app 二进制意图分析与可逆 patch。
- 日常构建、验证、证据收集必须能由 agent 独立完成；任何需要用户介入
  的步骤，都要先得到用户确认。

## 全局约束

- 对 `com.tencent.ngr` 的修复默认**按 bundle 精准生效**，不扩大为全局
  行为改动。
- 对该 app 的默认兼容配置把 `metal capture` / `startup injection` /
  `shader replacement` / `playChain` 视为非必要能力。
- 默认优先级：**对齐 iOS 语义 / 让 iOS 预置的行为在 macOS 也能跑** →
  **PlayTools 最小 bundle-scoped 兼容改动** → **LLDB / faulting
  instruction 归因** → **app 二进制可逆 patch（作为兜底；当前已不
  依赖）**。
- 不允许把"用户手工登录 / 手工点 UI / 手工看窗口表现"作为日常 gate。
- 主文档只保留当前主线、TODO、决策信息和高频复用经验；历史推理、长
  日志、反复试错过程必须下沉到子文档。

## 主线任务

- **当前状态（距离最终目标还差关键一步）**：candidate E 已 revert、
  HOK-013/010/014 让 app **进程不崩、窗口存在**、60s 长跑无新
  `NGR-*.ips`。但深入观察证明 app **没有真正活着**：
  - UE4 在 `Checking for command line in ue4commandline.txt ... FOUND!`
    **之前** 就有代码读 `FCommandLine::Get()`，在 command line 未初始
    化时 UE4 打出 3 条 `[UE4] Fatal error: [File:Unknown] [Line: 34]
    Attempting to get the command line but it hasn't been initialized
    yet.`。
  - UE4 fatal handler 接着：(a) 构造 `UIAlertController` 标题
    `"Message"` 消息 `"QtsFileSystem Create Failed!!"`，（iOS 上会
    sheet modal 挂住 UI 线程；macOS 上被 HOK-014 压制成 `completion(nil)`）；
    (b) set `GIsRequestingExit=true`，让 UE4 GameThread 自然退出 tick
    loop。
  - 现象：进程 state=`S`、~2% CPU、RSS 333MB（UE4 真正跑起来应 ≥1GB）、
    线程 10 个全部 sleep、主窗口 bounds `(72, -1007, 1478, 859)` 完全
    在可见屏幕之外（主屏 `frame=(0,0,1728,1117)`），`kCGWindowMemoryUsage=2288
    B` 说明没有实际内容被绘制——**僵尸存活状态**。
  - HOK-014 只消除了"用户看到错误对话框"这一步，但 UE4 主动 exit 的
    根因没被处理。**这违反最终目标里"没有 Fatal / 没有错误对话框"的
    硬性要求**。

- **当前兜底链路**（不再是闭合方案，是达到"根因修复"前的临时网）：
  1. `HOK-013`：PlayTools constructor 最早时刻为 `0x10e2146f8` 写入
     stub object，让 NGR dyld initializer 里 `ldr x8, [x19]; ldr x8,
     [x8, #0x10]; blr x8` reader 链安全 no-op。（`HOK-013-slot-preheat.md`）
  2. `HOK-010`：`PlaySettings.rootWorkDir` 从
     `disableForMinimalStartupCompat(...)` 摘除 + `PlayApp.launch()`
     self-heal 强制 NGR 的 `rootWorkDir=true`，让 UE4 相对路径以 `/`
     为基准。（`HOK-014-alert-suppressor.md` 合并说明）
  3. `HOK-014`：PlayTools swizzle `-[UIViewController
     presentViewController:animated:completion:]`，对 `UIAlertController`
     实例直接调 `completion(nil)` 返回。**HOK-015 落地后应降级为安全
     网**，正常情况下这个 swizzle 一次都不该触发。（`HOK-014-alert-suppressor.md`）

  HOK-007B 候选 E（NGR app 二进制 4 字节 patch）已 **revert**，HOK-013
  已替代它作为 slot 预热兜底；不再纳入日常链路。

- **当前已知事实**（维护仍需要的几条）：
  - `FCommandLine::Get()` early-read fatal 的 marker 字符串：
    `"Attempting to get the command line but it hasn't been initialized
    yet."`（在 NGR 二进制里常量存在，HOK-015-A 的扫描入口）。UE4 在
    `Checking for command line in ue4commandline.txt ... FOUND!` **之前**
    约 141ms 里有代码命中这条 fatal 3 次——早读者候选：`GCloudCore
    addObserver` / `PluginReportLifecycle init` / 其它 SDK static
    initializer。
  - Fatal 触发 UE4 `UIAlertController(title="Message",
    message="QtsFileSystem Create Failed!!")` + set
    `GIsRequestingExit=true`；后者让 UE4 GameThread 自然 exit tick
    loop，解释了当前"进程活着但不干活"的僵尸态。
  - `0x10e2146f8` 的 writer 是 `0x103a29c60`（不是 HOK-011 最初标的
    `0x103a29b7c`，那是相邻的 Logger dispatch wrapper）；NGR 自身
    `__init_offsets` 反向 BFS 不可达。HOK-013 之后**不再依赖识别实际
    writer** 就能让 reader 安全跨过。
  - `effectiveLaunchEnvironment` 在 host 侧有**两份实现**（
    `PlayCover/Model/PlayApp.swift` GUI 路径 +
    `PlayCoverMCP/HostServices/Launch/LaunchService.swift` MCP 路径）；
    对 `minimalStartupCompatBundleIdentifiers` 的任何 env 改动必须
    同时写两份。`minimalStartupCompatDiagnosticEnvironment` 的
    `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 已两侧对齐。
  - PlayCover GUI 端 `AppSettings.settings` 有 `didSet → encode()`，
    启动 app 时 `settings.sync()` 会触发写回 plist；HOK-010 已在
    `PlayApp.launch()` 里对 NGR self-heal
    `settings.settings.rootWorkDir=true`，避免 stale 内存把 plist
    改回 false。
  - 候选 E patch runner：`Scripts/hok007b_ngr_patch_runner.py`，当前
    `state=original`；`build/hok-007b-backups/*.bin` 保留作为历史备
    份，日常不 apply。

- **当前主线**：`HOK-015`——在 PlayTools 层消除 **UE4 cmdline early-read
  fatal** 的根因。方案架构与 HOK-013 一致（PlayTools `__attribute__((constructor))`
  最早时刻预写 NGR `__common` 槽位），目标是让 `FCommandLine::Get()` 在
  任意早期调用都读到**已初始化的合法 cmdline**，从而：
  - UE4 `Fatal error` 从不触发；
  - UE4 不构造 `UIAlertController`（HOK-014 swizzle 变成纯冷备）；
  - `GIsRequestingExit` 保持 false，GameThread 正常跑进主 tick loop；
  - app 真正"活着"，窗口被 UE4 正常摆位、RSS/CPU 达到 UE4 游戏典型
    量级。

  **约束**：完全在 PlayCover/PlayTools 层、bundle-scoped 到
  `com.tencent.ngr`、不动 NGR app 二进制。

- **当前卡点**：无。

- **下一步默认规划**：
  1. `HOK-015-A`（静态定位）：复用 `Scripts/hok011_ngr_common_init_chain.py`
     风格的扫描器，在 NGR 二进制里定位：
     - `"Attempting to get the command line but it hasn't been
       initialized yet"` 字符串的 xref → UE4 `FCommandLine::Get` 的
       fatal 分支；
     - 相邻 `ldrb` / `strb` 序列指向的 `bInitialized` bool slot；
     - cmdline char buffer 的起始地址 + 容量；
     输出 `build/hok-015-cmdline-slots.json`。
  2. `HOK-015-B`（PlayTools 落地）：`PlayLoader.m` 新增
     `pt_ngr_preseed_cmdline_once()`，在 `pt_ngr_preheat_slot_once()`
     之后、`pt_ngr_install_alert_suppressor_once()` 之前调用；
     `dispatch_once` 幂等；bundle gate 复用 `pt_ngr_should_preheat_slot()`；
     预写内容 = `"../../../NGR/NGR.uproject"` 与 `bInitialized=true`；
     诊断事件 `hok015_ngr_cmdline_preseed`。
  3. `HOK-015-C`（live 验证）判据（全部满足才视为闭合）：
     - `launch-events.jsonl` 出现 `hok015_ngr_cmdline_preseed status=primed`；
     - 子进程 stderr / dyld log 里**不再出现** `Attempting to get the
       command line but it hasn't been initialized yet` / `Fatal error:
       [File:Unknown]`；
     - `hok014_ngr_alert_suppressed` 事件次数 = **0**；
     - 自由启动 60s 后：进程 `%CPU ≥ 5%`、RSS ≥ 800MB、线程数 ≥ 20；
     - 主窗口 bounds 与主屏 frame 有非空交集（窗口在可见区域内）；
     - 无新 `NGR-*.ips`。
  4. 只有 HOK-015 全部通过，才把 HOK-014 正式降级为安全网（保留代码、
     保留事件入口，但日常观测期望"一次都不触发"）。
  5. （可选后续）`HOK-008`：HOK-015 闭合后再把完整验证链路固化成单
     脚本。

## 构建与验证

### 日常默认方法

- **PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1
  ./BuildScripts/sync_playtools_xcframework.sh`。
- **主 app / 注入 / 安装链路改动**：`./BuildScripts/build_and_install.sh`。
- **目标 app 配置**：优先用 `get_app_settings` / `update_app_settings`
  MCP；`com.tencent.ngr` 的目标状态是：`metalCaptureEnabled=false` /
  `injectMetalCaptureEnvironment=false` /
  `shaderSourceReplacementEnabled=false` / `playChain=false` /
  `rootWorkDir=true`。
- **Live 启动验证**：`launch_app` → 固定等待 → `create_session` /
  `list_sessions`。pass 条件：session 不秒断、settle window 内持续存
  活、`launch-events.jsonl` 有完整 compat 证据、无新同类 `NGR-*.ips`。
- **需要细粒度定位时**：`launch_app_with_lldb` + `Scripts/hok006_ngr_lldb_runner.py`；
  方法论与常用 CLI 见 `LocalDocs/HOKCrash/HOK-012-工具链与方法论归档.md`（当前
  日常启动不需要读取）。
- **离线二进制分析**：
  - `Scripts/hok007_ngr_callsite_mapper.py`：faulting callsite 一致性
    映射（当前没有未解的 faulting callsite）。
  - `Scripts/hok011_ngr_common_init_chain.py`：基于 `__init_offsets`
    的 `__common` 槽位 writer 扫描，`--target-address` 可推广。

### 证据收集点

- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`

关键事件：`playcover_startup_compat_profile_applied` /
`playcover_*_skipped` / `playcover_working_directory_changed`
（HOK-010 后应为 `_changed` 不是 `_preserved`）/
`hok013_ngr_slot_preheat status=primed` /
`hok014_ngr_alert_suppressor_installed` /
`hok014_ngr_alert_suppressed`。

### 需要用户确认后才能继续的事项

- 任何需要用户账号、验证码、手工登录、手工进游戏或手工点击复杂 UI
  的验证。
- 任何依赖外部下载、替换新 app 构建、或需要用户提供额外私有材料的
  步骤。
- 任何必须由用户亲自观察窗口视觉表现、而 agent 无法以 session /
  diagnostics / crash evidence 替代判断的步骤。

## agent 工作流程

1. 读取本文档，先理解**当前主线**与 **TODO** 最新状态。
2. 按优先级从高到低选取未完成任务执行；每次可以做一个或多个任务，只
   要每一项都能"构建/验证/证据闭环"独立收尾且改动不互相冲突。耦合
   的几项（共享磁盘 patch 状态、共享 live 证据）必须合并成一个更大
   的变更单元完成，不要半路切换。
3. 若任务已阻塞（需人工/外部协助），跳过、继续做其它未阻塞的高优先
   级任务；严禁把阻塞任务与无关任务混在同一轮。
4. 若任务过大，先拆子任务追加到 TODO 原位置再推进。
5. 新功能尽量靠 skills 或 MCP 做**实际测试**；受环境限制时至少做
   模拟性 / 离线 / 最小样本测试。
6. 每轮执行完必须整理本文档：删除过时信息，更新主线 / TODO / 踩坑 /
   优先级；**主文档保持简洁，不能只追加不整理**。
   - **主文档 vs 子文档分工**：局部细节、大段日志、方法论细节下沉到
     对应子文档；主文档只保留当前主线、TODO、决策信息、高频复用经验。
   - **任务状态只在本文档维护**：子文档**不允许**出现
     "DONE / TODO / DEFERRED / BLOCKED / 已完成 / 已落地 / 待执行 /
     下一步 / 结论 / handoff" 这类任务状态或进度字样。
   - **子文档不写时间戳快照**：引用某次 live run 改为指向 `build/`
     下的结构化报告文件名。
7. 复盘技术路线；除最终目标不变，中间方案可随新发现调整。
8. 收尾执行 `git commit`；一轮多条 TODO 的 commit 信息要把每条的证据
   指向清楚列出，不要合成一行。

## 所有任务 TODO 状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| HOK-001 | DONE | 复现 NGR 启动崩溃并固定第一轮基线证据 | — |
| HOK-002 | DONE | 落地 app-scoped 最小兼容启动 gate（跳过 `MetalCapture` / library hook；压低 `PlayChain` 早期副作用） | — |
| HOK-003 | DONE | 补齐最小兼容档 settings 的 MCP 自动化读写/reset 能力 | — |
| HOK-004 | DONE | 固化 `10s settle window` 启动闭环与失败非零退出语义（`Scripts/hok004_ngr_startup_runner.py`） | `HOK-004-启动验证与settle-window.md` |
| HOK-005A/B/C/D | DONE | DiscordIPC / PlayInput / PlayScreen app-scoped skip；AKInterface 1.0s 延迟 | `HOK-005-深层bootstrap分层最小化.md` |
| HOK-006 | DONE | LLDB 自动化入口 + 结构化证据链；崩点固定在 NGR early initializer 路径 | `HOK-006-LLDB归因与crash-window压缩.md`（按需） |
| HOK-007A | DONE | `0x10480df08` faulting callsite 的 LLDB / `.ips` / bytes / file offset 一致性映射 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-007B | DONE | 候选 E（`ldr x8,[x19]` → `b 0x10480df24`）设计 + apply/revert runner；当前已 **revert**，HOK-013/014 替代它作为兜底 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-011 | DONE | 离线定位 `0x10e2146f8` writer 不可达 NGR 自身 `__init_offsets`；真 writer 入口修正为 `0x103a29c60`；ObjC 重复类警告识别 | `HOK-011-静态初始化链分析.md`（按需） |
| HOK-012-A/B/C（全系列） | DONE | LLDB 自动化工具链：诊断 env 注入 + `LLDBRunOptions` 扩展 + legacy/pre-run/deferred-install watchpoint + SIGABRT 拦截 + sheet modal 拦截 + b.0 对话框污染 gate + teardownTimeout 参数化 + abort-stop handler 的 `memory read -fx` / `kill\nquit` 硬性规则。当前日常启动链路**不依赖**这些工具，但未来追查新 slot / 新 fatal-before-modal 问题时仍是主干工具链 | `HOK-012-工具链与方法论归档.md`（按需） |
| HOK-013 | DONE | PlayTools constructor 最早时刻为 NGR 写入 stub object 地址到 `0x10e2146f8`；bundle-scoped + slide 安全阀 + `dispatch_once` 幂等；诊断事件 `hok013_ngr_slot_preheat`。消除"reader 读 null deref"层面的崩溃，但不治 UE4 cmdline fatal / UIAlertController 构造 | `HOK-013-slot-preheat.md` |
| HOK-014 | DONE（HOK-015 闭合后降级为安全网） | PlayTools 层 swizzle `-[UIViewController presentViewController:animated:completion:]`，对 `UIAlertController` 直接 `completion(nil)` 返回。**消除 alert UI 表现但不治本**——UE4 fatal 仍然发生、`GIsRequestingExit` 仍被 set、GameThread 仍退出。HOK-015 落地后预期该 swizzle 一次都不触发 | `HOK-014-alert-suppressor.md` |
| HOK-010 | DONE | `rootWorkDir` 从 `disableForMinimalStartupCompat(...)` 摘除；GUI host 端 self-healing 保证 plist 不被 stale 内存覆盖 | `HOK-014-alert-suppressor.md`（合并说明） |
| HOK-015 | TODO（当前主线） | 在 PlayTools 层预写 NGR `FCommandLine` 存储（`bInitialized=true` + cmdline char buffer = `"../../../NGR/NGR.uproject"`），消除 UE4 early-read fatal 根因。拆分为 HOK-015-A（静态定位 + `build/hok-015-cmdline-slots.json`）/ HOK-015-B（`pt_ngr_preseed_cmdline_once()`）/ HOK-015-C（live 验证：fatal/alert 次数 = 0 + 僵尸态指标消除） | 待建 `HOK-015-cmdline-preseed.md` |
| HOK-007C | DEFERRED | 下游 crash 的离线映射 + 可逆 patch；HOK-013/014 之后未观察到新 faulting callsite，当前无触发动机 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-008 | TODO | 把"revert 候选 E → `rootWorkDir=1` → 启动 → 证据采集 → pass 判定"固化成单脚本；替代现在的人工组合 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号 / 手工 UI 的后续验证（登录 / 进游戏行为）；执行前必须得到用户确认 | 不执行 |

## 高频复用经验（当前仍适用的）

- **"进程不崩 + 窗口存在"不等于"最终目标达成"**。必须同时检查：
  `launch-events.jsonl` 里**零** `Fatal` / 零 `hok014_ngr_alert_suppressed`；
  进程 `%CPU` 持续 ≥5%、`RSS` 长到 UE4 典型量级；主窗口 bounds 与主
  屏 frame 有非空交集。
- **"UIAlertController 被 HOK-014 压制"是症状不是治愈**。HOK-014 只让
  alert 不可见，UE4 fatal 仍已触发、`GIsRequestingExit=true`、GameThread
  已退出；进程表现为"僵尸存活"。治本仍在 HOK-015。
- **`playcover_launch_complete` 不等于 app 已安全启动**；NGR 会在该
  事件之后进入 UE4 bootstrap、可能进入 fatal 路径。
- **`session briefly ready → disconnected`** 是比"窗口看起来闪退"更
  稳定的 automation 判据，但也不足以判定"app 活着"——需要配合上面
  CPU/RSS/窗口可见性指标。
- **`playcover_startup_compat_profile_applied` / `*_skipped`** 事件
  是判断最小兼容 gate 真正命中的首选证据，不用主观猜测。
- **`effectiveLaunchEnvironment` 两侧对齐**：`PlayApp.swift` 与
  `LaunchService.swift` 必须同步维护 `minimalStartupCompatDiagnosticEnvironment`。
- **PlayCover GUI 内存 vs plist 一致性**：`AppSettings.settings` 的
  `didSet` 会 encode 回 plist；改 `com.tencent.ngr` 的 settings 不要
  只用 `plutil -replace`（会被下一次 GUI launch 覆盖），要走
  `update_app_settings` MCP 或依赖 `PlayApp.launch()` 的 self-heal。
- **`.ips` 的 image offset 交叉验证**：`usedImage.base` + triggered
  thread `frames[0].imageOffset` + LLDB `faultPc` 三者应一致。
- **`launch_app_with_lldb` headless 结构化证据**：消费 `lldb.stopReason`
  / `lldb.faultingFrame` / `lldb.faultingInstruction` / `lldb.backtrace`
  / `lldb.blockingDialogWindows` / `lldb.watchpointHits`，不要把完整
  transcript 当人工日志用。`timedOut=true` + `didStop=true` + 完整
  fault 字段 = 证据有效。
- **`blockingDialogs >= 1` 不等于回归，但也不能立即判定为 pass**：b.0
  gate 对"NGR onscreen window"本身也会报 1。需要同时看：window bounds
  是否在主屏 frame 内（`Y + H > 0` 且 `Y < screen.height`）、
  `kCGWindowMemoryUsage` 是否非 trivial（合法渲染窗口通常 >1MB）。
- **LLDB 追 `__common` slot 写入的 watchpoint 方法论**：见
  `HOK-012-工具链与方法论归档.md`；当前日常启动不需要，仅在定位新
  slot / writer 不可达问题时读取。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、
  TODO 与默认验证口径。

### 当前兜底链路（修改这些代码/文件**需要同步更新本 Dashboard**）

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的
  dyld constructor / interpose 入口；HOK-013 stub 预写 + HOK-014
  UIAlertController swizzle 都在这里。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：PlayTools
  启动顺序、compat 诊断事件、HOK-013/014 的 Swift 事件入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime
  settings 读取；`minimalStartupCompatBundleIds`、`disableForMinimalStartupCompat(...)`、
  HOK-010 后的 `rootWorkDir` 透传。
- `PlayCover/Model/PlayApp.swift`：GUI 启动环境、`effectiveLaunchEnvironment()`、
  `minimalStartupCompatBundleIdentifiers`、HOK-010 self-heal。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 启动环
  境、`minimalStartupCompatDiagnosticEnvironment`、`LLDBRunOptions`
  定义（HOK-012 工具链）。
- `LocalDocs/HOKCrash/HOK-013-slot-preheat.md`：HOK-013 方案、stub
  布局、slide 计算、bundle gate、验证口径。
- `LocalDocs/HOKCrash/HOK-014-alert-suppressor.md`：HOK-014 swizzle
  方案、HOK-010 决策依据、plist/GUI 一致性约束、常见误区。
- `LocalDocs/HOKCrash/HOK-015-cmdline-preseed.md`：**当前主线**
  HOK-015 的方案分析、`bInitialized` + cmdline buffer 静态定位口径、
  预写原子性与幂等约束、三轮 live 验证判据（zero-fatal / zero-alert
  / 进程活跃度指标 / 窗口可见性）。

### 按需读取（与当前主线无直接关系，出问题再翻）

> 以下子文档**不强制读取**；只有当前排查内容明确涉及它们时才需要进入。

- `LocalDocs/HOKCrash/HOK-004-启动验证与settle-window.md`：HOK-004
  runner 的 settle window 口径与 raw settings 模板。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：HOK-005 四
  层 app-scoped skip 的代码落点与诊断事件语义。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：HOK-006
  自动化入口、证据口径、31 帧 backtrace。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：HOK-007A
  离线 callsite mapper、HOK-007B 候选 E 的 apply/revert 口径与回滚。
- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：HOK-011 扫描器
  设计、反向 call graph 方法论、writer 不可达离线结论、H1/H2/H3
  假设分类。
- `LocalDocs/HOKCrash/HOK-012-工具链与方法论归档.md`：HOK-012 全系列
  LLDB 工具链与 live-trace 方法论归档；当前日常启动不需要，仅在追查
  新 slot / 新 fatal-before-modal 路径时参考。

### 代码/脚本

- `Scripts/hok007b_ngr_patch_runner.py`：候选 E 磁盘 patch apply/revert
  的唯一来源；当前 `state=original`。
- `Scripts/hok011_ngr_common_init_chain.py`（+ test）：`__common`
  slot writer 扫描器。
- `Scripts/hok004_ngr_startup_runner.py`：`10s settle window` 启动
  baseline runner（HOK-010 后 `rootWorkDir=true` /
  `playcover_working_directory_changed`）。
- `Scripts/hok006_ngr_lldb_runner.py`：LLDB 自动化入口；详细选项与
  方法论见 `HOK-012-工具链与方法论归档.md`。

### 运行时证据路径

- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：
  每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于
  对照 faulting window 是否发生移动。
- `build/hok-*.json`、`build/hok-*.log`：历史结构化 live 证据，全部
  在 `.gitignore` 的 `build/` 下本地留存；Dashboard 不逐个罗列。

### 不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`、`LocalDocs/MCPFinal/*`：与本
  主线无关，除非需要借鉴 dashboard 维护方式或 MCP 验证套路。
- 未来若本目录新增 `HOK-xxx-*.md`，默认规则：**只有主文档明确点名的
  当前主线子文档才需要随手读取**。
