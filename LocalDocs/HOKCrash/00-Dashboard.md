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
  HOK-016-C.X / HOK-016-C.2.1 / HOK-016-C.2.2 / HOK-016-C.2.3 /
  HOK-016-C.2.4 / HOK-016-C.2.5 / HOK-016-C.2.6 / HOK-016-C.4 已落地；
  HOK-016-C.2.7 当前主线）**：
  - 已完成项已经把启动前半段边界收紧：`HOK-015` 稳定消除 UE4 cmdline
    fatal；`HOK-016-A / B / C.1` 锁定 Create Failed 外层调用链与 reporter；
    `HOK-016-C.X / C.2.1 / C.2.2 / C.2.3` 已排除 seed / sentinel /
    旧分支误判。
  - 当前主线认知已从“rootB 缺 `"main"`”修正为：`"main"` 注册存在，
    但 `mainChunk` 下面的 `"1"` 二级子树 / payload contract 没有闭合；问题
    已经下钻到 override object 成形，而不是入口 key 缺失。
  - natural run 的 active failure 目前收紧到
    `0x1001bd464 -> 0x1001ba50c -> 0x1001a5014 -> storage.vtable[0x18] -> 0x10012bb7c`；
    直接现象是 null table pointer + `storage+0x30 = 0x9000b`。
  - `HOK-016-C.4` 的双 checkpoint 诊断已证明：只让 storage-method success
    还不够；但再叠加 ready/save-header success 后，第一轮 readiness B
    可以被真正顶开，并会暴露 dormant writer path 对当前 tracked
    `mainChunk+0x60` 的真实写入。
  - 剩余核心问题已经进一步收敛到 **一个 active failure + 两支 sibling branch 的先后约束**：
    `0x10432df30` 这支里的首轮 `0x1001a53a0(..., 1)` 仍会在内部
    `0x1001a588c` / OpenNodeStorage gate 返回 0；而最新
    `build/hok-016c4-force-storage-ready-open-node.json` 已证明：
    `0x10432df30` 与 `0x10432dfdc` 两支在 `ba720(key="1")` 看到的
    `ctx[0]` / `ctx+0x18` raw bytes 与 key 都一致，真正分水岭是调用当下的
    `mainChunk+0x60`——`0x10432dfdc` 这支触发 `ba720` 时 subtree root 仍为 0，
    lookup 返回 0、`ctx+0x38` 被初始化成 0，后续只能硬编码走
    `0x1001bb73c(..., 0)` 跳过 `0x1001bc970`，最终产出
    `backref-to-entry + null-child` 的 hollow wrapper；对照地，
    `0x10432df30` 这支在 `mainChunk+0x60` 已非零后再进同一个 `ba720`，
    lookup 才会返回 nonzero 并把 `ctx+0x38` 真正填起来。`hok014_ngr_alert_suppressed`
    仍为 1，进程仍停在僵尸态。

- **修复路线（优先级最高 → 最低；按 HOK-016-C.2.7 当前证据重排）**：
  1. `HOK-016-C.2.7`（**当前主线**）：继续拆 `ba940` / second-gate 这条
     **override object 成形链**，但当前优先级已经改成并行回答两件事：
     (a) 为什么 `0x10432df30` 这支里的首轮 `0x1001a53a0(..., 1)` 会在内部
     `0x1001a588c` / OpenNodeStorage gate 上返回 0；
     (b) 为什么 `0x10432dfdc` 这支会在 `mainChunk+0x60` 仍为 0 的时刻先触发
     `ba720(key="1")`，从而让 lookup 返回 0、把 `ctx+0x38` 初始化成 0，使后续
     只能硬编码走 `0x1001bb73c(..., 0)`，跳过 `0x1001bc970` child/payload 路径并稳定
     产出 `backref-to-entry + null-child` 的 hollow override wrapper。
     同时保留对 natural run 前置条件的追踪：继续沿
     `0x1001bd464 → 0x1001ba50c → 0x1001a5014 → storage.vtable[0x18] → 0x10012bb7c`
     解释 `0x9000b` / null table 的来源，并对
     `0x10432dfdc → 0x10017f3c8 → 0x1001bc220 → 0x1001bc970 → 0x1001c6da4`
     这条 dormant writer path 的自然激活条件做按需 probe。
  2. `HOK-016-C.5`：若 C.2.7 能给出可重复的 override payload 成形签名
     （或完整的 `mainChunk -> "1"` 注册 / 对象构造路径），就在
     PlayTools constructor 里按同样签名补齐；这是新的最小侵入修法。
  3. `HOK-016-C.4`：若上述路径过深且对象形状无法安全模拟，基于
     PlayTools 现有 bundle-scoped runtime hook / direct patch 基建，
     对 second-gate / override object 闭合做诊断性强制成功验证，确认
     只要这层 contract 闭合，进程是否就能继续跑。
  4. `HOK-016-C.3`：终极野蛮方案——fishhook interpose
     `0x108878534` 直接返回 1，跳过整条 readiness B。稳定性风险极高。
  5. `HOK-016-C.6`：降级到 HOK-009 类型（需要用户介入）。

