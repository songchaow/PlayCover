## E-006d：原神同一界面重复启动时的随机渲染异常调查

## 状态：TODO

> ⚠️ **本文档是 `E-006d` 当前主线的详细执行说明。** `00-Dashboard.md` 负责记录当前最高优先级、最新基线与全局 TODO；本文档只展开 `E-006d` 自身的判断顺序、交付标准与技术备注。

## 当前已完成子项

- **E-006d1 ~ E-006d7（✅ DONE）** 已补齐当前主线所需的离线 / live 对照工具链：输入 diff、聚合源码 diff、replacement 开关、run 快照、`.gputrace` 固化、run matrix 汇总，以及 trace-level 归因索引都已落地。
- 这些子项的共同作用是：把 `E-006d` 当前最关键的问题从“缺工具、缺证据”前移为“已有工具，但还缺一组足够稳定的 off/on 多轮 run 结论”。
- 因此 `E-006d` 现在的主要工作，不是继续增加新基础设施，而是用现有工具把结论收敛到更窄的根因分支。

## 现象

- 当前现象：用 PlayCover 打开原神，按既有 Road E 流程会执行 `metal IR 提取 -> 反编译为 MSL -> makeLibrary(source:) 重编译替换`；即使停留在**同一个界面**，多次启动后画面表现也会不完全一样
- 已知边界：当前观察到的是**mesh 没有变化**，但局部渲染结果会随机异常；这说明异常不一定来自几何体本身，但也**还不能直接实锤是 shader 改坏**
- 新增判断：由于原神是延迟管线，base pass 对比看起来也可能类似，因此异常也可能出现在后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置，而不一定只在 `IR -> MSL -> makeLibrary(source:)` 这条链路
- 当前最保守结论：在现阶段，最稳定的复现口径仍是比较**进行了反编译/重编译替换**与**完全不做替换**两种运行方式；但根据当前 `off1/off2/on1/on2` 四轮快照，**跨模式稳定不同尚未被 corpus / trace 级证据坐实**，因此它现在是正确的比较基线，而不是已经完成证明的结论

## 目标

`E-006d` 的目标不是继续证明“源码可见”或“compile 通过”，而是回答下面四个问题：

1. **“替换”与“不替换”时，最终效果差异是否稳定存在？**
2. **同一界面重复启动时，进入 shader 链路的输入是否相同？**
3. **若输入相同，生成出的单模块 MSL / 聚合 MSL / compile 结果是否完全一致？**
4. **若生成结果也相同，运行时是否稳定使用了替换后的 library，还是问题出在更后续的着色 / 后处理 / render pipeline 阶段？**

## 当前最该做的事

- `E-006d8` 的第一轮 run matrix 已经完成 first-pass：`off1/off2/on1/on2` 足够证明“同模式输入稳定”，也足够说明当前**不该**继续机械补 run。
- 下一步应优先把 blocker 收敛到两个更窄的问题：1）`replacement=on` 时为什么始终没有 aggregate / 成功 replacement 证据；2）`create_session -> get_capture_status / capture_metal_frame` 为什么会在 `ready` 后仍超时掉线。
- 若本轮还拿不到完整 live 证据，采集动作必须继续固定为统一入口：使用 `Scripts/e006d_matrix_runner.py` 的 `prepare-run` / `finalize-run` / `analyze` 薄封装，固定 `replacement-<mode>-runN` 标签与分析入口，避免把模式、标签、快照目录或 compare 输入串错。
- 本轮完成标准不是“继续加脚本”或“继续补文档”，而是至少把当前问题明确收敛到以下之一：
  1. 输入集合不稳定
  2. 输入稳定但输出/聚合结果不稳定
  3. 输出稳定但替换实际命中不稳定
  4. 替换链路稳定，但差异落在更后续 render pipeline / post-processing
- **新增日常验证方法时，默认只接受 agent 可通过脚本或命令独立完成的方案。** 若某一步需要人工登录、摆场景、点按钮或其它交互，它不能成为当前阶段默认 gate；只有在 blocker 明确依赖该人工条件、且已得到用户确认后，才可作为例外保留。
- 只有在这一层结论明确后，下一轮才应该决定是否回到 `IRToMSLConverter`、replacement runtime，还是更后续的渲染链路。

