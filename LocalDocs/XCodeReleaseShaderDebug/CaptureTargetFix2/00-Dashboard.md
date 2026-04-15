## Capture Target Fix 2 Dashboard

> **单一来源规则**：本目录中，凡是围绕 capture 内容残缺问题的任务状态、优先级、主线判断、默认验证方法与 TODO，只在本文维护。更细的实验记录、对照结果、长日志与历史归档下沉到子文档；主文档保持简洁，不重复流水账。

## 最终目标

- 让 `恋与深空` 当前 fresh live capture 路径下的 `.gputrace` 不仅能稳定落盘、被 Xcode 打开，还能在结构化证据中表现出**更完整的真实渲染内容**，而不是长期保留一批固定的 near-empty render encoder。
- 当前只聚焦一个问题：**解释并收敛“capture 已成功，但内容仍残缺”** 的主因。
- 默认优先拆分并验证三条候选主因：
  - capture target 是否仍未稳定命中真实渲染路径
  - tracked queue 选择 / ranking 是否仍偏离真实主渲染 queue
  - preload timing / startup injection 是否仍让部分 Metal 对象错过代理窗口
- 默认只推进 agent 可自主完成的链路；若某一步必须依赖用户授权、GUI 权限补设、账号登录、人工点选或其它用户持续介入，必须**先得到用户确认**，再继续落地方案。

## 全局约束

- 默认控制面不再围绕“capture 能否开始/落盘”展开；该层已基本打通，当前主问题是**内容完整度**。
- 默认优先处理**实现层真正会影响 target / queue / timing 的问题**；只有在实现层证据不足时，才把主精力放到观测脚本口径。
- 默认每次只推进一个最高优先级任务；若任务过大，先拆子任务，再只完成其中一个。
- 默认验证必须以 agent 可自动执行的方法为主；不要把人工 GUI 点击、登录态、系统设置切换写成日常流程。
- 若 Xcode Accessibility 权限、开发者工具环境、用户登录态或工作区外高风险动作成为前置条件，必须先汇报并获得用户确认；未确认前立即停止该路径。
- 默认不扩散到更多 app；当前仍以 `com.papegames.lysk` 的 fresh live 路径为唯一主样本，直到它不再能有效区分 target / queue / timing。
- 本文会保留 workflow 中“收尾后执行 `git commit`”这条流程原文，但**实际执行仍以当前会话的系统/用户指令为准**；若当前会话未明确要求提交，不得擅自 commit。

## 主线任务

- **当前最新进展**：`CTF2-012` 已先完成一轮“证据链显式化”收敛：`MetalCaptureService.swift` 现已把当前 **preferred tracked queue**、`most_active_command_queue_*` 与两者之间的 `queue_selection_alignment` 一并暴露到 `get_capture_status`；`snapshot_capture_run.py` 会把这层 preferred-vs-most-active 证据写入 `snapshot.meta.json` 与 `queue-activity-summary.txt`；`compare_capture_runs.py` 与 `capture_target_compare_runner.py` 也已补齐对应入口与摘要输出，能够在同轮 snapshot 对照里直接看见 queue 选择是否对齐 activity 主样本。
- **当前主判断**：`CTF2-011` 的核心决策保持不变：queue-activity 主证据仍应优先来自 **runtime-side activity**，离线结构化分析继续承担 hollow encoder / source attribution / CB 结构对照。但 `CTF2-012` 现阶段不应在缺少 fresh live 样本前直接改 ranking；更合理的顺序是先把“preferred vs most-active 是否一致”固化进标准对照产物，再根据样本决定是否让 ranking 吸收 activity 权重。
- **当前关键缺口**：当前缺的已不再是 schema 或导出入口，而是**至少一轮 fresh live 样本**：需要把同轮 `get_capture_status` JSON、`.gputrace`、launch diagnostics 与 Xcode 结构化产物并排固化，才能回答 preferred queue 是否稳定等于 most-active queue，以及这种偏差是否只出现在 empty-capture 分支。
- **当前 blocker**：阻塞点已从“缺少 preferred-vs-most-active 的标准化证据出口”收敛为“尚未取得带新字段的 fresh live 对照样本”。若后续验证重新依赖用户登录、GUI 点选、Accessibility 或工作区外动作，仍需先得到用户确认。
- **下一步默认规划**：
  - 保留 `CTF2-010` 的当前结论：`scope` 多出的 `Command Buffer 29 / 9` 个槽位，应先按“capture 边界后移 / 多覆盖一个尾部 command buffer”处理；除非后续出现 overlap 内部结构分叉的新证据，否则不再把它当成未解释的主问题。
  - 将 `CTF2-011` 按“runtime-side queue-activity 证据层已落地、snapshot 入口已可复用”收尾；除非后续发现 runtime 计数口径明显失真，否则不再回到“runtime vs 离线二选一”的判断题。
  - 新的最高优先级保持为利用这层新 evidence 复核 queue ranking：优先采一轮 fresh live 样本，判断 `preferredTrackedCommandQueue()` 当前命中的 queue，是否持续等于 `most_active_command_queue_*` 所指向的 queue；若不一致，再决定 ranking 应如何吸收 activity 权重。
  - 继续把 `queue` 与 `queue_scope` 记为当前 empty-capture 分支；除非后续拿到新的 stable replay 证据，否则不要把它们重新并入 non-empty hollow encoder 对照。
  - 若 timing 证据显示 preload / startup 时序仍与尾部缺失程度相关，则拆出 preload timing 子任务单独推进。
  - 在结构化证据没有明显指向前，默认**不把 converter / replacement 主链重新拉回主线**。

