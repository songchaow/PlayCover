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

- **当前状态（HOK-015 / HOK-016-A / HOK-016-B / HOK-016-C.1 /
  HOK-016-C.X.1 / HOK-016-C.2.1 / HOK-016-C.2.2 / HOK-016-C.2.3 /
  HOK-016-C.2.4 / HOK-016-C.2.5 已落地；HOK-016-C.2.6 当前主线）**：
  HOK-015 `cmdline preseed` 在 PlayTools constructor 稳定命中，
  218 条 inline `FCommandLine::Get()` guard 全部 fall-through。
  HOK-016-A / B / C.1 已精确锁定 Create Failed 的外层触发链；
  HOK-016-C.X.1 证伪"HOK-015 seed 值驱动"假设；HOK-016-C.2.1
  / C.2.2 / C.2.3 证伪"sentinel `0x10e1eeef0` 未 bump" 假设；
  HOK-016-C.2.4 证伪"失败点在 `0x10017f3c8`"，把真因锁定到
  `0x10017f184` 内 `bl 0x1001cd114` 的字符串 lookup；
  **HOK-016-C.2.5 进一步更正：rootB 不是"空红黑树"，而是被
  reporter 在运行期 insert 过 2 个 entry，但这 2 个 entry 的
  key 都不是 "main"**：
  - readiness B 失败的直接输入：`0x10017f184` 内
    `bl 0x1001cd114(rootB=0x10e184b18, "main" PascalString, 1)`
    返回 0 → `0x10017f1e0 cbz x0 → fail_slot_2 → return 0`。
  - rootB 的 insert 发生在 **reporter 调用链内部**（不是 dyld
    static init）：`Scripts/hok016c25_ngr_rootB_watch.py` 在
    NGR `main` 入口装 8-byte modify watchpoint，捕获到 2 次命
    中，PC 均在 `0x1001cf020`（红黑树 insert writer）；Hit #1
    backtrace 明确：frame #4 = `0x108877bd0 +692`（reporter 内
    部、readiness B dispatcher 之前），frame #5..#9 = reporter
    入口 +176 → MeyersSingleton → FactoryRegister →
    QtsFileSystem_Init。
  - `Scripts/hok016c2_ngr_sentinel_writer_scan.py --target-address
    0x10e184b18`（离线直接 store 扫描）+
    `Scripts/hok016c25_ngr_rootB_xref_scan.py`（离线 adrp+add
    xref 扫描）证实：rootB 有 1 个合法的 static-constructor
    writer（`0x1001cf20c` 在 `__init_offsets` 可达链里，负责
    空容器初始化）和 94 个 helper 通过 x0 传参消费它；真正的
    entry insert 不出现在直接 store 扫描里，而是通过 helper 完成。
  - **"main" chunk 的预注册路径目前未知**——reporter 内部的 2 次
    insert 的 key 不是 "main"；iOS 下有某段 iOS-specific 的预
    注册代码更早填 "main"，macOS 下没触达。
  - `hok014_ngr_alert_suppressed` 仍稳定触发 1 次，HOK-014 swizzle
    守住 UI。进程依然僵尸态。

- **修复路线（优先级最高 → 最低；HOK-016-C.2.5 之后重新排）**：
  1. `HOK-016-C.2.6`（**当前主线**）：**定位 "main" chunk 的预注
     册路径**。静态路线：在 NGR 二进制扫 PascalString 字面量
     `"main"`（4-byte length prefix = `04 00 00 00 00 00 00 00 6d
     61 69 6e`）以及它的 adrp+add xref；看哪些 xref 函数与 dyld
     `__init_offsets` 可达链相交。运行路线：扩大 C.2.5
     watchpoint 范围——不仅监控 rootB[0..7]、也在每次 insert
     命中时 dump 新 node 的 key 字段，对比看哪次 insert 的 key
     真的是 "main"；若 "main" 的 insert 来自 reporter 路径以外
     的函数，backtrace 即给出 registrar 入口。
  2. `HOK-016-C.5`：若 C.2.6 能给出一个可重复的
     `bl <insert_helper>(x0=rootB, x1="main" PascalString, ...)`
     签名，PlayTools constructor 里按同样签名手动 invoke 一次；
     这是最小侵入的修法。
  3. `HOK-016-C.4`：若 insert 是 C++ template / lambda / 无法从
     PlayTools 复制的复杂路径，fishhook interpose
     `0x10017f184` / `0x1001cd114` 让 lookup 对 key "main" 强制
     返回非零。
  4. `HOK-016-C.3`：终极野蛮方案——fishhook interpose
     `0x108878534` 直接返回 1，跳过整条 readiness B。稳定性风险
     极高。
  5. `HOK-016-C.6`：降级到 HOK-009 类型（需要用户介入）。

