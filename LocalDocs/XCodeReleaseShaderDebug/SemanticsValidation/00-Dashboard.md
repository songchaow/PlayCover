## Semantics Validation Dashboard

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

- 如何把**已经采集到的 corpus 样本**，尽可能纳入 **L1/L2** 的自动化离线验证，而不是长期停留在“小代表集 + 少量后置行为样本”
- 如何让这条“全量已采集样本 → round-trip → canonical compare → 风险分级”的路径继续保持 **agent 可自主完成**，不把人工枚举样本、人工 fresh capture、人工找工具路径写回日常流程
- 如何把 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 的角色明确拆开：前者作为**当前可直接批量消费**的主入口，后者作为**failure-path 补充输入**，在未形成脚本化批量入口前不得冒充默认 gate
- 如何在当前阶段把控制面严格收口到 **全量 corpus 的 L1/L2 测试**，不让较旧的 L3/L4 规划继续占据主文档暴露面

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：立项初版关于“缺少 L1/L2”的历史表述已经下沉到 `01-现状调研与缺口.md` 与 `07-首轮基线与历史进展归档.md`；当前 dashboard 只保留 active gap 与当前控制面。
>
> 当前控制面事实以结构化报告为准；更细的 L1/L2 输入边界、preset / manifest / baseline 契约、以及“哪些路径可自动、哪些仍是待补齐缺口”的细节统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`（前两者**建议读取**；`08` 为工作参考，当前主线推进**不必须读取**）。

## 最终目标

当前阶段的最终目标先收口为：**全量 corpus 的 L1/L2 测试**。

当前只承诺把下面四件事收口：

1. **`ShaderCorpus` 全量已采集样本尽可能进入统一的 L1/L2 离线路径**
2. **`ShaderSourceDiagnostics` 仅作为 failure-path 补充输入进入同一套 L1/L2 报告语义**
3. **`test-data-representatives` 继续作为跨机器硬默认 gate，确保 fresh workspace 下也能由 agent 自主完成最小验证闭环**
4. **日常构建、测试、验证默认必须仍是 agent 可独立自动完成；若确实需要用户介入，必须先得到确认**

补充说明：

- `L3` / `L4` 仍作为后置能力保留，但当前**不是**本阶段最终目标，也**不进入当前 TODO**
- 四层模型与后置升级口仍保留在 `02-总体技术路线.md`、`05-L3-最小行为测试.md`、`06-L4-真实场景验证.md` 中，作为参考，不改变当前控制面

总体原则：

- **offline-first**：优先离线验证，减少 live 成本
- **automation-first**：默认只采用 agent 可独立完成的脚本 / MCP / skill 路径
- **minimal-human**：若确实需要人工/外部协助，必须先把留给用户的步骤压到最少、最简单；并在执行前得到用户确认
- **分层止损**：当前默认只把主路线收口到 `L1 → L2`；`L3 / L4` 只保留为后置参考，不反向定义当前主线

## 当前主线

### 主线任务

> **背景**：`SV-003` 的首轮 runner / compare / gate 基础已经具备；当前不再以“再补一条最小 L3 默认执行面”为主，而是以“让全量已采集样本尽可能进入 L1/L2，并且这条路径仍保持纯离线、自动化优先、agent 可自主完成”为主。为避免和 `SV-003` 的长期守护含义混淆，本文档把这条当前执行面记为 `SV-003F`。

**当前主线应统一理解为：`SV-003F` = 当前唯一实际执行面；`SV-003` = 这条执行面的自动化边界与硬默认 gate 约束；`SV-004 / SV-005` = 已后置、当前不进入 TODO。**

当前最该优先继续推进的事，已经收敛为两条：

1. **`SV-003F`：让全量已采集 corpus 样本尽可能进入 L1/L2**
   - 先以 `ShaderCorpus` 作为当前**可直接批量消费**的主入口
   - 用同一套 `roundtrip / compare / risk / gate` 结构化报告覆盖更多已采集真实样本，而不是继续把主线停在极小代表集
   - `ShaderSourceDiagnostics` 中已经具备 `module.ll / module.generated.metal / module.meta.json` 的 failure-path 样本，且现已可通过 `--diagnostics-root` / `--preset local-diagnostics-batch` 被 agent 批量纳入同一离线路径；它仍然只应作为 failure-path 补充输入，不能反向改写日常默认 gate
2. **自动化边界必须继续守住**
   - `test-data-representatives` 继续是跨机器硬默认入口
   - `SV-003F` 只能建立在现有自动化脚本能力之上；若某条新路径需要用户手工枚举大量 `.ll`、手工 fresh capture、手工准备工具或手工整理目录，就不能写回默认流程
   - 日常构建、调试、测试、验证默认不准出现需要人工介入协助的情况；若未来确有不可避免的阻塞，必须先停下汇报并征得用户确认

**只有直接改善下面 4 条收口判定的工作，才属于当前 TODO：**

- **硬默认 gate 不回退**：`test-data-representatives` 继续可在 fresh workspace 下由 agent 独立完成
- **`ShaderCorpus` 批量入口稳定**：可用单命令进入统一的 `roundtrip / compare / risk / gate` 报告，不要求 fresh capture 或人工整理目录
- **`ShaderSourceDiagnostics` 只作为补充输入**：可通过 `--diagnostics-root` / `--preset local-diagnostics-batch` 进入同一套 L1/L2 报告，但不改写默认 gate 身份
- **新增方法不破坏自动化边界**：任一新构建 / 测试 / 验证方法若不能保持 agent 自主自动完成，就不能落入日常流程

当前已确认、且直接驱动主线判断的事实只保留下面几条：

- `test-data-representatives` 继续是**跨机器硬默认 gate**；它的职责是守住 fresh workspace / 低上下文环境下的最小离线闭环
- `Scripts/ir_semantics_roundtrip_runner.py` 当前已经可以**直接批量消费整个 `ShaderCorpus`**；因此“先让成功路径样本全量进入 L1/L2”是当前最直接、最该做的事
- `ShaderSourceDiagnostics` 在 `E-004f4` 后已经为 failure-path 样本提供 `module.ll / module.generated.metal / module.meta.json`，且当前已可通过 `Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ...` 被批量发现并进入同一套 L1/L2 报告；它的定位仍是 failure-path 补充输入，而不是默认 gate
- 当 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 在同一次批量运行中出现相同 `bundleId + moduleKey` 时，结构化报告里的 `comparisonKey / sampleKey` 必须继续保持 source-aware，避免 diagnostics failure-path 样本伪装成 success-path 主入口事实
- 既有 `L3 / L4` 规划、白名单行为边界、本机增强入口与历史快照统一下沉到 `05-L3-最小行为测试.md`、`06-L4-真实场景验证.md`、`07-首轮基线与历史进展归档.md` 与 `08-当前代表集与Gate契约参考.md`（均为参考；除 `05` 外当前主线推进**不必须读取**）

因此当前最高优先级可直接概括为：**先把“全量 corpus 的 L1/L2 测试”这条自动化离线路径收口；在这之前，不把 L3/L4 或本机增强入口重新写成当前主线。**

### 当前不该抢跑的事

在 `SV-003F` 这条执行面还未收口前，默认**不要**把精力放到：

- 为覆盖率而继续扩默认 L3 白名单
- 大规模 live `.gputrace` 验证或高成本 GUI / Accessibility 操作
- 需要用户频繁登录 / 摆场景 / 点按钮的流程
- 即使当前已经支持 `--diagnostics-root`，也不要把人工批量枚举 `.ll` 路径重新写回日常步骤；优先复用现有脚本化入口
- 因为当前机器缺少某批样本，就把 fresh capture / 手工准备环境写回日常 gate
- 仅因为旧文档长期强调 `SV-004F` 或 `daily-default`，就继续把当前主线误写成“维护后置行为边界”或“维护本机增强快照”

除非它们是为解除当前最高优先级阻塞所**绝对必要**的最小步骤，且已获得用户确认。

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：文档、离线脚本、`IRToMSLConverter`、compare 逻辑、L1/L2 全量样本纳入路径。

- 已有离线 replay / compile：

```bash
python3 Scripts/corpus_replay_runner.py --compile --ll <sample.ll>
```

- 已有 PlayTools 构建守门（**仅在改动涉及 `IRToMSLConverter` / PlayTools 构建产物时执行**；文档整理或纯 compare/gate 调整不必附带重建；若脚本失败，应先停下汇报，不要改成手写 `xcodebuild`、手工复制产物或其它需要人工介入的替代流程）：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

- **跨机器硬默认 gate**（优先保证这条始终可由 agent 自主执行）：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

- **当前最高优先级的本机离线主线**（只复用已存在样本，不引入人工准备；若本机没有现成 `ShaderCorpus`，直接退回跨机器硬默认 gate，不把 fresh capture 写回日常步骤）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

- **failure-path 批量补充验证**（仅在需要补充 failure-path 证据时运行；当前已具备 agent 可自主的脚本化入口，但仍只作为补充输入，不替代默认 gate）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

- **failure-path 定向补充验证**（仅在已有明确 blocker 样本、且需要聚焦单个模块时使用；不要因为已有 `--diagnostics-root` 入口，就把人工批量枚举 `.ll` 路径重新写回日常步骤）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --ll <path_to_failure_module.ll> --allow-failures
```

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
6. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
7. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
8. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
9. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

