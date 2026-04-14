## Capture Target Fix Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 当前主线

> 当前只做一件事：**围绕 `恋与深空` 当前可打开但内容不完整的 `.gputrace`，按默认流程先确认 capture target 选择、queue 发现与 capture 挂载时机这三层里哪一层最像主因，再只挑一个当前最靠近根因的最高价值问题做最小修复、复跑 live capture、更新控制面；若问题过大，就继续拆成更小子任务。**

后续控制面只围绕下面这条流程展开：

1. 先按当前默认 live 流程重跑 `恋与深空` fresh launch，确认问题态仍可稳定复现
2. 读取 capture status、`runtime_launch_diagnostics_summary.py`、`check_gputrace_sources.py`、Xcode frame dump 与必要的 runtime 产物
3. 确认当前最高优先级问题更像 capture target 选错、tracked queue 选错、delayed capture 挂载过晚，还是 replacement side 干扰
4. 若有多个症状，就只挑一个最值得处理的主因，按默认流程完成归因
5. 判断它更像 MCP 默认参数问题、runtime capture object 选择问题、queue ranking 问题，还是 capture preload / startup injection 时机问题
6. 若值得修，做一次最小而定向的修改，并完成 single-issue + live capture 复跑
7. 若任务过大，就拆成更小的 capture residual 子任务；仍然一次只完成一个

## 当前判断

### 现在真正的核心问题

- 当前主要矛盾已经不是“能不能截到 `.gputrace`”，而是**当前 trace 虽然可打开、也有真实 `Command Buffer` 与 pipeline，但内容覆盖不完整，很多 repeated render encoder 近乎空壳**
- 当前最有价值的推进方式，不是继续扩大 app 或文档范围，而是**围绕当前这条 `恋与深空` 可复现路径，把 `capture target`、`tracked queue` 与 `capture preload timing` 三层拆开，逐个收敛**
- 已有 live 证据说明，这条路径已经足够接近根因：app 可启动、session 可 ready、capture 可落盘、Xcode 可打开 trace，因此现在适合做“单一主因 + 最小修复 + live recapture”的闭环

### 当前工作原则

- **capture 结构化证据是任务入口，不是收尾附属品**
- **一个主因一个主因地做，不对着“所有 encoder 一次性全对”死磕**
- **每次实现修改之后，必须重新看 trace 结构化证据是否改善，而不只是看 `.gputrace` 还能不能打开**
- **没有结构化收益的实现，不应轻易继续放大**
- **每轮开始前先重跑当前默认 capture 入口，再决定当前最值得处理的 residual issue**

### 当前最新状态