## 最新执行结果（2026-04-05，本轮）

- 已通过统一入口把 `E-006d8` 的 run 矩阵扩到四轮：
  - `build/e006d-run-snapshots/replacement-off-run1/com.miHoYo.Yuanshen`
  - `build/e006d-run-snapshots/replacement-off-run2/com.miHoYo.Yuanshen`
  - `build/e006d-run-snapshots/replacement-on-run1/com.miHoYo.Yuanshen`
  - `build/e006d-run-snapshots/replacement-on-run2/com.miHoYo.Yuanshen`
- `replacement-off-run1` 仍是当前唯一带 `.gputrace` 的快照，`snapshot.meta.json` 摘要为：`replacementEnabled=false`、`gputraceMSL=2`、`modules=91`、`diagnostics=18`
- `replacement-off-run2` 在同样 live 条件下两次 `create_session` 都直接超时；因此本轮只保留了**无 `.gputrace`** 的快照，但同样固化了 `manifest.jsonl + modules/ + diagnostics + app settings`，摘要为：`replacementEnabled=false`、`manifestLines=1427`、`modules=91`、`replacements=0`、`diagnostics=18`
- `replacement-on-run1` 与 `replacement-on-run2` 都没有拿到 `.gputrace`，且两轮摘要都显示 `replacements=0`；其中 `replacement-on-run2` 一度成功拿到 `session=ready`，但随后 `get_capture_status` bridge timeout，session 在真正截帧前消失，说明当前 live blocker 已经从“单纯拿不到 session”收敛为“session 即使 ready 也不稳定、并且 replacement 成功路径始终没有落盘 aggregate event”
- 基于四轮快照重新跑出的 `build/e006d-run-matrix.json` 目前给出：
  - `groups.off.pairSummary.allPairsInputStable=true`
  - `groups.on.pairSummary.allPairsInputStable=true`
  - `crossMode.offVsOnPairSummary.allPairsDifferent=false`
  - `crossMode.offVsOnPairSummary.differentPairCount=2`
  - `crossMode.offVsOnPairSummary.allPairsReplacementStable=false`
- 对应的 `build/e006d-run-diff-off1-vs-off2.json`、`build/e006d-run-diff-on1-vs-on2.json` 与 `build/e006d-run-diff-off2-vs-on2.json` 都显示：共享 `moduleKey=91`、`onlyInRunA=0`、`onlyInRunB=0`；脚本报告中的 `sharedModulesWithDifferencesCount` 主要来自 `module.meta.json` / `captureCount` 这类 bookkeeping 漂移，而不是 `module.bc` / `module.ll` / `module.generated.metal` 的语义差异
- `build/e006d-run-diff-off2-vs-on2.json` 还进一步表明：在排除 `.gputrace` 缺失带来的快照差异后，当前跨模式可见的语义级 snapshot 差异只剩 `replacementMode.enabled` 本身；与此同时，两侧都没有可比较的 replacement aggregate（`hasComparableReplacement=false`）
- 本轮已补充 runtime replacement 尝试级证据：`LibrarySourceInjectionSwizzles` 会把每次替换尝试都记为 `manifest.jsonl` 中的 `event=replacement_attempt`，并写出 `outcome` / `reasonCode` / `moduleKeys` / `invalidModuleCount` / `dumpPath`。`Scripts/compare_capture_runs.py` 现会额外输出 latest replacement attempt 对比；`Scripts/analyze_capture_run_matrix.py` 也会额外汇总 `allPairsReplacementAttemptStable`，并把 **`replacementEnabled=true` 但 `replacement_attempt=0`** 单独标成 blocker。
- 基于这轮对现有快照的重跑结果，`replacement-on-run1` 与 `replacement-on-run2` 当前都被明确标记为：`latest replacement attempt unavailable for: runA, runB` 且 `replacement attempts missing while replacementEnabled=true for: runA, runB`；矩阵层则对应 `groups.on.pairSummary.allPairsReplacementAttemptPresentWhenEnabled=false` 与 `missingAttemptWhileEnabledPairs=1`。这说明当前 on-run 证据仍停留在“enabled 但没有 attempt 级落盘”，还**不能**把 blocker收敛成某个固定 `reasonCode`。
- 这意味着当前已可稳定排除“captured corpus 输入集合漂移”与“单模块输出本体随机变化”两条分支；但这里排除的仍只是 **captured corpus / 单模块 artifact 层面的 drift**，还**没有**排除 runtime replacement-hit 是否稳定、以及更后续 live render-path / trace 行为是否稳定。现阶段最值得优先排查的 blocker 已进一步收敛为：**先通过标准 `BuildScripts/build_and_install.sh` 恢复一轮 fresh `replacement=on` run，使其至少出现 `replacement_attempt` 级证据**，以及 **live capture/session 为什么会在 ready 后超时掉线**。在拿到至少一轮 `replacement=on` 且带 `.gputrace` + aggregate source 的稳定样本前，还不能继续把结论往 shader lowering 或更后续 pipeline 方向过早定性。