> 注：已完成里程碑与较旧说明统一下沉到 `07-首轮基线与历史进展归档.md`（历史参考，当前主线推进**不必须读取**）；dashboard 只保留仍会改变下一步选择的 active items。
>
> 补充：若某条 TODO 仍明显过大，它只能作为**父任务**存在；实际执行前必须先在本区补出更短的子任务，并把“当前唯一实际执行面”落到其中一条，避免单个 TODO 过长。

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-003F | 收口“全量 corpus 的 L1/L2 测试” | ONGOING | P0（父任务） | 只负责定义本阶段目标与自动化边界；实际执行时必须先落到下方某个更短子任务，单轮只推进其中**一个最关键**的实际执行面 | `03-L1-IR-RoundTrip.md` / `04-L2-CanonicalCompareAndRiskGrading.md` |

### `SV-003F` 当前子任务拆分

| # | 子任务 | 状态 | 优先级 | 结束标准 |
|---|---|---|---|---|
| SV-003F1 | 守住 `test-data-representatives` 硬默认 gate 不回退 | READY | P1 | 固定三条硬默认命令继续可由 agent 独立完成，且无新增 gate 回归 |
| SV-003F2 | 收口 `ShaderCorpus` 批量主入口 | NEXT | P0（当前唯一实际执行面） | 解决一个最关键的 corpus 批量 blocker / contract 问题，或把该 blocker 与可验证结束标准文档化；不得要求 fresh capture、人工整理目录或其它用户协助 |
| SV-003F3 | 守住 `ShaderSourceDiagnostics` 补充入口与 source-aware 身份隔离 | READY | P1 | `--diagnostics-root` / `--preset local-diagnostics-batch` 继续可批量进入同一套 L1/L2 报告，且 `comparisonKey / sampleKey` 不污染 corpus 主入口事实 |