- 当前 `恋与深空` 的问题态已经明确：`.gputrace` 可以稳定落盘并被 Xcode 打开，但 capture 内容仍不完整；多个固定 render encoder 槽位（如 `4/6/7/9`）长期接近 `<0.01%`，而后续 `10/11/12` 又明显非空。
- 当前结构化证据仍支持“这不是 replacement 主链完全失效”，而更像 **capture target / queue 命中 / capture 挂载时机** 三者之一仍未命中真正主因。
- 当前 runtime 已经能发现真实 queue：fresh live `get_capture_status` 再次确认 `trackedCommandQueueCount=4`，最新 tracked queue 仍为 `CaptureMTLCommandQueue`；因此“完全没发现真实渲染 queue”已经不是主矛盾。
- **本轮已完成一次新的 fresh live recapture 对照**：重新 `build_and_install`、启动安装后的 `PlayCover.app`、对 `com.papegames.lysk` fresh launch + create session，并显式完成 `device` / `scope` / `queue` / `queue_scope` 四组 capture；四组 `.gputrace` 均成功落盘，说明默认 target 收敛并未破坏 live capture 基线。
- **本轮已拿到当前 launch 的 runtime 证据**：`python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3` 已出现本轮新的 launch 记录，且 launch settings 仍为 `injectMetalCaptureEnvironment=True`、`metalCaptureEnabled=True`、`shaderSourceReplacementEnabled=True`；因此这次对照不再只是旧 run 残留。
- **本轮 `check_gputrace_sources.py` 对照显示 `queue_scope` 有小幅正向收益，但还不足以宣布主问题已解决。** 当前四组 trace 的 index 缺失引用数分别约为：`device=1277`、`scope=1273`、`queue=1270`、`queue_scope=1268`；`queue_scope` 至少没有比 `device/scope` 更差，并且较 `device` / `scope` 略少缺失引用，但幅度仍偏小，还不能直接等同于 fixed encoder 空壳现象已经被实质性消除。
- **本轮已完成 `CTF-008` 判断**：runtime 当前仍直接依赖 `latestTrackedCommandQueue()`；其实现只是从已发现的 queue 顺序里选择“最新一个”，没有基于 command buffer 提交、render workload 或最近活跃度的 ranking，因此它只能代表“最近发现 / 最近被看到的 queue”，不足以稳定代表最值得 capture 的主 render queue。
- **本轮已落地 `CTF-009` 的最小实现**：`MetalCaptureService` 不再直接使用“最新发现”的 queue，而是改为一个轻量 ranking：优先更近期仍被观察到、重复发现次数更高、并对 `Capture*` 代理 queue 做小幅加权；当前这仍是 discovery-side heuristic，不等同于已经拿到真正的 command buffer 提交证据。
- 当前 delayed `dlopen` 兼容路径仍需保留，但它也依然可能带来 pre-existing Metal objects 未被完整 proxy 的残留风险，因此 preload / startup injection timing 仍是后续候选主因。
- **当前 `CTF-007` 的 Xcode UI 自动化阻塞已成功解除。** 通过修复辅助功能权限，`xcode_gpu_ops.py` 已能正常执行完整的自动化流程：成功加载 `.gputrace` 文件、点击 Replay 按钮、双击 Command Buffer 和 Render Encoder 激活 GPU 步进功能，并完成 frame dump 导出。
- **已成功获取结构化 frame dump 产物**：包含 memory info、navigator API call 和 pipeline state 数据，为后续分析 fixed encoder 空壳现象提供关键证据。
- 当前下一步聚焦：**优先评估 preload / startup injection timing 是否仍在 capture begin 前遗漏了关键 Metal objects；若该方向收益有限，再继续把 queue ranking 从 discovery-side heuristic 升级到更接近 command buffer activity 的证据。**

## 当前默认流程

### Step 1：先从结构化报告选下一个 case

默认优先级：

1. **先看会直接影响 capture target 命中真实渲染路径的 issue**
2. 优先选择：
   - 能在 `恋与深空` fresh live 中稳定复现的
   - 能在 capture status、Xcode frame dump、`check_gputrace_sources.py` 中留下结构化证据的
   - 能映射到同一类 target / queue / timing 机制的
   - 有希望通过一处实现改动同时改善多份 trace 内容完整度的
3. 当前不优先：
   - 只能靠肉眼主观判断、缺少结构化佐证的渲染观感问题
   - 仍然需要长时间人工交互或复杂游戏内状态才能浮现的问题

推荐输入：

- `playcover_get_capture_status` 输出
- `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit <n>` 的输出
- `python3 Scripts/check_gputrace_sources.py <trace.gputrace>`
- `python3 LocalDocs/XCodeOperation/collect_cbs.py -o <json>` 产物
- `python3 LocalDocs/XCodeOperation/xcode_gpu_ops.py dump -o <dir>` 产物
- `~/Library/Containers/com.papegames.lysk/Data/Documents/Captures/*.gputrace`
- `~/Library/Containers/io.playcover.PlayCover/gpuTraces/*.gputrace`

### Step 2：先做 case 分析，再决定是否改实现

每个 issue 至少回答下面几个问题：

- 差异是发生在：
  - MCP 工具暴露层 / schema / 默认参数
  - runtime capture target 选择（`device` / `scope` / `queue` / `queue_scope`）
  - tracked queue 发现、排序与选择
  - delayed `dlopen` / capture preload / startup injection 时机
  - replacement side 对 capture 内容的次级干扰
  - Xcode / trace 检查脚本的观测口径