## 优先排查顺序

### 1. 先固定复现条件

- 尽量固定 app 版本、停留界面、画质设置、注入步骤和启动顺序
- 同一条件下至少做 `2~3` 轮重复启动
- 增加一组**完全不做替换**的对照运行，作为最低风险基线
- 对当前原神链路，默认可把“启动后数十秒自动停在登录界面”视为稳定复现面；因此 `E-006d8` 当前轮次的 live 启动、等待、截帧、快照固化都默认可由 agent 独立完成，不要求人工登录、选场景或手动停到指定位置
- 只有当某个 blocker 明确依赖登录后场景、账号态或其它人工交互条件时，才把“人工把界面摆到指定位置”升级为本轮前置条件；若出现这种情况，必须在对应子任务文档中单独写明
- 当前可直接使用：

```bash
python3 Scripts/set_shader_replacement_mode.py \
  --bundle-id com.miHoYo.Yuanshen \
  --mode off
```

- 更推荐先用统一 runner 准备该轮：

```bash
python3 Scripts/e006d_matrix_runner.py prepare-run \
  --bundle-id com.miHoYo.Yuanshen \
  --mode off \
  --run-index 1
```

- 切完开关并完成该轮 live 后，立刻固化当前 run：

```bash
python3 Scripts/e006d_matrix_runner.py finalize-run \
  --bundle-id com.miHoYo.Yuanshen \
  --mode off \
  --run-index 1 \
  --gputrace /path/to/replacement-off-run1.gputrace \
  --print-compare-path
```

- 如需直接调用底层脚本，原命令仍保持不变：

```bash
python3 Scripts/snapshot_capture_run.py \
  --bundle-id com.miHoYo.Yuanshen \
  --label replacement-off-run1 \
  --gputrace /path/to/replacement-off-run1.gputrace \
  --print-compare-path
```

- 对照结束后再切回：

```bash
python3 Scripts/set_shader_replacement_mode.py \
  --bundle-id com.miHoYo.Yuanshen \
  --mode on
```

- 对应的 replacement=on run 同样保留：

```bash
python3 Scripts/snapshot_capture_run.py \
  --bundle-id com.miHoYo.Yuanshen \
  --label replacement-on-run1 \
  --gputrace /path/to/replacement-on-run1.gputrace \
  --print-compare-path
```

- 每轮都保存：
  - `manifest.jsonl` 增量
  - `ShaderCorpus/` 新增模块目录
  - `ShaderSourceDiagnostics/` 新文件
  - 单模块 `module.bc` / `module.ll` / `module.generated.metal`
  - 聚合 MSL
  - 对应 `.gputrace`
- 对当前主线，默认要求 agent 把以上 live 证据全部采齐并固化；人工只保留到最后用 Xcode 打开 `.gputrace` 做可视确认
- 当 `replacement=off` 与 `replacement=on` 各自都已积累 `2~3` 轮快照后，可直接批量汇总：

```bash
python3 Scripts/e006d_matrix_runner.py analyze \
  --bundle-id com.miHoYo.Yuanshen \
  --output build/e006d-run-matrix.json
```

- 如需直接调用底层汇总脚本，原命令仍保持不变：