## 构建与验证的方法

### 默认原则

- 构建、重建、安装必须优先使用 `BuildScripts/` 的标准脚本；不要手写 `xcodebuild` 替代，也不要人工拼装安装流程。
- 默认只采用 agent 可独立完成的命令链路；不把人工点击、人工登录、人工准备环境写入日常流程。
- 若某一步必须依赖用户介入，必须先说明原因并得到用户确认；未确认前立即停止，不得擅自继续该路径。

### 日常默认验证

- **纯文档改动**：更新文档并自检章节结构、引用和 TODO 状态即可，无需额外构建。
- **Python 脚本 / Xcode 自动化 / trace 检查脚本改动**：优先跑与本轮改动直接相关的最小自动化验证，例如：
  - `python3 Scripts/check_gputrace_sources.py <trace.gputrace>`
  - `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 5 --json`
  - `python3 LocalDocs/XCodeOperation/xcode_gpu_ops.py dump -o <dir>`
  - `python3 LocalDocs/XCodeOperation/collect_cbs.py -o <json>`
- **Swift runtime / PlayTools / host bridge / capture service 相关改动**：
  - `./BuildScripts/build_and_install.sh`
  - 若改动会影响 trace 内容判断，再补跑与本轮问题直接相关的 capture 结构化验证。
- **改动了工程文件**：
  - `./BuildScripts/lint_pbxproj.sh`

### capture residual 默认验证顺序

1. **最小样本验证**：先在单轮 fresh run 中确认本轮改动是否命中了目标异常。
2. **结构化证据验证**：至少读取同轮的 capture status、launch diagnostics、source summary，以及一份 Xcode dump 或 CB 结构化产物。
3. **对照验证**：若本轮问题涉及 target / queue / timing，默认至少保留一组可比较的对照样本，而不是只看单份 `.gputrace`。
4. **必要时再升级**：只有当前三层都无法回答问题时，才考虑需要用户确认的更重验证路径。

### 当前推荐的自动化入口

- `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 5 --json`
- `python3 Scripts/check_gputrace_sources.py <trace.gputrace>`
- `python3 Scripts/snapshot_capture_run.py --bundle-id <id> --label <label> --gputrace <trace.gputrace> --capture-target <target> --capture-status-json <get_capture_status.json> --print-compare-path`
- `python3 Scripts/capture_target_compare_runner.py finalize-pair --bundle-id <id> --pair-label <label> --device-gputrace <device.gputrace> --queue-scope-gputrace <queue_scope.gputrace>`
- `python3 Scripts/capture_target_compare_runner.py finalize-pair --bundle-id <id> --pair-label <label> --device-gputrace <device.gputrace> --device-capture-status-json <device-get_capture_status.json> --queue-scope-gputrace <queue_scope.gputrace> --queue-scope-capture-status-json <queue_scope-get_capture_status.json>`
- `python3 Scripts/capture_target_compare_runner.py compare-pair --bundle-id <id> --pair-label <label>`
- `python3 Scripts/compare_capture_runs.py --run-a <snapshotA> --run-b <snapshotB>`
- `python3 Scripts/analyze_capture_run_matrix.py --run <snapshotA> --run <snapshotB> ...`
- `python3 Scripts/capture_target_hollow_encoder_report.py --collection <collection-device> --collection <collection-scope> --collection <collection-queue> [--collection <collection-queue-scope> --empty-target queue_scope] --output <report.json>`
- `python3 LocalDocs/XCodeOperation/xcode_gpu_ops.py open <trace.gputrace>`
- `python3 LocalDocs/XCodeOperation/xcode_gpu_ops.py dump -o <dir>`
- `python3 LocalDocs/XCodeOperation/collect_cbs.py -o <json>`

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

