## E-006d：原神同一界面重复启动时的随机渲染异常调查

## 状态：TODO

> ⚠️ **本文档是 `E-006d` 当前主线的详细执行说明。** `00-Dashboard.md` 负责记录当前最高优先级、最新基线与全局 TODO；本文档只展开 `E-006d` 自身的判断顺序、交付标准与技术备注。

## 当前已完成子项

- **E-006d1 ~ E-006d7（✅ DONE）** 已补齐当前主线所需的离线 / live 对照工具链：输入 diff、聚合源码 diff、replacement 开关、run 快照、`.gputrace` 固化、run matrix 汇总，以及 trace-level 归因索引都已落地。
- 这些子项的共同作用是：把 `E-006d` 当前最关键的问题从“缺工具、缺证据”前移为“已有 first-pass run matrix，且已能把 blocker 收敛到更窄的 live / replacement 分支”。
- 因此 `E-006d` 现在的主要工作，不是继续增加新基础设施，也不是继续机械补 run，而是用现有工具优先收敛 **session / capture bridge 不稳定** 与 **`llvm-dis` 权限失败只部分命中** 这两条主线。

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

其中第 4 问**不能只停留在“shader 是否被替换”**。如果 corpus / aggregate / trace 证据还不足以稳定解释差异，就必须继续比较 **draw call 数、Render Encoder 结构、Pipeline State 分组、关键 pass summary**，把绘制内容差异作为独立证据层处理。

## 当前最该做的事

