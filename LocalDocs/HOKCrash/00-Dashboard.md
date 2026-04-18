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

- **当前状态（HOK-015 / HOK-016-A / HOK-016-B 已落地；HOK-016-C 未决）**：
  HOK-015 `cmdline preseed` 在 PlayTools constructor 稳定命中
  （`bInitializedBefore=0 → bInitializedAfter=1` /
  `cmdlinePreview="../../../NGR/NGR.uproject"` / `slide=0x44f0000`），
  218 条 inline `FCommandLine::Get()` guard 全部 fall-through。
  HOK-016-A 静态定位 + HOK-016-B LLDB backtrace 已精确锁定
  `QtsFileSystem Create Failed` 的触发链与判定点——仅剩 "为何
  `0x108877bd0` 返回 w0=0" 这一内部业务分支待定。
  - `hok014_ngr_alert_suppressed` 仍稳定触发 1 次，`title=Message` /
    `message=QtsFileSystem Create Failed!!`。
  - **判定点**：reporter `0x108879164 +180: tbz w0, #0, +364`，其中 w0
    是 `+176: bl 0x108877bd0` 的返回值。w0=0 直接跳到 Create Failed
    分支；`0x108877bd0` 是一个 544 字节栈的大函数，语义为 NGR QtsFS
    "资源根目录/VFS 可用性初始化"，目前尚未确定它到底在检查什么
    （iOS-only 路径 / iOS-only NSBundle 资源 / 某个 reflection check）。
  - 进程仍表现为"僵尸存活"（peak CPU ~59% 瞬间 → 掉到 0.2%、RSS 332MB、
    线程 11、窗口离屏、60s 无新 `.ips`），HOK-014 swizzle 守住 UI。
  - **修正**：`QtsFileSystem Create Failed` 不是 UE4
    `FCommandLine::Get()` fatal 的下游，而是 NGR 自研 `QtsFileSystem`
    自己的初始化失败；但**它所在函数 frame 3 `0x103a29c60 +796: str x0, [x8, #0x6f8]`
    恰好就是 HOK-011 全二进制扫描找到的 `0x10e2146f8` 唯一 writer**，即
    HOK-013 的 stub 会被这条路径真正覆盖；HOK-013 / HOK-015 在 HOK-016
    的触发点之前守住安全读，前提被 HOK-016 依赖。

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
  - **QtsFileSystem 家族共 3 条 UTF-16-LE 字符串（HOK-016-A 扫描结果）**：
    `"QtsFileSystem init Failed!!" @ 0x10c09d00a`（xref `0x108879248`）、
    `"QtsFileSystem Create Failed!!" @ 0x10c09d070`（xref `0x1088792d4`）、
    `"QtsFileSystem Create failed." @ 0x10c09d0ac`（xref `0x10432f4b0`）。
    前两条 xref 共属同一 reporter 函数 `0x108879164`（walk-back
    stp-prologue + 两 marker 一致），第三条在另一个函数
    `0x10432f490`。
  - **reporter 调用链（HOK-016-B LLDB 命中稳定结果）**：
    frame0=`0x108879164`（vtable[0x30] 方法） ← frame1=`0x103a29bec`
    (MeyersSingleton `0x103a29b7c +112`，第二次 vtable[0x30] blr 返回
    点) ← frame2=`0x107e5df4c` (FactoryRegister `0x107e5df10 +60`，
    HOK-011 记录的唯一 caller) ← frame3=`0x103a29fa0`
    (`0x103a29c60 +832 = QtsFileSystem_Init`，内部 `+796 str x0,
    [x8, #0x6f8]` 就是 HOK-011 的 `0x10e2146f8` 唯一 writer) ←
    frame4=`0x107e5c970` (`0x107e5c964 +12`，`cbnz w0` tail-call
    fatal) ← frame5=`0x103a227d0` (`0x103a227a4 +44 = MessagingInit`，
    `FCommandLine::Get()` inline guard 之后传 CmdLine 给 frame 4) ←
    frame6..8 = NSThread worker / Foundation / pthread（**非主线程**）。
  - **reporter 入口寄存器语义**（HOK-016-B 跨 run 稳定）：x0=`this`
    (QtsFS 实例)、x1=`0x10e2005f0`（log category / NGR `__common`）、
    **x2=`0x10e20107a`（= HOK-015 preseeded `FCommandLine::CmdLine`
    buffer）**、x3=TCHAR 长度、x22=`0x10e1fc8e8`（Meyers singleton
    guard）。即这条 UE_LOG 把 cmdline 当 `%s` context 打印，**QtsFS
    的 fail/success 不由 cmdline 内容决定**。
  - **Create Failed 分支判定点（核心根因）**：reporter 内部
    `0x108879214 +176: bl 0x108877bd0; +180: tbz w0, #0, +364`。
    `0x108877bd0` 是一个 544 字节栈的大函数，语义为 NGR QtsFS
    "资源根目录/VFS 可用性初始化"；w0=0 时 reporter 走 +364 分支构造
    `"QtsFileSystem Create Failed!!"` 的 UIAlertController（经
    `0x10432f490`），然后 reporter 把自身返回值设为 0 给 frame 1，
    frame 4 `cbnz w0, +32` 走 tail-call fatal 路径，UE4 GameThread 退
    出，进程落入僵尸态。HOK-016-C 的任务就是查清 `0x108877bd0` 的
    返回值由什么决定。
  - "QtsFileSystem Create Failed!!" 字符串在 NGR 二进制里仅**1 个
    xref**（`0x1088792d4`，与 "init Failed!!" 的 `0x108879248` 同属
    reporter `0x108879164`）；其调用者是 vtable[0x30] virtual
    dispatch（静态 BL/B 零匹配，HOK-016-B LLDB `--shlib NGR --address`
    BP 成功捕获——**绝对 VA 格式 BP 在 ASLR 下不命中，必须用
    `--shlib NGR` module-relative**）。
  - `effectiveLaunchEnvironment` 两份实现（GUI + MCP）依然需同步；
    目前对 HOK-013 / HOK-015 / HOK-016 没有新增 env 要求。
  - PlayCover GUI `AppSettings.settings` 的 `didSet → encode()` 写回
    plist 行为未变；HOK-010 self-heal 仍是改 settings 的正确入口。
  - 候选 E 磁盘备份仍在 `build/hok-007b-backups/*.bin`，日常不 apply。

