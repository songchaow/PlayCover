## Live Error Fix Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 当前主线

> 当前只做一件事：**围绕 `恋与深空` 的当前 live 回归，按默认流程先稳定复现并分离“host bridge / replacement / capture / 渲染表现”四类异常，再只挑一个当前最靠近根因的最高价值问题做最小修复、复跑 live、更新控制面；若问题过大，就继续拆成更小子任务。**

后续控制面只围绕下面这条流程展开：

1. 先按当前默认 live 流程重跑 `恋与深空` fresh launch，确认问题态仍可稳定复现
2. 读取 `runtime_launch_diagnostics_summary.py`、capture status、`check_gputrace_sources.py` 与必要的 runtime 产物
3. 确认当前最高优先级问题更像 `Session not registered`、`llvm-dis timeout`、capture 内容异常，还是纯渲染语义错误
4. 若有多个症状，就只挑一个最值得处理的主因，按默认流程完成归因
5. 判断它更像 host bridge 生命周期问题、replacement 聚合/编译问题、compile posture 漂移，还是 converter 实现问题
6. 若值得修，做一次最小而定向的修改，并完成 single-issue + live 复跑
7. 若任务过大，就拆成更小的 live residual 子任务；仍然一次只完成一个

## 当前判断

### 现在真正的核心问题

- 当前主要矛盾已经不是“能不能启动 app”，而是**当前 runtime 在真实 live 路径上同时出现 replacement 主链异常与 capture/export 异常信号**
- 当前最有价值的推进方式，不是继续泛化做更多 app smoke，而是**围绕 `恋与深空` 当前这条可复现路径，把 `Session not registered` / `llvm-dis timeout` / trace 内容异常拆开，逐个收敛**
- 已有 live 证据说明，这条路径已经能稳定落到真实 runtime：app 可启动、session 可 ready、capture 可落盘，因此现在适合做“单一主因 + 最小修复 + live 复跑”的闭环

### 当前工作原则

- **live 结构化证据是任务入口，不是收尾附属品**
- **一个主因一个主因地做，不对着“所有问题一起消失”死磕**
- **每次实现修改之后，必须重新看 live 结构化证据是否改善，而不只是看 app 是否还活着**
- **没有 live 统计或结构化收益的实现，不应轻易继续放大**
- **每轮开始前先重跑当前默认 live 入口，再决定当前最值得处理的 residual issue**

### 当前最新状态

- 当前 `HEAD` 已完成一轮真实 live 复现：使用 `恋与深空`、`metalCaptureEnabled=true`、`injectMetalCaptureEnvironment=true`、`shaderSourceReplacementEnabled=true` 的问题态三开关，app 可以启动，`create_session` 能返回 `ready`，说明不是简单的“完全起不来”。
- 当前 live 结构化诊断已经确认 replacement 主链存在硬异常：`runtime_launch_diagnostics_summary.py` 在最近一轮 fresh run 中记录到了 `replacement_exception`，主因集中在 `Host bridge reported an error: Session not registered` 与 `Host llvm-dis timed out after 30 seconds`。
- 当前 capture status 也出现不协调信号：`supportsGPUTrace=true` 但 `supportsDeveloperTools=false`，同时 queue discovery 已安装、tracked queue 已存在，说明 capture 基础设施并未完全失效，但导出链路和开发者工具链路并不处于理想状态。
- 当前 fresh run 中，直接把 `.gputrace` 输出到工作区 `build/` 会触发权限拒绝；改为输出到 `~/Library/Containers/io.playcover.PlayCover/gpuTraces/` 后，`device` 与 `scope` 两种 capture target 都能成功开始并落盘，因此“截帧命令本身彻底失效”不是当前第一主因。
- 当前两份 fresh trace（`live-caseE-device.gputrace` / `live-caseE-scope.gputrace`）都能被 `Scripts/check_gputrace_sources.py` 解析，但都表现出大量 index 引用缺失；同时，已知好的 `capture_20260404_roadE_e006c3_final.gputrace` 也存在类似的“自动脚本覆盖率不高”现象，因此当前脚本只能证明“trace 已落盘且结构可解析”，不能单独证明“Xcode 打不开就是当前版本新退化”。
- 当前代码与提交区间分析已经把嫌疑范围显著收窄到 `PlayTools` runtime replacement 主链，而不是 `PlayCoverMCP` capture tool 自身：重点集中在 `LibrarySourceInjectionSwizzles.swift`、`SharedCompilePlanner.swift`、`IRToMSLConverter*` 与其相关提交族。
- 当前 `LibrarySourceInjectionSwizzles.swift` 里的 aggregate replacement 仍采用“同名函数保留首个模块、跳过后续重复”的策略；这对 Unity 类多 variant shader 是高风险点，因为它可能不 crash，但会把 live 渲染 silently 带偏。
- 当前 `PlayCover.swift` 仍采用“先 preload capture for source attribution，再安装 library injection hook”的顺序；结合当前 live 诊断，这条顺序关系依然是高优先级怀疑对象，因为它直接耦合了 capture、replacement 与 hook 生效时机。
- 当前 `SharedCompilePlanner` 已经是 replacement 编译姿态的一等决策入口；因此在 `b1b91553` 之后，即使 converter 语义不变，compile posture 漂移也足以让 runtime replacement 生成“可编译但不等价”的 shader。
- 当前默认下一步，不再扩散到别的 app 或更重 GUI 观察，而是回到“当前最高价值主因”上：优先确认 `Session not registered` 到底是 bridge 生命周期时序问题，还是 replacement 线程在 host 尚未完成 registration 就开始调用 host bridge 的设计缺口。

