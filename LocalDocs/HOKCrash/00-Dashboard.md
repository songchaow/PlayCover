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

**QtsFileSystem Create Failed!! 已修复**（RIPC-007）。W^X 合规修复使全部
runtime hook 成功安装，NGR 启动后 11+ 分钟无 QtsFS 告警、进程稳定存活。
下一步：验证是否达成最终目标（进入真正的游戏主循环）。

### 当前状态摘要

- 外层防线已全部稳定：HOK-013/014/015/010 全部 apply，进程不再秒崩。
- **RIPC-007 已修复 QtsFS Create Failed 根因**：`pt_ngr_make_patch_writable()`
  的 W^X 违规是所有 hook install 失败的根因。修复后 PDT-006 ConvertToPlatformPath
  patch、HOK-016c5 consumer-family-hook、alt1 hook 全部成功安装。
  验证报告：`build/ripc-007-verification-report.json`。
  详情见 `RealIPadCompare/00-Dashboard.md`。
- **HOK-014 `hok014_ngr_alert_suppressed` 降为 0**：修复后不再触发
  `QtsFileSystem Create Failed!!` 弹框。
- HOK-016-C.2.7 / C.4 / C.5 等原主线任务被 RIPC-007 **superseded**——
  根因通过真机对比方向（RIPC 系列）找到并修复。

### 修复路线（优先级从高到低）

1. ~~**RIPC-007（已完成）**~~：W^X 合规修复 → 全部 hook 安装成功 →
   QtsFS Create Failed 消除。详见 `RealIPadCompare/00-Dashboard.md`。
2. **HOK-016-D（当前主线）**：live 验证最终目标——进程进入真正的游戏
   主循环（CPU ≥5%、RSS 增长到 UE4 典型量级、Metal frame 推进）。
   若通过，HOK-014 正式降级为冷备安全网。
3. ~~HOK-016-C.2.7 / C.4 / C.5~~（被 RIPC-007 superseded）。
4. ~~PathDifferenceTrial / PDT-001-B-revised~~（被 RIPC-007 superseded）。

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

1. **待验证最终目标**：QtsFS Create Failed 已消除，但尚未确认 app 是否进入
   真正的游戏主循环（CPU ≥5%、RSS 增长、Metal frame 推进）。当前观察到
   进程稳定但 CPU 仅 2%、RSS ~316MB（低于 UE4 典型量级），可能还需要
   用户手工操作（如点击"开始游戏"按钮）。

### 下一步默认规划

1. **执行 `HOK-016-D`**：进行完整 live 验证，确认最终目标是否达成。
2. 若需要用户手工操作推进游戏初始化，向用户报告并请求协助。
3. HOK-016-D 通过后，正式把 HOK-014 降级为冷备安全网。
4. 闭合后做 `HOK-008`：固化启动验证单脚本。

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
| HOK-016-C.2.7 | DONE（被 RIPC-007 superseded） | QtsFS 根因通过 RIPC 真机对比方向修复：W^X 合规修复使全部 hook 安装成功。 | `RealIPadCompare/00-Dashboard.md`、`build/ripc-007-verification-report.json` |
| HOK-016-C.3 | DEFERRED | 终极野蛮方案：fishhook interpose `0x108878534` 直接返回 1，仅作最后兜底（当前不需要） | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.4 | DONE（被 RIPC-007 superseded） | 诊断性强制成功验证，不再需要 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.5 | DONE（被 RIPC-007 superseded） | `__DATA_CONST` 写保护问题被 W^X 修复绕过 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-C.6 | DEFERRED | 仅在必须依赖外部资源或登录态时，才降级到需要用户介入的路线 | `HOK-016-qts-fs-create-failed.md` |
| HOK-016-D | TODO（当前主线） | live 验证最终目标：进程进入游戏主循环（CPU ≥5%、RSS 增长、Metal frame）+ `hok014_ngr_alert_suppressed = 0` + 无新 `NGR-*.ips` | `HOK-016-qts-fs-create-failed.md` |
| PDT-001-B-revised | DONE（被 RIPC-007 superseded） | 路径转换差异验证不再需要，QtsFS 已通过 W^X 修复解决 | `PathDifferenceTrial/00-Dashboard.md` |
| PDT-002 | DONE（被 RIPC-007 superseded） | 不再需要独立路径伪装方案 | — |
| PDT-003 | DONE（被 RIPC-007 superseded） | PathDifferenceTrial 不再需要 | — |
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
  thread `frames[0].imageOffset` + LLDB `faultPc` 三者应一致。详见
  `HOK-007-二进制意图分析与callsite映射.md`。**阅读建议：需要追查新
  faulting callsite 时按需读取。**