- **已证伪路径**：
  - ~~HOK-016-C.X~~（HOK-015 seed 替换）—— 4 种 seed 下
    `w0@+912` 恒 0，`build/hok-016cx-summary.json` +
    `build/hok-016cx-*-trace.json`。
  - ~~HOK-016-C.2.1 / C.2.2~~（sentinel 未 bump）—— probe 实测
    sentinel = 0x05、全 __text 0 writer；证据
    `build/hok-016c2-sentinel-writer.json`（__init_offsets 扫描） +
    `build/hok-016c2-sentinel-writer-full-text.json`（全 __text
    扫描） + `build/hok-016c2-sentinel-probe.json`（运行期 probe）
    + `build/hok-016c2-step-into-readinessB.json`（证实 bl
    0x10432dd98 命中、返回 0）。
  - ~~HOK-016-C.2.3 里"`0x10432dd98` → `0x10017f3c8`" 路径~~——
    HOK-016-C.2.4 v2/v3/v4/v5 run 证实 `0x10432dd98` 实际走
    `+0x54 b.eq 0x10432df8c` 分支，`0x10017f3c8` 在 NGR 当前 run
    中不可达。真路径经过 `0x10017f184`。证据
    `build/hok-016c24-readinessB-inner-args.json`。
  - ~~HOK-016-C.5 path fixup~~（间接证伪）—— lookup key 是内部
    PascalString `"main"`（chunk 名），不是 FString 路径；pt_stat
    / NSBundle swizzle 无法修正这种 rootB 缺 name entry 问题。
  - ~~"rootB 从头到尾完全是空" 推测~~（HOK-016-C.2.5 更正）—— 
    LLDB watchpoint 实测 rootB 在 reporter 运行期被 insert 过
    2 次 entry（来自 `0x1001cf020` 红黑树 insert 路径）；只是
    insert 的 key 都不是 "main"。证据
    `build/hok-016c25-rootB-watch.json`。

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
  - **Create Failed 分支判定点（核心根因仍在 HOK-016 内部）**：
    reporter 内部 `0x108879214 +176: bl 0x108877bd0; +180: tbz w0,
    #0, +364`。`0x108877bd0` 是 NGR QtsFS 的"资源根目录/VFS 可用性初
    始化"大函数；w0=0 时 reporter 走 +364 分支构造
    `"QtsFileSystem Create Failed!!"` 的 UIAlertController（经
    `0x10432f490`），然后 reporter 返回 0，frame 4 的 `cbnz w0,
    +32` 走 tail-call fatal，UE4 GameThread 退出，进程落入僵尸态。
  - **HOK-016-C.1 w0 trace（`Scripts/hok016c_ngr_qts_w0_trace.py`）
    稳定观察**：`0x108877bd0 +900` 前 w0 = **1**（readiness A
    `0x108876a94` ok），`+912` 前 w0 = **0**（readiness B
    `0x108878534` fail）。
  - **UE4 自身 stderr 关键 log（与 QtsFS 失败无因果关联）**：
    `[UE4] Project file not found: ../../../NGR/NGR.uproject` 只与
    HOK-015 seed 文本相关；HOK-016-C.X.1 已证实换成 `empty` /
    `project` / `ue4cmdfile` 后，这条 log 可消失，但
    `w0@+912` 与 failure sink 命中数完全不变。
  - **sentinel `0x10e1eeef0` 已被证伪为根因**（HOK-016-C.2.2）：
    reporter 调用链命中瞬间，运行期 probe 直接测得
    `0x10e1eeef0 = 0x05`；`0x108878534 +48 ldrb; +52 cmp w8,#0x4;
    +56 b.lo` 与 `0x108877bd0 +1364 ldrb; +1368 cmp w8,#0x2` 两处
    sentinel 判定都**不会**因该 byte 触发 early-exit。也就是说
    "macOS 下 sentinel 未 bump" 的假设是错的。
  - **sentinel writer 链对当前修复已失去意义**：HOK-016-C.2.1
    `__init_offsets` 扫描 0 hit；HOK-016-C.2.2 全 `__text`
    （169MB）扫描 `adrp+add+str/strb/strh/str.w` 也 0 hit。writer
    可能在 framework 或用非常规模式，但因为 sentinel 已 = 5，继续追
    writer 已不再逼近根因。
  - **`0x108878534` 的真正失败源已下钻到 `0x10432dd98`**
    （HOK-016-C.2.3）：
    * `0x108878534` 实际范围 `0x108878534..0x1088786ec`（≈440
      字节），不是之前口头估计的更大区间；
    * `+352 bl 0x10432dd98` 稳定被 call 到；
    * `+356` 立刻观测到 `x0 = 0x0`，即 `0x10432dd98` 返回 0；
    * 这正是 `0x108878534 +360 tbz w0,#0` 的输入，因此 readiness B
      fail 的直接来源不是 sentinel，而是 `0x10432dd98`。
  - **`0x10432dd98` 真实控制流（HOK-016-C.2.4 v3/v4/v5 ~30 个 Python
    callback BP 抓到）**：入口做 `Printf("%d", 1) → "1"`，然后
    `cmp w22(=Num=2), decision_c08(=2) → EQ → b.eq 0x10432df8c`
    跳 alt-path；经两次 vtable[0xf8] blr 得 `x21=1, x20=0`；
    `cbnz w21 → 0x10432dfac; cbz w20 → 0x10432e06c`；然后
    `mov x0,x1(=0); bl 0x10017f184(x0=0)`。**整条路径完全不经过
    `bl 0x10432b734`、也不经过先前 Dashboard 假设的 `bl 0x10017f3c8`**。
    证据：`build/hok-016c24-readinessB-inner-args.json` +
    `probe_inner_entry` 等 7 个 f3c8 BP 在 v3/v4/v5 run 命中 0 次。
  - **真正的失败决定点是 `0x10017f184`**（HOK-016-C.2.4）：它与
    `0x10017f3c8` 结构同构（adrp → ldr root → bl 0x1001ac168 → cbz
    → bl 0x1001cd114 → cbz）但目标不同：用 `sp+0x20` 作 out slot，
    入参 x0=int key=0；`bl 0x1001ac168` 成功查到 rootA 中 key=0 对
    应的 entry（entry+0x10 = PascalString `[length=4]"main"`、
    entry+0x20 = `[length=1]"1"`）；但
    `bl 0x1001cd114(x0=rootB=0x10e184b18, x1=entry+0x10="main", w2=1)`
    **返回 0**（cbz x0 → fail_slot_2 @ 0x10017f2bc）。v5 实测 rootB
    运行期 header = `10 3e 33 16 01 00 00 00  10 3e 33 16 01 00 00 00
    01 00 00 00 00 00 00 00`——两个 parent/sentinel ptr 都指向
    `*rootB` 自身，count=1 = 典型的**空红黑树 sentinel 自指**。
    即 macOS 下根本没人往 rootB 注册 "main" 这个 chunk 名，导致
    QtsFileSystem 初始化第二段 readiness check 永远 fail。
  - `"QtsFileSystem Create Failed!!"` 字符串在 NGR 二进制里仅**1 个
    xref**（`0x1088792d4`，与 `"init Failed!!"` 的 `0x108879248`
    同属 reporter `0x108879164`）；其调用者是 vtable[0x30]
    virtual dispatch。对主 image 内固定地址设 BP 时，**必须**用
    `--shlib NGR --address <unslid>`，绝对 VA 在 ASLR 下不命中。
  - `effectiveLaunchEnvironment` 两份实现（GUI + MCP）依然需同步；
    目前对 HOK-013 / HOK-015 / HOK-016 没有新增 env 要求。
  - PlayCover GUI `AppSettings.settings` 的 `didSet → encode()` 写回
    plist 行为未变；HOK-010 self-heal 仍是改 settings 的正确入口。
  - 候选 E 磁盘备份仍在 `build/hok-007b-backups/*.bin`，日常不 apply。