## 当前默认流程

### Step 1：先从结构化报告选下一个 case

默认优先级：

1. **先看会直接破坏 replacement 主链的 issue**
2. 优先选择：
   - 能在 fresh live 中稳定复现的
   - 能在 `runtime_launch_diagnostics_summary.py` / capture status / trace 检查中留下结构化证据的
   - 能映射到同一类 host bridge / replacement / compile posture / converter 机制的
   - 有希望通过一处实现改动同时改善多个 live 症状的
3. 当前不优先：
   - 只能靠纯肉眼主观判断、缺少结构化佐证的渲染问题
   - 仍然需要人工登录、长时间挂机或复杂交互后才可能浮现的问题

推荐输入：

- `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit <n>` 的输出
- `playcover_get_capture_status` 输出
- `Scripts/check_gputrace_sources.py` 的检查结果
- `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.papegames.lysk/launch-events.jsonl`
- `~/Library/Containers/io.playcover.PlayCover/gpuTraces/*.gputrace`
- `build/` 下与当前 live run 对应的辅助产物与脚本输出

### Step 2：先做 case 分析，再决定是否改实现

每个 issue 至少回答下面几个问题：

- 差异是发生在：
  - host bridge registration / session lifecycle
  - `llvm-dis` / host-side disassemble 超时
  - replacement aggregate / compile / load
  - capture manager / queue discovery / trace export
  - live render 语义或 shader variant 选择
  - compile posture / planner decision / metadata
- 这是“观测口径问题”还是“更像真实 runtime 缺口”
- 这个差异更像来自：
  - bridge 生命周期与并发时序
  - emitted MSL / aggregate source 组织方式
  - metadata / module grouping 建模不足
  - compile posture / planner decision
  - compare / trace 检查脚本口径不对称
- 当前结构化证据是否已经回答了：
  - session 是否真实处于 registered / ready
  - host bridge 异常是否发生在 registration 之前、期间或之后
  - `llvm-dis` timeout 是否具备稳定命中的 cacheKey / moduleKey
  - trace 是否“落盘但内容质量差”，还是“根本无法导出”
- 若问题属于 aggregate / 多模块形态，`LibrarySourceInjectionSwizzles.swift` 当前的聚合、去重、compile plan 与 dump 逻辑是否已经给出更贴近 runtime 的结论
- 如果修复，应该改哪一层最合适：
  - host bridge listener / registration contract
  - `LibrarySourceInjectionSwizzles.swift`
  - `SharedCompilePlanner.swift`
  - `IRToMSLConverter*`
  - trace 检查脚本或导出路径管理

- **必须严格优先尝试修改真正负责 runtime 生命周期、replacement 组织或 compile decision 的实现层。** 只有当反复验证后确认实现层没有问题，才考虑优先改 trace 检查口径或观测脚本。

若这一步还没有明确判断，**不要急着改实现**。

### Step 3：只做最小实现改动

一旦判断某类差异确实值得修，默认策略是：

- 只修一个清晰问题
- 只引入一个清晰机制
- 尽量保持 diff 小、影响面可控

例如：

