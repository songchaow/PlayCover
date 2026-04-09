## Semantics Validation Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 问题背景

前置任务已经建立了比较完整的工程链路：

```text
metallib / wrapper payload
  ↓
BitcodeModule.data
  ↓
llvm-dis
  ↓
LLVM IR
  ↓
IRToMSLConverter
  ↓
MSL
  ↓
makeLibrary(source:) / metal -c
```

但现状更接近：

- **逐指令机械翻译 + compile 守门 + replay/diff 回归**
- 而不是 **已被严格证明的语义等价闭环**

当前缺口主要在：

- 如何把**已经采集到的 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 样本**，都稳定纳入同一套 **L1/L2** 自动化离线验证，而不是长期停留在“小代表集 + 少量后置行为样本”
- 如何让这条“全量批量样本 → round-trip → canonical compare → 风险分级”的路径继续保持 **agent 可自主完成**，不把人工枚举样本、人工 fresh capture、人工找工具路径写回日常流程
- 如何把 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 的角色明确拆开：前者继续作为**success-path 主入口**，后者继续作为**failure-path 补充入口**；二者都进入当前待修错误范围，但 `ShaderSourceDiagnostics` 仍不得冒充默认 gate
- 如何在当前阶段把控制面严格收口到 **当前 full-batch L1/L2 错误清零**：也就是 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 两条批量入口都不再 `fail`，而不是只看其中一边

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：立项初版关于“缺少 L1/L2”的历史表述已经下沉到 `01-现状调研与缺口.md` 与 `07-首轮基线与历史进展归档.md`；当前 dashboard 只保留 active gap 与当前控制面。
>
> 当前控制面事实以结构化报告为准；更细的 L1/L2 输入边界、preset / manifest / baseline 契约、以及“哪些路径可自动、哪些仍是待补齐缺口”的细节统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`（前两者**建议读取**；`08` 为工作参考，当前主线推进**不必须读取**）。

## 当前主线

> **当前最该做的事只有一件：`SV-003F`。** 也就是清零当前 full-batch L1/L2 错误：`ShaderCorpus` 与 `ShaderSourceDiagnostics` 两条批量入口都不再 `fail`。

### 这条主线怎么理解

- `SV-003F` = 当前唯一实际执行面
- `SV-003` = 自动化边界与跨机器硬默认 gate 约束
- `SV-004 / SV-005` = 后置升级口，当前不进入主线

### 当前主线的完成判定

只有同时满足下面几条，当前阶段才算完成：

1. `ShaderCorpus` full-batch 不再 `fail`
2. `ShaderSourceDiagnostics` full-batch 不再 `fail`
3. `test-data-representatives` 继续保持跨机器硬默认 gate，不回退
4. 日常构建、测试、验证仍可由 agent 独立自动完成；若某步必须人工介入，必须先得到用户确认

### 最新进展（2026-04-09）

- `IRToMSLConverter` 已完成一轮 `internal helper / entry` 误分类修复：包括 helper 递归发射、前置声明补齐，以及 `fastcc` 返回类型解析修正（提交：`da062c30`）
- 当前本机控制面已经从“compile blocker 主导”推进到“compile 已清零、L2/L3 风险仍待收口”
- 最新回归结果显示：
  - `ShaderCorpus` full-batch 已不再 `fail`
  - `ShaderSourceDiagnostics` full-batch 已不再 `fail`
  - `test-data-representatives` 仍为既有 `WARN`，未出现新增回退
- 因两条 full-batch 当前仍存在 `generic gate FAIL` / `unexpected blocked sample`，`SV-003F` **尚未完成**；剩余工作已从“修 compile blocker”切换为“收口 L2/L3 语义漂移与高风险样本”

### 当前最该做的事

1. **继续收口 `ShaderCorpus` 的 L2/L3 blocked sample**
   - 它仍是 success-path 主入口
   - 当前重点已从 compile blocker 转为 `compare / risk / gate` 报告里的高风险样本与 `unexpected blocked sample`
2. **同时收口 `ShaderSourceDiagnostics` 的 L2/L3 blocked sample**
   - 它仍是 failure-path 补充入口，不替代默认 gate
   - compile blocker 已清零，但其 full-batch 暴露出的 compare / gate 风险仍在完成判定内
3. **继续守住自动化边界**
   - `test-data-representatives` 必须继续可在 fresh workspace 下由 agent 独立完成
   - 不要把人工枚举样本、fresh capture、手工准备工具或手工整理目录写回默认流程

### 当前不该抢跑的事

在 `SV-003F` 未收口前，默认不要把精力放到：

- 为覆盖率继续扩默认 L3 白名单
- 大规模 live `.gputrace` 验证或高成本 GUI / Accessibility 操作
- 需要用户频繁登录 / 摆场景 / 点按钮的流程
- 已有 `--diagnostics-root` 批量入口时，重新把人工批量枚举 `.ll` 路径写回日常步骤
- 因当前机器缺少某批样本，就把 fresh capture / 手工准备环境写回日常 gate
- 把 L3/L4、本机增强入口或体系打磨本身重新写成当前主线

## TODO

> 注：已完成里程碑与较旧说明统一下沉到 `07-首轮基线与历史进展归档.md`；本节只保留 active item。

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `SV-003F` | DOING | `ShaderCorpus` 与 `ShaderSourceDiagnostics` 两条批量入口都不再 `fail`，且 `test-data-representatives` 与自动化边界不回退；当前 compile blocker 已清零，正在收口 L2/L3 gate | `03-L1-IR-RoundTrip.md` / `04-L2-CanonicalCompareAndRiskGrading.md` |

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：当前主线 `SV-003F` 相关改动，包括文档、离线脚本、`IRToMSLConverter`、`LLVMDisassembler`、canonical compare / gate 逻辑，以及 `ShaderCorpus` / `ShaderSourceDiagnostics` 的样本纳入路径。

**当前要求**：只要本轮修改触及上述范围，agent 在收尾测试时默认按下面顺序执行所有**适用**步骤；不要只跑其中一条就结束。

1. **必要时先做 PlayTools 构建守门**（仅当改动涉及 `IRToMSLConverter` / PlayTools 构建产物时执行；文档整理或纯 compare/gate 调整不必附带重建；若脚本失败，应先停下汇报，不要改成手写 `xcodebuild`、手工复制产物或其它需要人工介入的替代流程）：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

2. **跨机器硬默认 gate**（每次当前主线改动后都应优先执行，确保 fresh workspace 最小闭环不回退）：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

3. **当前最高优先级的本机离线主线：`ShaderCorpus` 全量批量验证**（当前阶段是否完成，以这条结果为主；只复用已存在样本，不引入人工准备；若本机没有现成 `ShaderCorpus`，直接退回第 2 步，并在结果里明确说明“本轮未执行 corpus 全量批量验证”）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

4. **failure-path 批量补充验证：`ShaderSourceDiagnostics`**（当前不替代完成判定，但只要本机已有这批样本，默认也应在收尾测试里一起跑一遍，避免只看 success-path 主入口）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

5. **定向 blocker 复现 / 单样本 smoke**（仅在修复明确 blocker 时追加，用于更快复现，不替代前面第 2-4 步的批量验证）：

```bash
python3 Scripts/corpus_replay_runner.py --compile --ll <sample.ll>
python3 Scripts/ir_semantics_roundtrip_runner.py --ll <path_to_failure_module.ll> --allow-failures
```

- **当前不纳入日常默认验证**：automation / nightly、`L3` 最小行为验证、`L4` live / `.gputrace` 验证
- 其它 preset 变体、baseline snapshot 保存/复用、固定输出目录约定，以及“哪些入口只是参考、哪些入口仍不能写成默认 gate”的细节，统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`；主文档只保留当前硬默认入口与最高优先级执行面，避免把旧代表集口径重新暴露回控制面
### `SV-004` 当前最小行为验证