- **当前主线**：`HOK-016-C`——查清 `0x108877bd0` 为何返回 w0=0，并选定
  PlayTools 层 bundle-scoped 的修复形式。目标状态：`launch-events.jsonl`
  里 `hok014_ngr_alert_suppressed` 事件次数 **真正归零**；进程
  `RSS ≥ 800MB` / 线程数 ≥ 20 / 窗口在主屏内 / `%CPU` 持续 ≥ 5%。
  方法：
  - 静态：继续反汇编 `0x108877bd0`（`___lldb_unnamed_symbol1166736`）
    内部的每一条 BL，确认它调用的 syscall / Foundation API / NGR
    内部 C++ 方法是否涉及 iOS-only 路径 / iOS-only bundle key。
  - 运行期：在 `0x108877bd0` 入口设 BP（已验证 `--shlib NGR --address`
    module-relative 格式命中稳定；参考 `Scripts/hok016_ngr_qts_reporter_trace.py`
    的 BP 设置模式），命中后串联激活 `stat` / `open` / `access` /
    `fopen` / `NSFileManager` 相关 BP（当前一次尝试 `breakpoint
    disable ... -C 'breakpoint enable'` 的动态 enable 链未成功；
    HOK-016-C 的下一步需要改用 Python LLDB script action 或者直接
    裸激活 + backtrace filter）。
  - 约束同 HOK-015：bundle-scoped、PlayTools 层、不动 NGR 二进制、
    失败时无副作用。

- **当前卡点**：无（HOK-016-A / HOK-016-B 已产出稳定证据；HOK-016-C
  只需选定修复形式并落地）。