- host bridge registration 前后的调用时序收紧
- replacement 聚合 / 去重策略的一处明确修正
- planner 中一条明确的 compile posture / timeout / fallback 规则
- capture 输出路径或导出契约的一项明确修补

禁止一次混入多条彼此无关的修正。

### Step 4：每次实现后都要做两层验证

#### 4.1 单 case 验证

目的：先确认本轮改动确实命中了目标 live 异常。

默认动作：

- 对 `恋与深空` 执行一轮 fresh launch + create session
- 读取同轮 `runtime_launch_diagnostics_summary.py`、capture status、必要的 trace 检查输出
- 若问题涉及 replacement / aggregate / compile posture，再补读对应 dump、`compile-summary`、日志片段或 host-side产物

要求回答：

- 原来的那条异常是否消失 / 降级
- runtime 生命周期是否已经对齐
- 是否引入新的更坏异常

#### 4.2 full-batch 验证

目的：确认这不是单次偶然改善，而是对当前主线问题有稳定收益。

当前默认要看两条 live 复跑：

- `恋与深空` 当前问题态 fresh launch
- 至少一种 capture target 的 trace 落盘与结构化检查

必须回答：

- `Session not registered` 是否减少或消失
- `llvm-dis timeout` 是否减少或消失
- capture 是否仍能正常开始并落盘
- 是否出现新的 startup / bridge / replacement 回归

### Step 5：把结果写回控制面

每次任务结束后，必须把下面内容回写到文档：

- 当前分析的是哪一类 live issue
- 该类 issue 的当前结论是什么
- 是否已经落到实现改动
- single-issue 与 live 复跑的关键证据是什么
- 若涉及 compile posture / aggregate / bridge，结构化报告给出的结论是什么
- 下一步最值得继续分析的 issue 是什么

## TODO

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `LEF-001` 建立 live error 修复主线与默认证据链 | DONE | 已完成 `恋与深空` 当前问题态的 fresh live 路径梳理，并把默认控制面切换到 live error 修复主线 | 本文档 |
| `LEF-002` 验证当前问题态是否仍可稳定 fresh 复现 | DONE | 已确认当前 `HEAD` 下 app 可启动、session 可 ready，且 live 结构化证据可稳定产生 | 本文档 |
| `LEF-003` 分离 capture 写路径问题与 trace 内容问题 | DONE | 已确认写到工作区 `build/` 会触发权限拒绝，而写到 `~/Library/Containers/io.playcover.PlayCover/gpuTraces/` 后可成功开始 capture 与落盘 | 本文档 |
| `LEF-004` 建立 trace 自动检查与已知好版本对照基线 | DONE | 已用同一脚本检查 current fresh trace 与已知好 trace，确认脚本可证明“可落盘可解析”，但单靠覆盖率不足以证明当前版本比好版本更坏 | 本文档 / `Scripts/check_gputrace_sources.py` |
| `LEF-005` 确认当前最高优先级 issue 所在层级 | DONE | 已把当前首要嫌疑收敛到 `PlayTools` runtime replacement 主链，而不是 `PlayCoverMCP` capture tool 自身 | 本文档 |
| `LEF-006` 分析 `Session not registered` 的 bridge 生命周期主因 | DOING | 需要把 fresh live 中的 registration 时序、replacement 调用时机与 host bridge 调用点对齐，明确它是 registration race、channel 丢失还是 replacement 过早触发 | 本文档 |
| `LEF-007` 评估 `llvm-dis timeout` 是否属于同一主因家族 | TODO | 明确 timeout 是由 bridge 堵塞/未注册派生，还是独立的 host-side disassemble 性能问题；若是独立问题，需要再拆子任务 | 本文档 |
| `LEF-008` 评估 aggregate 去重与 shader variant 选择是否导致 live 渲染异常 | TODO | 需要确认 `buildAggregateReplacementSource()` 的“保留首个模块”策略是否与当前异常 case 直接相关，并判断是否值得作为下一轮主任务 | 本文档 |
| `LEF-009` 对 `b1b91553..HEAD` 的高风险 runtime replacement 改动做精确 hunk 级收敛 | TODO | 至少完成 `LibrarySourceInjectionSwizzles.swift`、`SharedCompilePlanner.swift`、`IRToMSLConverter*` 的高风险差异列表，并把下一轮最小修复点缩到单个 issue | 本文档 |

## 任务执行规则

### 一次只做一个任务

