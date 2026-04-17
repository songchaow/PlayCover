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
- 默认优先级：**兼容配置 / 运行时最小化副作用** → **延迟或分层关闭早期 bootstrap** → **LLDB / faulting instruction 归因** → **app 二进制 patch**。
- 不允许把“用户手工登录、手工点 UI、手工看窗口表现”作为日常验证 gate；这些只能作为例外步骤，且需先确认。
- 主文档只保留决策信息、默认执行路径和高频复用经验；历史细节、长日志、反复试错过程必须下沉到子文档。

## 主线任务

- **当前结论**：`com.tencent.ngr` 的 **app-scoped 最小兼容启动 gate 已落地**。最新一轮验证中，即使把 `metalCaptureEnabled`、`injectMetalCaptureEnvironment`、`playChain`、`rootWorkDir` 人为改回 `true`，runtime 仍会记录 `playcover_startup_compat_profile_applied`，并把这一组高风险早期路径压成关闭态；但进程依旧在 `playcover_launch_complete` 之后很快崩溃，说明问题**不再主要卡在这组已知早期副作用是否被误打开**。
- **当前已知事实**：2026-04-18 本地验证生成了新的 `NGR-2026-04-18-001136.ips`。对应的 `launch-events.jsonl` 显示：`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved` 已出现，且 `playcover_library_injection_installed` 不再出现；但 `create_session` 仍超时，`list_sessions` 只看到 `disconnected`，新的 `.ips` 仍是主线程 `EXC_BAD_ACCESS / SIGSEGV`，faulting address 为 `0x0`，faulting frames 继续落在 `NGR` image 的早期 initializer 窗口。
- **当前主线**：保留已落地的 `com.tencent.ngr` 最小兼容启动 gate，继续把“runtime 实际生效值”和“plist / MCP 设置值”分开看待；在此基础上，下一阶段要么补齐最小兼容档的自动化表达能力，要么继续向更深一层 bootstrap（`AKInterface`、`PlayScreen`、`PlayInput`、`DiscordIPC`）下钻。
- **当前卡点**：虽然 startup gate 已经证明能把 `MetalCapture` / `library hook` / `rootWorkDir` 压掉，且代码路径上已对 `PlayChain` 做 app-scoped 屏蔽，但崩溃窗口没有实质离开 `NGR` 自身 early initializer；同时，现有自动化写入路径还不能完整表达这套最小兼容档，host/MCP 看到的原始 settings 也不等于 runtime 最终生效值，其中 `shaderSourceReplacementEnabled` 仍是最明显的缺口。
- **下一步默认规划**：
  1. 补 `com.tencent.ngr` 的 settings 自动化表达能力，把最小兼容档里被 runtime 强制压低的开关都纳入稳定写入/对照范围，尤其是 `shaderSourceReplacementEnabled`。
  2. 继续沿用“构建 → 启动 → session → launch diagnostics → `.ips`”闭环，对 clean minimal settings 再做一轮固定口径验证。
  3. 若崩溃窗口仍保持不变，再按顺序分层延迟或禁用 `AKInterface`、`PlayScreen`、`PlayInput`、`DiscordIPC` 等更深一层早期 bootstrap。
  4. 只有当 PlayTools 已被最小化到近乎空载、崩溃仍保持同一 faulting window 时，才升级到 LLDB + 二进制意图分析 / patch。

## 构建与验证的方法

### 日常默认方法（必须可由 agent 独立完成）

