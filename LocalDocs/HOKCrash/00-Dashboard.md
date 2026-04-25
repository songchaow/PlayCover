## HOKCrash Dashboard

> **单一来源规则**：`com.tencent.ngr`（`王者荣耀世界`）启动崩溃问题的
> 优先级、主线、TODO、验证口径只在本文维护；长日志、历史推理细节、
> 一次性 live 基线、脚本/工具细节、历史子任务的踩坑和证伪过程都下沉
> 到对应子文档与附录。主文档保持可快速通读。
>
> **阅读次序建议**：
> 1. 先读本文档"最终目标 → 全局约束 → 主线任务 → 当前主线 / 卡点 / 下一步"；
> 2. 只有在需要动当前主线子任务时，才进入
>    `HOK-016-qts-fs-create-failed.md`（当前主线总入口）；
> 3. 其它 HOK-0xx 子文档按"默认必读 / 按需读取"章节的指引决定是否展开；
>    每个子文档顶部也有各自的"何时读"提示。

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

### 当前主线一句话

`HOK-016-C.2.7`：消除 NGR 启动期 `QtsFileSystem Create Failed!!` 路径的
根因。HOK-013 / 015 / 010 / 014 已把外层崩溃边界全部收敛，当前进程不再
秒崩但仍停在"GameThread 已退出"的僵尸态。

### 当前状态摘要

- 外层防线已全部稳定：HOK-013 stub preheat、HOK-015 cmdline preseed、
  HOK-010 rootWorkDir self-heal、HOK-014 `UIAlertController` 压制全部 apply。
- 真因已下钻到 storage create-table 链（`0x1001a5014 → 0x10012bb7c`）；
  natural run 的直接现象是 null table + `storage+0x30 = 0x9000b`。
- dual-force 诊断已证明 dormant writer path（`0x10432dfdc → ... →
  0x1001c6da4`）真实存在，只在双 checkpoint 顶开后才激活。
- materialization target trace 已把差异收紧到 pre-`1c8` state：同一
  target 内 post-`1c8` pair 已收敛，success / fail 的分叉只剩 entry tuple
  / helper state 差异导致 `0x10432a224` vs `0x10432a2c8/0x10432a2e0` 的分流。
  详细 checkpoint 证据见 `HOK-016-appendix-C27.md` §14。
- PathDifferenceTrial 的 `PDT-001-A` 已完成：`Scripts/pdt001_ngr_materializer_literal_extractor.py`
  从 `0x10432a068` 提取到的 fixed literal 为 UTF-16 `"r"` / `"rb"`，不含路径前缀、
  文件名或数据库片段；因此“materializer fixed literal 直接做路径相关 compare”
  这层假设已被排除，主线不再优先投入路径重定向实验。详见
  `PathDifferenceTrial/PDT-001A-compare-literals.md` 与 `build/pdt-001a-compare-literals.json`。
- `branch-238` / `branch-3e0` / `branch-580` 经 natural run 验证：**natural
  failing path 在 `branch-224` 分流后直接返回 0 到 caller（`0x100122f58`），
  未进入 `branch-238` compare ladder 及后续 tail**。LLDB trace 在
  `0x100122f98`（err direct writer）捕获到 `x21=0`、`x8=0x9000b`，与
  `build/hok-016c27-mainchunk-subtree-trace.json` 一致。
- **本轮关键新发现**：natural run 中 `0x100122f54` 的 materialize vcall
  实际 `x8(target)=0x100128c6c`（或 `0x115a5eb30`），**不是**静态分析锁定的
  `0x10432a068`。这意味着 dual-force / 附录 C27 中基于 `0x10432a068` 的
  target-side trace 与 natural run 的实际 target 不同；C.5 安装在
  `0x10432a068` vtable slot 上的 hook **从未被 natural run 触发**。
