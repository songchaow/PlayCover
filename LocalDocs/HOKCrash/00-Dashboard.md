## HOKCrash Dashboard

> **单一来源规则**：`com.tencent.ngr`（`王者荣耀世界`）启动崩溃问题的优先级、主线、TODO、验证口径只在本文维护；长日志、单轮实验细节和大段崩溃分析下沉到子文档，主文档始终保持可快速通读。

## 最终目标

- 让 `com.tencent.ngr` 在 PlayCover 中**稳定启动并持续存活**，不再出现当前这类启动期秒崩。
- 当前**不要求**为该 app 保留 `metal capture` 与 `shader source replacement`；兼容启动优先于截帧能力。
- 默认先走**最小、可逆、app-scoped** 的 PlayCover/PlayTools 兼容修复；只有这条线证伪后，才升级到 app 二进制意图分析与可逆 patch。
- 日常构建、验证、证据收集必须能由 agent 独立完成；若某一步确实需要用户介入，必须先得到用户确认。

## 全局约束

- 对 `com.tencent.ngr` 的修复默认应为**按 bundle 精准生效**，不扩大为全局行为改动，除非后续证据证明全局改动安全且必要。
- 对该 app 的默认兼容配置应把 `metal capture`、`startup injection`、`shader replacement` 视为**非必要能力**；它们不是日常 gate。
- 默认优先级：**对齐 iOS 环境 / 让 iOS 预置的 framework/ObjC/static ctor 链在 macOS 下也能跑起来** → **PlayTools 最小 bundle-scoped 兼容改动** → **LLDB / faulting instruction 归因** → **app 二进制可逆 patch（作为兜底）**。
- 不允许把"用户手工登录、手工点 UI、手工看窗口表现"作为日常验证 gate；这些只能作为例外步骤，且需先确认。
- 主文档只保留决策信息、默认执行路径和高频复用经验；历史细节、长日志、反复试错过程必须下沉到子文档。

## 主线任务