- `E-006d8` 的第一轮 run matrix 已经完成 first-pass：`off1/off2/on1/on2/on3/on4/on5/on6` 已足够证明“同模式输入稳定”，也足够说明当前**不该**继续机械补 run。
- 标准 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` + `./BuildScripts/build_and_install.sh` + fresh `replacement-on-run6`，已经把 live blocker 从“fresh 注入后 runtime 可能根本没进入 launch / registration”前移到四条更窄的线：1）**host bridge `Session not registered` 生命周期 / command reachability**；2）**`capture_metal_frame` 自定义 `output_path` 权限失败**；3）**trace 侧合法 MSL 覆盖仍偏低**；4）**绘制内容差异还没有被正式做成结构化 diff**。
- 2026-04-06 随后补了一轮 host 侧 split-brain 修复：`SessionHealthMonitor` 在移除 stale session 后，不再只在 registry 里静默删除，而会同步通过 `RegistrationListener.disconnectSessions(...)` 主动断开对应 runtime 的 registration channel。这样 runtime 若仍持有旧 `sessionId`，会立刻感知连接被 host 关闭并走标准 re-register，而不是继续在 host bridge 命令阶段才暴露为 `Session not registered`。这条修复当前已由 `PlayCoverMCPTests` 集成用例覆盖，但还需要新的 fresh on-run 把 live 证据补齐。
- **绘制内容差异检查现在必须并入 `E-006d8` 主线，不能继续只看 shader / corpus / trace 哈希。** 当前优先对照应是 `replacement-off-run1` vs `replacement-on-run5`：前者是目前最低风险的“未替换 + 带 `.gputrace`”基线，后者是当前唯一稳定拿到 `.gputrace` 的“替换成功”侧代表样本。应至少导出 **Command Buffer 数、Render Encoder 列表、Pipeline State 分组、关键 pass summary**，先回答差异是否已经落在更后续 render pipeline / post-processing。
- 这条线优先复用 `LocalDocs/XCodeOperation/` 现有脚本：`xcode_gpu_ops.py`、`collect_cbs.py`、`collect_re_details.py`。它们已经能自动打开 `.gputrace`、点击 Replay、导出结构化 JSON；但它们依赖 Xcode GUI 环境、Accessibility 权限，以及部分 `cliclick` 操作。因此**在已验证 agent 能独立跑通前，它只能作为重要专项分析分支，不能写成当前默认日常 gate。**
- 若本轮还要继续扩证据，采集动作仍必须固定为统一入口：使用 `Scripts/e006d_matrix_runner.py` 的 `prepare-run` / `finalize-run` / `analyze` 薄封装，固定 `replacement-<mode>-runN` 标签与分析入口，避免把模式、标签、快照目录或 compare 输入串错；其中 `capture_metal_frame` 当前优先走目标 app 容器默认 `Captures/` 输出，再通过 `finalize-run --latest-gputrace` 自动并回 run 快照，避免继续依赖自定义工作区 `output_path`。
- 本轮完成标准不是“继续加脚本”或“继续补文档”，而是至少把当前问题明确收敛到以下之一：
  1. 输入集合不稳定
  2. 输入稳定但输出/聚合结果不稳定
  3. 输出稳定但 replacement / `llvm-dis` 闭环只部分命中
  4. capture 导出 / trace 可见性仍不稳定
  5. 替换链路稳定，但差异落在更后续 render pipeline / post-processing
- **新增日常验证方法时，默认只接受 agent 可通过脚本或命令独立完成的方案。** 若某一步需要人工登录、摆场景、点按钮或其它交互，它不能成为当前阶段默认 gate；只有在 blocker 明确依赖该人工条件、且已得到用户确认后，才可作为例外保留。
- 只有在这一层结论明确后，下一轮才应该决定是否回到 `IRToMSLConverter`、replacement runtime，还是更后续的渲染链路。

## 最新执行结果（2026-04-06，本轮）

- `E-006d8` 已通过统一入口形成 `off1/off2/on1/on2/on3/on4/on5/on6/on7` 九轮快照；更早 live blocker 如何逐步前移，以及本轮之前的详细 run-history，统一下沉到 `00-Dashboard-Archive.md`
- `replacement-off-run1` 仍是当前最低风险的 trace-level 基线；而 fresh `replacement-on-run7` 则成为新的 on-run live 基线：它补齐了最新代码、`session=ready`、`RuntimeLaunchDiagnostics` breadcrumb，以及没有 `.gputrace` 时的标准快照固化
- 本轮执行的标准 fresh 路径为：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` → `./BuildScripts/build_and_install.sh` → `Scripts/set_shader_replacement_mode.py --bundle-id com.miHoYo.Yuanshen --mode on` → `Scripts/e006d_matrix_runner.py prepare-run --bundle-id com.miHoYo.Yuanshen --mode on --run-index 7` → `remove_playtools` / `inject_playtools` / `launch_app` / `create_session(timeout=30)` → `Scripts/e006d_matrix_runner.py finalize-run`。这条路径仍保持为 agent 可独立完成的自动流程，不需要人工登录、摆场景或手工拷目录
- 构建验证方面，本轮先误把 `sync_playtools_xcframework.sh` 与 `build_and_install.sh` 并发执行，命中同一 `derivedData` 的 `build.db` 锁；改为串行后，`./BuildScripts/build_and_install.sh` 再次通过，说明标准安装产物已更新到最新代码
- live 复测方面，本轮在 fresh 注入前先确认 `list_sessions` 为空；随后 `remove_playtools` 成功、首次 `inject_playtools` 失败，但通过 `re-sign` + 再次 `inject_playtools` 恢复到可启动状态。之后 `launch_app` 与 `create_session(timeout=30)` 成功返回新的 `session=ready`；`RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl` 继续记录了最新 `processLaunchId` 的完整阶段链路：`playcover_launch_enter`、`bridge_listener_command_listener_ready`、`bridge_registration_established`、`playcover_launch_complete`
- 与 `on6` 不同的是，本轮在 `session=ready` 之后连续两次 `get_capture_status` 都返回 `Receive timed out`，但 `list_sessions` 持续显示同一个 `sessionId` 仍保持 `ready`，没有再掉成 `Session not found`。这说明当前 blocker 已不再是“fresh 注入后完全起不来”或“session 立刻掉线”，而是 **capture bridge / reachability 在 `session=ready` 下仍不稳定**
- 更关键的是，fresh `replacement-on-run7` 没有再把最新 failure 前移为 `Host bridge reported an error: Session not registered: <sessionId>`。`Scripts/compare_capture_runs.py --run-a replacement-on-run6 --run-b replacement-on-run7` 给出：共享 `moduleKey=91/91`、`changedShared=27`，latest replacement attempt 已从 `failed / exception` 回到 `succeeded / none`。换句话说，host 侧 stale-session cleanup 主动断链修复后的 fresh run **暂未再复现 split-brain 型 `Session not registered`**
- `replacement-on-run7` 现已作为标准快照固化，摘要为：`replacementEnabled=true`、`manifestLines=2249`、`modules=91`、`replacements=206`、`diagnostics=18`、`gputraceMSL=n/a`。将 `on7` 纳入矩阵后，`build/e006d-run-matrix.json` 最新摘要为：`mode=off allInputStable=True`、`mode=on allInputStable=True`、`mode=on allReplacementAttemptStable=False`、`mode=on missingAttemptWhileEnabledPairs=11`、`off-vs-on allPairsDifferent=False`、`differentPairCount=12`
- 截至当前，**绘制内容差异**这条线已经不是“缺工具”，而是“还没把现成工具正式接入 `E-006d8` 的默认执行顺序”：`LocalDocs/XCodeOperation/` 已具备打开 `.gputrace`、Replay、导出 `Command Buffer` / `Render Encoder` / `Pipeline State` 结构摘要的脚本，但还没对 `replacement-off-run1` vs `replacement-on-run5` 产出正式结构化 diff。
- 因此当前主线已经进一步收敛为四条更窄的 blocker：1）**对 latest fresh `replacement-on` 路径而言**，为什么 `session=ready` 之后，capture bridge / `get_capture_status` 仍会稳定 `Receive timed out`，以及这是否与 `capture_metal_frame` reachability 或 runtime service 状态有关；2）**为什么 `capture_metal_frame` 的自定义工作区 `output_path` 仍会被权限拒绝**；3）**为什么上一轮成功 `.gputrace` 仍只有 `2/11` 个合法 MSL**；4）**当前代表性 off/on 截帧在 draw call / Render Encoder / Pipeline State 层面到底有没有结构差异**。在这四条线收敛前，还不能继续把结论往 shader lowering 或更后续 pipeline 方向过早定性
- 2026-04-06 本轮新增了一步小闭环：`Scripts/e006d_matrix_runner.py finalize-run` 已支持 `--latest-gputrace`，会默认从 `~/Library/Containers/<bundleId>/Data/Documents/Captures/` 选取最新 `.gputrace` 并直接纳入 run 快照；只有在确需对比非默认落盘路径时，才继续显式传 `--gputrace /path/to/trace.gputrace`。

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
  --latest-gputrace \
  --print-compare-path