- **已证伪路径**：
  - ~~HOK-016-C.X~~：seed 内容不驱动 QtsFS 失败，`w0@+912` 在 4 组 seed 下都保持 0。
  - ~~HOK-016-C.2.1 / C.2.2~~：sentinel 不是当前主因；运行期已是 `0x05`，也没有可用 writer 线索。
  - ~~HOK-016-C.2.3 里的 `0x10432dd98` → `0x10017f3c8` 路径~~：实际失败链经过 `0x10017f184`，不是旧假设分支。
  - ~~HOK-016-C.5 path fixup~~：lookup key 是内部 PascalString `"main"`，不是可由路径修正解决的问题。
  - ~~"rootB 从头到尾完全是空"~~：后续 run 已证明 rootB 会被 insert；当前缺口在更深层的 `mainChunk -> "1"` 子树 / payload。

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

- **当前主线**：`HOK-016-C.2.7`——继续把 **两个 sibling branch 如何共同把 second-gate 压回 0** 这条链钉死。当前已知：natural run 的 active
  failure 已收紧到 `0x10012bb7c` null table + `storage+0x30 = 0x9000b`；dual-force
  诊断 run 则进一步证明 dormant writer path 不仅会真实写当前 tracked
  `mainChunk+0x60`，还把第二个分水岭从“`ba720` 自己看错了上下文”收紧成了
  “**调用 `ba720(key="1")` 当下 `mainChunk+0x60` 是否已经非零**”：
  `0x10432dfdc` 这支触发 `ba720` 时 subtree root 仍为 0，所以 lookup 返回 0、
  `ctx+0x38 = 0`，后续只能硬编码走 `0x1001bb73c(..., 0)`，最终把一份
  `backref-to-entry + null-child` 的 hollow wrapper 写进 `slot1`；对照地，
  `0x10432df30` 这支在 `mainChunk+0x60` 已非零后再进同一个 `ba720`，lookup
  才会返回 nonzero 并把 `ctx+0x38` 真正填起来。但 branch A 的首轮
  `0x1001a53a0(..., 1)` 仍会在 `0x1001a588c` / OpenNodeStorage gate 上失败，
  `0x1001bb844` 也仍只负责补 `entry` backref。目标状态不变：
  `launch-events.jsonl` 里 `hok014_ngr_alert_suppressed` 事件**真正归零**；进程
  `RSS ≥ 800MB` / 线程数 ≥ 20 / 窗口在主屏内 / `%CPU` 持续 ≥ 5%。

- **当前卡点**：当前未闭合的 contract 已不再是“`mainChunk+0x60` 从头到尾没写”
  或“final entry 的 `slot1` 没写进去”，而是 **谁该为 `0x10432df30` 这支满足
  `0x1001a588c` / OpenNodeStorage gate，以及为什么 `0x10432dfdc` 这支总在
  `mainChunk+0x60` 仍为 0 的时刻先触发 `ba720(key="1")`**。换句话说，当前 second-gate
  `0x10017faa0 -> 0x1001be550(flag=1)` 看到的对象已经来自 final entry 的真实
  override slot，但它自身仍缺 child/payload 语义，所以返回值继续被压成 0。