```bash
python3 Scripts/analyze_capture_run_matrix.py \
  --runs-root build/e006d-run-snapshots \
  --bundle-id com.miHoYo.Yuanshen \
  --output build/e006d-run-matrix.json
```

- 重点先看：
  - `groups.off.pairSummary.allPairsInputStable`
  - `groups.on.pairSummary.allPairsInputStable`
  - `crossMode.offVsOnPairSummary.allPairsDifferent`
- 只有当“同模式稳定、跨模式稳定不同”成立后，才说明已经形成可复用的 `E-006d` 稳定对照样本，可继续往更细的 stage / pipeline 归因下钻。

### 2. 先确认“替换 vs 不替换”差异是否稳定

- 在相同界面、相同设置下，对比：
  - 正常执行替换链路
  - 完全不做替换
- 若两者最终效果稳定不同，说明问题至少与“替换开启后引入的变化”有关；但这仍不足以直接证明根因就是某一段 shader lowering
- 若差异并不稳定，则需先回到更基础的 live 条件控制，避免把运行条件波动误判为链路问题

### 3. 再比较“输入是否相同”

- 比较每轮新增或命中的 `moduleKey`
- 比较 `functionNames` / `functionTypes`
- 比较 `module.bc` / `module.ll` 哈希
- 若这里已经不同，先不要直接归咎于 converter；应继续追踪是 app 本身输入变了，还是拦截 / 导出路径在不同轮次拿到了不同 metallib/module
- 推荐先保存每轮 `manifest.jsonl` 与 `modules/` 快照后，运行：

```bash
python3 Scripts/compare_capture_runs.py \
  --run-a build/e006d-run-snapshots/replacement-off-run1/com.miHoYo.Yuanshen \
  --run-b build/e006d-run-snapshots/replacement-on-run1/com.miHoYo.Yuanshen \
  --output build/e006d-run-diff.json
```

- 若报告中的 `onlyInRunA` / `onlyInRunB` 非空，说明同一界面重复启动时，至少进入 corpus 的 `moduleKey` 集合还不稳定
- 若两轮都已有 `event=replacement`，脚本还会继续比较最新一次成功替换的聚合产物；若 `latestReplacementComparison.differences` 非空，则说明即使共享 `moduleKey` 看起来稳定，最终聚合替换源码仍可能发生漂移

### 4. 再比较“输出是否相同”

- 对相同 `moduleKey` 比较：
  - `module.generated.metal`
  - 聚合后的 MSL 源码
  - `xcrun metal` / `makeLibrary(source:)` 编译结果
- 若同一 `.ll` 产生不同 `.metal`，优先排查：
  - `IRToMSLConverter` 是否存在依赖遍历顺序的发射逻辑
  - 聚合阶段是否存在函数顺序 / 去重 / struct emission 顺序不稳定
  - 日志 / diagnostics / baseline 是否把同一模块的不同版本混在一起
- `Scripts/compare_capture_runs.py` 会对共享 `moduleKey` 直接比较 `.bc/.ll/.metal/.meta` 的 sha256；如果 `module.ll` 一致而 `module.generated.metal` 不一致，可优先怀疑 converter / 聚合稳定性，而不是先回到 live 侧猜测
- `E-006d2` 后，成功替换的 aggregate source 也会落盘到 `ShaderCorpus/.../replacements/`；如果共享 `moduleKey` 与单模块 `.metal` 都一致，但 `aggregate.generated.metal` 的 sha256 仍不同，应优先怀疑聚合顺序、重名去重结果，或 runtime 成功路径拿到的 module 组合不同
- 若两轮都含 `snapshot.meta.json` 且通过 `--gputrace` 固化了最终截帧，`Scripts/compare_capture_runs.py` 还会补充 `snapshotComparison`，直接比较 replacement 开关状态、`validMSLFiles`、可见 MSL hash 集合与 `indexHashReferences`，先回答“最终 trace 层证据是否一致”。
- `E-006d7` 后，若 run 快照含 `.gputrace`，还可直接查看 `gputrace-attribution-index.json`：它会按源码内容指纹把可见 MSL hash 归因到 `module.generated.metal` 与 `aggregate.generated.metal`，用于回答“最终 trace 里新增/消失的源码究竟来自哪个 moduleKey / replacement 目录”。若两轮快照都具备该索引，`Scripts/compare_capture_runs.py` 也会继续比较 `attributedVisibleMSLHashes`、`attributedModuleKeys`、`attributedReplacementDirectories` 与 `visibleMSLContentSHA256`，把最终 trace 差异直接拉回 corpus / replacement 侧证据。