- **当前主线**：`HOK-016-C.2.6`——定位 **"main" chunk 的预注册路径**。
  静态路线：在 NGR 二进制扫 PascalString 字面量 `"main"`（4-byte
  length prefix = `04 00 00 00 00 00 00 00 6d 61 69 6e`）以及它的
  adrp+add xref；看哪些 xref 函数与 dyld `__init_offsets` 可达链相
  交。运行路线：扩大 C.2.5 watchpoint 覆盖——不仅监控 rootB[0..7]、
  也在每次 insert 命中时 dump 新 node 的 key 字段；若 "main" 的
  insert 来自 reporter 路径以外的函数，backtrace 即给出 registrar
  入口。目标状态不变：`launch-events.jsonl` 里
  `hok014_ngr_alert_suppressed` 事件**真正归零**；进程 `RSS ≥ 800MB` /
  线程数 ≥ 20 / 窗口在主屏内 / `%CPU` 持续 ≥ 5%。

- **当前卡点**：reporter 运行期只 insert 了 2 个非-"main" entry；
  "main" chunk 的 registrar 函数还未定位。iOS 下有某段 iOS-specific
  的预注册代码更早填 "main"，macOS 下没触达——候选位置：(a) dyld
  `__init_offsets` 的另一条 initializer（目前 C.2.5 离线扫描未发
  现从 `__init_offsets` 可达的 "main" literal），(b) Objective-C
  `+load` 方法，(c) `__mod_init_func` 等 constructor 段。