- **下一步默认规划**：
  1. `HOK-016-C.1`：**深入静态 + 动态 `0x108877bd0`**——用
     `Scripts/hok016_ngr_qts_reporter_trace.py` 的 BP 模板（
     `breakpoint set --shlib NGR --address 0x108877bd0`）加上
     Python LLDB scripted breakpoint，当 `0x108877bd0` 入口命中时
     动态 enable `stat` / `open` / `access` / `fopen` / `-[NSBundle
     pathForResource:ofType:]` 这一批 BP、做完 30 秒 observation 后
     disable；落 `build/hok-016c-qts-init-syscalls.json`。目的：判定
     `0x108877bd0` 返回 0 的触发条件究竟是 iOS sandbox 路径、iOS
     NSBundle 键、还是纯 C++ 内部 reflection check。
  2. `HOK-016-C.2`：根据 C.1 的真因分类选定修复形态：
     - 若是 iOS-only 路径 → PlayTools `pt_stat` / `pt_access`
       filename fixup 追加 NGR 特定路径映射；
     - 若是 iOS-only NSBundle 键 → PlayTools 层 swizzle
       `-[NSBundle pathForResource:ofType:]` 做 key 补齐；
     - 若是纯 C++ 内部 check → 通过 PlayTools fishhook 对
       `0x108877bd0` 的入口做符号化 interpose 返回 1（有风险，仅作
       兜底，且必须扫完 C.1 的 syscall 路径确认无 side-effect 依赖）。
  3. `HOK-016-C.3`：PlayTools 侧落地实现（复用 HOK-013/015 的 bundle
     gate 与 slide 计算），bundle-scoped、幂等、失败 no-op。
  4. `HOK-016-D` live 验证判据（全部满足才视为闭合、取代本文主线状态）：
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
| HOK-014 | DONE（HOK-016 闭合后降级为安全网） | PlayTools 层 swizzle `-[UIViewController presentViewController:animated:completion:]`，对 `UIAlertController` 直接 `completion(nil)` 返回。**消除 alert UI 表现但不治本**——业务 fatal 仍然发生、GameThread 仍退出。HOK-015 已把 UE4 cmdline fatal 路径消除（在此路径上 swizzle 一次都不触发），当前仍触发的是 HOK-016 的 QtsFS Create Failed 独立分支 | `HOK-014-alert-suppressor.md` |
| HOK-010 | DONE | `rootWorkDir` 从 `disableForMinimalStartupCompat(...)` 摘除；GUI host 端 self-healing 保证 plist 不被 stale 内存覆盖 | `HOK-014-alert-suppressor.md`（合并说明） |
| HOK-015 | DONE | 在 PlayTools 层预写 NGR `FCommandLine` 存储（`bInitialized=true` + cmdline char buffer = `"../../../NGR/NGR.uproject"`），消除 UE4 early-read fatal 根因。218 条 inline `FCommandLine::Get()` guard 全部 fall-through；HOK-014 alert 观察期 HOK-016 未闭合前仍为 1（由 QtsFS Create Failed 独立路径触发，与 HOK-015 语义无关） | `HOK-015-cmdline-preseed.md` |
| HOK-016-A | DONE | 离线静态定位 `QtsFileSystem` 字符串家族 + reporter 函数入口（`Scripts/hok016_ngr_qts_locator.py`，产物 `build/hok-016-qts-fs-static.json`）。结果：`"Create Failed!!"` / `"init Failed!!"` / `"Create failed."` 各 1 条 UTF-16-LE xref；前两条 xref 共属 reporter `0x108879164`，walk-back stp-prologue 与 xref 一致 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-B | DONE | 运行期 LLDB 在 reporter 入口 + 家族 xref 设 BP 抓 backtrace + x0..x8（`Scripts/hok016_ngr_qts_reporter_trace.py`，产物 `build/hok-016-qts-reporter-lldb.json` / `build/hok-016-qts-reporter-summary.json`）。锁定完整 8 层调用链（frame 0 = `0x108879164` vtable[0x30] 方法、frame 3 = HOK-011 `0x10e2146f8` 真 writer、frame 7 = Foundation NSThread）与 Create Failed 分支判定点（`0x108877bd0` 返回 0 时触发）；x2 严格匹配 HOK-015 preseed 的 CmdLine buffer。**绝对 VA BP 在 ASLR 下不命中，必须用 `--shlib NGR --address <unslid>` 格式** | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C | TODO（当前主线） | 查清 `0x108877bd0` 为何返回 w0=0（syscall / NSBundle / 纯 C++ reflection），并选定 PlayTools 层 bundle-scoped 修复（`pt_stat` fixup / `-[NSBundle pathForResource:ofType:]` swizzle / fishhook interpose）；按 HOK-016 子文档 C.1..C.4 推进 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-D | TODO | HOK-016-C 落地后 live 验证（`hok014_ngr_alert_suppressed = 0` + 进程活跃度指标 + 窗口可见性 + 无新 `NGR-*.ips`）；闭合后把 HOK-014 降级为冷备安全网 | `HOK-016-qts-fs-create-failed.md` |
| HOK-007C | DEFERRED | 下游 crash 的离线映射 + 可逆 patch；HOK-013/014 之后未观察到新 faulting callsite，当前无触发动机 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-008 | TODO | 把"revert 候选 E → `rootWorkDir=1` → 启动 → 证据采集 → pass 判定"固化成单脚本；替代现在的人工组合 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号 / 手工 UI 的后续验证（登录 / 进游戏行为）；执行前必须得到用户确认 | 不执行 |