- **下一步默认规划**：
  1. `HOK-016-C.2.7`：优先围绕 `ba720` / `ba940` / `0x1001a53dc` / `0x1001bb73c` 一带继续补 live trace，直接回答：
     (a) 为什么 `0x10432df30` 这支里的首轮 `0x1001a53a0(..., 1)` 会卡在 `0x1001a588c` / OpenNodeStorage gate；
     (b) 为什么 `0x10432dfdc` 这支会在 `mainChunk+0x60` 仍为 0 的时刻先触发 `ba720(key="1")`，从而让 lookup 返回 0、把 `ctx+0x38` 初始化成 0，最终只能走硬编码 `w3 = 0` 的 `0x1001bb73c`；
     (c) 当前 natural run 里要满足什么额外前置条件，才能不再落回这份 hollow wrapper。
  2. 并行保留对 natural run 前置条件的追踪：继续沿
     `0x1001bd464 -> 0x1001ba50c -> 0x1001a5014 -> storage.vtable[0x18](0x1001b3d0c)
     -> 0x10012bb7c` 解释 `0x9000b` / null table 的来源；同时围绕
     `0x10432dfdc -> 0x10017f3c8 -> 0x1001bc220 -> 0x1001bc970 -> 0x1001c6da4`
     继续拆 dormant writer path 的自然激活条件。
  3. 若 C.2.7 能定位可重复的对象成形签名或完整 `mainChunk -> "1"`
     注册路径，进入 `HOK-016-C.5`：在 PlayTools constructor 里补齐该契约。
  4. 若 C.2.7 证实路径过深、对象形状又无法安全模拟，进入 `HOK-016-C.4`：
     做 bundle-scoped 诊断性强制成功验证，先确认只要这层 contract 闭合，进程
     是否就能继续跑。
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
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。
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
| HOK-001 | DONE | 复现 NGR 启动崩溃并固定基线证据 | — |
| HOK-002 | DONE | 落地 app-scoped 最小兼容启动 gate | — |
| HOK-003 | DONE | 补齐最小兼容档 settings 的 MCP 自动化 | — |
| HOK-004 | DONE | 固化 `10s settle window` 启动 runner 与失败退出语义 | `HOK-004-启动验证与settle-window.md` |
| HOK-005A/B/C/D | DONE | 最小化深层 bootstrap 副作用（skip + 延迟） | `HOK-005-深层bootstrap分层最小化.md` |
| HOK-006 | DONE | 固化 LLDB 自动化入口与结构化证据链 | `HOK-006-LLDB归因与crash-window压缩.md`（按需） |
| HOK-007A | DONE | 完成首轮 faulting callsite 一致性映射 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-007B | DONE | 候选 E 设计与 apply/revert runner；当前已 revert | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-011 | DONE | 修正 `0x10e2146f8` 真 writer 入口并排除 `__init_offsets` 主线 | `HOK-011-静态初始化链分析.md`（按需） |
| HOK-012-A/B/C（全系列） | DONE | 补齐 HOK-012 LLDB 工具链；当前按需使用 | `HOK-012-工具链与方法论归档.md`（按需） |
| HOK-013 | DONE | `0x10e2146f8` slot preheat 落地 | `HOK-013-slot-preheat.md` |
| HOK-014 | DONE（HOK-016 闭合后降级为安全网） | `UIAlertController` suppressor 落地；当前仅作安全网 | `HOK-014-alert-suppressor.md` |
| HOK-010 | DONE | `rootWorkDir` self-heal 落地 | `HOK-014-alert-suppressor.md`（合并说明） |
| HOK-015 | DONE | `FCommandLine` preseed 落地，218 条 guard 全部放行 | `HOK-015-cmdline-preseed.md` |
| HOK-016-A | DONE | 静态定位 `QtsFileSystem` 字符串族与 reporter | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-B | DONE | 运行期锁定 reporter 调用链与 Create Failed 判定点 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.1 | DONE | 锁定 readiness B（`0x108878534`）为失败源 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.X | DONE（证伪） | 证伪“seed 内容驱动 QtsFS 失败” | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.1 | DONE（证伪） | 证伪“sentinel writer 在 NGR `__init_offsets` 链上” | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.2 | DONE（证伪） | 证伪“sentinel 未 bump” | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.3 | DONE | 证实 `0x10432dd98` 稳定返回 0 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.4 | DONE | 收紧到 `0x10017f184` 的 lookup 失败 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.5 | DONE | 补齐 rootB writer / insert-helper 的侧证 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.6 | DONE | 更正为 `mainChunk` 的 `"1"` 子树缺失，不是 `"main"` 缺失 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.7 | TODO（当前主线） | 继续拆 `override candidate -> final entry slot1 -> second-gate payload`：优先解释 `0x1001a53a0(..., 1)` 为什么返回 0、fallback 为什么固定落到 `0x1001bb73c(..., 0)`，以及 natural run 触发 hollow wrapper 的前置条件 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.3 | DEFERRED | 终极野蛮方案：fishhook interpose `0x108878534` 直接返回 1，仅作最后兜底 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.4 | TODO | 若 C.2.7 证明自然路径过深或对象形状不可安全模拟，再做诊断性强制成功验证 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.5 | TODO | 若 C.2.7 找到可重复的对象成形签名 / 注册路径，就在 PlayTools constructor 中按同样签名补齐 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.6 | DEFERRED | 仅在必须依赖外部资源或登录态时，才降级到需要用户介入的路线 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-D | TODO | HOK-016-C 落地后做 live 验证，并把 HOK-014 降级为冷备安全网 | `HOK-016-qts-fs-create-failed.md` |
| HOK-007C | DEFERRED | 下游 crash 的离线映射 + 可逆 patch；当前无触发动机 | `HOK-007-二进制意图分析与callsite映射.md`（按需） |
| HOK-008 | TODO | 把“revert 候选 E → `rootWorkDir=1` → 启动 → 证据采集 → pass 判定”固化成单脚本 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号 / 手工 UI 的后续验证；执行前必须得到用户确认 | 不执行 |

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
> 各主文档都把长篇细节（多轮验证口径、LLDB 证据快照、逐步下钻证据）
> 再下沉到了同名 `*-appendix-*.md` 附录文件——附录的进入时机都写在各
> 附录开头的"何时读"提示里，日常阅读对应主文档时不必随手打开附录。

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
  LLDB 工具链与 live-trace 方法论归档（证据 6 种语义 / CLI 清单 /
  secondary fault 解读下沉到 `HOK-012-appendix-evidence-and-cli.md`）；
  当前日常启动不需要，仅在追查新 slot / 新 fatal-before-modal 路径
  时参考。