| 任务 | 状态 | 任务描述 | 备注 |
|---|---|---|---|
| `CTF2-001` | DONE | 建立新的 residual-control dashboard，明确主问题从“capture 是否成功”切换为“capture 成功后内容为何仍残缺” | 本文档 |
| `CTF2-002` | DONE | 确认 fresh live 证据链已恢复到可复用状态：capture status、四组 target 落盘、Xcode replay / dump、`collect_cbs.py` | 结论来自旧主线收尾 |
| `CTF2-003` | DONE | 收敛当前三条一等候选主因：target、queue ranking、preload timing | 当前主线以此三轴推进 |
| `CTF2-004` | DONE | 已把 runtime launch diagnostics 固化进 `snapshot_capture_run.py`，并新增 `capture_target_compare_runner.py` 标准化同轮 `device` vs `queue_scope` 的双 snapshot + compare 报告流程 | 默认对照入口已就位 |
| `CTF2-005` | DONE | 建立 hollow encoder 槽位的结构化对照口径，并产出首份 fresh live 报告 `ctf2-005-hollow-encoder-first-20260415b`；当前结论是 `device / scope` 的 overlap 槽位完全同构，`queue / queue_scope` 归入 empty-capture 分支 | 本轮已补齐四个 target 的 collection，并修正 empty 判定与百分比伪差异 |
| `CTF2-010` | DONE | 解释 `scope` 相比 `device` 额外多出的 `Command Buffer 29 / 9` 个槽位：当前证据更支持 capture 边界后移 / 多覆盖一个尾部 command buffer，而不是 overlap 内部结构分叉 | 依据是 `261` 个 shared slots 完全同构、launch/source 摘要保持一致，且额外 `9` 个槽位全部集中在尾部新增的 `Command Buffer 29` |
| `CTF2-006` | DONE | 已确认现有 queue ranking 仍主要依赖 discovery-side 代理特征，缺少 activity-grade evidence；已决定拆出 queue-activity 子任务继续推进 | 依据包括 `queue` / `queue_scope` 仍属 empty-capture 分支，以及 `MetalCaptureService.swift` 当前 ranking 尚未使用 command-buffer activity |
| `CTF2-011` | DONE | 已确定 queue-activity 证据优先补在 runtime 侧，并已通过 `get_capture_status` + `snapshot_capture_run.py --capture-status-json` 固化成可复用入口 | 当前可直接把 per-queue creation / commit activity 与单轮 snapshot 绑定保存 |
| `CTF2-012` | TODO | 使用新的 runtime queue-activity snapshot 复核当前 preferred queue 是否稳定等于 most-active queue，并据此决定 ranking 是否要吸收 activity 权重 | 当前标准证据出口已补齐；剩余工作是拿 fresh live 样本做验证 |
| `CTF2-013` | DONE | 将 preferred-vs-most-active queue 对齐状态显式暴露到 `get_capture_status`、snapshot 元数据、compare 报告与 pair runner 标准入口 | 现在可直接在 snapshot / compare 产物里看 `queue_selection_alignment` 与两侧 queue 摘要 |
| `CTF2-007` | TODO | 判断 preload timing 是否仍与残缺程度相关，并决定是否拆出 timing 子任务 | 结合 launch diagnostics 与 snapshot 对照 |
| `CTF2-008` | TODO | 若 target / queue / timing 都不能解释残缺，再重新评估是否需要把 replacement side 或其它观测口径拉回主线 | 当前明确不是默认优先项 |
| `CTF2-009` | BLOCKED | 任何需要用户授权补设 Accessibility、手工登录 app、持续人工交互或工作区外动作的验证 | 触发时必须先获得用户确认 |

## 踩坑与经验