- HOK-016-C.5 materialize shim 现状更新：
  - 原 hook（`0x10432a068`）在 natural run 中从未被触发；`cache-probe` +
    `cache` 实际来自 primary hook 的 provider-clone 路径，不是 alt1。
  - 已修复 `installed-provider-clone` 路径会跳过 alt1 安装的 bug：将 alt1
    安装逻辑提取为 `pt_ngr_c5_install_alt1_hook()`，在 provider-clone
    return 前也调用。
  - 已在 `pt_ngr_c5_materialize_dispatch_hook_alt1` 中增加每调用细粒度日志
    (`action=alt1-dispatch`)，含 `callIndex` / `path` / `originalRetObj` /
    `selectedObj`，用于区分同一路径多次调用 vs 独立第二条 failure path。
  - **新卡点**：`__DATA_CONST` 写保护导致 alt1 slot 不可写；
    `pt_ngr_make_patch_writable`（`mprotect` + `vm_protect`）失败，
    `vm_write` fallback 也失败，记录 `alt1-not-writable`。当前 macOS 下
    C.5 无法通过 vtable patch 拦截 `0x100128c6c` 路径。
  - live 验证（`build/hok-004-ngr-startup-report.json`，pid 97177，
    processLaunchId=`launch-97177-272c5ad8-f770-4e3b-92da-c691f042b89a`）
    确认 alt1 hook **未能安装**，`hok014_ngr_alert_suppressed` 仍出现 1 次。
    materialize shim 在当前系统环境下无法完成 alt1 部署，需降级评估。

### 修复路线（优先级从高到低）

1. **`HOK-016-C.2.7`（当前主线）**：
   - (a) natural run 中 `0x1001a588c` 已观测到一次 success 命中（`pkg+0x10=0x0`
     `pkg+0xa8=0x2` `pkg+0xb0=0x0` `pkg+0x110=0x1`），label=`gate1-ret`；
     natural fail 路径在 `branch-224` 后直接返回 0，未进入 `branch-238`
     tail，因此 (a) 的 OpenNodeStorage gate 可能**不是** natural fail 的直
     接来源。
   - (b) `ba720(key="1")` 的时序差异已在 dual-force run 中闭合；natural
     run 中 `mainChunk+0x60` 为 0 时 `ba720` 返回 0 是预期行为。
   - **(c) 新口径**：natural run 中 `0x100122f54` 的 `x8(target)` 实际是
     `0x100128c6c` / `0x115a5eb30`，不是 `0x10432a068`。dual-force run 与
     natural run 的 materialize target 不同，附录 C27 §14 的 target-side
     分析需要重新评估是否适用于 natural path。
2. **`HOK-016-C.5`**：alt1 hook 因 `__DATA_CONST` 写保护无法安装（`alt1-not-writable`），
   `vm_write` fallback 同样失败。在当前 macOS 环境下，vtable patch 方案对
   `0x100128c6c` 不可行。C.5 已收集到足够证据（`alt1-dispatch` 日志代码保留），
   但不再作为主线推进，待环境变化或找到新的写 `__DATA_CONST` 方法后再评估。
3. **`HOK-016-C.4`**：由于 natural run 的 materialize target 与 dual-force
   不同，对象形状假设需要重新验证。若 C.5 修正后仍无法覆盖，进入诊断性
   强制成功验证。
4. **`HOK-016-C.3`**：fishhook interpose `0x108878534` 直接返回 1，
   稳定性风险极高，仅作最后兜底。
5. **`HOK-016-C.6`**：若必须依赖用户外部资源 / 登录态，才降级到 HOK-009。

### 当前兜底链路（按 PlayTools constructor 执行序）

1. `HOK-013`：为 `0x10e2146f8`（UE4 GLog 实例 slot）写入 stub object。
   （`HOK-013-slot-preheat.md`）
2. `HOK-015`：为 `FCommandLine::bCommandLineInitialized` +
   `FCommandLine::CmdLine` 预写 `bInitialized=1` 与种子字符串
   `"../../../NGR/NGR.uproject"`，218 条 inline `FCommandLine::Get()`
   guard 全部 fall-through。（`HOK-015-cmdline-preseed.md`）
3. `HOK-010`：`PlaySettings.rootWorkDir` 透传 + `PlayApp.launch()`
   self-heal，让 `com.tencent.ngr` 的 cwd 为 `/`。
   （`HOK-014-alert-suppressor.md` 合并说明）
4. `HOK-014`：PlayTools swizzle
   `-[UIViewController presentViewController:animated:completion:]`，
   对 `UIAlertController` 直接 `completion(nil)` 返回。**HOK-016 闭合
   前，HOK-014 仍承担"用户看不到错误对话框"的硬性要求**；
   `hok014_ngr_alert_suppressed = 1` 当前由 HOK-016 的 `QtsFileSystem
   Create Failed!!` 独立分支稳定触发 1 次。（`HOK-014-alert-suppressor.md`）