- **`launch_app_with_lldb` headless 结构化证据**：消费
  `lldb.stopReason` / `lldb.faultingFrame` / `lldb.faultingInstruction`
  / `lldb.backtrace` / `lldb.blockingDialogWindows` / `lldb.watchpointHits`，
  不要把完整 transcript 当人工日志用。`timedOut=true` + `didStop=true`
  + 完整 fault 字段 = 证据有效。详见 `HOK-006-LLDB归因与crash-window压缩.md`。
  **阅读建议：需要改 LLDB 证据 schema 时按需读取。**
- **`blockingDialogs >= 1` ≠ 回归，也不能立即判定为 pass**：b.0 gate
  对"NGR onscreen window"本身也会报 1。需要同时看窗口 bounds 与
  `kCGWindowMemoryUsage` 区分 sheet（~260×204）vs 主游戏窗口
  （≥1024×512）。详见 `HOK-014-alert-suppressor.md` 与
  `HOK-012-工具链与方法论归档.md`。**阅读建议：需要跑 LLDB watchpoint /
  解读 b.0 gate 时按需读取。**
- **HOK-016 LLDB BP / watchpoint 踩坑**：完整脚本清单与踩坑汇总见
  `HOK-016-appendix-tooling.md`。**阅读建议：需要新增 HOK-016 系列 probe
  或复用 Python callback helper 时按需读取。**
- **natural run 的 materialize target 可能与 dual-force 不同**：任何基于
  固定 vtable slot 的 hook 方案，都必须先通过 live BP 验证运行期实际 target。
- **`__DATA_CONST` vtable slot 在当前 macOS 下不可写**：`mprotect` /
  `vm_protect` / `vm_write` 均失败。任何依赖 runtime vtable patch 的方案，
  必须先验证页保护是否允许写入。
- **Apple Silicon W^X 策略**：`mprotect(PROT_READ|PROT_WRITE|PROT_EXEC)`
  在 Apple Silicon 上 100% 失败。正确做法是两阶段：写入用 `R+W`（无 X），
  执行用 `R+X`（无 W）。`vm_protect` 回退使用 `VM_PROT_COPY` 触发
  copy-on-write。此修复（RIPC-007）使 PDT-006、HOK-016c5 consumer-family-hook、
  alt1 hook 从 install-failed 变为 installed，直接消除了 QtsFS Create Failed。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、
  TODO 与默认验证口径。**阅读建议：总是读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：当前主线
  HOK-016 的目的、核心证据、根因链、修复方向、已证伪路径。**阅读
  建议：只要在做 HOK-016-C 系列任务就总是读取。**
- `LocalDocs/HOKCrash/PathDifferenceTrial/00-Dashboard.md`：路径差异
  trial 的当前主线、TODO 与验证口径。**阅读建议：总是读取。**

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
- `PathDifferenceTrial/PDT-001A-compare-literals.md`：PDT-001-A 离线证据
  （`0x10432a068` compare literal 提取）。**阅读建议：需要复核
  PathDifferenceTrial 历史证据时按需读取。**
- `PathDifferenceTrial/PDT-004-natural-target-literal.md`：PDT-004 离线证据
  （natural run target `0x100128c6c` 的结构分析）。**阅读建议：需要复核
  natural run 与 dual-force 结构差异时按需读取。**

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