- `.gputrace` 能落盘、能打开，不等于 capture 内容已经完整。
- `.gputrace` 是 macOS bundle，不是普通目录；若要把 trace 固化进工作区 snapshot，必须保留 bundle 元数据。当前已确认 `shutil.copytree()` 复制出的 snapshot trace 会在 Xcode 中退化成 `NotConnected Device`，而改用 `ditto` 后可恢复正常 replay。
- `queue_scope` 比 `device` 略好，不等于 target 已经找对；小幅改善和主因闭环是两回事。
- `queue_scope` 的 source summary 即便比 `device` 略好，也可能和 empty-capture 分支并存；因此不能把“引用缺失少一点”直接当作“Xcode 里可分析内容更多”。
- hollow encoder 对照必须先把 empty-capture 分支剥离；若把 `queue_scope` 和 `device / scope / queue` 强行混进同一批 slot 对照，结论会被 replay 能力差异污染。
- 用 `navigator_api_call.json` 直接数 Render Encoder 很容易把非空样本误判成 empty，因为默认 dump 并不会先展开所有 CB；当前 empty-capture 口径应优先看 `cb_data.json` 是否真的抽到了槽位。
- 做跨 target 的 slot 签名对照时，`Render Encoder ... | 0.57%` / `Compute Encoder ... | ≈ 0.01%` 这类时长百分比只是展示性噪声；如果不先归一化，就会把 overlap 完全一致的结构误报成大面积 differing slots。
- 多份 `.gputrace` 同时在 Xcode 里打开时，后续 GUI 自动化不能默认依赖 `windows[0]` 就是目标 trace；必须先确认当前窗口已经切到目标文档，否则很容易把 dump/collect 跑到上一份 trace 的 Summary 页上。
- source attribution 变丰富，只能证明部分链路恢复，不能直接证明 hollow encoder 已消失。
- 若跨 target 对照里 `shared slots` 全部同构、`missing slots` 又只集中在尾部连续新增的一个 command buffer，那么应优先把它解释成 capture stop 边界 / 尾帧纳入窗口差异，而不是 overlap 内部结构分叉。
- 当前 queue ranking 仍偏 discovery-side 代理证据；若缺少 command-buffer activity 级别证据，就不要过早断言“已命中主渲染 queue”。
- source attribution 轻微改善并不能替代 queue-activity 证据；若 `queue` / `queue_scope` 仍拿不出可 replay 的 CB / RE 结构，就不要把 source summary 的小幅改善当成 ranking 已有效命中主渲染 queue。
- 当前最值得长期保留的 queue-activity 证据，应优先来自 runtime 侧直接观察到的 tracked queue command-buffer creation / commit 活跃度；离线 `cb_data.json` / `key_pass_details.json` 更适合作为 replay 结构与 hollow encoder 对照，而不是单独承担 queue 归因主证据。
- 若要把 queue-activity 证据带入后续对照，应优先把 `get_capture_status` 原始 JSON 与 `snapshot_capture_run.py --capture-status-json` 一起固化进单轮 snapshot；不要只在终端里留下口头摘要。
- 若当前主问题是“preferred queue 是否真的跟 most-active queue 对齐”，不要再把 `latest_command_queue_*` 当成语义主字段；后续证据与脚本输出应优先读取显式的 `preferred_command_queue_*` 与 `queue_selection_alignment`。
- preload timing 的价值是缩小错过代理窗口的风险，不是天然保证所有 pre-existing Metal 对象都被完整纳入 capture。
- 若对照样本没有被 snapshot 固化，后续很容易只剩口头结论，无法稳定比较 target / queue / timing 的收益。
- 主文档只保留决策信息；长日志、单次 run 细节和大段命令输出应下沉到子文档或运行产物。

## 参考信息

### 必须读取

- `LocalDocs/XCodeReleaseShaderDebug/CaptureTargetFix2/00-Dashboard.md`（本文）

### 按需读取

- `LocalDocs/XCodeReleaseShaderDebug/CaptureTargetFix/00-Dashboard.md`：上一阶段主线与已完成的 target / queue / preload 收敛结果；需要确认当前结论来源时再读。
- `LocalDocs/XCodeOperation/README.md`：Xcode GPU 自动化入口、`xcode_gpu_ops.py` / `collect_cbs.py` 的使用前提与能力边界；需要做 Xcode 结构化验证时必须读取。
- `Scripts/check_gputrace_sources.py`：当前 source attribution / coverage 检查入口。
- `Scripts/snapshot_capture_run.py`：固化单轮 capture run 证据包的标准入口；后续若把 snapshot 对照流程固定下来，应优先引用它。
- `Scripts/capture_target_compare_runner.py`：CTF2-004 的标准对照入口；用于同轮固化 `device` vs `queue_scope` 双 snapshot，并直接生成 compare 报告。
- `Scripts/capture_target_hollow_encoder_report.py`：CTF2-005 的 collection 离线分析入口；读取已收集的 `cb_data.json` / `frame_dump`，输出 non-empty target 的 Render Encoder 槽位同构报告，并把 `queue_scope` 之类的 empty-capture 分支单独记账。
- `Scripts/compare_capture_runs.py`：两轮 snapshot 的细粒度比较入口。
- `Scripts/analyze_capture_run_matrix.py`：多轮 snapshot 的矩阵对照入口。
- `Scripts/runtime_launch_diagnostics_summary.py`：launch / preload timing / bridge 结构化摘要入口。
- `LocalDocs/XCodeOperation/xcode_gpu_ops.py`：Xcode replay、frame dump 与导航自动化。
- `LocalDocs/XCodeOperation/collect_cbs.py`：Command Buffer / encoder 结构化导出入口。

### 暂不需读取

- 本目录下的后续子文档当前暂未建立；当某个任务需要长期维护详细实验记录、口径定义或历史归档时，再新增子文档并在此处重新归类。