HOK-007B 候选 E（NGR 二进制 4 字节 patch）已 **revert**；磁盘备份保留
在 `build/hok-007b-backups/*.bin`，不默认 apply。HOK-013 + HOK-015 不
再依赖它。

### 已证伪路径（高层记录）

- `HOK-016-C.X`：换 HOK-015 seed value 不改变 `w0@+912`。详见
  `HOK-016-appendix-CX.md`。
- `HOK-016-C.2.1 / C.2.2`：sentinel `0x10e1eeef0` 运行期 = `0x05`，
  不是失败因；全 `__text` 扫描 0 writer。
- `HOK-016-C.2.3` 里"走 `0x10017f3c8`"的旧假设：实际走 `0x10017f184`。
- 旧 "rootB 从头到尾是空 / 缺 main" 假设：reporter 运行期会 insert
  `"main"`，真缺口是下一层 `mainChunk -> "1"`。

> 每条证伪的具体实验、寄存器值、脚本产物都在对应 HOK-016 附录里。

### 当前卡点

四层未闭合问题：
1. `0x1001a588c` 在 natural run 中观测到一次 success 命中（`pkg+0x10=0x0`
   `pkg+0xb0=0x0`），但 natural fail 走 `branch-224` 直接返 0；OpenNodeStorage
   gate 可能不是 natural fail 的直接来源。
2. **C.5 alt1 hook 安装被 `__DATA_CONST` 写保护阻塞**：`pt_ngr_make_patch_writable`
   与 `vm_write` 均无法修改 alt1 vtable slot，导致 `0x100128c6c` 路径无法被
   hook。`cache-probe` + `cache` 来自 primary hook（provider-clone），不是
   alt1；natural run 的 materialize target（`0x100128c6c` 或堆地址
   `0x115a5eb30`）仍未被 intercept。
3. **C.2.7 (c) 新口径**：dual-force 与 natural run 的 materialize target
   不同；C.5 因系统写保护证伪，需换方向下钻。需要确认 natural run 中
   `0x100128c6c` 被调用的次数、返回值、以及是否存在多条独立调用路径。
4. **细粒度日志已就绪但无法触发**：`alt1-dispatch` 日志代码已写入
   `pt_ngr_c5_materialize_dispatch_hook_alt1`，只要 alt1 hook 安装成功即可
   输出每调用参数；当前 blocked by 卡点 2。

### 下一步默认规划

1. **评估 C.5 路线是否继续**：`__DATA_CONST` 写保护在当前 macOS 版本下
   不可绕过。若短期内无法找到新的写保护突破方法（如 `vm_remap` 可写映射、
   `pthread_jit_write_protect_np`、或利用 `dyld` 的 `__DATA_CONST` 重绑定
   机制），C.5 降级为 blocked，优先切回 C.2.7 / C.4。
2. **继续下钻 C.2.7（当前主线）**：不依赖 vtable hook，改用 LLDB 直接对
   `0x100122f54`（materialize vcall）设 BP，统计 natural run 中该 BP 的
   命中次数、每次 `x8(target)` 实际值（`0x100128c6c` vs 堆地址）、每次返回值
   `x0`，与 `hok014_ngr_alert_suppressed` 的时序做关联分析。目标：确认
   (a) 同一路径被调用多次、部分返回 0；还是 (b) 存在独立第二条 failure path。
3. 若 C.2.7 通过 LLDB trace 仍无法收敛，进入 **`HOK-016-C.4`**（诊断性强
   制成功验证：直接 patch `0x100122f58` 返回值或在 `0x100122f5c` 后注入
   non-null object）。
4. `HOK-016-C.3` 保留作为最后兜底。
5. `HOK-016-D` live 验证标准：`hok014_ngr_alert_suppressed = 0` +
   `%CPU/RSS/线程/窗口` 活跃度达标 + 无新 `NGR-*.ips`。
6. 只有 HOK-016 闭合，才把 HOK-014 正式降级为冷备安全网。
7. 闭合后再做 `HOK-008`：把"revert 候选 E → `rootWorkDir=1` → 启动 →
   证据采集 → pass 判定"固化成单脚本。

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
- **需要细粒度定位时**：`launch_app_with_lldb` +
  `Scripts/hok006_ngr_lldb_runner.py`；所有 LLDB 选项 / BP callback
  套路 / watchpoint 证据语义都在 `HOK-012-工具链与方法论归档.md` 与
  其附录。日常启动不需要打开。