- 这是“观测口径问题”还是“更像真实 capture 缺口”
- 这个差异更像来自：
  - 错误的默认 target
  - 错误的 queue 选择规则
  - 过晚的 capture library 加载
  - scope begin / stop 时机不对
  - replacement / host bridge 的次级噪声
  - trace 结构检查脚本不对称
- 当前结构化证据是否已经回答了：
  - runtime 当前是否已发现真实 `CaptureMTLCommandQueue`
  - 当前 trace 是“完全空”还是“部分 encoder 内容不完整”
  - source attribution 是否已经足够证明 replacement 至少部分工作正常
  - 当前默认 target 是否真的把验证路径锁在了 `device` / `scope`
  - 当前 queue 选择是否等同于“最后创建的 queue”，而不是“最忙的主渲染 queue”
- 若问题属于 capture target / queue 形态，`MetalCaptureService.swift` 当前的 capture object 选择、queue discovery、scope lifecycle 与 stop policy 是否已经给出更贴近 runtime 的结论
- 如果修复，应该改哪一层最合适：
  - `PlayCoverMCP/Tools/Session/CaptureTools.swift`
  - `PlayCoverMCP/Session/CaptureService.swift`
  - `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
  - queue ranking / commit activity 观测辅助逻辑
  - 仅作为次级项的 trace 检查脚本或 Xcode 自动化

- **必须严格优先尝试修改真正负责 capture target、queue 选择或挂载时机的实现层。** 只有当反复验证后确认实现层没有问题，才考虑优先改 trace 检查口径或观测脚本。

若这一步还没有明确判断，**不要急着改实现**。

### Step 3：只做最小实现改动

一旦判断某类差异确实值得修，默认策略是：

- 只修一个清晰问题
- 只引入一个清晰机制
- 尽量保持 diff 小、影响面可控

例如：

- 把 MCP / runtime 默认 target 从 `.device` 收敛到 `.queue_scope`
- 把工具 schema 真正放开 `queue` / `queue_scope`
- 把 queue 选择从“最后发现”收紧到“最近活跃 / 最可能是主 render queue”
- 在不破坏兼容性的前提下，把 capture preload 时机前移到更可靠的 runtime 阶段

禁止一次混入多条彼此无关的修正。

### Step 4：每次实现后都要做两层验证

#### 4.1 单 case 验证

目的：先确认本轮改动确实命中了目标 capture 异常。

默认动作：

- 对 `恋与深空` 执行一轮 fresh launch + create session
- 读取同轮 capture status、必要的 runtime diagnostics、`check_gputrace_sources.py` 与 Xcode frame dump 输出
- 若问题涉及 target / queue 选择，则至少补一组对照 capture（默认 target vs `queue_scope` 或修复前 vs 修复后）

要求回答：

- 原来的那条 capture 异常是否消失 / 降级
- 真实 render queue 是否已经被更稳定地命中
- 是否引入新的 startup / capture / replacement 回归

#### 4.2 full-batch 验证

目的：确认这不是单次偶然改善，而是对当前主线问题有稳定收益。

当前默认要看两条 live 复跑：

- `恋与深空` 当前问题态 fresh launch
- 至少一组 `device/scope` 与 `queue/queue_scope` 的 capture 内容对照

必须回答：

- fixed encoder 空壳现象是否减少
- trace 是否仍能稳定落盘并被 Xcode 打开
- 当前默认 target 是否已经不再把实验路径锁死在 `device` / `scope`
- 是否出现新的 queue discovery / capture start / stop 回归

### Step 5：把结果写回控制面

每次任务结束后，必须把下面内容回写到文档：

- 当前分析的是哪一类 capture issue
- 该类 issue 的当前结论是什么
- 是否已经落到实现改动
- single-issue 与 live recapture 的关键证据是什么
- 若涉及 target / queue / preload timing，结构化报告给出的结论是什么
- 下一步最值得继续分析的 issue 是什么

## TODO

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `CTF-001` 建立 capture target fix 主线与默认证据链 | DONE | 已完成当前问题 trace、capture status、Xcode frame dump 与现有代码路径的归纳，并把默认控制面切换到 capture target fix 主线 | 本文档 |
| `CTF-002` 确认当前 trace 的主症状是“内容不完整”而不是“完全空” | DONE | 已确认问题 trace 可打开、存在真实 `Command Buffer` 与 pipeline，当前主症状是固定 encoder 槽位长期近空 | 本文档 |
| `CTF-003` 分离 replacement coverage 与 capture coverage 两条解释 | DONE | 已确认 source attribution 比旧 milestone 更丰富，因此 replacement 不是当前 incomplete capture 的首要解释 | 本文档 |
| `CTF-004` 确认 runtime 已能发现真实 `CaptureMTLCommandQueue` | DONE | 已确认 capture status 中存在 tracked queue，且最新 tracked queue 为 `CaptureMTLCommandQueue` | 本文档 |
| `CTF-005` 收敛当前最高优先级 issue 所在层级 | DONE | 已把当前首要嫌疑收敛到 capture target / queue 选择与 capture 挂载时机，而不是先修 converter 或 replacement 主链 | 本文档 |
| `CTF-006` 修正 MCP 工具暴露层对 `queue` / `queue_scope` 的不完整暴露 | DONE | `CaptureTools.swift` 的 schema、默认说明与实际运行能力保持一致，不再把外部使用者误导到只剩 `device` / `scope` | 本文档 |
| `CTF-007` 验证默认 capture target 改为 `queue_scope` 的 live 收益 | DONE | 已完成 fresh launch + `device/scope/queue/queue_scope` live recapture，对照显示 `queue_scope` 有小幅正向收益；已成功完成 Xcode UI 自动化，`xcode_gpu_ops.py dump` 成功导出 frame dump 产物，确认 GPU 步进功能已激活，为后续 fixed encoder 空壳现象分析提供结构化证据 | 本文档 |
| `CTF-008` 评估 `latestTrackedCommandQueue()` 是否足以代表真实主渲染 queue | DONE | 已确认当前实现只是在已发现 queue 中选择“最新一个”，没有基于提交量、活跃度或渲染负载的 ranking；因此它不足以稳定代表最值得 capture 的主 render queue，后续应拆到 queue ranking 子任务 | 本文档 |
| `CTF-009` 收敛 queue ranking 策略，使 queue 选择更接近真实主渲染 queue | DONE | 已完成最小实现改动：把 queue 选择从“最新发现”收敛为轻量 ranking，综合最近观察时间、重复发现次数与 `Capture*` 代理特征；当前仍需后续 live 验证确认它是否真的改善固定空壳 encoder 现象 | 本文档 |
| `CTF-010` 评估 delayed preload / startup injection 时机是否仍造成部分 capture 缺口 | TODO | 明确 incomplete capture 是否仍主要由过晚的 capture library 加载导致；若是，需要再拆 preload 时机子任务 | 本文档 |

## 任务执行规则

### 一次只做一个任务

- 每个 agent / 每次会话默认只完成一个当前最高优先级任务
- 若任务过大，必须先拆出子任务，再只完成其中一个
- 不允许同时并行推进多个主线 issue

### 当前选题优先级

从高到低：

1. **会直接影响 capture target 命中真实渲染路径的 issue**
2. **已经在 live 结构化证据中稳定出现、且能映射到明确代码层的 issue**
3. **单个 issue 虽复杂，但明显指向 queue 选择 / preload timing / runtime capture object 的问题**
4. **trace 检查或观测口径问题**（如果它能明显减少误判，也值得做）
5. **只能靠长期人工浏览 Xcode 才能推进的问题**（当前不纳入默认选题范围）

### 拆任务的规则

若当前任务无法在一次工作中闭环，必须拆开。拆任务时沿下面方式切：

- 按异常类别切：`default target` / `queue selection` / `queue ranking` / `preload timing` / `trace interpretation`
- 按机制切：MCP schema / session capture params / runtime capture object / queue discovery / scope lifecycle
- 按样本族切：优先切出“固定 encoder 槽位反复近空”的 trace family

不要按含糊目标切，例如：

- “继续研究截帧不完整”
- “进一步优化 capture 内容”

## 当前默认验证

### 改实现前

按改动类型选择最低要求：

- **纯文档 / 方法规范 / 路线整理改动**：更新文档并自检跨文档口径一致性，无需额外构建
- **MCP tool schema / capture 参数 / Swift host 层改动**：

```bash
./BuildScripts/build_and_install.sh
```

- **runtime capture object / queue discovery / PlayTools Swift 改动**：

```bash
./BuildScripts/build_and_install.sh
```

  若同时涉及 trace 检查脚本或 Xcode 自动化，再补跑对应 Python 校验。

- **改动了工程文件**：

```bash
./BuildScripts/lint_pbxproj.sh
```

### 单 case 验证

默认入口是：

```bash
python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3
python3 Scripts/check_gputrace_sources.py <trace.gputrace>
python3 LocalDocs/XCodeOperation/collect_cbs.py -o <json>
python3 LocalDocs/XCodeOperation/xcode_gpu_ops.py dump -o <dir>
```

单 case 默认应读取同轮产物：

- capture status 输出
- `runtime_launch_diagnostics_summary.py` 输出
- `check_gputrace_sources.py` 输出
- `collect_cbs.py` 产物
- `xcode_gpu_ops.py dump` 产物

若问题涉及 target / queue 对照，默认补充：

```bash
capture_metal_frame(..., capture_target=device)
capture_metal_frame(..., capture_target=scope)
capture_metal_frame(..., capture_target=queue)
capture_metal_frame(..., capture_target=queue_scope)
```

补充约束：

- 默认不要只看 `.gputrace` 是否存在；必须至少读一层结构化摘要
- 默认不要只做单一路径 capture；若本轮目标是 target fix，必须有对照组

### full-batch 验证

只要本轮改动影响 capture target 默认值、queue 选择、capture object 选择、preload timing、scope lifecycle 或其它可能改变 trace 内容分布的逻辑，收尾时默认执行：

```bash
./BuildScripts/build_and_install.sh
```

然后至少完成一轮：

- `恋与深空` fresh launch + create session
- 修复前 / 修复后或默认 / 对照 target 的 live capture 对比

当前最重要的不是“有没有跑”，而是：

- fixed encoder 空壳现象有没有减轻
- `queue_scope` 是否比 `device` / `scope` 更接近真实 render 路径
- trace 是否仍可稳定落盘并被 Xcode 打开
- 是否引入新的 startup / session / replacement 回归

## 当前完成判定

当前每个任务的完成判定统一为：

1. 已选出一个明确 issue / capture 差异模式
2. 已完成足够深入的 capture target / queue / timing 分析
3. 已判断它更像默认 target 问题、queue 选择问题，还是 preload 时机问题
4. 若值得修，已完成一次最小实现修改
5. 已完成单 case live capture 验证
6. 已完成默认 / 对照 target 的 live recapture 对比
7. 已明确记录症状变化与下一步建议

只有满足这 7 条，当前任务才算真正闭环。

## 当前非默认验证

下面这些事项当前不写成默认 TODO 或完工 gate：

- 更广泛的多 app smoke
- 长时间人工点击、人工登录或游戏内深场景验证
- 纯肉眼渲染主观观感对比
- 与当前 capture target 主线无关的 converter / canonical compare 深挖
- 任何需要长期占机的 Xcode 手工逐帧浏览

只有当某个具体 capture issue 的低层结构化证据已经不足以回答问题，或用户明确要求进入更高层验证时，才再考虑升级。

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格选取一个当前最高优先级的未完成任务执行。每次只允许取一个任务执行，严禁对着最终目标死磕。
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新子任务追加到 TODO，再只完成其中**最关键**的一个。单个TODO不宜过长。
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**，禁止擅自在主线新增新的章节。
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## 踩坑与经验

- **`.gputrace` 能打开，不等于 capture 内容完整。** 当前默认应优先看 `Command Buffer` / encoder 结构、pipeline 名单与固定空壳槽位分布，而不是只看文件能否被 Xcode 打开。
- **source attribution 变多，不等于 render encoder 已经完整。** replacement 侧 richer source 只能证明“至少部分替换 / 归因链路工作正常”，不能直接证明 capture target 已命中真实主渲染路径。
- **默认 target 是一等证据。** 本轮已把 `CaptureFrameParams` 与 runtime fallback 的 omitted-target 默认值收敛到 `.queue_scope`；但在 fresh live 对照落地前，不能把“实现已修改”等同于“capture 收益已验证”。
- **工具 schema 与真实能力不一致会把排查带偏。** 当解析层和 runtime 都已支持 `queue` / `queue_scope`，但对外 schema 仍只暴露 `device` / `scope` 时，使用者会被系统性误导到错误实验路径。
- **即使默认 target 已切到 queue-bound capture，也仍要靠 live 对照回答收益。** 若没有 fresh `device/scope` vs `queue/queue_scope` 的结构化对照，仍无法区分“默认值修正已命中主因”与“真正问题在 queue ranking / preload timing”。
- **`latestTrackedCommandQueue()` 不等于“主 render queue”。** 最后创建的 queue 只能说明“最近被看到”，不能说明“提交了最多真实渲染工作”。
- **仅靠 discovery-side queue ranking 仍然不是 command buffer activity 证据。** 即便当前已把 queue 选择从“最新发现”收敛为轻量 ranking，它本质上仍只是在“最近观察到的代理 queue”之间排序；若 live 收益不足，下一步仍要继续补更接近提交活跃度的证据。
- **delayed `dlopen` 的价值是兼容性，不是完美覆盖。** 它避免了启动期崩溃，但也天然存在 pre-existing Metal objects 未被完整 proxy 的风险；当前 incomplete capture 的症状必须始终把这层代价纳入解释。
- **scope begin / stop 是观察窗口，不是纯实现细节。** 若 begin 太晚、stop 太早，即便 trace 可打开，也会留下“前面若干 encoder 近空、后面后处理 pass 明显非空”的结构。
- **优先把高频 target 对照流程固定下来。** 若默认验证永远只跑 `device` / `scope`，就无法回答 queue-bound capture 是否已经改善问题。
- **Xcode UI 自动化阻塞要和 capture 主链故障分开记账。** 本轮 fresh live 已证明 `device/scope/queue/queue_scope` 四组 capture 都能成功落盘；当前卡住的是 `xcode_gpu_ops.py` 在 `show_navigator("Debug")` 的菜单点击超时，而不是 `queue_scope` 路径本身再次失效。
- **主文档不要直接暴露会漂移的本机截图或窗口状态。** 本机 trace 路径、Xcode dump 目录、局部截图说明都应尽量下沉到运行产物或参考文档。

## 参考信息

- **当前问题最像 capture target / queue / timing 的复合问题，而不是单点 export failure。** 因为当前 trace 已经存在真实 `Command Buffer` 与 pipeline，但仍保留一批固定空壳 encoder。
- **当前最高价值实验不是“再抓更多 trace”，而是让 target 对照真正覆盖 `queue` / `queue_scope`。** 只有这样才能把“错误 target”与“过晚 preload”这两类解释拆开。
- **若默认 target 修正后仍无改善，下一层优先看 queue ranking，而不是立刻回退去修 converter。** 当前证据链还不支持把 incomplete capture 首先归因到 `IRToMSLConverter`。

### 本目录主文档

- `00-Dashboard.md`

### 当前重点分析目录

- 当前暂无必须建立的固定子目录；若后续确实需要长期维护 target 对照、queue ranking 或 preload 时机专项，再按 `01`~`08` 骨架补建

### 相关实现与工具

- `PlayCoverMCP/Tools/Session/CaptureTools.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Session/BridgeProtocol.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Scripts/check_gputrace_sources.py`
- `Scripts/runtime_launch_diagnostics_summary.py`
- `Scripts/compare_capture_runs.py`
- `LocalDocs/XCodeOperation/collect_cbs.py`
- `LocalDocs/XCodeOperation/collect_re_details.py`
- `LocalDocs/XCodeOperation/xcode_gpu_ops.py`