### 5. 最后比较“替换与实际使用是否相同”

- 确认每轮 `attemptLibraryReplacement(...)` 是否都进入成功路径
- 对照是否出现 silent fallback、部分模块跳过、聚合失败后回退原始 library
- 结合 `.gputrace` 确认最终被 draw call 使用的 library 是否稳定来自 PlayTools 注入源码
- 若 base pass 对比看起来接近，则继续检查更后续的着色 / 后处理 / render pipeline 行为，不要在这一步过早停在“shader 本身没问题”或“shader 一定有问题”的二选一

## 当前工作假设

- **假设 A：输入并不稳定**
  - 同一界面看似相同，但真实命中的 metallib/module 集合并不完全一致
- **假设 B：输入相同，但 `IR -> MSL` 结果不稳定**
  - 同一 `.ll` 在不同运行中生成了不同的 MSL 或聚合顺序不同
- **假设 C：源码生成稳定，但 runtime 替换或 pipeline 实际使用不稳定**
  - 例如聚合后部分替换、静默 fallback、或最终 draw call 并未稳定使用替换后的 library
- **假设 D：源码与替换都稳定，但问题出在更后续的着色 / 后处理 / render pipeline 阶段**
  - 这能解释“base pass 看起来类似，但最终画面仍然不一样”
- **假设 E：源码与替换都稳定，但当前 MSL 只是“可编译”而非“语义等价”**
  - 这会表现为 `compile green`、`.gputrace` 也可见源码，但真实渲染结果仍然漂移或局部错误

## 完成标准

- 至少形成一组**可重复复现**的对照样本
- 至少形成一组**替换 vs 不替换**的稳定对照样本
- 至少形成一组**agent 独立完成**的 live 启动 / 等待 / 截帧 / 快照固化样本；不要再把“人工先把游戏停到某个界面”当作 `E-006d8` 当前阶段的默认前提
- 能明确将问题归到以下某一层：
  - 替换开启后引入的稳定差异（但根因层级未定）
  - 输入差异
  - `IRToMSLConverter` 非确定性 / 错误 lowering
  - 聚合 MSL / replacement 链路问题
  - runtime 实际使用阶段问题
  - 更后续的着色 / 后处理 / render pipeline 顺序或配置问题
- 若定位到具体 blocker，需要把它转化为可离线 replay / compile / diff 的样本或规则，而不是继续只停留在 live 观察层面

## 当前建议执行顺序

1. 固定 live 条件；对当前原神基线，直接以“启动后数十秒自动停在登录界面”为统一复现面，由 agent 独立完成每轮启动与等待；每轮结束后立即用 `Scripts/snapshot_capture_run.py` 或 `Scripts/e006d_matrix_runner.py finalize-run` 固化 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings 快照
2. 当前已完成 `replacement-off-run1/off-run2/on-run1/on-run2`；“同模式输入稳定”已经成立，因此下一步不再是继续机械补 run，而是优先恢复**至少一轮 replacement=on 的稳定 `.gputrace` + aggregate source 样本**
3. 把 `replacement=on` 的 live 异常单独视为 blocker：先看最新 run 是否至少出现 `event=replacement_attempt`。若像当前 `on1/on2` 一样已经被脚本明确标成 **`replacementEnabled=true` 但 `replacement_attempt` 缺失**，则下一步应先做一次标准 `BuildScripts/build_and_install.sh` 后的 fresh on-run，确认是部署/命中问题；只有在 attempt 级证据重新出现后，才继续下钻 `outcome` / `reasonCode`。与此同时，继续核对 runtime session 为什么会在 `ready` 之后于 `get_capture_status` / `capture_metal_frame` 前后超时掉线
4. `Scripts/analyze_capture_run_matrix.py` 的第一层结论已更新为：“captured corpus / 单模块 artifact 层面的同模式稳定”成立，但“跨模式稳定不同”**尚未**成立；这意味着当前还不能把最终差异稳定位于 replacement 开关本身
5. `Scripts/compare_capture_runs.py` 的第二层结论也已更新为：共享 `moduleKey` 与单模块 `.bc/.ll/.metal` 本体仍然稳定，当前没有任何一轮 run 落出可比较的 `latestReplacementComparison`
6. 因此下一轮应优先下钻 runtime replacement / live bridge 稳定性，而不是先回到 converter 或更后续的 pass / pipeline；只有在拿到 replacement 成功样本后，后两条分支才值得继续展开