- **离线二进制分析**：`Scripts/hok007_ngr_callsite_mapper.py`（faulting
  callsite 映射）、`Scripts/hok011_ngr_common_init_chain.py`（`__common`
  slot writer 扫描器）；`Scripts/hok015_ngr_cmdline_locator.py`、
  `Scripts/hok016_ngr_qts_locator.py` 等 HOK-016 附近扫描器详见
  `HOK-016-appendix-tooling.md`。

### 证据收集点

- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- `build/hok-*.json` / `build/hok-*.log`：历史结构化 live 证据本地留存
  （`.gitignore` 的 `build/`），Dashboard 不逐个罗列；附录在引用时
  按文件名指向。

关键事件：`playcover_startup_compat_profile_applied` /
`playcover_*_skipped` / `playcover_working_directory_changed`
（HOK-010 后应为 `_changed` 不是 `_preserved`）/
`hok013_ngr_slot_preheat status=primed` /
`hok014_ngr_alert_suppressor_installed` /
`hok014_ngr_alert_suppressed` /
`hok015_ngr_cmdline_preseed status=primed`。

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
| HOK-006 | DONE | 固化 LLDB 自动化入口与结构化证据链 | `HOK-006-LLDB归因与crash-window压缩.md` |
| HOK-007A | DONE | 完成首轮 faulting callsite 一致性映射 | `HOK-007-二进制意图分析与callsite映射.md` |
| HOK-007B | DONE（已 revert） | 候选 E 设计与 apply/revert runner；当前仅作磁盘备份 | `HOK-007-二进制意图分析与callsite映射.md` |
| HOK-011 | DONE | 修正 `0x10e2146f8` 真 writer 入口并排除 `__init_offsets` 主线 | `HOK-011-静态初始化链分析.md` |
| HOK-012-A/B/C（全系列） | DONE | 补齐 HOK-012 LLDB 工具链；当前按需使用 | `HOK-012-工具链与方法论归档.md` |
| HOK-013 | DONE | `0x10e2146f8` slot preheat 落地 | `HOK-013-slot-preheat.md` |
| HOK-014 | DONE（HOK-016 闭合后降级为安全网） | `UIAlertController` suppressor 落地；当前仍作必要闭环 | `HOK-014-alert-suppressor.md` |
| HOK-010 | DONE | `rootWorkDir` self-heal 落地 | `HOK-014-alert-suppressor.md`（合并说明） |
| HOK-015 | DONE | `FCommandLine` preseed 落地，218 条 guard 全部放行 | `HOK-015-cmdline-preseed.md` |
| HOK-016-A | DONE | 静态定位 `QtsFileSystem` 字符串族与 reporter | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-B | DONE | 运行期锁定 reporter 调用链与 Create Failed 判定点 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.1 | DONE | 锁定 readiness B（`0x108878534`）为失败源 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.X | DONE（证伪） | 证伪"seed 内容驱动 QtsFS 失败" | `HOK-016-appendix-CX.md` |
| HOK-016-C.2.1 | DONE（证伪） | 证伪"sentinel writer 在 NGR `__init_offsets` 链上" | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.2 | DONE（证伪） | 证伪"sentinel 未 bump" | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.2.3 | DONE | 证实 `0x10432dd98` 稳定返回 0 | `HOK-016-appendix-C23-C24.md` |
| HOK-016-C.2.4 | DONE | 收紧到 `0x10017f184` 的 lookup 失败 | `HOK-016-appendix-C23-C24.md` |
| HOK-016-C.2.5 | DONE | 补齐 rootB writer / insert-helper 的侧证 | `HOK-016-appendix-C25-C26.md` |
| HOK-016-C.2.6 | DONE | 更正为 `mainChunk` 的 `"1"` 子树缺失，不是 `"main"` 缺失 | `HOK-016-appendix-C25-C26.md` |
| HOK-016-C.2.7 | TODO（当前主线） | (a) `0x1001a588c` natural run 已观测到一次 success 命中（`pkg+0x10=0x0 pkg+0xa8=0x2 pkg+0xb0=0x0 pkg+0x110=0x1`），label=`gate1-ret`；natural fail 走 `branch-224` 直接返 0，未进入 `branch-238` tail。**(c) 新发现**：natural run 中 `0x100122f54` 的 `x8(target)=0x100128c6c/0x115a5eb30`，不是 `0x10432a068`。PathDifferenceTrial 的 `PDT-001-A` 又进一步证实 `0x10432a068` fixed literal 仅为 UTF-16 `"r"` / `"rb"`，与路径无关；主线因此继续聚焦 selected buffer / compare accumulator / helper state，而不是路径模板。C.5 因 `__DATA_CONST` 写保护无法安装 alt1 hook，已降级。下一步改用 LLDB 直接对 `0x100122f54` 设 BP，统计命中次数、每次 `x8` 实际值与返回值，关联 `hok014_ngr_alert_suppressed` 时序，区分 (a) 同一路径多次调用部分失败 vs (b) 独立第二条 path。详见 `HOK-016-appendix-C27.md` §14。 | `HOK-016-appendix-C27.md` |
| HOK-016-C.3 | DEFERRED | 终极野蛮方案：fishhook interpose `0x108878534` 直接返回 1，仅作最后兜底 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.4 | TODO | 若 C.2.7 通过 LLDB trace 仍无法收敛，进入诊断性强制成功验证。natural run 的 materialize target 与 dual-force 不同，对象形状假设需重新验证。 | `HOK-016-appendix-C27.md` |
| HOK-016-C.5 | BLOCKED | 已修复 provider-clone 路径跳过 alt1 安装的 bug，已增加 `alt1-dispatch` 细粒度日志。但 `__DATA_CONST` 写保护导致 alt1 slot 不可写（`alt1-not-writable`），`vm_write` fallback 也失败。在当前 macOS 环境下无法通过 vtable patch 拦截 `0x100128c6c` 路径。待找到新的写保护突破方法或环境变化后再评估。live 证据：`build/hok-004-ngr-startup-report.json`，pid 97177，processLaunchId=`launch-97177-272c5ad8-f770-4e3b-92da-c691f042b89a`。 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.6 | DEFERRED | 仅在必须依赖外部资源或登录态时，才降级到需要用户介入的路线 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-D | TODO | HOK-016-C 落地后做 live 验证，并把 HOK-014 降级为冷备安全网 | `HOK-016-qts-fs-create-failed.md` |
| HOK-007C | DEFERRED | 下游 crash 的离线映射 + 可逆 patch；当前无触发动机 | `HOK-007-二进制意图分析与callsite映射.md` |
| HOK-008 | TODO | 把"revert 候选 E → `rootWorkDir=1` → 启动 → 证据采集 → pass 判定"固化成单脚本 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号 / 手工 UI 的后续验证；执行前必须得到用户确认 | 不执行 |