```

- 若需要覆盖默认搜索目录，可追加：

```bash
python3 Scripts/e006d_matrix_runner.py finalize-run \
  --bundle-id com.miHoYo.Yuanshen \
  --mode off \
  --run-index 1 \
  --latest-gputrace \
  --capture-root /custom/Captures \
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
- 若 base pass 对比看起来接近，**不要停在“shader 本身没问题”或“shader 一定有问题”的二选一**；应立刻进入绘制内容差异检查：
  - 先用 `LocalDocs/XCodeOperation/xcode_gpu_ops.py open <gputrace> --no-analysis` + `dump` 导出整帧 `navigator_api_call.json` / `navigator_pipeline_state.json`
  - 再用 `collect_cbs.py` 比较 `Command Buffer` 数与每个 `CB` 下的 `Render Encoder` 列表
  - 必要时再用 `collect_re_details.py` 收集关键 `Render Encoder` 的 `pipeline_state`、`vertex/fragment resources` 与 `attachments`
- 当前仓库里**没有**稳定的纯离线 `.gputrace` drawcall 解析器；由于 `device-resources` / `unsorted-capture` 是私有 `MTSP` 结构，现阶段最稳的办法仍是 **Xcode + GUI 自动化脚本**
- 这条线的具体操作与边界统一见 `E-006d-RenderingPathDiffReference.md`；若环境尚未满足 Accessibility / `cliclick` 前提，它只能作为专项分析分支，不能写成当前默认日常 gate

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