- **当前结论**：`HOK-004`、`HOK-005A`、`HOK-005B`、`HOK-005C`、`HOK-005D`、`HOK-006`、`HOK-007A`、`HOK-007B`、`HOK-011`（静态分析阶段）、`HOK-012-A`（bundle-scoped `DYLD_PRINT_INITIALIZERS=1` 注入）、`HOK-012-B`（watchpoint + dyld-log 自动化）、`HOK-012-C.1`（legacy 基线 live 确认候选 E 有效）、`HOK-012-C.2`（首轮 watchpoint live run，`0x10e2146f8` 0 hit + secondary fault 指向 HOK-010）均已完成。经过 HOK-011 的深度静态分析，之前在 HOK-007B 做的"候选 E = 在 faulting `ldr x8, [x19]` 处无条件跳 epilogue"已被重新认识为**掩盖症状的 workaround**，而真正的根因是 `com.tencent.ngr` 的 dyld static initializer 链在 macOS/PlayCover 下**没按 iOS 上应有的顺序运行**：faulting caller（`__init_offsets[1563]` / `0x10460e2c0`）直接 `ldr x0, [0x10e2146f8]`，假设该槽位已被更早的代码填好；但静态分析（`Scripts/hok011_ngr_common_init_chain.py` + 全二进制逆向 call graph）证明**NGR 自己的 `__init_offsets` 链路中没有任何入口能传递调用到写该槽位的 lazy accessor `0x103a29b7c`**，因此该槽位只可能由外部机制（embedded Framework initializer / ObjC `+load` / 跨 dylib 静态构造链）预先填充。HOK-012-C.1/C.2 的 live 证据表明：候选 E apply 状态下 app 能跨过 `0x10480df08`、跑出 PlayTools 完整 compat 事件序列、进入 `GCloudCore` / `PluginManager` / `CAppLifecycleLaunch` 的 C++ ctor 链，并最终在 **UE4 层撞上 `QtsFileSystem Create failed.`**（HOK-010 方向）伴随一个 secondary fault（Thread #10，`0x1047862bc` + `address=0x30`，属 HOK-010 下游，**不是 `0x10e2146f8` reader 的原始 fault**）；`0x10e2146f8` 上的 8 字节 watchpoint 本轮 0 hit，但 backtrace 中已出现 writer 函数 `0x103a29b7c` 内 + `0x434` 偏移（`0x103a29fb0`），说明 accessor **在本轮被触达但没有走 first-initialization 分支**（很可能 slot 在 watchpoint 装入窗口之前就被更早的 store 填好，或 LLDB `target create` → `run` 之间存在 race）。HOK-012-A/B 的自动化栈保持不变：host 侧（`PlayApp` 与 MCP `LaunchService` 两处 `effectiveLaunchEnvironment`）的 bundle-scoped `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 注入、headless LLDB runner + `launch_app_with_lldb` MCP 工具 + `hok006_ngr_lldb_runner.py` 脚本三层同步扩展的 watchpoint 自动化（`watchAddress`/`watchSize`/`preRunCommands`）、`process launch -e <dyldInitializersLogPath>` 子进程 stderr 重定向、`stop 抓 backtrace 后 continue` 的多命中循环、默认地址 `0x10e2146f8` / 默认 size 8 / 默认日志 `build/hok-012-ngr-dyld-initializers.log` / 默认报告 `build/hok-012-ngr-watchpoint-report.json` 全部经过 live 验证可用，legacy 行为通过 `LLDBRunOptions.default`/缺省 MCP 字段保持 100% 兼容。
- **当前已知事实**：
  - faulting PC `0x10480df08`，`x19 = 0`，语义是从未被初始化的空指针 deref；直接由 caller `ldr x0, [0x10e2146f8]` 把 null 传进来。
  - `0x10e2146f8` 位于 `__DATA,__common`，dyld 只做零初始化；`dyld_info -fixups` 没有 bind/rebase 条目。
  - NGR 全二进制对该地址**只有 1 个 store 点**：`0x103a29f7c: str x0, [x8, #0x6f8]`，位于函数 `0x103a29b7c` 内，该函数是 `__cxa_guard` 保护的 Meyers-singleton accessor，只被 `0x107e5df10`（Logger accessor）这 1 个函数调用，`0x107e5df10` 在全二进制中只有 1 个调用点，且其调用者**不属于 __init_offsets**。
  - 反向 BFS 调用图（仅在 NGR 自身 __text 内的 `bl` 边上）从 `0x107e5df10` 出发**无法到达任何 __init_offsets 入口**——该 slot 的 writer 在 NGR 自身 initializer 链中不可达。
  - `DYLD_PRINT_INITIALIZERS=1` 直接裸跑 NGR 主二进制时，dyld 输出同时伴随 **ObjC 重复类警告**：`PxFrameworkLoader`、`AReachability`、`PxDyLibFrameworkLoader` 分别在两个 image 中同时声明；iOS vs macOS 对重复类的挑选顺序不同，是 iOS 行为差异的一个非常强的候选。
  - `Scripts/hok007b_ngr_patch_runner.py` 当前状态：已 re-apply 候选 E（`currentBytesHex=07000014`），backup `build/hok-007b-backups/hok-007b-b0e109d761a3eefb.bin` 保留；HOK-012 期间先保留 patch，确保 app 能跑过 index 1563 从而观察到下游 writer 真的被谁触发。
  - HOK-012-A 已落地：host 侧 `PlayApp.minimalStartupCompatDiagnosticEnvironment` / MCP 侧 `LaunchService.minimalStartupCompatDiagnosticEnvironment` 都是 `{"DYLD_PRINT_INITIALIZERS": "1", "DYLD_PRINT_APIS": "0"}`；`launch_app` 与 `launch_app_with_lldb` 两条启动路径共用同一套注入语义，单元测试（`LaunchServiceTests` 覆盖 inject/non-inject 分支）。
  - HOK-012-B 已落地：新增 `LLDBRunOptions` 类型（`watchAddress`/`watchSize`/`preRunCommands`/`dyldInitializersLogPath`）贯穿 `LaunchService.launchAppWithLLDB` → `runLLDBHeadless` → `launch_app_with_lldb` MCP schema → `hok006_ngr_lldb_runner.py` CLI；watchpoint 模式下 `parseLLDBEvidence` 改为优先挑选**非 watchpoint** 的 stop 作为 fault 字段，同时新增 `parseWatchpointHits` 把每一段 `stop reason = watchpoint …` 切成带 `oldValue`/`newValue`/`frame #0`/`backtrace` 的结构化 `WatchpointHit`；`LaunchServiceTests` 追加 5 个单元测试（默认 options 兼容、非空地址触发、hit 切片、非 watchpoint stop 优先、options 透传），23 个测试全部通过。
  - 结构化证据：`build/hok-007-ngr-callsite-report.json`（HOK-007A 一致性）、`build/hok-007b-ngr-patch-report.json`（HOK-007B apply 状态）、`build/hok-011-ngr-common-init-chain-report.json`（HOK-011 扫描报告）、`build/hok-011-analysis-notes.json`（HOK-011 深度静态分析 hand-off）、`build/hok-012-ngr-watchpoint-report.json`（HOK-012-B watchpoint 命中清单，脚本 `--watch-address` 启用后生成）、`build/hok-012-ngr-dyld-initializers.log`（HOK-012-B 子进程 stderr 重定向，与上者同轮产生、可交叉对齐时间戳）。
