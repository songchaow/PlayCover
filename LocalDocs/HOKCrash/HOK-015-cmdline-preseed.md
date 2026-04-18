# HOK-015: PlayTools 侧预种 `com.tencent.ngr` 的 UE4 CommandLine

> 本文只沉淀 HOK-015 的**设计依据、实现口径、验证口径**。任务状态以
> `LocalDocs/HOKCrash/00-Dashboard.md` 为准；本文不出现 "DONE / TODO /
> 已落地 / 下一步" 等字样，也不写日期快照。

## 目的

在 HOK-013（`0x10e2146f8` stub 预热）与 HOK-014（UIAlertController
swizzle）之后，`com.tencent.ngr` 进程不再秒崩，但**真实 UE4 GameThread
并未真正跑起来**——UE4 在 `Checking for command line in
ue4commandline.txt ... FOUND!` 之前约 141ms 里被某段 SDK static
initializer 提前读取 `FCommandLine::Get()`，UE4 因 `bInitialized=false`
打出 3 条 fatal，接着：

1. 构造 `UIAlertController(title="Message", message="QtsFileSystem
   Create Failed!!")` 投递到主 VC；HOK-014 压下这个 alert 的 UI 表
   现、但 alert 本身的**构造与 present**仍然发生（`hok014_ngr_alert_suppressed`
   事件 ≥1）。
2. UE4 fatal handler set `GIsRequestingExit=true`；GameThread 随之退
   出 tick loop；进程落入僵尸态（`%CPU ≈ 2%`、RSS ≈ 333MB、线程全部
   sleeping、主窗口停在 UE4 未完成布局时的随机 bounds 如 `Y=-1007`）。

HOK-015 目的是**在 PlayTools constructor 最早时刻把 NGR 的
`FCommandLine` 存储预置成已初始化状态**（与 HOK-013 相同的套路：预
写 NGR `__common` 槽位），从而根本消除 fatal：

- UE4 `Fatal error: ... Attempting to get the command line ...` 从不
  触发；
- UIAlertController 从不构造；
- `GIsRequestingExit` 保持 false；GameThread 正常进入主 tick loop；
- app 真正"活着"。

本方案仍然遵守 Dashboard 最终目标的硬约束：**不改动 NGR app 二进
制、bundle-scoped 到 `com.tencent.ngr`、失败时无副作用**。

## 设计决策

### D1：为什么不是扩展 HOK-014（让 alert completion 带 Close action）

HOK-014 改成"模拟用户点 Close"可以消除 alert 的可见表现，但**无法阻
止 UE4 fatal handler 之后的 `GIsRequestingExit=true`**——UE4 的 alert
completion 回到主路径后仍然会 `FPlatformMisc::RequestExit(true)`。
因此 HOK-014 类型的改动只能停留在"UI 外观"层，不能消除僵尸态。

**只有消除 fatal 本身**才能让 UE4 不退出。这要求在 `FCommandLine::Get()`
的首次 early-read 时就已经读到合法值——等价于"提前让 `bInitialized=true`
且 cmdline buffer 填好"。

### D2：写什么值

`ue4commandline.txt` 的内容已确认为 `"../../../NGR/NGR.uproject"`
（相对 iOS 打包布局的 executable-relative 路径）。UE4 的正常
bootstrap 在 `Checking for command line in ...` 之后**本来**会把这
个值读进 `FCommandLine::InternalCmdLine`，HOK-015 只是把这一步提前
到 PlayTools constructor。

两种选择：

- **(a) 用 HOK-010 之后的 cwd=`/`**：`"../../../NGR/NGR.uproject"` 按
  UE4 默认 base（通常是 executable 所在目录）解析。
- **(b) 写绝对路径**：`"/Users/.../com.tencent.ngr.app/NGR/NGR.uproject"`
  这条路径在 iOS 打包产物里**根本不存在**（打包后不保留 .uproject
  文件），所以给 cooked-only 走的路径更合适。

  *实际情况*：NGR app bundle 没 `.uproject` 文件，只有 `cookeddata/ngr/`
  目录；UE4 的 runtime 会走 cooked-only 路径。UE4 fatal 不是因为
  "找不到 uproject"，是因为"command line 在 init 前被读"。因此 cmdline
  内容其实**只要是一个合法字符串就足够**——UE4 随后在 `FCommandLine::Set`
  的官方路径里会用合法值覆盖它。

**选 (a)**：直接复用 NGR 自己的 `ue4commandline.txt` 内容
`"../../../NGR/NGR.uproject"`。这让 HOK-015 的预种状态与 UE4 正式初
始化后的状态**严格一致**，不引入行为差异。

### D3：何时写

同 HOK-013：PlayTools `__attribute__((constructor)) initialize(void)`
的第一层，紧接 `pt_ngr_preheat_slot_once()`（HOK-013）之后、
`pt_ngr_install_alert_suppressor_once()`（HOK-014）之前。