## 高频复用经验（当前仍适用的）

以下经验跨任务复用概率高，写在主文档便于 agent 日常直接记住；更长的
分类细节见对应子文档。

- **"进程不崩 + 窗口存在" ≠ 最终目标达成**。必须同时检查：
  `launch-events.jsonl` 里零 `Fatal` / 零 `hok014_ngr_alert_suppressed`；
  进程 `%CPU` 持续 ≥5%、`RSS` 长到 UE4 典型量级；主窗口 bounds 与主
  屏 frame 有非空交集。
- **"UIAlertController 被 HOK-014 压制" 是症状不是治愈**。HOK-014 只
  让 alert 不可见，业务 fatal 仍已触发、GameThread 仍退出；进程表现
  为"僵尸存活"。当前还在触发 HOK-014 的是 HOK-016 的
  `QtsFileSystem Create Failed!!` 分支（`0x108877bd0` 返回 0）；治本
  在 HOK-016-C。
- **`playcover_launch_complete` ≠ app 已安全启动**：NGR 会在该事件之
  后进入 UE4 bootstrap、可能进入 fatal 路径。
- **`session briefly ready → disconnected`** 是比"窗口看起来闪退"更
  稳定的 automation 判据，但不足以判定"app 活着"——需要配合 CPU / RSS
  / 窗口可见性指标。
- **`playcover_startup_compat_profile_applied` / `*_skipped`** 是判断
  最小兼容 gate 真正命中的首选证据，不用主观猜测。
- **`effectiveLaunchEnvironment` 两侧对齐**：`PlayApp.swift` 与
  `LaunchService.swift` 必须同步维护
  `minimalStartupCompatDiagnosticEnvironment`。
- **PlayCover GUI 内存 vs plist 一致性**：`AppSettings.settings` 的
  `didSet` 会 encode 回 plist；改 `com.tencent.ngr` 的 settings 不要
  只用 `plutil -replace`（会被下一次 GUI launch 覆盖），要走
  `update_app_settings` MCP 或依赖 `PlayApp.launch()` 的 self-heal。