- **构建 PlayTools 改动**：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- **涉及主 app / 注入 / 安装链路时**：`./BuildScripts/build_and_install.sh`
- **读取 / 固化目标 app 配置**：优先使用 `get_app_settings` / `update_app_settings`，目标是让 `com.tencent.ngr` 处于最小兼容模式；若某个关键开关当前还无法经现有 MCP 稳定写入，则应先补自动化写入路径，而不是退回手工 GUI 点选。
- **运行时验证**：`launch_app` → 固定等待 → `create_session` / `list_sessions`。默认 pass 条件是：session 不再秒断、进程在 settle window 内持续存活、且没有新的同类 `NGR-*.ips` 崩溃报告。
- **证据收集**：每轮都要对照读取
  - `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  - `~/Library/Logs/DiagnosticReports/NGR-*.ips`
- **需要更细粒度定位时**：使用 `launch_app_with_lldb` 做同一轮自动化复现，抓 faulting instruction / backtrace；这仍属于 agent 可独立完成的默认升级路径。

### 当前建议的最小兼容验证口径

- 默认把 `metalCaptureEnabled=false`、`injectMetalCaptureEnvironment=false`、`shaderSourceReplacementEnabled=false`、`rootWorkDir=false`、`playChain=false` 视为 `com.tencent.ngr` 的优先隔离态；其中如果某项当前无法通过现有自动化接口可靠施加，应先补自动化能力。
- 只要本轮改动触及启动顺序、PlayTools 注入内容、settings 默认值、per-app gate、签名/重签或 app 包内二进制，就必须重新跑一轮完整的“构建 → 启动 → session → launch diagnostics → crash report”闭环。

### 需要用户确认后才能继续的事项

- 任何需要用户账号、验证码、手工登录、手工进游戏或手工点击复杂 UI 的验证。
- 任何依赖外部下载、替换新的 app 构建、或需要用户提供额外私有材料的步骤。
- 任何必须由用户亲自观察窗口视觉表现、而 agent 无法以 session / diagnostics / crash evidence 替代判断的步骤。

## agent的工作流程介绍

1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。
4. 若任务过大，先拆出新的子任务并追加到 TODO的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 执行完毕后必须整理本文档：删除过时信息，更新 主线 /TODO / 踩坑 / 优先级变化，并把真正高频复用的手工流程收敛成脚本；主文档保持简洁，不能只追加不整理，也不能改变本文档章节结构。
7. 复盘当前技术路线；除最终目标不能改变外，中间方案可根据新发现随时调整。
8. 收尾后执行 `git commit`。

## 所有任务TODO状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| HOK-001 | DONE | 复现 `com.tencent.ngr` 启动崩溃并固定第一轮基线证据（session / launch diagnostics / `.ips`） | 暂无；证据已体现在主线结论中 |
| HOK-002 | DONE | 为 `com.tencent.ngr` 落地 app-scoped 最小兼容启动 gate；runtime 现已显式跳过 `MetalCapture` / `library hook`，显式保留 working directory，并在代码路径上压低 `PlayChain` 早期副作用 | 暂无；结果已体现在主线结论与 launch diagnostics 中 |
| HOK-003 | TODO | 为 `com.tencent.ngr` 补齐最小兼容档的 settings 自动化表达能力，让被 runtime compat gate 压低的关键开关也能被稳定写入、读取和对照，尤其是 `shaderSourceReplacementEnabled` | 待建 |
| HOK-004 | TODO | 验证 `HOK-002 ~ HOK-003` 后的启动表现，并固化自动化对照脚本与 settle window 口径 | 待建 |
| HOK-005 | TODO | 若仍崩溃，分层延迟或禁用 `AKInterface`、`PlayScreen`、`PlayInput`、`DiscordIPC` 等更深一层早期 bootstrap | 待建 |
| HOK-006 | TODO | 做 LLDB / faulting instruction / crash window 归因，确认崩点是否仍固定在同一 `NGR` early initializer 路径 | 待建 |
| HOK-007 | TODO | 当 PlayTools 已接近最小副作用仍无法启动时，进入 `NGR` 二进制意图分析、callsite 归因与可逆 patch 设计 | 待建 |
| HOK-008 | TODO | 将构建、配置、启动、证据收集、结论汇总收敛成可重复的自动化脚本链路 | 待建 |
| HOK-009 | BLOCKED | 需要用户账号/手工 UI 的后续验证（若未来必须验证“进入游戏后”行为） | 暂不执行；执行前必须先得到用户确认 |

## 踩坑与经验

- `playcover_launch_complete` **不等于** app 已安全启动；`com.tencent.ngr` 当前就是在该事件之后很快崩溃。
- `metal capture` 关闭并不自动等于“没有启动期 Metal / library hook 副作用”；对该 app 需要显式做 per-app 最小化处理。
- `shaderSourceReplacementEnabled` 在 host/runtime 默认值里都偏向开启思路，不能想当然地把它当作“默认无影响”。
- `session briefly ready -> disconnected` 与新的 `.ips` 搭配起来，是比“窗口看起来闪退”更稳定的自动化判定信号。
- `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved` 是本轮之后判断 `com.tencent.ngr` 最小兼容 gate 是否真正命中的首选证据；不要再只看 plist 里的原始布尔值。
- 当前阶段的核心不是恢复全部 PlayCover 能力，而是先证明**最小兼容运行**能不能成立；能力恢复必须放在启动稳定之后。

## 参考信息

### 默认必读

- `LocalDocs/HOKCrash/00-Dashboard.md`：本文件；唯一维护当前主线、TODO 与默认验证口径。

### 按需读取

- `PlayCover/Model/AppSettings.swift`：host 侧 app 设置默认值与落盘路径。
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`：runtime 侧对同一份 settings 的读取方式与默认值。
- `PlayCover/Model/PlayApp.swift`：目标 app 启动环境、`DYLD_*` 清洗与 `injectMetalCaptureEnvironment` 逻辑。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`：PlayTools 的 dyld constructor / interpose 入口。
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`：`PlayTools` 启动顺序与 `playcover_launch_complete` 前后的关键路径。
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`：每轮 live 启动证据。
- `~/Library/Logs/DiagnosticReports/NGR-*.ips`：系统崩溃报告；用于对照 faulting window 是否发生移动。
- `LocalDocs/MCPFinal/04-接入与验证.md`：需要借用 MCP/自动化验证套路时再读。

### 暂不需默认读取

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`：仅在需要借鉴 dashboard 维护方式时参考。
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/00-Dashboard-Archive.md`：历史归档；不作为当前 HOK 主线入口。
- 未来若本目录新增 `HOK-xxx-*.md` 子文档，默认规则是：**只有主文档明确点名的当前任务子文档才需要随手读取**，其余均按需进入。