- **当前主线**：`HOK-012-C.3`——基于 C.1/C.2 的 live 证据调整 watchpoint 装入时序，让 `0x10e2146f8` 的真实 writer **在本轮生效窗口内被抓到**。C.2 观察到"backtrace 已触达 writer 函数内偏移 `0x434` 但 0 hit"，最可能的解释是 LLDB watchpoint 在 `target create` → `run` 之间的 first-initialization 窗口之外才装入（或 slot 被更早的 ObjC `+load` 预填并在 watchpoint 未装好前就完成了 store）。C.3 的默认策略是在 `preRunCommands` 中**先在 writer 函数 `0x103a29b7c` 本身打软断点**（`breakpoint set --address 0x103a29b7c`），`run` 后 hit 这个 bp 再在同一线程上装 watchpoint + `continue`——从而保证 watchpoint 的"装入瞬间"处在 slot 真正被写的前夕；失败则退到"在 dyld entry 处打 bp → 装 watchpoint → continue"的更前置策略。所有改动仍落在 `Scripts/hok006_ngr_lldb_runner.py`（默认追加 `--pre-run-command`）与 `LaunchService` 的 `LLDBRunOptions.preRunCommands` 已有管道，不引入新 MCP schema 字段。
- **当前卡点**：
  - C.2 live 证明 `0x10e2146f8` 的 8 字节 watchpoint 在当前装入时序下拿不到 writer（0 hit + backtrace 显示 writer 函数已被触达）。C.3 必须解决"watchpoint 装入时机晚于 first store"的 race。
  - watchpoint 命中瞬间若 NGR 仍在 dyld 初始化阶段，`thread backtrace` 输出可能被 `DYLD_PRINT_INITIALIZERS` 干扰到 stdout pipe 之外；C.3 第一轮 live 出来后若发现 backtrace 丢失，需要回来给 `runLLDBHeadless` 加 `settings set stop-line-count-before/after` 或让 `continue` 前多加一次 `frame info` 写入 transcript 的冗余抓取。
  - 子进程 stderr 重定向依赖 `process launch -e`；C.2 已证明该重定向在本环境稳定工作（97933 字节、有 `[GPM] cpp constructor call` 等 app 自研日志与 ObjC 重复类警告），所以暂不需要退回 shell tee 方案。
  - `QtsFileSystem Create failed.` 与 Thread #10 `0x1047862bc`（`address=0x30`）是 HOK-010 方向的下游 fault，与 `0x10e2146f8` 的 root cause **不同层**，HOK-012 不在同一轮处理它们；这是解读 `hok-006-ngr-lldb-report.json.launch.lldb.faultingFrame` 时必须注意的分层。
- **下一步默认规划**：
  1. 执行 `HOK-012-C.3.a`：先跑一轮带 `--pre-run-command "breakpoint set --address 0x103a29b7c"` 的 watchpoint run，确认 bp 是否能在 first store 之前命中；若命中，`LaunchService.runLLDBHeadless` 需要在 `preRunCommands` 之外再新增一条 post-bp-hit 钩子，把 watchpoint 装入的时机从"`run` 之前"挪到"bp 命中、stop 时"。
  2. 若 C.3.a 证明 `0x103a29b7c` 根本没被命中（bp 未 stop），改用 `--pre-run-command "breakpoint set --shlib GCloudCore --name load"` / `"breakpoint set --shlib PxKit3 --name load"` 等 framework `+load` 级别的 bp 逐 framework 排查，`LLDBRunOptions` 已有的 `preRunCommands` 字段可直接承载。
  3. 根据 C.3 拿到的真实 writer 位置，判断是：
     - **H1**：某个 framework initializer 有 NGR 内部函数调用回 NGR（通过 dlsym 或直接链接）→ HOK-013 方向变成"在 PlayTools 里手动预触发同一个函数"。
     - **H2**：某个 ObjC `+load` → HOK-013 方向是"确认 iOS ObjC 类挑选策略，看是否需要 PlayTools 在注入时把 `PxDyLibFrameworkLoader` 等重复类的挑选顺序对齐 iOS"。
     - **H3**：framework 的 C++ static ctor → HOK-013 方向是"让 dyld 初始化顺序把该 framework 在 NGR `__init_offsets[1563]` 之前 load（例如通过 `DYLD_INSERT_LIBRARIES` 提前 dlopen）"。
  4. 若 C.3 经过 a/b 两种更前置的装入策略仍无法抓到 writer（例如所有 bp 都未命中、或命中者仍只是 writer 函数内偏移而 slot 已被预填），则候选 E 成为长期方案，主线回到 QtsFileSystem + `rootWorkDir` 路径（HOK-010），不再继续追 `0x10e2146f8`；Dashboard 此时需要把 HOK-012 整体标记为 DEFERRED 并把 HOK-010 从 DEFERRED 升回 TODO。

## 构建与验证的方法

### 日常默认方法（必须可由 agent 独立完成）