- **下一步默认规划**：
  1. `HOK-016-C.2.6`：先写
     `Scripts/hok016c26_ngr_main_literal_xref.py`——离线扫
     NGR `__TEXT` / `__DATA_CONST` / `__DATA` 里的 PascalString
     `"main"` 字面量（`04 00 00 00 00 00 00 00 6d 61 69 6e ...`）
     以及它的 adrp+add xref；产物
     `build/hok-016c26-main-literal.json`。
  2. 如果 C.2.6 离线直接给出候选 registrar，进入
     `HOK-016-C.5`：PlayTools constructor 里直接调用同样签名的
     insert helper 预注册 "main"。
  3. 如果离线扫不出来，扩大 C.2.5 watchpoint 到 rootB 前 64 字节（
     覆盖 insert 时写 leftmost / rightmost / count / new-node 的
     所有位置），在每次命中时 dump 新 node 的 key；这能直接把
     "main" insert 的 registrar 函数暴露出来。
  4. 若上两步证实 insert 来自第三方 framework / Obj-C +load 且不
     可模拟，进入 `HOK-016-C.4`：fishhook interpose
     `bl 0x1001cd114` / `0x10017f184` / `0x10432dd98`。
  5. `HOK-016-C.3` 保留作为最后兜底。
  6. `HOK-016-D` live 验证标准不变：`hok014_ngr_alert_suppressed = 0`
     + `%CPU/RSS/线程/窗口` 活跃度达标 + 无新 `NGR-*.ips`。
  7. 只有 HOK-016 闭合，才把 HOK-014 正式降级为冷备安全网。
  8. （可选后续）`HOK-008`：闭合 HOK-016 后，把完整验证链路固化成
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
| HOK-016-C.1 | DONE | 运行期追踪 `0x108877bd0` 的失败分支 w0 来源（`Scripts/hok016c_ngr_qts_w0_trace.py`，产物 `build/hok-016c-w0-trace.json`）。稳定结论：**w0@+900=1 / w0@+912=0 / `0x108878534` 是失败源**。同一 transcript 稳定捕获 UE4 自身 log `[UE4] Project file not found: ../../../NGR/NGR.uproject`，但 HOK-016-C.X.1 已证实该 log 与 QtsFS 失败无因果关联 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.X | DONE（证伪） | HOK-015 seed 替换实验（`Scripts/hok016cx_lldb_cmdline_override.py` + `Scripts/hok016cx_ngr_seed_experiment.py`，产物 `build/hok-016cx-{summary,empty,project,ue4cmdfile,uproject}-*.json`）。LLDB Python BP 动态改写 `FCommandLine::CmdLine` 为 4 种候选值，`w0@+912` 恒 = 0、failure sink 命中恒 = 3 —— **"seed 内容驱动 QtsFS 失败" 假设被证伪**。**踩坑固化**：`breakpoint set` 不支持 `--script-type python -F`；Python callback 必须拆成 `breakpoint set` + 紧邻的 `breakpoint command add -s python -F <func>` 两步（默认对最后创建的 BP 操作，两步之间不能插入其它 `breakpoint set`） | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.1 | DONE（证伪） | 用 `Scripts/hok011_ngr_common_init_chain.py --target-address 0x10e1eeef0` 扫 `__init_offsets` initializer 链，输出 `build/hok-016c2-sentinel-writer.json`。结果：**0 hit**，证明 sentinel writer 不在 NGR 自身 dyld initializer 可达链上 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.2 | DONE（证伪） | 新增 `Scripts/hok016c2_ngr_sentinel_writer_scan.py` 做全 `__text` writer 扫描（`str/strb/strh/str.w`），并用 `Scripts/hok016c2_ngr_sentinel_probe.py` + `hok016c2_lldb_sentinel_watch.py` 运行期 probe。结果：**sentinel `0x10e1eeef0` = 0x05、全 `__text` 0 writer**，"sentinel 未 bump" 假设被证伪 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.3 | DONE | 新增 `Scripts/hok016c2_ngr_step_into_readinessB.py`，在 `0x108878534 +352 bl 0x10432dd98` 前 / 后及 `0x10432dd98` 入口设探针。结果：**`0x10432dd98` 被稳定 call 到，且返回 0**；readiness B 失败源从 sentinel 改写为 `0x10432dd98` 深层 lookup（HOK-016-C.2.4 进一步修正为 `0x10017f184` 而非 `0x10017f3c8`） | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.4 | DONE | 新增 `Scripts/hok016c24_ngr_readinessB_inner_args.py` + `Scripts/hok016c24_lldb_inner_probes.py`，分三轮实验（v2/v3/v4-5）在 `0x10432dd98` / `0x10017f184` / `0x10017f3c8` 装 ~30 个 Python callback BP。结论：**真正失败点是 `0x10017f184` 内 `bl 0x1001cd114(rootB=0x10e184b18, "main", 1)` 返回 0**——rootB 是空红黑树（sentinel 自指），没人注册过 key `"main"` 这个 chunk 名。先前 Dashboard "`0x10432dd98 → 0x10017f3c8`" 路径被证伪（f3c8 系列 BP 跨 run 0 命中）；C.5 path fixup 路线也被间接证伪（lookup key 是内部 PascalString 而非 FString 路径）。证据 `build/hok-016c24-readinessB-inner-args.json` | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.5 | DONE | 新增 `Scripts/hok016c25_ngr_rootB_xref_scan.py` + `Scripts/hok016c25_ngr_rootB_watch.py`；复用 `hok016c2_ngr_sentinel_writer_scan.py --target-address 0x10e184b18` 做离线直接 store 扫描（1 真 writer `0x1001cf314` = static init 空容器初始化、1 误报）+ 94 个 adrp+add xref 入 x0 的 helper 消费方 + LLDB watchpoint 在 NGR main 入口装 modify watchpoint 捕获到 2 次命中，PC 均在 `0x1001cf020`（红黑树 insert writer），backtrace 证实 insert 发生在 reporter 运行期内部（frame #4 = `0x108877bd0 +692`）。**关键结论更正**：rootB 不是"空红黑树"，而是被 reporter 内部 insert 过 2 个 entry，但 key 不是 "main"；"main" 预注册是 iOS-specific、macOS 下缺失。证据 `build/hok-016c25-rootB-writer.json` + `build/hok-016c25-rootB-xrefs.json` + `build/hok-016c25-rootB-watch.json` | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.6 | TODO（当前主线） | 定位 "main" chunk 的预注册路径：离线扫 NGR 二进制里 PascalString 字面量 `"main"`（4-byte length prefix = `04 00 00 00 00 00 00 00 6d 61 69 6e`）及其 adrp+add xref，看哪些 xref 函数在 `__init_offsets` 可达链上；运行期扩大 C.2.5 watchpoint 覆盖到 rootB 前 64 字节并在每次 insert 命中时 dump 新 node 的 key。目标：把 iOS-specific 的 "main" registrar 函数入口钉死，作为 C.5 修法的输入 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.3 | DEFERRED | 终极野蛮方案：fishhook interpose `0x108878534` 直接返回 1，跳过整条 readiness B。稳定性风险极高，仅在 C.2.6/C.4/C.5 全部证伪时作为最后兜底 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.4 | TODO | 若 C.2.6 证实 "main" registrar 不可模拟（第三方 framework / Obj-C +load / C++ template），fishhook interpose `0x10017f184` 或 `0x1001cd114` 让其对 key="main" 强制返回非零；先作为诊断验证"只要 rootB lookup 返回 1 进程就能继续跑" | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.5 | TODO | 若 C.2.6 定位到 "main" registrar 且可在 PlayTools constructor 中模拟其"注册 main entry" 行为，这是最小侵入修复。先前"pt_stat / NSBundle path fixup" 形式已被 C.2.4 间接证伪（lookup key 不是 FString 路径），此处意图改为"在 rootB 中模拟插入 main entry" | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.6 | DEFERRED | 若 C.2.6 最终指向必须由用户提供外部资源或登录态，才把问题降级到 HOK-009 类型（需要用户介入）。在此之前不主动走这条线 | `HOK-016-qts-fs-create-failed.md` |
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
- **不要再把 `0x10e1eeef0` sentinel 当主线**。HOK-016-C.2.2 已实测
  sentinel = `0x05`，足够通过 `cmp #0x4` / `cmp #0x2` 两处判定；继续
  追 writer 对当前闭环帮助不大。当前真正要抓的是
  `0x10432dd98 → 0x10017f184 → bl 0x1001cd114(rootB, "main", 1)`
  返回 0 这条 lookup 失败链。**`0x10017f3c8` 虽然静态反汇编结构相同，
  但 HOK-016-C.2.4 v2/v3/v4/v5 run 实测 0 hit，不在 readiness B 的
  实际控制流上；不要再用它做方案设计的锚点**。