- **`.ips` 的 image offset 交叉验证**：`usedImage.base` + triggered
  thread `frames[0].imageOffset` + LLDB `faultPc` 三者应一致。
- **`launch_app_with_lldb` headless 结构化证据**：消费
  `lldb.stopReason` / `lldb.faultingFrame` / `lldb.faultingInstruction`
  / `lldb.backtrace` / `lldb.blockingDialogWindows` / `lldb.watchpointHits`，
  不要把完整 transcript 当人工日志用。`timedOut=true` + `didStop=true`
  + 完整 fault 字段 = 证据有效。
- **`blockingDialogs >= 1` ≠ 回归，也不能立即判定为 pass**：b.0 gate
  对"NGR onscreen window"本身也会报 1。需要同时看窗口 bounds 是否在
  主屏 frame 内（`Y + H > 0` 且 `Y < screen.height`）、
  `kCGWindowMemoryUsage` 是否非 trivial（合法渲染窗口通常 >1MB）。
- **HOK-016 LLDB BP / watchpoint 踩坑**：对 NGR 主 image 内的固定地址
  设 BP 必须用 `breakpoint set --shlib NGR --address <unslid>`；
  `breakpoint set` **不支持** `--script-type python -F <func>`，必须
  拆成 `breakpoint set ...` + `breakpoint command add -s python -F
  <func>` 两步；`-C 'shell cmd'` 与 `command add -s python -F` 不能
  同时作用于同一 BP。完整脚本清单与踩坑汇总见
  `HOK-016-appendix-tooling.md`。
- **C.5 vtable hook 的 target 地址可能在 natural run 中变化**：静态分析
  锁定的 `0x10432a068` 在 dual-force run 中确实被命中，但 natural run 中
  `0x100122f54` 的 `x8` 实际是 `0x100128c6c`/`0x115a5eb30`。任何基于固定
  vtable slot 的 hook 方案，都必须先通过 live BP 验证运行期实际 target。
- **`__DATA_CONST` vtable slot 在当前 macOS 下不可写**：`mprotect` /
  `vm_protect` / `vm_write` 均无法修改 `__DATA_CONST` 中的指针。
  provider-clone 方案（malloc 新 vtable + redirect provider entry）只对
  primary hook 可行，alt1 slot 若无对应 provider entry 则无法 clone。
  任何依赖 runtime vtable patch 的方案，必须先验证页保护是否允许写入。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、
  TODO 与默认验证口径。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：当前主线
  HOK-016 的目的、核心证据、根因链、修复方向、已证伪路径。**阅读
  建议：只要在做 HOK-016-C 系列任务就总是读取。**

### 当前兜底链路（修改这些代码/文件需要同步更新本 Dashboard）

代码/文件改动路径：

- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的
  dyld constructor / interpose 入口；HOK-013 stub 预写 + HOK-014
  UIAlertController swizzle + HOK-015 cmdline preseed 都在这里。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：PlayTools
  启动顺序、compat 诊断事件、HOK-013/014/015 的 Swift 事件入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：
  runtime settings 读取；`minimalStartupCompatBundleIds`、
  `disableForMinimalStartupCompat(...)`、HOK-010 后的 `rootWorkDir`
  透传。
- `PlayCover/Model/PlayApp.swift`：GUI 启动环境、
  `effectiveLaunchEnvironment()`、`minimalStartupCompatBundleIdentifiers`、
  HOK-010 self-heal。
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：MCP 启动环
  境、`minimalStartupCompatDiagnosticEnvironment`、`LLDBRunOptions`
  定义（HOK-012 工具链）。

当前兜底链路的实现/决策文档：

- `HOK-013-slot-preheat.md`（+ `HOK-013-appendix-verification.md`）：
  **修改 HOK-013 相关代码时总是读取；验证方案细节按需读取。**
- `HOK-014-alert-suppressor.md`（+ `HOK-014-appendix-verification.md`）：
  **修改 HOK-014 / HOK-010 相关代码时总是读取；验证方案细节按需读取。**
- `HOK-015-cmdline-preseed.md`（+ `HOK-015-appendix-verification.md`）：
  **修改 HOK-015 相关代码时总是读取；验证方案细节按需读取。**
- `HOK-016-qts-fs-create-failed.md`（+ 5 份附录）：**当前主线，做
  HOK-016-C 系列任务时总是读取；附录按其"何时读"提示展开。**