- 每个 agent / 每次会话默认只完成一个当前最高优先级任务
- 若任务过大，必须先拆出子任务，再只完成其中一个
- 不允许同时并行推进多个主线 issue

### 当前选题优先级

从高到低：

1. **会直接破坏 replacement 主链或 bridge 生命周期的 issue**
2. **已经在 live 结构化证据中稳定出现、且能映射到明确代码层的 issue**
3. **单个 issue 虽复杂，但明显指向 runtime hook / aggregate / compile posture 逻辑的问题**
4. **trace 检查或观测口径问题**（如果它能明显减少误判，也值得做）
5. **只能靠长期人工观察才能推进的问题**（当前不纳入默认选题范围）

### 拆任务的规则

若当前任务无法在一次工作中闭环，必须拆开。拆任务时沿下面方式切：

- 按异常类别切：`bridge registration` / `llvm-dis timeout` / `replacement compile` / `capture export` / `render anomaly`
- 按机制切：bridge 生命周期 / aggregate 组织 / planner compile posture / converter emission / trace 口径
- 按样本族切：优先切出“重复模式明显”的 cacheKey / moduleKey / symptom family

不要按含糊目标切，例如：

- “继续研究 live 错误”
- “进一步优化截帧和渲染”

## 当前默认验证

### 改实现前

按改动类型选择最低要求：

- **纯文档 / 方法规范 / 路线整理改动**：更新文档并自检跨文档口径一致性，无需额外构建
- **Python 脚本 / trace 检查 / runtime 辅助脚本改动**：

```bash
python3 Scripts/check_gputrace_sources.py <gputrace>
python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3
```

- **Swift runtime / PlayTools / host bridge / compile decision 相关改动**：

```bash
./BuildScripts/build_and_install.sh
```

  若同时涉及 trace 检查、launch 诊断或脚本口径，继续补跑对应 Python 验证。

- **改动了工程文件**：

```bash
./BuildScripts/lint_pbxproj.sh
```

### 单 case 验证

默认入口是：

```bash
python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3
```

单 case 默认应读取同轮产物：

- fresh live run 对应的 diagnostics summary
- capture status
- 必要的 `.gputrace` 结构化检查结果
- 若存在 replacement dump / host-side 产物，则读取对应证据

若问题涉及 aggregate / 多模块 / compile posture / runtime-like compile，默认补充：

```bash
python3 Scripts/check_gputrace_sources.py <trace.gputrace>
python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3
```

补充约束：

- 纯 GUI 目测只适合做补充，不替代默认单 case 入口
- 若要比对 current / known-good trace，优先使用同一脚本、同一口径、同一 bundle 目录

### full-batch 验证

只要本轮改动影响 host bridge、runtime registration、replacement aggregate、IR 反汇编、MSL 重编译、capture 初始化、queue discovery、trace 导出路径或其它可能改变当前 live 结构化证据分布的逻辑，收尾时默认执行：

```bash
./BuildScripts/build_and_install.sh
python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 3
python3 Scripts/check_gputrace_sources.py <latest-trace.gputrace>
```

当前最重要的不是“有没有跑”，而是：

- `Session not registered` 是否减少
- `llvm-dis timeout` 是否减少
- replacement exception / compile failure 的模式是否收敛
- capture 是否仍可开始并落盘
- 有没有新增 startup / bridge / render 回归

## 当前完成判定

当前每个任务的完成判定统一为：

1. 已选出一个明确 case / 异常模式
2. 已完成足够深入的 live 结构化证据分析
3. 已判断它更像观测问题还是实现问题
4. 若值得修，已完成一次最小实现修改
5. 已完成单 case 验证
6. 已完成 full-batch 验证
7. 已明确记录异常数量变化与下一步建议

只有满足这 7 条，当前任务才算真正闭环。

## 当前非默认验证

下面这些事项当前不写成默认 TODO 或完工 gate：

- 需要人工登录、人工推进大量 UI 流程的验证
- 长时间占机的连续 render diff 观察
- 多 app 并行 smoke 扩散验证
- 纯 Xcode 手工点选分析作为唯一证据来源
- 任何缺少结构化记录、只能靠回忆描述的操作

只有当某个具体 issue 的低层结构化证据已经不足以回答问题，或用户明确要求进入更高层验证时，才再考虑升级。

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