当前**不是**当前阶段目标，也**不是**日常默认验证步骤。

当前口径：

- 这条路径继续保留为**后置升级口**，仅在用户后续明确决定升级到 L3 时再回到 `05-L3-最小行为测试.md`
- 若未来新增方法做不到“单命令、本地、无人工介入”，就不能写回日常默认流程
- 当前主线推进无需默认读取本节对应文档

### 运行时链路验证（只在必要时）

若当前改动不涉及运行时 replacement 主链路，**跳过本节**。

当前口径：

- 标准构建/安装方式仍是 `./BuildScripts/build_and_install.sh`
- **禁止**手写 `xcodebuild` 替代标准脚本
- 若未来真的需要进入这条路径，仍必须保证默认步骤可由 agent 自主自动完成；若做不到，必须先得到用户确认

### 真实场景验证（后置 gate）

仅当用户后续明确决定升级到 live / `.gputrace` 验证时才启用；它不是当前默认 gate。

当前口径：

- 具体工具、顺序与确认规则统一见 `06-L4-真实场景验证.md`
- 若需要 GUI / Accessibility / 人工登录 / 工作区外修改，**必须先得到用户确认**

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的 **一个最关键的** 未完成任务执行；若存在更细的未完成子任务，优先以子任务为实际执行面
3. 若选中的任务**没有明确结束标准**（例如无法判断“本轮做到哪里算完成”，或很可能导致下一次新 agent 继续在同一任务上查漏补缺式推进），立即停止实现并汇报；优先先补齐/澄清该任务的结束标准，再决定是否继续执行
4. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
5. 若任务过大，先拆分出新子任务附加到 TODO，再只完成其中**最关键**的一个。单个TODO不宜过长。
6. 若本轮修改触及 `SV-003F` 主线（包括 dashboard / 文档、离线脚本、`IRToMSLConverter`、`LLVMDisassembler`、compare / gate 逻辑或样本纳入路径），收尾测试时必须回到上面的“日常默认验证（优先）”，并按顺序执行所有**适用**步骤：必要时先做 PlayTools 构建守门，然后执行跨机器硬默认 gate，再执行 `ShaderCorpus` 全量批量验证；若本机存在 `ShaderSourceDiagnostics`，再追加它的批量补充验证；只有在聚焦单个 blocker 时，才额外追加单样本 smoke / 定向 `--ll`。**不要只做单样本 smoke 就宣称验证完成。**
7. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
8. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
9. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## 踩坑与经验