顺序规则：

1. `pt_ngr_preheat_slot_once()` —— HOK-013，最优先，让任何 dyld
   initializer 里 reader 读 `0x10e2146f8` 都安全；
2. `pt_ngr_preseed_cmdline_once()` —— HOK-015，第二位，让任何
   `FCommandLine::Get()` early-read 都拿到合法值；
3. `pt_ngr_install_alert_suppressor_once()` —— HOK-014，最后作为安
   全网，拦任何万一还跑到 `presentViewController:` 的 alert；
4. `[PlayCover launch]` —— 进入正常 PlayTools 逻辑。

三者之间**没有数据依赖**，但按上面顺序 defense-in-depth（越早消除
根因越好）。

### D4：如何定位 `bInitialized` + `CmdLine` 的 slot

纯离线静态分析（沿用 HOK-011 工具链）：

1. 在 NGR 二进制里 grep 字符串 `"Attempting to get the command line
   but it hasn't been initialized yet"`（已确认存在）。
2. 找引用该字符串的函数——就是 UE4 `FCommandLine::Get()`（或其 fatal
   包装）。
3. 函数入口处应有 `ldrb` 从某个 `__common` slot 读 `bInitialized`；
   紧接一个 `cbz` / `tbz` 跳到 fatal 分支。把这个 slot 的地址记为
   `UE4_CMDLINE_BINITIALIZED`。
4. 正常分支（非 fatal 分支）里会有 `adrp + add` 把 `CmdLine` char
   buffer 的基址加载到某个寄存器；这个地址是
   `UE4_CMDLINE_BUFFER`。容量通常是 `UE4_CMDLINE_MAX = 16384` bytes
   （UE4 iOS 默认），可从 `FCommandLine::Set` 的 `memcpy` 参数推算。
5. 所有地址都按 NGR 主 image 的 unslid vmaddr 记录；runtime 用
   HOK-013 已经实现的 `pt_ngr_find_main_image()` + slide 计算。
6. 输出结构化报告到 `build/hok-015-cmdline-slots.json`：
   ```json
   {
     "bInitializedAddr": "0x...",
     "cmdlineBufferAddr": "0x...",
     "cmdlineBufferSize": 16384,
     "markerString": "Attempting to get the command line ...",
     "markerAddr": "0x...",
     "fatalBranchFunctionEntry": "0x..."
   }
   ```

如果静态分析结果与预期不一致（比如 `bInitialized` 是 uint32 而不是
uint8、或 buffer 容量不是 16384），报告里给出实际观察值，HOK-015-B
按实际值落地、不硬编码。

### D5：写入的原子性与幂等

- `dispatch_once` 保证整个进程生命周期只写一次。
- 写入顺序：**先写 buffer、后置 `bInitialized=true`**——任何读者在
  `bInitialized=true` 观察到的 buffer 一定是有效的。加 `std::
  atomic_thread_fence(memory_order_release)` 等价语义（`__sync_synchronize()`
  在 clang 下对 AArch64 发 `dmb ish`）。
- 读取前检查 `bInitialized` 当前值：若已为 true，说明 UE4 本尊已经
  init（通常不会在 PlayTools constructor 时发生），写事件
  `status=already-initialized` 直接 return。

### D6：失败时无副作用

- `pt_ngr_find_main_image` 失败 / `unslidTextVMAddr != 0x100000000`
  / 静态定位地址与实际二进制不符 → 写事件 `status=locate-failed`
  直接 return；不 touch 任何 slot。
- `bInitializedAddr == 0` 或 `cmdlineBufferAddr == 0` → 同上。
- 这些失败路径不会让 app 崩——最坏情况回到 HOK-013 + HOK-014 的兜底
  状态（alert 被 swizzle 压制、进程僵尸存活）。

### D7：与 HOK-014 的关系

HOK-014 现在是**必要闭环**（没有它 alert 会挂 UI）；HOK-015 落地后：

- 观察期标准：`hok014_ngr_alert_suppressed` 事件次数 = **0**。
- 若连续多轮 live 验证都是 0，HOK-014 降级为 **纯冷备安全网**（代码
  保留，事件入口保留，但日常观测期望一次都不触发）。
- HOK-014 不自动 revert——作为"UE4 未来可能在别的路径上弹 alert"的
  防御层，保留代码对后续维护成本近 0。

### D8：bundle-scoped gate

复用 HOK-013 的 `pt_ngr_should_preheat_slot()`（精确字符串比较 bundle
identifier = `com.tencent.ngr`）。其它 bundle 完全不走 HOK-015 路径。