1. 固定 live 条件；对当前原神基线，继续以“启动后数十秒自动停在登录界面”为统一复现面，由 agent 独立完成每轮启动与等待；每轮结束后立即用 `Scripts/snapshot_capture_run.py` 或 `Scripts/e006d_matrix_runner.py finalize-run` 固化 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings 快照
   - 若该轮已经通过 `capture_metal_frame` 产出了默认容器内 `.gputrace`，优先使用 `finalize-run --latest-gputrace` 自动接回最新产物，不再默认手填工作区 `--gputrace` 路径
2. 当前已完成 `replacement-off-run1/off-run2/on-run1/on-run2/on-run3/on-run4/on-run5/on-run6`；“同模式输入稳定”已经成立，而 fresh `replacement-on-run6` 也已经证明 launch / registration 主链可以再次拉起。2026-04-06 还额外补上了 host 侧 stale-session cleanup 主动断开 registration channel 的修复与对应 `PlayCoverMCPTests` 集成验证。因此下一步不再是继续机械补 run，而是把**当前四条更窄 blocker**继续收敛：带着该修复重新验证 host bridge `Session not registered` 生命周期问题、自定义 `capture` 输出路径权限、trace 侧合法 MSL 覆盖偏低，以及代表性 off/on 截帧的 draw call / Render Encoder / Pipeline State 结构化差异
3. 为了继续推进，优先保留当前已经打通的 **launch / session 标准链路**：fresh on-run 结束后先用 `Scripts/runtime_launch_diagnostics_summary.py --bundle-id <bundleId>` 读取 `RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl`，确认 runtime 是否进入 `PlayCover.launch()`、是否起了 command listener、是否真的发起并建立了 registration channel；随后继续用 `create_session` / `list_sessions` / `get_capture_status` 观察 session 在 `ready` 之后是否会掉到 `Session not registered`，并在必要时先无 `.gputrace` 地通过 `Scripts/e006d_matrix_runner.py finalize-run` 固化证据
4. 与此同时，并行处理 manifest 中**历史仍存在**但本轮最新增量已不再前移到最前面的 `llvm-dis` `Operation not permitted` 失败样本：优先复用现有 diagnostics、run 快照与 replay/diff 工具，把它们与新的 `Session not registered` 失败桶分层整理，而不是回到人工 live 观察
5. `Scripts/analyze_capture_run_matrix.py` 与 `Scripts/compare_capture_runs.py` 的现有结论已经足够回答：同模式输入稳定、fresh build/install 已恢复 replacement 证据、live session/capture 主链也已恢复，但跨模式稳定不同仍未成立；因此当前**不能只继续看 shader / corpus / trace 哈希**，而应把下一步明确切到 `replacement-off-run1` vs `replacement-on-run5` 的绘制内容结构化 diff，优先导出 `frame_dump`、`cb_data.json`、`key_pass_details.json`
6. 只有在 agent 可独立完成的自动流程内继续收敛 **session 生命周期**、**capture 输出路径**、**trace 合法 MSL 覆盖** 与 **draw call / Render Encoder / Pipeline State 差异** 这四条线后，才继续把问题往 converter、本体 replacement runtime，或更后续的 pass / pipeline 方向展开；若某个新方法必须引入人工交互，需先得到用户确认

## 从 dashboard 下沉的细粒度技术备注