- **rootB `0x10e184b18` 运行期为空红黑树（sentinel 自指）**。当在
  `probe_f184_before_bl2` 读到 header `10 3e 33 16 01 00 00 00
  10 3e 33 16 01 00 00 00  01 00 00 00 ...` 时，两 ptr 都指向
  `*rootB` 自身 + count=1，意味着**没有任何 entry 被注册过**。这是
  HOK-016-C.2.4 锁定的真因源头；C.2.5 需要定位其 writer。
- **HOK-016 LLDB BP 设置规则**：对 NGR 主 image 内的固定 unslid 地址
  （如 reporter 入口 `0x108879164`）设 BP，**必须**用
  `breakpoint set --shlib NGR --address <unslid>`；不带 `--shlib` 的
  绝对 VA 在 ASLR slide 下不命中（`hok006_ngr_lldb_runner.py` 默认
  透传 pre-run-command，调用方负责拼这条格式）。
- **HOK-016 LLDB Python BP callback 套路**：`breakpoint set` 本身
  **不支持** `--script-type python -F <func>`（会报 `unknown or
  ambiguous option`）；必须拆成 `breakpoint set ...` + 紧邻的
  `breakpoint command add -s python -F <func>` 两步。
  `breakpoint command add` 默认对最后创建的 BP 操作，所以两步之间
  **不能插入其它 `breakpoint set`**。参考
  `Scripts/hok016cx_ngr_seed_experiment.py` 的 pre_run_commands
  结构。