- **构建 PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- **涉及主 app / 注入 / 安装链路时**：`./BuildScripts/build_and_install.sh`
- **读取 / 固化目标 app 配置**：优先使用 `get_app_settings` / `update_app_settings`，目标是让 `com.tencent.ngr` 处于最小兼容模式；若某个关键开关当前还无法经现有 MCP 稳定写入，则应先补自动化写入路径，而不是退回手工 GUI 点选。
- **运行时验证**：`launch_app` → 固定等待 → `create_session` / `list_sessions`。默认 pass 条件是：session 不再秒断、进程在 settle window 内持续存活、且没有新的同类 `NGR-*.ips` 崩溃报告。
- **证据收集**：每轮都要对照读取
  - `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  - `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- **需要更细粒度定位时**：使用 `launch_app_with_lldb` 做同一轮自动化复现，抓 faulting instruction / backtrace / watchpoint；这仍属于 agent 可独立完成的默认升级路径。
- **需要离线二进制层分析时**：
  - `Scripts/hok007_ngr_callsite_mapper.py`：faulting callsite 一致性映射。
  - `Scripts/hok011_ngr_common_init_chain.py`：基于 `__init_offsets` 的 initializer store-site 扫描，默认目标地址 `0x10e2146f8`；可通过 `--target-address` 推广到其他 `__common` 槽位。

### 当前建议的最小兼容验证口径