- **app 能启动不等于 replacement 主链健康。** 当前默认应以 `runtime_launch_diagnostics_summary.py + capture status + trace 结构化检查` 这组证据为主，而不是只看 session 是否 ready。
- **trace 能落盘不等于 trace 对 Xcode 一定健康。** 当前 `check_gputrace_sources.py` 只能证明“落盘且可解析到一定程度”，不能单独替代 Xcode 打开结果。
- **优先分离“写路径问题”和“内容问题”。** 若先把输出写到错误路径，得到的失败结论会污染对 capture/export 真正状态的判断。
- **优先读结构化诊断，不要优先翻大日志。** 报告用于回答“当前哪一层先坏”，日志只在报告仍不足以解释时才作为补充证据。
- **构建、重建、安装统一走 `BuildScripts/`。** 不要手写 `xcodebuild`、手工复制产物，也不要把人工安装步骤写回默认流程。
- **live 主线不要轻易扩 app。** 当一个 app 已经能稳定暴露目标异常时，继续换 app 往往只会放大变量，不会更快靠近根因。
- **`supportsGPUTrace=true` 与 `supportsDeveloperTools=false` 并存时，不要过早下“capture 完全坏了”的结论。** 这更像导出链路与开发者工具链路未完全一致，而不是 capture manager 不存在。
- **`Session not registered` 是一等证据。** 它直接指向 host bridge 生命周期或调用时序问题，应先于更主观的渲染表现处理。
- **`llvm-dis timeout` 不一定是独立问题。** 若它和 registration / bridge 异常同轮出现，要先排除 host-side 阻塞或未注册派生故障，再决定是否拆成独立性能问题。
- **aggregate 去重策略可能导致“不崩但画错”。** 当多模块 metallib 中存在同名函数 variant 时，“保留首个模块、跳过后续重复”是 live 渲染高风险点。
- **capture preload 顺序是高风险耦合面。** 当前 capture preload 与 library injection hook 具有显式顺序依赖，任何时序漂移都可能同时污染 capture attribution 与 replacement 主链。
- **主文档不要直接堆原始命令流水账。** 重复执行所需的是默认流程、优先级、完成判定与关键证据，而不是一次性的长日志。

## 参考信息

- **已知好版本只能作为对照锚点，不应替代当前 live 复现。** `b1b91553` 的价值是缩小 diff 与判断嫌疑范围，不是跳过当前问题态验证。
- **当前自动脚本口径对 good/current trace 都偏保守。** 若未来需要证明“trace 内容已恢复到 Xcode 可读”，应补一条更贴近 Xcode bundle 健康度的自动化检查，而不是继续只看当前覆盖率统计。
- **未提交的 runtime / PlayTools 改动会污染 live 复跑结果。** 跑 live 复现前必须确认当前构建与安装的产物就是预期版本，否则 bridge / replacement / capture 行为无法和文档结论对应。

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“当前 live 证据链覆盖到哪里、还差什么”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；live error 修复的分层策略与止损边界参考）
- `03-L1-Bridge-And-Replacement.md`（**建议读取**；host bridge / replacement 主链入口与脚本参考）
- `04-L2-Capture-And-GPUTrace.md`（工作参考；capture / `.gputrace` / 导出口径说明）
- `05-L3-Render-Symptom-Validation.md`（资料参考，当前**不纳入默认规划**）
- `06-L4-真实场景验证.md`（资料参考；仅在需要更重 live / Xcode / render-diff 验证时再读）
- `07-历史基线与回归归档.md`（历史归档与已知好版本参考，**不必须读取**）
- `08-当前代表问题与Gate参考.md`（维护当前问题族、gate 与脚本口径细节时再读）

### 当前重点分析目录

- `RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`
- `RoadE-HookMakeLibraryWithSrc/E-006e-QQSpeedCaptureReplacementStartupCrash.md`
- `RoadE-HookMakeLibraryWithSrc/E-006d-GenshinRenderingNondeterminism.md`
- `SemanticsValidation/00-Dashboard.md`
- `LocalDocs/MCPFinal/Problems/RenderCapture/Tasks/RC-009-延迟注入方案.md`
- `LocalDocs/MCPFinal/Problems/RenderCapture/Tasks/RC-014-启动期注入兼容性修复.md`
- `LocalDocs/MCPFinal/Problems/RenderCapture/Tasks/RC-015-原神Metal代理调查.md`

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/SharedCompilePlanner.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift`
- `Scripts/runtime_launch_diagnostics_summary.py`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- `BuildScripts/build_and_install.sh`