## 实现位置

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：
  - 宏 `NGR_UE4_CMDLINE_BINITIALIZED_UNSLID` /
    `NGR_UE4_CMDLINE_BUFFER_UNSLID` / `NGR_UE4_CMDLINE_BUFFER_SIZE` /
    `NGR_UE4_CMDLINE_SEED_VALUE`。
  - `pt_ngr_preseed_cmdline_once()`：`dispatch_once` + bundle gate +
    slide 计算（复用 HOK-013 的 helpers）+ 写 cmdline buffer + release
    fence + 置 `bInitialized=true` + 诊断事件。
  - constructor 第二行调用（紧接 HOK-013 之后、HOK-014 之前）。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：新增
  `@objc static public func recordHOK015CmdlinePreseed(details:)`，
  把事件 `hok015_ngr_cmdline_preseed` 落到 `launch-events.jsonl`。
- `Scripts/hok015_ngr_cmdline_locator.py`（新建）：静态扫描器；
  `--target-app-path` 指向 `~/Library/.../com.tencent.ngr.app/NGR`；
  输出 `build/hok-015-cmdline-slots.json`。

## 验证口径

### 第一轮：静态分析 + 写入落地

前置：HOK-013、HOK-014 保持 apply；plist `rootWorkDir=1`；候选 E 保
持 revert。

1. 跑 `python3 Scripts/hok015_ngr_cmdline_locator.py
   --output build/hok-015-cmdline-slots.json`；核对 `bInitializedAddr`
   与 `cmdlineBufferAddr` 在合理 `__common` / `__data` 范围。
2. 按扫描结果写入 `PlayLoader.m` 宏；重建 PlayTools xcframework +
   重装 PlayCover。
3. 自由启动 NGR（`launch_app`，不带 LLDB），等 60s。
4. 判据（全部满足才视为第一轮通过）：
   - `launch-events.jsonl` 出现 `hok015_ngr_cmdline_preseed
     status=primed`，details 里 `bInitializedBefore=0` /
     `bInitializedAfter=1` / `cmdlinePreview="../../../NGR/NGR.uproject"`；
   - 子进程 stderr / dyld log 里**不再出现** `Attempting to get the
     command line but it hasn't been initialized yet` 与
     `[UE4] Fatal error: [File:Unknown] [Line: 34]` 任何一条；
   - `launch-events.jsonl` 里 `hok014_ngr_alert_suppressed` 事件
     **次数 = 0**；
   - `ps -p <pid>` 采样：`%CPU ≥ 5%` 持续 ≥ 30s，RSS ≥ 800MB，线程数
     ≥ 20；
   - `CGWindowListCopyWindowInfo` 读主窗口 bounds：与主屏 frame 有
     非空交集（`bounds.x < screen.width && bounds.x + bounds.w > 0`
     且 Y 同理），`kCGWindowMemoryUsage > 1_000_000`；
   - `~/Library/Logs/DiagnosticReports/NGR-*.ips` 无新文件。

### 第二轮：HOK-014 降级为冷备

在连续 ≥ 3 轮第一轮判据全部通过后：

1. 把 Dashboard TODO 表里 HOK-014 的状态描述改成"DONE（冷备安全网）"；
   代码不动。
2. 若后续某轮 `hok014_ngr_alert_suppressed > 0`，视为回归：立刻把该
   轮 details（title/message）作为 HOK-015 / 下一个修复的输入材料，
   不允许"容忍 alert 再次出现"。

### 第三轮：bundle-scoped gate 不影响其它 bundle

- 其它已安装 bundle 的 `launch-events.jsonl` 里**不**出现
  `hok015_ngr_cmdline_preseed` 事件；
- 快捷检查：
  ```
  grep -l "hok015_ngr" \
    ~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/*/launch-events.jsonl
  ```
  应只返回 `com.tencent.ngr` 的子目录。

## 非目标 / 边界

- **HOK-015 不解决** UE4 主循环进入后的业务逻辑错误（例如登录、网
  络、账号、MSDK 初始化失败等）。这些属于 HOK-009 范畴，需要用户
  介入。
- **HOK-015 不改** UE4 cmdline 的语义——它只是把 `FCommandLine::Set`
  发生的**时机**提前；UE4 自己后续 `Set()` 调用仍然走正常路径（要么
  覆盖为同值 no-op、要么写新值）。
- **HOK-015 不适用于其它 UE4 app**。别的 bundle 的 `__common` 布局
  不一样、cmdline 值不一样；推广需要重做 HOK-015-A 静态定位 +
  bundle gate。

## 参考

- `HOK-013-slot-preheat.md`：同一套路的最早落地、slide 计算 helper、
  bundle gate 复用。
- `HOK-014-alert-suppressor.md`：HOK-014 swizzle 的实现；HOK-015 闭
  合后 HOK-014 的定位从"必要闭环"降级为"冷备安全网"。
- `HOK-011-静态初始化链分析.md`：`__common` 槽位扫描器套路。
- `HOK-012-工具链与方法论归档.md`：LLDB watchpoint / abort-stop / 对
  话框污染 gate 的工具链；HOK-015-A 静态定位失败时可以用 watchpoint
  在 fatal 触发的瞬间捕获 `bInitialized` / cmdline buffer 实际地址。