## 高频复用经验（当前仍适用的）

- **"进程不崩 + 窗口存在"不等于"最终目标达成"**。必须同时检查：
  `launch-events.jsonl` 里**零** `Fatal` / 零 `hok014_ngr_alert_suppressed`；
  进程 `%CPU` 持续 ≥5%、`RSS` 长到 UE4 典型量级；主窗口 bounds 与主
  屏 frame 有非空交集。
- **"UIAlertController 被 HOK-014 压制"是症状不是治愈**。HOK-014 只让
  alert 不可见，业务 fatal 仍已触发、GameThread 仍退出；进程表现为
  "僵尸存活"。当前还在触发 HOK-014 的是 HOK-016 的 QtsFS Create Failed
  分支（`0x108877bd0` 返回 0）；治本在 HOK-016-C。
- **HOK-016 LLDB BP 设置规则**：对 NGR 主 image 内的固定 unslid 地址
  （如 reporter 入口 `0x108879164`）设 BP，**必须**用
  `breakpoint set --shlib NGR --address <unslid>`；不带 `--shlib` 的
  绝对 VA 在 ASLR slide 下不命中（`hok006_ngr_lldb_runner.py` 默认
  透传 pre-run-command，调用方负责拼这条格式）。
- **HOK-016 reporter 调用链速查**：frame0 `0x108879164` (QtsFS vtable[0x30])
  ← frame3 `0x103a29fa0` (QtsFileSystem_Init，内部 `+796` 是 HOK-011
  `0x10e2146f8` 唯一 writer) ← frame5 `0x103a227d0` (MessagingInit，
  FCommandLine::Get inline guard 之后) ← NSThread worker（**非主线程**）。
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
- `LocalDocs/HOKCrash/HOK-015-cmdline-preseed.md`：HOK-015 的方案分析、
  `bInitialized` + cmdline buffer 静态定位口径、预写原子性与幂等约束、
  三轮 live 验证判据（zero-fatal / zero-alert / 进程活跃度指标 / 窗
  口可见性）。
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：**当前主线**
  HOK-016 的字符串家族 / reporter 调用链 / Create Failed 分支判定点
  （`0x108877bd0` 返回 w0=0）归档；HOK-016-C 的四种候选修复路径与证
  据需求；与 HOK-011 / HOK-013 / HOK-015 的依赖关系。

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
  方法论见 `HOK-012-工具链与方法论归档.md`。**HOK-016 使用提示**：
  对 NGR 主 image 内的固定地址设 BP 必须用
  `breakpoint set --shlib NGR --address <unslid>` 的 module-relative
  格式——绝对 VA 在 ASLR 下不命中（`hok006_ngr_lldb_runner.py`
  本身只透传 pre-run 命令字符串，不做此改写，调用方负责拼命令）。
- `Scripts/hok015_ngr_cmdline_locator.py`：HOK-015-A 离线定位
  `FCommandLine` 存储；输出 `build/hok-015-cmdline-slots.json`。
- `Scripts/hok015_ngr_live_verify.py`：HOK-015-C live 验证（60s settle
  window + 事件 diff + CGWindow snapshot）；输出
  `build/hok-015-live-report.json`。
- `Scripts/hok016_ngr_qts_locator.py`：HOK-016-A 离线定位
  `QtsFileSystem` 字符串家族 + reporter 函数入口；复用 HOK-015 locator
  的 Mach-O parser，新增 UTF-16-LE 扫描 + prologue walk-back；输出
  `build/hok-016-qts-fs-static.json`。
- `Scripts/hok016_ngr_qts_reporter_trace.py`：HOK-016-B 运行期 LLDB
  BP + backtrace/register 捕获；消费 `build/hok-016-qts-fs-static.json`
  + `build/hok-015-cmdline-slots.json`，输出
  `build/hok-016-qts-reporter-lldb.json`（原始 hok006 schema）+
  `build/hok-016-qts-reporter-summary.json`（HOK-016-B 专属 summary，
  含 x1/x2 低 28 位交叉比对）。

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