- **compile green 不等于语义等价**
- **不要把“文本完全一样”误当成“语义一样”**；当前默认应以 canonical summary + 风险分级为主
- **先做离线，再做 live**；在当前阶段，live 不是默认主战场
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **当前最重要的是把已采集真实样本尽可能纳入 L1/L2**；只要 `ShaderCorpus` / failure-path 样本还没有被尽可能吃进离线主回路，就不应把主文档继续写成后置行为样本维护
- **主文档不要直接暴露会漂移的本机快照**：本机增强入口、历史批量快照、manifest 描述文字与局部样本数量都应下沉到参考文档，主文档只保留当前主线真正依赖的控制面事实
- **非 preset 的默认输出目录必须避免碰撞**：当前离线路径允许 agent 近同时发起 corpus / diagnostics 等批量运行；默认输出目录若只按秒命名，会导致报告互相覆盖，因此默认目录需要追加唯一后缀
- **L2 compare 需要主动降噪**；更细的降噪对象与风险口径统一见 `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考，当前主线推进**不必须读取**）

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“为什么当前目标收口为 `ShaderCorpus` 全量已采集样本的 L1/L2 测试通过”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；当前目标、分层模型与后置升级口的路线参考）
- `03-L1-IR-RoundTrip.md`（**建议读取**；当前主线 `SV-003F` 的详细执行参考）
- `04-L2-CanonicalCompareAndRiskGrading.md`（**建议读取**；当前主线 `SV-003F` 的风险分级与 gate 参考）
- `05-L3-最小行为测试.md`（后置升级口参考，当前**不必须读取**）
- `06-L4-真实场景验证.md`（后置 live / `.gputrace` 参考，当前**不必须读取**）
- `07-首轮基线与历史进展归档.md`（历史归档与样本名单参考，**不必须读取**）
- `08-当前代表集与Gate契约参考.md`（维护 preset / gate / manifest 细节，或排查 `gate-summary.json` / `preset-manifest.json` 口径不一致时再读；当前主线推进**不必须读取**）

### 背景参考

- `../RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-004-MetallibSourceExtraction.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-005-OfflineReplayBatchCompileDiff.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006d-GenshinRenderingNondeterminism.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006d-RenderingPathDiffReference.md`（背景参考，**不必须读取**）
- `../RoadE-HookMakeLibraryWithSrc/E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md`（背景参考，**不必须读取**）

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift`
- `Scripts/corpus_replay_runner.py`
- `Scripts/ir_semantics_roundtrip_runner.py`
- `Scripts/ir_canonical_compare.py`
- `Scripts/test_ir_canonical_compare.py`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
- `Scripts/ir_semantics_behavior_runner.py`
- `Scripts/test_ir_semantics_behavior_runner.py`
- `Scripts/metal_compute_behavior_runner.swift`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- `Scripts/runtime_launch_diagnostics_summary.py`