### 按需读取（与当前主线无直接关系，出问题再翻）

> 下列文档日常不展开；只在具体排查内容涉及时按建议展开。每份文档顶部
> 都标了自己的"阅读建议"；附录开头同样有"阅读建议"。

- `HOK-004-启动验证与settle-window.md`：settle window 口径与 raw settings
  模板。**阅读建议：一般无需读取；需要改 runner 或 compat 事件判据时按需读取。**
- `HOK-005-深层bootstrap分层最小化.md`：四层 app-scoped skip 的代码落点
  与诊断事件语义。**阅读建议：一般无需读取；需要调整 skip / 延迟分层时按需读取。**
- `HOK-006-LLDB归因与crash-window压缩.md`：自动化入口、证据口径、31 帧
  backtrace。**阅读建议：一般无需读取；需要改 `launch_app_with_lldb` / LLDB
  证据 schema 时按需读取。**
- `HOK-007-二进制意图分析与callsite映射.md`：离线 callsite mapper、候选 E
  的 apply/revert 口径。**阅读建议：一般无需读取；需要追查新 faulting
  callsite 或重新上/下候选 E 时按需读取。**
- `HOK-011-静态初始化链分析.md`：扫描器设计、反向 call graph 方法论。
  **阅读建议：一般无需读取；需要为新 `__common` slot 做 writer 扫描 / 反向
  BFS 时按需读取。**
- `HOK-012-工具链与方法论归档.md`（+ `HOK-012-appendix-evidence-and-cli.md`）：
  LLDB 工具链与 live-trace 方法论。**阅读建议：一般无需读取；需要跑新
  watchpoint live run / 解读命中 / 调 `LLDBRunOptions` 时按需读取。**
- `HOK-016-appendix-tooling.md` / `HOK-016-appendix-C23-C24.md` /
  `HOK-016-appendix-C25-C26.md` / `HOK-016-appendix-C27.md` /
  `HOK-016-appendix-CX.md`：HOK-016 的 5 份附录。**阅读建议：
  `HOK-016-appendix-C27.md` 在做 C.2.7 / C.4 / C.5 时总是读取，只想同步
  最新收紧口径时优先看 §14；其余附录按各自顶部"阅读建议"按需进入。**

### 代码 / 脚本速查

脚本详细说明统一沉淀在对应子文档与附录里，主文档只保留"名字 → 干什么
→ 想读细节看哪里"的索引：

- `Scripts/hok004_ngr_startup_runner.py`：10s settle window 启动
  baseline runner。→ `HOK-004-启动验证与settle-window.md`
- `Scripts/hok006_ngr_lldb_runner.py`：LLDB 自动化入口 / BP callback
  唯一 CLI。→ `HOK-006-LLDB归因与crash-window压缩.md`、
  `HOK-012-工具链与方法论归档.md`
- `Scripts/hok007_ngr_callsite_mapper.py` /
  `Scripts/hok007b_ngr_patch_runner.py`：候选 E apply/revert 唯一来源，
  当前 `state=original`。→ `HOK-007-二进制意图分析与callsite映射.md`
- `Scripts/hok011_ngr_common_init_chain.py`：`__common` slot writer
  扫描器。→ `HOK-011-静态初始化链分析.md`
- `Scripts/hok015_ngr_cmdline_locator.py` /
  `hok015_ngr_live_verify.py`：HOK-015 定位器 + live 验证。→
  `HOK-015-cmdline-preseed.md`
- `Scripts/hok016_ngr_qts_locator.py` /
  `hok016_ngr_qts_reporter_trace.py` /
  `hok016c_ngr_qts_w0_trace.py` /
  `hok016c2_ngr_sentinel_*` /
  `hok016c24_*` / `hok016c25_*` / `hok016c26_*` /
  `hok016c27_*` / `hok016c4_ngr_force_storage_success.py` /
  `hok016cx_*`：HOK-016 系列 locator / step-into / watchpoint / force
  / seed 实验的全部脚本；完整说明、产物路径、BP callback 踩坑见
  `HOK-016-appendix-tooling.md`。

### 不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/*`、`LocalDocs/MCPFinal/*`：与本
  主线无关，除非需要借鉴 dashboard 维护方式或 MCP 验证套路。
- 未来若本目录新增 `HOK-xxx-*.md`，默认规则：**只有本 Dashboard 明确
  点名的当前主线子文档才需要随手读取**。