### 当前关键状态

- **当前最终目标已收口**：当前只以“全量 corpus 的 L1/L2 测试”作为本阶段目标；L3/L4 继续保留为参考，不进入当前 TODO
- **当前唯一实际执行面已下沉到子任务**：父任务 `SV-003F` 只负责目标与边界；本轮默认只推进 `SV-003F2`，除非它阻塞或已完成
- **跨机器硬默认 gate 不变**：`test-data-representatives` 继续是 fresh workspace 下必须可由 agent 自主完成的最小 L1/L2 入口
- **`ShaderCorpus` 是当前唯一主入口**：主线优先关注“全量已采集 corpus 样本尽可能进入 L1/L2”，而不是继续维护后置行为边界或本机增强快照
- **`ShaderSourceDiagnostics` 已具备 agent 可自主的批量入口**：failure-path 样本当前可通过 `--diagnostics-root` 进入同一套离线 L1/L2 报告；它仍然只是补充输入，不应把人工枚举或人工辅助重新写回默认流程
- **日常自动化边界不变**：若未来某条新构建/测试/验证方法不是 agent 可独立自动完成的，就不能默认落地；若确实存在必须由用户介入的步骤，必须先得到用户确认

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

- `01-现状调研与缺口.md`（需要理解“为什么当前目标收口为全量 corpus 的 L1/L2 测试”时再读，当前日常推进**不必须读取**）
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