## 从 dashboard 下沉的细粒度技术备注

- **真实 corpus compile 通过不等于 `.gputrace` 源码可见，更不等于真实渲染正确**：这三层验证必须分开
- **延迟管线下，base pass 看起来类似并不能排除后续阶段问题**：若当前观察主要来自最终画面差异，就必须把后处理、着色阶段与 render pipeline 顺序 / 配置一起纳入排查范围
- **“替换 vs 不替换”是当前最低风险的稳定比较基线**：在根因层级未明确前，先确认开启替换后是否稳定引入了最终效果差异，再继续往具体 stage / pass 下钻
- **“替换 vs 不替换”必须有明确控制面**：`E-006d3` 后不要再通过改代码或手改 plist 临时构造“无替换”样本，统一使用 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py`，避免把控制变量本身做脏
- **run 快照要在 live 结束后立即固化**：`E-006d4` 后统一使用 `Scripts/snapshot_capture_run.py` 保留 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings；不要再手工从容器里零散拷目录，否则很容易把 replacement 开关状态与对应 run 搞混
- **若本轮已产出 `.gputrace`，也要与 run 快照一起固化**：`E-006d5` 后优先通过 `Scripts/snapshot_capture_run.py --gputrace /path/to/xxx.gputrace` 一次性保留 trace 与源码覆盖摘要，不要再把 `.gputrace` 单独散落在其它目录，避免后续 run-vs-run diff 时丢失最终可见性证据
- **当前默认不是“人工控场”，而是“agent 自动到登录界面”**：对原神当前阶段，登录界面已经足够作为 `E-006d8` 的稳定对照面；文档里出现“同一界面 / 相同设置”时，默认指这个 agent 可独立到达的界面，除非子任务另行声明更深的人工场景要求
- **成功路径也要落盘聚合产物，才能回答“最终替换源码是否稳定”**：只保留单模块 `.bc/.ll/.metal` 不足以覆盖聚合顺序、重名去重与最终 `makeLibrary(source:)` 输入；`E-006d2` 后应优先比较 `manifest.jsonl` 中最新 `event=replacement` 对应的 aggregate source hash
- **`module.meta.json` 的统计字段要与真实 artifact diff 分开看**：`captureCount`、`sourceCacheKeys`、`generatedMSLBytes`、`llvmIRBytes`、`bitcodeBytes` 这类 bookkeeping 字段会让 `module.meta.json` hash 变化，但不等于 `.bc/.ll/.metal` 本体变化；对 `E-006d8` 的“输入 / 输出是否稳定”判断，必须优先看真实 artifact 与 aggregate source，不能把 metadata 漂移误收敛成 shader 漂移
- **`throw` + 静默 `catch` 回退是 runtime hook 的危险反模式**：会把关键 blocker 隐藏为“看似正常但实际回退原始 library”
- **失败路径导出是闭环的关键一环**：`ShaderSourceDiagnostics/<baseName>_modules/` 让失败样本也能进入离线 replay 主路径；该闭环规则本身见 `E-004-CorpusClosureAndRecapturePolicy.md`
- **更早的 lowering 细节与已收敛 compile blocker 不再由本文档维护**：相关历史实现经验已经沉到 `E-004-MetallibSourceExtraction.md` 与 archive，避免当前主线文档同时承担“执行说明”和“历史修复百科”两种职责

## 与其他文档的关系

- 当前主线 / 优先级 / TODO：`00-Dashboard.md`
- 历史 live blocker 时间线：`00-Dashboard-Archive.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- corpus replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