- **LLDB transcript 解析 BP `-C` callback 输出**：LLDB 把 callback
  命令 echo 成 `(lldb)  <cmd>`（**2 空格**），而 `breakpoint set ... -C 'cmd'`
  这种 BP-creation 行 echo 成 `(lldb) <cmd>`（**1 空格**）。解析
  "register read x0 的输出值"时必须锚定 `startswith("(lldb)  register
  read x0")` 两空格，否则会误命中 BP-creation 行里出现的
  `register read x0` 字符串。
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
  HOK-015 专属验证判据（**zero UE4 cmdline fatal** / `hok015_ngr_cmdline_preseed`
  命中 / 不把 HOK-016 尚未闭合导致的 `hok014_ngr_alert_suppressed = 1`
  误判成 HOK-015 回归）。
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
- `Scripts/hok016c_ngr_qts_w0_trace.py`：HOK-016-C.1 最小 runner。在
  `0x108877bd0` 的两条 tbz 前设 auto-continue BP 抓 `register read
  x0`、在 `+1364` 失败 sink 作 hard-stop 终结。输出
  `build/hok-016c-w0-trace.json`；transcript 稳定同时捕获 UE4 自身
  `[UE4] Project file not found: ../../../NGR/NGR.uproject` 一行，
  但 HOK-016-C.X.1 已证明此 log 与 QtsFS Create Failed 路径无因果
  关联。