- 默认把 `metalCaptureEnabled=false`、`injectMetalCaptureEnvironment=false`、`shaderSourceReplacementEnabled=false`、`playChain=false` 视为 `com.tencent.ngr` 的优先隔离态。**`rootWorkDir` 当前保持 `disableForMinimalStartupCompat(...)` 强制关闭**，HOK-010 未被重启；候选 E 仍处于 apply 状态，负责把原 null deref 压成 no-op 以便 app 跑到更下游。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped` 仍然是判断兼容 gate 真正命中的首选证据；**`playcover_working_directory_preserved` 仅说明最小兼容 gate 命中了 cwd 分支，不代表 app 一定能正常使用 `QtsFileSystem`**；该问题已下沉到 HOK-010，HOK-012 完成后再重新评估是否要 reopen。
- 只要本轮改动触及启动顺序、PlayTools 注入内容、settings 默认值、per-app gate、签名/重签或 app 包内二进制，就必须重新跑一轮完整的"构建 → 启动 → session → launch diagnostics → crash report"闭环。

### 需要用户确认后才能继续的事项

- 任何需要用户账号、验证码、手工登录、手工进游戏或手工点击复杂 UI 的验证。
- 任何依赖外部下载、替换新的 app 构建、或需要用户提供额外私有材料的步骤。
- 任何必须由用户亲自观察窗口视觉表现、而 agent 无法以 session / diagnostics / crash evidence 替代判断的步骤。

## agent的工作流程介绍

1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 按优先级从高到低选取未完成任务执行；**每次可以做一个或多个任务**——只要每一项都能按"构建/验证/证据闭环"独立收尾、并且改动不互相冲突，可以在同一轮内连续推进多条 TODO。但若某几项之间存在明显耦合（例如共用同一份磁盘二进制 patch 状态、或需要共同的 live 证据复用），则必须把它们合并成一个更大的变更单元完成，不要半路切换。
3. 若某个任务已阻塞（如需人工或外部协助），跳过它、继续做其它未阻塞的高优先级任务；严禁把"阻塞任务"与"无关任务"混在同一轮里试图绕过阻塞。
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再按正常优先级顺序推进；拆出的子任务可以在同一轮内连续完成，也可以下一轮再来，视变更面积决定。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 执行完毕后必须整理本文档：删除过时信息，更新 主线 / TODO / 踩坑 / 优先级变化，并把真正高频复用的手工流程收敛成脚本；主文档保持简洁，不能只追加不整理，也不能改变本文档章节结构。
   - **主文档 vs 子文档的分工**：不重要的信息、过于局部/细节的推导过程、大段日志、方法论细节一律下沉到对应子文档；主文档只保留当前主线、TODO、决策信息与高频复用经验。
   - **任务状态只在本文档维护**：子文档**不允许**出现 "DONE / TODO / DEFERRED / BLOCKED / 已完成 / 已落地 / 待执行 / 下一步 / 结论 / handoff" 这类**任务状态或进度描述**；子文档只沉淀**方法、口径、设计依据、结构化证据与可复用脚本**，对应任务的状态以 Dashboard TODO 表格为唯一来源。
   - **子文档不写时间戳快照**：子文档不保留"某月某日的 live 结果基线"这类瞬态快照；若确需引用某次 live run，改为指向 `build/` 下的结构化报告文件名，把解释文字留给 Dashboard。
7. 复盘当前技术路线；除最终目标不能改变外，中间方案可根据新发现随时调整。
8. 收尾后执行 `git commit`。一轮内若完成多条 TODO，commit 信息必须把每条的证据指向清楚列出，不要合成一行。

## 所有任务TODO状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| HOK-001 | DONE | 复现 `com.tencent.ngr` 启动崩溃并固定第一轮基线证据（session / launch diagnostics / `.ips`） | 暂无；证据已体现在主线结论中 |
| HOK-002 | DONE | 为 `com.tencent.ngr` 落地 app-scoped 最小兼容启动 gate；runtime 现已显式跳过 `MetalCapture` / `library hook`，显式保留 working directory，并在代码路径上压低 `PlayChain` 早期副作用 | 暂无；结果已体现在主线结论与 launch diagnostics 中 |
| HOK-003 | DONE | 已补齐 `com.tencent.ngr` 最小兼容档的 settings 自动化表达能力；MCP 现可稳定写入、读取、reset 并对照 `shaderSourceReplacementEnabled` 等关键开关，但 runtime 实际生效值仍需结合 launch diagnostics 判断 | 暂无；结果已体现在 MCP settings 覆盖与主线结论中 |
| HOK-004 | DONE | 已固化 `com.tencent.ngr` 的自动化启动闭环、`10s settle window` 口径与失败非零退出语义；live 确认最小兼容 gate 命中 | `LocalDocs/HOKCrash/HOK-004-启动验证与settle-window.md` |
| HOK-005A | DONE | `DiscordIPC` app-scoped skip；live 证明 Discord 不是首个推动 faulting window 移动的 bootstrap 层 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005B | DONE | `PlayInput.shared.initialize()` app-scoped skip；live 证明 `PlayInput` 不是首个 faulting mover | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005C | DONE | `PlayScreen.shared.initialize()` app-scoped skip；live 证明 `PlayScreen` 不是首个 faulting mover | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-005D | DONE | `AKInterface.initialize()` `1.0s` app-scoped 延迟；live 证明 crash 发生在 `AKInterface` 实际初始化之前 | `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` |
| HOK-006 | DONE | LLDB 自动化入口 + 结构化证据链（含 31 帧 backtrace）；崩点稳定固定在 `NGR` early initializer 路径 | `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md` |
| HOK-007A | DONE | `0x10480df08` faulting callsite 的 `LLDB` / `.ips` / `instructionByteStream` / file bytes / `__TEXT,__text` file offset 一致性映射 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-007B | DONE | 候选 E（`ldr x8,[x19]` → `b 0x10480df24`，4 字节可逆）已 apply；app 能跨过原 faulting window 抵达游戏 UI 层；候选 E 被重新标记为**症状 workaround**，不是根因修复 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-011 | DONE | 离线定位 `0x10e2146f8` 的 writer/reader 关系；**证明 NGR 自身 `__init_offsets` 链无法 prime 该 slot**，真正的 prime 必来自外部 framework/ObjC/跨 dylib 路径；顺带发现 3 组 ObjC 重复类警告 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md` |
| HOK-012-A | DONE | 在 `PlayApp.effectiveLaunchEnvironment()` 与 MCP `LaunchService.effectiveLaunchEnvironment()` 两侧落地 bundle-scoped `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 注入；两处共用 `minimalStartupCompatDiagnosticEnvironment` 语义，仅对 `minimalStartupCompatBundleIdentifiers` 生效；`LaunchServiceTests` 新增 2 个单元测试覆盖 inject/non-inject 分支，18 个测试全过；`BuildScripts/build_and_install.sh` 构建+安装+ad-hoc 签名成功 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`（`HOK-012 live-trace 方法论` 小节） |
| HOK-012-B | DONE | 扩展 `launch_app_with_lldb` + headless LLDB runner 支持 `watchAddress` / `watchSize` / `preRunCommands` / `dyldInitializersLogPath`，watchpoint 模式下 stop→`continue` 循环、并用 `process launch -e` 把子进程 stderr 重定向到独立文件；扩展 `Scripts/hok006_ngr_lldb_runner.py` 新增 `--watch-address` / `--watch-size` / `--pre-run-command` / `--dyld-log` / `--watchpoint-report`，watchpoint 模式下默认写 `build/hok-012-ngr-watchpoint-report.json` + `build/hok-012-ngr-dyld-initializers.log`；`LaunchServiceTests` 23 个全过（新增 5 个用例覆盖 default options、watchpoint 模式判定、hit 切片、fault-vs-watchpoint 优先级、options 透传）；`BuildScripts/build_and_install.sh` 构建+安装+ad-hoc 签名成功 | `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`（`HOK-012 live-trace 方法论` 小节） |
| HOK-012-C.1 | DONE | 在真实 NGR 环境跑 legacy 基线 `python3 Scripts/hok006_ngr_lldb_runner.py --skip-build-install`，确认候选 E apply 状态下 `0x10480df08` 原 fault 已被绕过（`faultingFrame=None`、`lldbStopObserved=False`、5s 窗口内 session 保持 ready、无新 `NGR-*.ips`、PlayTools compat 事件齐全） | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（legacy baseline 口径） |
| HOK-012-C.2 | DONE | 首轮 watchpoint live run：`--watch-address 0x10e2146f8 --watch-size 8 --skip-build-install`。结果 `watchpointHits=0` 但 `didStop=true`、`backtraceDepth=254`，且 `backtrace` 已触达 writer 函数内偏移（`0x103a29fb0` = `0x103a29b7c + 0x434`），secondary fault 指向 HOK-010 方向（`QtsFileSystem Create failed.` + Thread #10 `0x1047862bc` `address=0x30`）；`build/hok-012-ngr-dyld-initializers.log` 97933 字节，含 3 条 ObjC 重复类警告与 `[GPM] cpp constructor call` 等 C++ static ctor 证据；证明 writer 函数被触达但 first-initialization store 未落入 watchpoint 生效窗口 | `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`（证据口径 5 种语义 + Thread #10 secondary fault 分层） |
| HOK-012-C.3 | TODO | 调整 watchpoint 装入时序：用 `--pre-run-command "breakpoint set --address 0x103a29b7c"` 在 writer 函数本身打 bp，hit 后再装 watchpoint + `continue`；若 bp 未命中则退到 `--shlib <framework> --name load` 级别的逐 framework 排查。目标是把 `0x10e2146f8` 的 first store 抓进 hit 列表从而落到 H1/H2/H3 任一分类；若 C.3 两种策略都失败则把 HOK-012 整体 DEFER、HOK-010 从 DEFERRED 升回 TODO | 待建；首轮 live 证据就绪后补 `HOK-012-C.3-writer-bp.md` 或直接并入 `HOK-012-C-watchpoint-live-trace.md` |
| HOK-010 | DEFERRED | 把 `rootWorkDir` 从 `PlaySettings.disableForMinimalStartupCompat(...)` 摘除以消除 `QtsFileSystem Create Failed!!`（HOK-012-C.2 live 已实际复现该 UE4 fatal 与 Thread #10 `0x1047862bc` secondary fault，属 HOK-010 领地）；**暂缓**，等 HOK-012-C.3 的结论明确后再评估是升回 TODO 还是保持 DEFERRED | 暂无 |
| HOK-007C | DEFERRED | 为下游 crash（`0x10915b114` / `far=0x50`、以及 HOK-012-C.2 观察到的 Thread #10 `0x1047862bc` / `address=0x30`）做 HOK-007A 离线映射 + HOK-007B 风格最小可逆 patch；**暂缓**，等 HOK-012-C.3 / HOK-010 结果 | `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md` |
| HOK-008 | TODO | 将构建、配置、启动、证据收集、结论汇总收敛成可重复的自动化脚本链路 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号/手工 UI 的后续验证（若未来必须验证"进入游戏后"行为） | 暂不执行；执行前必须先得到用户确认 |

