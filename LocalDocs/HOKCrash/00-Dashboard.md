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

- **当前状态（HOK-015 已落地、下一步根因已暴露）**：HOK-015 `cmdline
  preseed` 已在 PlayTools constructor 落地且 live 验证 `status=primed`
  （`bInitializedBefore=0 → bInitializedAfter=1` /
  `cmdlinePreview="../../../NGR/NGR.uproject"` / `slide=0x44f0000`）。
  但 live run 暴露了一个**与 Dashboard 早期假设不一致的事实**：
  - `hok014_ngr_alert_suppressed` 事件 **仍然触发 1 次**，title=`Message`、
    message=`QtsFileSystem Create Failed!!` —— 即使 HOK-015 把 UE4
    `FCommandLine` bInitialized 预置为 true（离线定位也证明 NGR 里所有
    218 条 inline `FCommandLine::Get()` guard 都已走 normal path）。
  - 意味着 **"QtsFileSystem Create Failed" 并不是 UE4
    `FCommandLine::Get()` fatal 路径的下游**。它来自 **NGR 自研的
    `QtsFileSystem`（腾讯 NGR 的 VFS 初始化层）自己的失败**——静态上，
    该字符串位于 `__ustring` `0x10c09d070`，在 NGR 二进制里**只有 1
    个 adrp+add xref**（`0x1088792d4`，error reporter 函数内部），上
    游 caller 走 virtual dispatch / 函数指针，离线反向一步追不到。
  - 进程依然表现为"僵尸存活"：peak CPU 瞬间到 ~59%（说明 UE4 确实启
    动了主线程一段时间），但随后 `%CPU → 0`、RSS 停在 332MB、线程
    数 11、`state=S`、主窗口在屏幕外；60s 无新 `.ips`，HOK-014
    swizzle 依然守住 UI（用户仍然看不到 dialog，但 app 没真正活着）。
  - **修正**：Dashboard 之前把 `QtsFileSystem Create Failed` 归在"UE4
    fatal handler (a)"名下。实际上那条路径需要重新独立归因——它和
    HOK-013 / HOK-015 的 UE4 bootstrap 修复完全不在同一条 call graph
    上。

- **当前兜底链路**（全部 apply，顺序按 PlayTools constructor 内执行序）：
  1. `HOK-013`：为 `0x10e2146f8`（UE4 GLog 实例 slot）写入 stub object，
     让所有 dyld initializer 里 reader 链安全 no-op。
     （`HOK-013-slot-preheat.md`）
  2. `HOK-015`：为 `FCommandLine::bCommandLineInitialized`
     （`0x10e201078`）+ `FCommandLine::CmdLine`（`0x10e20107a`, UTF-16-LE
     `TCHAR[16384]`）预写 `bInitialized=1` 与种子字符串
     `"../../../NGR/NGR.uproject"`，让 218 条 inline
     `FCommandLine::Get()` guard 的 `TBZ w?, #0, <fatal>` 都 fall-through。
     （`HOK-015-cmdline-preseed.md`）
  3. `HOK-010`：`PlaySettings.rootWorkDir` 透传 + `PlayApp.launch()`
     self-heal，让 `com.tencent.ngr` 的 cwd 为 `/`。
     （`HOK-014-alert-suppressor.md` 合并说明）
  4. `HOK-014`：PlayTools swizzle
     `-[UIViewController presentViewController:animated:completion:]`，
     对 `UIAlertController` 直接 `completion(nil)` 返回；**HOK-015
     闭合后的观测期望本来是"零触发"，但因 QtsFileSystem Create
     Failed 的独立 fatal 路径，日常仍会触发 1 次**。在 HOK-016
     根因消除前，HOK-014 继续承担"用户看不到错误对话框"硬性要求的
     防线。（`HOK-014-alert-suppressor.md`）

  HOK-007B 候选 E（NGR app 二进制 4 字节 patch）已 **revert**。
  HOK-013 + HOK-015 不再依赖它。