- **真实 corpus compile 通过不等于 `.gputrace` 源码可见，更不等于真实渲染正确**：这三层验证必须分开
- **延迟管线下，base pass 看起来类似并不能排除后续阶段问题**：若当前观察主要来自最终画面差异，就必须把后处理、着色阶段与 render pipeline 顺序 / 配置一起纳入排查范围
- **“替换 vs 不替换”是当前最低风险的稳定比较基线**：在根因层级未明确前，先确认开启替换后是否稳定引入了最终效果差异，再继续往具体 stage / pass 下钻
- **“替换 vs 不替换”必须有明确控制面**：`E-006d3` 后不要再通过改代码或手改 plist 临时构造“无替换”样本，统一使用 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py`，避免把控制变量本身做脏
- **run 快照要在 live 结束后立即固化**：`E-006d4` 后统一使用 `Scripts/snapshot_capture_run.py` 保留 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings；不要再手工从容器里零散拷目录，否则很容易把 replacement 开关状态与对应 run 搞混
- **若本轮已产出 `.gputrace`，也要与 run 快照一起固化**：`E-006d5` 后优先通过 `Scripts/snapshot_capture_run.py --gputrace /path/to/xxx.gputrace` 一次性保留 trace 与源码覆盖摘要，不要再把 `.gputrace` 单独散落在其它目录，避免后续 run-vs-run diff 时丢失最终可见性证据
- **当前默认不是“人工控场”，而是“agent 自动到登录界面”**：对原神当前阶段，登录界面已经足够作为 `E-006d8` 的稳定对照面；文档里出现“同一界面 / 相同设置”时，默认指这个 agent 可独立到达的界面，除非子任务另行声明更深的人工场景要求
- **成功路径也要落盘聚合产物，才能回答“最终替换源码是否稳定”**：只保留单模块 `.bc/.ll/.metal` 不足以覆盖聚合顺序、重名去重与最终 `makeLibrary(source:)` 输入；`E-006d2` 后应优先比较 `manifest.jsonl` 中最新 `event=replacement` 对应的 aggregate source hash
- **draw call / Render Encoder / Pipeline State 是独立证据层，不是可选项**：当前异常很可能落在 deferred shading / post-processing / render pipeline；因此当 shader / trace 侧证据不足时，必须补做结构化的绘制内容 diff，而不是继续只围绕 hash 打转
- **当前 draw-content 方案依赖 Xcode GUI 自动化前提**：`xcode_gpu_ops.py`、`collect_cbs.py`、`collect_re_details.py` 已可复用，但它们依赖 Xcode、Accessibility 权限与部分 `cliclick` 操作；在确认 agent 能独立跑通前，这条线只能作为专项分析分支，不能升级为默认日常 gate
- **`module.meta.json` 的统计字段要与真实 artifact diff 分开看**：`captureCount`、`sourceCacheKeys`、`generatedMSLBytes`、`llvmIRBytes`、`bitcodeBytes` 这类 bookkeeping 字段会让 `module.meta.json` hash 变化，但不等于 `.bc/.ll/.metal` 本体变化；对 `E-006d8` 的“输入 / 输出是否稳定”判断，必须优先看真实 artifact 与 aggregate source，不能把 metadata 漂移误收敛成 shader 漂移
- **`throw` + 静默 `catch` 回退是 runtime hook 的危险反模式**：会把关键 blocker 隐藏为“看似正常但实际回退原始 library”
- **host 侧 stale cleanup 若不主动断链，会制造 host/runtime split-brain**：只删除 registry 中的 session，而不关闭 runtime 仍在使用的 registration channel，会让 runtime 继续持有旧 `sessionId` 并在后续 host bridge 命令阶段才暴露为 `Session not registered`。当前已改为 stale cleanup 时同步调用 `RegistrationListener.disconnectSessions(...)` 断链；后续若同类错误仍存在，应优先判断是否为断链后的剩余重注册 / reachability 问题。
- **失败路径导出是闭环的关键一环**：`ShaderSourceDiagnostics/<baseName>_modules/` 让失败样本也能进入离线 replay 主路径；该闭环规则本身见 `E-004-CorpusClosureAndRecapturePolicy.md`
- **更早的 lowering 细节与已收敛 compile blocker 不再由本文档维护**：相关历史实现经验已经沉到 `E-004-MetallibSourceExtraction.md`、`E-006d-RenderingPathDiffReference.md` 与 archive，避免当前主线文档同时承担“执行说明”和“历史修复百科”两种职责

## 与其他文档的关系

- 当前主线 / 优先级 / TODO：`00-Dashboard.md`
- 历史 live blocker 时间线：`00-Dashboard-Archive.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- corpus replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
- 绘制内容差异（draw call / render pass / pipeline）专项参考：`E-006d-RenderingPathDiffReference.md`
- Xcode GPU GUI 自动化工具说明：`../../XCodeOperation/README.md`
