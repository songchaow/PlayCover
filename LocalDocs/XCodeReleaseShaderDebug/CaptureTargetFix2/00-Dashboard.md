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

- **当前最新进展**：`CTF2-004` 已落地为可复用脚本链：`snapshot_capture_run.py` 现在会把 runtime launch diagnostics 一并固化到 snapshot，`capture_target_compare_runner.py` 则把同轮 `device` vs `queue_scope` 的双 snapshot + compare 报告串成标准入口；fresh live recapture 仍保持可稳定复用，`xcode_gpu_ops.py dump` 与 `collect_cbs.py` 证据链未回退。
- **当前主判断**：问题已经不再像“capture/export failure”，而更像**成功 capture 之后仍存在部分内容残缺**；`queue_scope` 相比 `device` 只有小幅收益，还不足以单独证明主因就是 target 默认值。
- **当前关键缺口**：同轮 target 对照与 snapshot/compare 入口已经固化，但 hollow encoder 槽位仍缺少稳定的结构化对照口径；下一优先级转到回答“固定空壳 encoder 是否跨 target 同构”。
- **当前 blocker**：现有 queue 选择仍主要基于 discovery-side proxy 线索，而不是 command-buffer activity 级别证据；因此即便 capture 命中了 `CaptureMTLCommandQueue`，也还不能证明命中了最值得截取的真实主渲染 queue。
- **下一步默认规划**：
  - 先使用 `capture_target_compare_runner.py` 固化同一路径下的 `device` vs `queue_scope` fresh snapshot 对照，保留 `.gputrace`、source summary、launch diagnostics 与 compare 报告的同轮证据；若需要 hollow encoder 对照，再补跑对应 Xcode dump。
  - 再用 `collect_cbs.py` / Xcode dump 对照固定的 hollow encoder 槽位是否跨 target 仍然重复出现。
  - 若 hollow encoder 在 target 对照中基本同构，下一优先级切到 queue ranking 证据，而不是继续放大 target 默认值改动。
  - 若 timing 证据显示 preload / startup 时序仍与残缺程度相关，则拆出 preload timing 子任务单独推进。
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
- `python3 Scripts/snapshot_capture_run.py --bundle-id <id> --label <label> --gputrace <trace.gputrace> --capture-target <target> --print-compare-path`
- `python3 Scripts/capture_target_compare_runner.py finalize-pair --bundle-id <id> --pair-label <label> --device-gputrace <device.gputrace> --queue-scope-gputrace <queue_scope.gputrace>`
- `python3 Scripts/capture_target_compare_runner.py compare-pair --bundle-id <id> --pair-label <label>`
- `python3 Scripts/compare_capture_runs.py --run-a <snapshotA> --run-b <snapshotB>`
- `python3 Scripts/analyze_capture_run_matrix.py --run <snapshotA> --run <snapshotB> ...`
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
| `CTF2-005` | DOING | 建立 hollow encoder 槽位的结构化对照口径，回答“固定空壳 encoder 是否跨 target 同构” | 默认使用 Xcode dump + `collect_cbs.py` |
| `CTF2-006` | TODO | 判断 queue ranking 是否仍缺少足够接近 command-buffer activity 的证据，并决定是否拆出 queue-activity 子任务 | 若 target 对照收益持续很小，则其优先级上升 |
| `CTF2-007` | TODO | 判断 preload timing 是否仍与残缺程度相关，并决定是否拆出 timing 子任务 | 结合 launch diagnostics 与 snapshot 对照 |
| `CTF2-008` | TODO | 若 target / queue / timing 都不能解释残缺，再重新评估是否需要把 replacement side 或其它观测口径拉回主线 | 当前明确不是默认优先项 |
| `CTF2-009` | BLOCKED | 任何需要用户授权补设 Accessibility、手工登录 app、持续人工交互或工作区外动作的验证 | 触发时必须先获得用户确认 |

## 踩坑与经验

- `.gputrace` 能落盘、能打开，不等于 capture 内容已经完整。
- `queue_scope` 比 `device` 略好，不等于 target 已经找对；小幅改善和主因闭环是两回事。
- source attribution 变丰富，只能证明部分链路恢复，不能直接证明 hollow encoder 已消失。
- 当前 queue ranking 仍偏 discovery-side 代理证据；若缺少 command-buffer activity 级别证据，就不要过早断言“已命中主渲染 queue”。
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
- `Scripts/compare_capture_runs.py`：两轮 snapshot 的细粒度比较入口。
- `Scripts/analyze_capture_run_matrix.py`：多轮 snapshot 的矩阵对照入口。
- `Scripts/runtime_launch_diagnostics_summary.py`：launch / preload timing / bridge 结构化摘要入口。
- `LocalDocs/XCodeOperation/xcode_gpu_ops.py`：Xcode replay、frame dump 与导航自动化。
- `LocalDocs/XCodeOperation/collect_cbs.py`：Command Buffer / encoder 结构化导出入口。

### 暂不需读取

- 本目录下的后续子文档当前暂未建立；当某个任务需要长期维护详细实验记录、口径定义或历史归档时，再新增子文档并在此处重新归类。