## 踩坑与经验

- `playcover_launch_complete` **不等于** app 已安全启动；`com.tencent.ngr` 会在该事件之后崩溃。
- `metal capture` 关闭并不自动等于"没有启动期 Metal / library hook 副作用"；对该 app 需要显式做 per-app 最小化处理。
- `shaderSourceReplacementEnabled` 在 host/runtime 默认值里都偏向开启思路，不能想当然地把它当作"默认无影响"。
- 现在可以通过 MCP 稳定写入 / 读取 `shaderSourceReplacementEnabled`，但这只代表 raw settings 已可自动化表达；是否真正命中 `com.tencent.ngr` 的最小兼容 gate，仍应优先看 `launch-events.jsonl`。
- `session briefly ready -> disconnected`、`runtime-* = disconnected` + `pending-* = starting` 持续停留，比"窗口看起来闪退"更稳定，是自动化判定的首选信号。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped` 是判断最小兼容 gate 真正命中的首选证据；`playcover_working_directory_preserved` 仅代表走了 cwd 保留分支，不代表 app 一定能工作。
- `playcover_input_skipped` / `playcover_screen_skipped` 的出现（且对应 initialized 事件缺席）是 `HOK-005B/C` 真正命中的首选证据；不要再用"猜测"替代 launch diagnostics。
- GUI HTTP MCP 的 `tools/call` 在真实运行中可能返回 `text/event-stream` 包裹的 JSON，不是裸 JSON；HTTP runner 不能按单一内容类型解析。
- 对 `GUI HTTP MCP` 的长调用不要默认套 `5s` HTTP 超时；`create_session(timeout=10)`、`launch_app_with_lldb(timeoutSeconds=5)` 必须让 HTTP request timeout 与 tool 自身 timeout 对齐。
- `launch_app_with_lldb` 在 headless 模式下会返回结构化 LLDB 证据；消费 `lldb.stopReason` / `lldb.faultingFrame` / `lldb.faultingInstruction` / `lldb.backtrace` / `lldb.transcriptTail`，不要把完整 transcript 仅当人工阅读日志。
- `launch_app_with_lldb` 返回 `timedOut=true` 不等于"没抓到崩溃"；只要同一轮同时有 `didStop=true`、`faultingFrame`、`faultingInstruction` 与 `backtrace`，就说明 capture window 到期前已拿到 LLDB 归因证据。
- `.ips` 的 `usedImage.base`、triggered thread `frames[0].imageOffset` 与 LLDB `faultPc` 可交叉验证 callsite 是否收敛到稳定 image offset；三者一致时优先围绕 image offset / file offset 做 patch 设计。
- `.ips instructionByteStream` 记录的是磁盘小端字节序；`llvm-objdump` 行内的 `f9400268` 展示串和它顺序不同。字节级 patch 必须以 `instructionByteStream` / 实际 binary bytes 为准。
- 设计 ARM64 最小可逆 patch 时，必须沿反汇编窗口追到 `b`/`b.cc`/`cbz` 的跳转目标——faulting 函数里某些分支会把控制流送回原 faulting 指令，只改条件跳转是空操作。
- 对 `NGR` 这类巨型 mach-o 做字节级 patch，`codesign -f -s -` 即可重签，`codesign -dvv` 仍报 `adhoc` 说明签名有效。
- `Scripts/hok007b_ngr_patch_runner.py` 的 `--apply` / `--revert` / `--dry-run` 是"当前磁盘 NGR 处于哪一代 patch"的唯一来源；不要另起手工流程。
- **"应用层崩溃" ≠ "没修好"**：候选 E apply 后 app 能跑到游戏 UI 层并弹 `QtsFileSystem Create Failed!!` / 新 `.ips`；这代表 patch 正确，只是 NGR 自身还有后续依赖未满足。
- **小 `__common` 槽位没 fixup 不意味着没被谁写**：`0x10e2146f8` 没有 bind/rebase 条目，初值是 dyld 零填；NGR 里**有且仅有 1 个 store 指令**写它（`0x103a29f7c`），但该 store 所在函数 `0x103a29b7c` 属于 `__cxa_guard` 保护的 Meyers-singleton accessor，只能被一条调用链到达；若该链本身不会被 `__init_offsets` 任何入口触发，那这个 slot 在 faulting 前必然为 0。
- **"full disasm + 反向 call graph + init_offsets 比对"** 是 NGR 这种 3000+ initializer 二进制里**定位 static-init ordering 问题**的默认手段；`Scripts/hok011_ngr_common_init_chain.py` 解决第一步（找 store-site），全二进制反向 BFS 解决第二步（找可达性）。
- `dyld_info -inits` 才是官方的 initializer 列表来源；手工 parse `__init_offsets` 必须和它对齐数量才算解析正确。
- `DYLD_PRINT_INITIALIZERS=1` 直接裸跑 NGR 主二进制只会看到系统 dylib 的前几段初始化序列就退出，但**伴随的 ObjC 重复类警告**（`PxFrameworkLoader`、`AReachability`、`PxDyLibFrameworkLoader`）是"iOS vs macOS 类挑选策略差异"这个问题域的首次强证据，不要忽略。
- ObjC 重复类在 macOS vs iOS 上的**挑选规则不同**（主要是 dylib 加载顺序影响 `objc_registerClassPair` 的胜者）；这是 HOK-012 live-trace 必须显式观察的点。
- `effectiveLaunchEnvironment` 在 host 侧存在**两份实现**：`PlayCover/Model/PlayApp.swift`（GUI 启动路径）和 `PlayCoverMCP/HostServices/Launch/LaunchService.swift`（MCP `launch_app` / `launch_app_with_lldb` 路径）。对 `minimalStartupCompatBundleIdentifiers` 的任何 env 改动**必须同时写到两份**，否则 `launch_app` 和 `launch_app_with_lldb` 的行为会偏离；HOK-012-A 已把 `DYLD_PRINT_INITIALIZERS=1` / `DYLD_PRINT_APIS=0` 两侧对齐，并用 `LaunchServiceTests` 覆盖 inject/non-inject 两条分支。
- 给 `minimalStartupCompat` bundle 打开 `DYLD_PRINT_INITIALIZERS=1` 时，**同时显式置 `DYLD_PRINT_APIS=0`** 是必要的——否则若父终端之前 export 过 `DYLD_PRINT_APIS=1`，子进程会被 dyld API 的洪水淹没，initializer 日志就读不到了。这个技巧在 HOK-012-B 的 stderr 抓取里必须保留。
- HOK-012-C live 证明："**backtrace 里已经出现 writer 函数内某个偏移** ≠ **watchpoint 命中**"。这两件事在 arm64 + LLDB + dyld 早期阶段并不等价：writer 函数的 first-initialization 分支可能在 `target create` → `run` 之间、或 watchpoint 真正 armed 之前就完成了 store。排查 `0x10e2146f8` 这类 `__common` slot 的 writer 时，必须把 watchpoint 装入时机下推到"writer 函数自身 bp 命中之后"，而不是依赖 `run` 之前的预装。
- watchpoint 模式下 `didStop=true` + `watchpointHitCount=0` 是一种合法状态：表示 capture window 内发生了**其他** stop（典型是下游 UE4 fatal + Thread #10 `EXC_BAD_ACCESS`）。`LaunchService.parseLLDBEvidence` 已把这种情况的 fault 字段优先挑选到非 watchpoint stop 上，**不要**再把 `faultingFrame` 当成原 `0x10480df08` 那一层的证据使用；它可能指向 HOK-010 / HOK-007C 的下游 fault。
- `build/hok-012-ngr-dyld-initializers.log` 里 dyld 原生 `dyld[pid]: initializer …` 行在当前 macOS 版本可能不会出现；但 **ObjC 重复类警告**（`PxFrameworkLoader` / `AReachability` / `PxDyLibFrameworkLoader`）、app 自研 `[GPM] [EVENT] [launch_time] cpp constructor call` 与 `CAppLifecycleLaunch::CAppLifecycleLaunch` 等构造 log 是同一阶段的可靠替代判据。`hok006_ngr_lldb_runner.py` 的 `initializerLineCount` 字段若为 0，不代表 dyld static init 没跑——必须结合 `byteCount` 与 `tail` 文本判断。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑；`effectiveLaunchEnvironment()` 是 `HOK-012-A` 注入 `DYLD_PRINT_INITIALIZERS=1` 的目标点（已落地，见 `minimalStartupCompatDiagnosticEnvironment`）。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 侧 `launch_app` / `launch_app_with_lldb` 的启动环境组装入口；同步维护着 `minimalStartupCompatDiagnosticEnvironment` 常量、`LLDBRunOptions` 定义（HOK-012-B watchpoint/preRunCommands/stderr 重定向）与 `parseWatchpointHits` 解析器；`HOK-012-C` 的 live run 直接消费这里的 `launch_app_with_lldb` 扩展 schema。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值；`disableForMinimalStartupCompat(...)` / `minimalStartupCompatBundleIds` 是 `HOK-010` 的主改点，`HOK-012` 暂不触发。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md`：`HOK-005` 分层最小化子任务与每层 live 结论。
- `LocalDocs/HOKCrash/HOK-006-LLDB归因与crash-window压缩.md`：`HOK-006` 的自动化入口、证据口径与 31 帧 backtrace。
- `LocalDocs/HOKCrash/HOK-007-二进制意图分析与callsite映射.md`：`HOK-007A` 离线 callsite mapper、`HOK-007B` 候选 E（branch-to-epilogue）patch 设计与回滚口径、以及候选 E 在 HOK-011 之后被定位为 workaround 的技术依据。
- `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md`：`HOK-011` 的扫描器设计、反向 call graph 方法论、`0x10e2146f8` writer 不可达的离线结论、ObjC 重复类警告，以及 HOK-012 live-trace 的工具链、标准命令与 H1/H2/H3 假设分类。
- `LocalDocs/HOKCrash/HOK-012-C-watchpoint-live-trace.md`：HOK-012-C 的方法论沉淀——legacy baseline vs watchpoint run 的角色分工、watchpoint run 的 5 种语义、dyld log 交叉对齐规则、secondary fault 的分层解读、与 HOK-011 静态结论的交叉校验。
- `Scripts/hok007b_ngr_patch_runner.py`：候选 E 最小可逆 patch 的单一来源；当前状态 `applied`。
- `Scripts/hok011_ngr_common_init_chain.py` + `Scripts/test_hok011_ngr_common_init_chain.py`：`__common` slot writer 扫描器与单元测试。
- `build/hok-011-analysis-notes.json`：HOK-011 的完整证据结构化文件（含 caller/reader/writer 地址表、反向 BFS 结论、ObjC 重复类列表、HOK-012 hand-off 建议）。
- `build/hok-012-ngr-watchpoint-report.json`：HOK-012-B watchpoint 命中清单；由 `Scripts/hok006_ngr_lldb_runner.py --watch-address …` 生成，字段定义见 `LaunchService.parseWatchpointHits`。
- `build/hok-012-ngr-dyld-initializers.log`：HOK-012-B 子进程 stderr 重定向文件；由 `Scripts/hok006_ngr_lldb_runner.py` 在 watchpoint 模式下自动写入，`DYLD_PRINT_INITIALIZERS=1` 的所有 `dyld[pid]: …` 输出都会落到这里，供与 watchpoint 命中时间戳交叉对齐。
- `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/Frameworks/`：20+ 个嵌入 framework 的集合；`HOK-012` 的 watchpoint 很可能命中其中某一个（`GCloud`、`PixUI_PXPlugin`、`PxKit3`、`BqCCS` 等）。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`：与本主线无关，除非需要借鉴 dashboard 维护方式。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