- `LocalDocs/HOKCrash/HOK-013-slot-preheat.md`（+
  `HOK-013-appendix-verification.md`）：HOK-013 stub 写入的设计决策、
  实现位置；三轮验证口径与已否决方案细节在附录。
- `LocalDocs/HOKCrash/HOK-014-alert-suppressor.md`（+
  `HOK-014-appendix-verification.md`）：HOK-014 swizzle 的设计决策、
  实现位置；live 验证口径与常见误区（`blockingDialogs>=1` 判读等）
  在附录。
- `LocalDocs/HOKCrash/HOK-015-cmdline-preseed.md`（+
  `HOK-015-appendix-verification.md`）：HOK-015 预种 cmdline 的设计
  决策、实现位置；4 轮验证口径 + HOK-014/016 联动归属规则 + 非目标/
  边界在附录。
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`（+ 5 份附录：
  `HOK-016-appendix-tooling.md` / `...-C23-C24.md` / `...-C25-C26.md` /
  `...-C27.md` / `...-CX.md`）：当前主线 HOK-016 的骨干证据 + 根因链
  + 修复方向；脚本目录、逐层下钻证据、seed 替换实验详情分别在对应
  附录（附录开头的"何时读"提示给出进入时机）。

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
- `Scripts/hok016c27_ngr_mainchunk_subtree_trace.py` +
  `Scripts/hok016c27_lldb_mainchunk_watch.py`：HOK-016-C.2.7 的
  live trace driver + LLDB helper。在 `0x10017f1dc` 动态装
  `mainChunk+0x60` watchpoint，并对 `0x1001bd448` /
  `0x1001ba82c` / `0x1001ba50c` / `0x1001a5014` / `0x10432e074` 采样；
  当前结果证明 watchpoint 安装干净、到 failure sink 前 `0 hit`，且当前
  run 只出现 1 次 `lookup2` 命中；`lookup2` miss 后的 `ba50c` fallback
  builder 会返回非零对象，但 builder object 的 `+0x60` 仍为 0，
  `0x1001a5014` 也继续返回 0。产物
  `build/hok-016c27-mainchunk-subtree-trace.json`。
- `Scripts/hok016c4_ngr_force_storage_success.py`：HOK-016-C.4 的诊断性
  force-success runner。当前支持两档实验：
  (a) 只强制 `0x1001a522c` 的 storage-method return；
  (b) 再叠加 `0x1001a6958` 的 ready/save-header return。
  后者已证明 `0x10017f184` / `0x10432dd98` 能被推成 success，并能激活
  dormant writer path；产物
  `build/hok-016c4-force-storage-success.json` /
  `build/hok-016c4-force-storage-ready-success.json` /
  `build/hok-016c4-force-storage-ready-no-wp.json`。
- `Scripts/hok016c27_ngr_mainchunk_callers.py`：HOK-016-C.2.7 的
  离线 caller scan。枚举 `0x1001ba82c` / `0x1001bd448` /
  `0x1001cd114` 的 direct callers、shallow callers 与附近 `#0x60`
  store；当前结果显示 `lookup2` 有 7 个 direct caller function，
  `0x1001ba50c` 是唯一带 5 个 shallow callers 的 wrapper 候选。产物
  `build/hok-016c27-mainchunk-callers.json`。
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