- `Scripts/hok016c2_ngr_sentinel_writer_scan.py`：HOK-016-C.2.2 全
  `__text` 扫描器，覆盖 `str` / `strb` / `strh` / `str.w` 对
  sentinel `0x10e1eeef0` 的写入；输出
  `build/hok-016c2-sentinel-writer-full-text.json`。
- `Scripts/hok016c2_lldb_sentinel_watch.py`：HOK-016-C.2.x 的 LLDB
  Python helper。提供 `probe_sentinel_on_hit(...)`（读 sentinel
  值 + window）和 `install_watchpoint_on_hit(...)`（运行期装 1-byte
  modify watchpoint）。
- `Scripts/hok016c2_ngr_sentinel_probe.py`：HOK-016-C.2.2 运行期
  probe driver；在 `+900` / `+912` / `+1364` 附近抓 sentinel 值，
  并可选在 NGR `main` 入口装 watchpoint。产物
  `build/hok-016c2-sentinel-probe.json` /
  `build/hok-016c2-sentinel-watch.json`。
- `Scripts/hok016c2_ngr_step_into_readinessB.py`：HOK-016-C.2.3
  step-into driver；在 `0x108878534 +352 bl 0x10432dd98` 前 / 后、
  `0x10432dd98` 入口与 failure sink 设 BP，证实 `0x10432dd98`
  稳定被命中且返回 0。产物 `build/hok-016c2-step-into-readinessB.json`。
- `Scripts/hok016c24_ngr_readinessB_inner_args.py` +
  `Scripts/hok016c24_lldb_inner_probes.py`：HOK-016-C.2.4 的
  step-into driver + LLDB Python probe helper。在 `0x10432dd98`
  全函数 + `0x10017f184` 的 lookup 入口/出口 + `0x10017f3c8`
  的 lookup 入口/出口 + 可选的 `0x10432b734` 内部装 ~30 个
  Python callback BP，每个 BP 解析 FString / PascalString / rootB
  header；产物 `build/hok-016c24-readinessB-inner-args.json`。
  关键经验固化：(a) `breakpoint set ... -C '...'` shell callback
  与 `breakpoint set ... + breakpoint command add -s python -F`
  **不能同时对一个地址生效**（两个 BP 会冲突，产生无法分辨的
  hit），必须二选一；(b) FString 与 PascalString 的区别—— NGR
  的 Qtsk 容器里 `[length:u64][chars:N\0]` PascalString 不等同于
  UE4 FString (`[data_ptr:u64][Num:i32][Max:i32]`)，解码时要分
  开尝试。
- `Scripts/hok016c25_ngr_rootB_xref_scan.py`：HOK-016-C.2.5 的
  离线 adrp+add xref 扫描器。枚举所有把目标全局地址
  materialize 到寄存器的 `adrp+add` pair、按 dst reg + 函数分组
  给出 helper 消费视图。对 rootB 找到 94 hits / 52 不同函数、
  全部经 x0/x1 传参；产物 `build/hok-016c25-rootB-xrefs.json`。
- `Scripts/hok016c25_ngr_rootB_watch.py`：HOK-016-C.2.5 的
  LLDB watchpoint live-trace driver。在 NGR `main` 入口
  （unslid `0x107e5cad4`）装 8-byte modify watchpoint 到 rootB，
  确保只抓 dyld static init 之后的写；命中时自动 dump backtrace +
  registers。产物 `build/hok-016c25-rootB-watch.json`。
- `Scripts/hok016cx_lldb_cmdline_override.py` +
  `Scripts/hok016cx_ngr_seed_experiment.py`：HOK-016-C.X.1 seed 替换
  实验。LLDB Python callback 动态改写 `FCommandLine::CmdLine` 为 4
  候选 seed（empty / project / ue4cmdfile / uproject），每 seed 跑一
  轮 hok006 runner；产物 `build/hok-016cx-summary.json` + 4 份
  per-seed trace。**已用于证伪** "HOK-015 seed 驱动 QtsFS 失败"
  假设。

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