- **当前已知事实**（维护仍需要的）：
  - UE4 iOS `TCHAR` 是 `uint16_t`，fatal marker 字符串
    `"Attempting to get the command line but it hasn't been
    initialized yet."` 在 NGR 二进制里以 **UTF-16-LE** 存在
    `__TEXT,__ustring` 段 `0x10c12d70a`，不是 ASCII。HOK-015-A
    `Scripts/hok015_ngr_cmdline_locator.py` 据此编码扫描。
  - `FCommandLine::bCommandLineInitialized` 的 reader 模式是**218 条**
    inline 副本（UE4 UE4.25+ arm64 inline `FCommandLine::Get()`）：
    ```
    adrp xB, <page(bInitialized)>
    ldrb wB, [xB, #0x78]
    tbz  wB, #0, <fatal_branch>
    adrp xC, <page(CmdLine)>
    add  xC, xC, #0x7a
    ```
    182/218 条指向 NGR 主 UE4 的 `0x10e201078` / `0x10e20107a`；其余
    落到第三方 framework（GCloud / MSDK 等）里自己的 UE4 派生，不在
    HOK-015 干预范围内，也不影响兼容启动。
  - "QtsFileSystem Create Failed!!" 字符串在 NGR 二进制里仅**1 个
    xref**（error reporter `0x1088792d4`）；其调用者是 virtual
    dispatch / 函数指针（静态 BL/B 零匹配）。HOK-016 需要通过 LLDB
    运行期追踪或反向 UE4 subsystem init 顺序定位其上游业务逻辑。
  - `effectiveLaunchEnvironment` 两份实现（GUI + MCP）依然需同步；
    目前对 HOK-013 / HOK-015 没有新增 env 要求。
  - PlayCover GUI `AppSettings.settings` 的 `didSet → encode()` 写回
    plist 行为未变；HOK-010 self-heal 仍是改 settings 的正确入口。
  - 候选 E 磁盘备份仍在 `build/hok-007b-backups/*.bin`，日常不 apply。

- **当前主线**：`HOK-016`——定位并消除
  `QtsFileSystem Create Failed!!` 的根因。目标状态：`launch-events.jsonl`
  里 `hok014_ngr_alert_suppressed` 事件次数 **真正归零**；进程
  `RSS ≥ 800MB` / 线程数 ≥ 20 / 窗口在主屏内 / `%CPU` 持续 ≥ 5%。
  方法：
  - 静态：反向跟踪 `0x1088792d4` 所在 reporter 函数的 vtable / 函数
    指针消费点（可参考 HOK-011 的 __common slot writer 扫描器套
    路），定位 `QtsFileSystem::Create` / `QtsFileSystem::Init` 的入
    口，看其 failure 条件是什么（路径不存在？`access()`/`stat()`
    返回 -1？一个 iOS-only 的 sandbox container path？）。
  - 运行期：`launch_app_with_lldb`（HOK-006 runner 的
    `--defer-watchpoint-install` 路径）在 `0x1088792d4` 设 BP 抓到
    命中瞬间 backtrace + `x0..x8` 全状态；再沿 backtrace 反溯真正
    的 failure 点。
  - 约束同 HOK-015：bundle-scoped、PlayTools 层、不动 NGR 二进制、
    失败时无副作用。

- **当前卡点**：无。

- **下一步默认规划**：
  1. `HOK-016-A`：用 `Scripts/hok006_ngr_lldb_runner.py` 自动化
     在 `0x1088792d4` 设 BP，结合 `--pre-run-command 'breakpoint
     set --address 0x1088792d4'`，收集 backtrace + 寄存器状态，
     落 `build/hok-016-qts-fs-create-failed.json`。
  2. `HOK-016-B`：根据 backtrace 定位 `QtsFileSystem::Create`
     入口函数，静态反汇编看 failure 条件（预计落在 `mkdir` /
     `access` / `stat` 路径检查）。
  3. `HOK-016-C`：在 PlayTools 层做 bundle-scoped 修复——最可能
     的形态是在 `pt_stat` / `pt_access` 的 filename fixup 里
     增加 NGR 特定路径映射；或直接 swizzle `QtsFileSystem::Create`
     vtable 入口返回 success。具体由静态 + LLDB 证据决定。
  4. `HOK-016-D`：live 验证判据（全部满足才视为闭合，替换本文
     当前的"主线任务"状态）：
     - `hok014_ngr_alert_suppressed` 事件 **次数 = 0**；
     - `hok015_ngr_cmdline_preseed status=primed` 事件仍然存在；
     - 进程 `%CPU ≥ 5%` 持续 ≥ 30s、RSS ≥ 800MB、线程数 ≥ 20；
     - 主窗口 bounds 与主屏 frame 有非空交集、`kCGWindowMemoryUsage
       > 1_000_000`；
     - 无新 `NGR-*.ips`。
  5. 只有 HOK-016 闭合，才把 HOK-014 正式降级为冷备安全网。
  6. （可选后续）`HOK-008`：闭合 HOK-016 后，把完整验证链路固化成
     单脚本。

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
