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

- 如何把**已经采集到的样本**，尽可能纳入 **L1/L2** 的自动化离线验证，而不是长期停留在“小代表集 + 少量白名单行为样本”
- 如何让这条“全量已采集样本 → round-trip → canonical compare → 风险分级”的路径继续保持 **agent 可自主完成**，不把人工枚举样本、人工 fresh capture、人工找工具路径写回日常流程
- 如何把 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 的角色明确拆开：前者作为**当前可直接批量消费**的主入口，后者作为**failure-path 补充输入**，在未形成脚本化批量入口前不得冒充默认 gate
- 如何在 L1/L2 的全量样本路径还未稳定前，严格把 **L3 最小行为测试** 与 **L4 真实场景验证** 保持为后置升级口，而不是继续占据当前控制面

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：立项初版关于“缺少 L1/L2”的历史表述已经下沉到 `01-现状调研与缺口.md` 与 `07-首轮基线与历史进展归档.md`；当前 dashboard 只保留 active gap 与当前控制面。
>
> 当前控制面事实以结构化报告为准；更细的 L1/L2 输入边界、preset / manifest / baseline 契约、以及“哪些路径可自动、哪些仍是待补齐缺口”的细节统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`（前两者**建议读取**；`08` 为工作参考，当前主线推进**不必须读取**）。

## 最终目标

建立一套尽可能完善的 **Semantics Validation** 测试体系，覆盖四层：

1. **L1：IR Round-trip 结构验证**
2. **L2：Canonical Compare + 风险分级**
3. **L3：最小行为测试**
4. **L4：真实场景验证**

总体原则：

- **offline-first**：优先离线验证，减少 live 成本
- **automation-first**：默认只采用 agent 可独立完成的脚本 / MCP / skill 路径
- **minimal-human**：若确实需要人工/外部协助，必须先把留给用户的步骤压到最少、最简单；并在执行前得到用户确认
- **分层止损**：最终做到哪一层，取决于当时的人力余量（包括 token 预算与实现成本）；但主路线始终按 L1 → L2 → L3 → L4 推进

## 当前主线

### 主线任务

> **背景**：`SV-003` 的首轮 runner / compare / gate 基础已经具备，当前不再以“再补一条最小 L3 默认执行面”为主，而是以“让全量已采集样本尽可能进入 L1/L2，并且这条路径仍保持纯离线、自动化优先、agent 可自主完成”为主。为避免和 `SV-003` 的长期守护含义混淆，本文档把这条当前执行面记为 `SV-003F`。

**当前主线应统一理解为：`SV-003F` = 唯一实际执行面，`SV-003` = 长期守护约束，`SV-004 / SV-004F / SV-005` = 严格后置升级口。**

当前最该优先继续推进的事，已经收敛为三条：

1. **`SV-003F`：让全量已采集样本尽可能进入 L1/L2**
   - 先以 `ShaderCorpus` 作为当前**可直接批量消费**的主入口
   - 用同一套 `roundtrip / compare / risk / gate` 结构化报告去覆盖更多已采集真实样本，而不是继续把主线停在极小代表集
   - `ShaderSourceDiagnostics` 中已经具备 `module.ll / module.meta.json` 的 failure-path 样本，且现已可通过 `--diagnostics-root` 被 agent 批量纳入同一离线路径；它仍然只应作为 failure-path 补充输入，不能反向改写日常默认 gate
2. **`SV-003`：继续守住跨机器硬默认 gate，不让全量样本路径带来人工依赖回流**
   - `test-data-representatives` 继续是跨机器硬默认入口
   - `SV-003F` 只能建立在现有自动化脚本能力之上；若某条新路径需要用户手工枚举大量 `.ll`、手工 fresh capture、手工准备工具或手工整理目录，就不能写回默认流程
   - `preset-manifest.json` / gate profile / baseline 说明若滞后，只能当参考，当前事实口径仍以结构化报告字段为准
3. **`SV-004 / SV-004F / SV-005`：只在 L1/L2 全量样本路径仍不足时才升级**
   - L3 最小行为测试继续保留，但当前不是默认执行面
   - L4 真实场景验证继续保留为严格后置 gate
   - 若涉及 GUI / 登录 / 工作区外修改，必须先得到用户确认

当前已确认、且直接驱动主线判断的事实只保留下面几条：

- `test-data-representatives` 继续是**跨机器硬默认 gate**；它的职责是守住 fresh workspace / 低上下文环境下的最小离线闭环
- `Scripts/ir_semantics_roundtrip_runner.py` 当前已经可以**直接批量消费整个 `ShaderCorpus`**；因此“先让成功路径样本全量进入 L1/L2”是当前最直接、最该做的事
- `ShaderSourceDiagnostics` 在 `E-004f4` 后已经为 failure-path 样本提供 `module.ll / module.generated.metal / module.meta.json`，且当前已可通过 `Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ...` 被批量发现并进入同一套 L1/L2 报告；它的定位仍是 failure-path 补充输入，而不是默认 gate
- 既有 `SV-004F` 默认白名单行为边界、`daily-default / local-corpus-representatives` 本机增强入口，以及更早的批量快照/样本数字，统一下沉到 `05-L3-最小行为测试.md`、`07-首轮基线与历史进展归档.md` 与 `08-当前代表集与Gate契约参考.md`（均为参考；除 `05` 外当前主线推进**不必须读取**）

因此当前最高优先级可直接概括为：**先把“全量已采集样本尽可能进入 L1/L2”这条自动化离线路径收口，再讨论 L3/L4；在这之前，不把最小行为白名单继续误写成当前唯一主线。**

### 当前不该抢跑的事

在 `SV-003F` 这条执行面还未收口前，默认**不要**把精力放到：

- 为覆盖率而继续扩默认 L3 白名单
- 大规模 live `.gputrace` 验证或高成本 GUI/Accessibility 操作
- 需要用户频繁登录 / 摆场景 / 点按钮的流程
- 即使当前已经支持 `--diagnostics-root`，也不要把人工批量枚举 `.ll` 路径重新写回日常步骤；优先复用现有脚本化入口
- 因为当前机器缺少某批样本，就把 fresh capture / 手工准备环境写回日常 gate
- 仅因为旧文档长期强调 `SV-004F`，就继续把当前主线误写成“守住 `pass/pass` 白名单”

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

- **当前最高优先级的本机离线主线**（只复用已存在样本，不引入人工准备）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

- **failure-path 批量补充验证**（当前已具备 agent 可自主的脚本化入口，但仍只作为补充输入，不替代默认 gate）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

- **failure-path 定向补充验证**（仅在已有明确 blocker 样本、且需要聚焦单个模块时使用）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --ll <path_to_failure_module.ll> --allow-failures
```

- 其它 preset 变体（`daily-default` / `local-corpus-representatives` / `test-data-batch`）、baseline snapshot 保存/复用、固定输出目录约定，以及“当前哪些入口只是参考、哪些入口仍不能写成默认 gate”的细节，统一下沉到 `03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md` 与 `08-当前代表集与Gate契约参考.md`；主文档只保留当前硬默认入口与最高优先级执行面，避免把旧代表集口径重新暴露回控制面

### `SV-004` 当前最小行为验证

适用于：**在 `SV-003F` 的 L1/L2 证据仍不足时**，把少量高价值样本推进到第一批本地行为证据。

```bash
python3 Scripts/test_ir_semantics_behavior_runner.py
python3 Scripts/ir_semantics_behavior_runner.py --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json
```

当前口径：

- 这条路径**保留可用**，但当前不再是默认主线执行面
- 默认继续复用固定输出目录里的 `gate-summary.json` / `roundtrip-summary.json`
- 默认继续保持“单命令、本地、无 UI、无工作区外修改、agent 可独立执行”的自动化边界
- 更细的样本名单、artifact 契约与 render-second 细节统一下沉到 `05-L3-最小行为测试.md`（当前已不是主线，按需读取即可）

补充约束：

- 若新增方法做不到“单命令、本地、无人工介入”，就不能写回日常默认流程
- 若当前机器上没有合适样本，不应自动升级成需要用户介入的 fresh capture 流程；这时应优先退回 `test-data-representatives` 或停在离线层汇报
- `daily-default` / `local-corpus-representatives` 的定位继续是“增强证据”，不是把人工准备环境重新引回默认 gate

### 运行时链路验证（只在必要时）

若当前改动不涉及以下任何内容，**跳过本节**。

仅在修改以下内容时执行：

- `LibrarySourceInjectionSwizzles`
- `MetallibParser`
- `LLVMDisassembler`
- runtime 导出路径 / host bridge / 安装部署逻辑
- 必须依赖真实 app 或 `.gputrace` 才能验证的变更

标准构建/安装方式：

```bash
./BuildScripts/build_and_install.sh
```

补充约束：

- 该脚本默认安装到 `~/Applications`，保持 agent 可自动执行；日常验证不要主动切到 `PLAYCOVER_INSTALL_MODE=auto/system`，以免引入 `sudo` / 权限交互
- **禁止**手写 `xcodebuild` 替代标准脚本

### 真实场景验证（后置 gate）

仅当 L1/L2 已基本收敛，且需要确认“真实 shader / 真实场景下没有明显退化”时才启用；它不是日常默认 gate。

优先使用：

- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- PlayCover MCP 能力（如 `launch_app` / `create_session` / `capture_metal_frame` 等）

若需要以下条件之一，**必须先得到用户确认**：

- GUI / Accessibility / `cliclick`
- 人工登录或手动摆场景
- 工作区外静态分析
- 工作区外文件或 app bundle 修改

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的 **一个最关键的** 未完成任务执行；若存在更细的未完成子任务，优先以子任务为实际执行面
3. 若选中的任务**没有明确结束标准**（例如无法判断“本轮做到哪里算完成”，或很可能导致下一次新 agent 继续在同一任务上查漏补缺式推进），立即停止实现并汇报；优先先补齐/澄清该任务的结束标准，再决定是否继续执行
4. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
5. 若任务过大，先拆分出新子任务到 TODO，再只完成其中**最关键**的一个
6. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
7. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
8. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
9. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

> 注：已完成里程碑与旧子任务统一下沉到 `07-首轮基线与历史进展归档.md`（历史参考，当前主线推进**不必须读取**）；dashboard 只保留仍会改变下一步选择的 active items。

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-003 | 把 L1/L2 接入 `test-data/` 与已采集真实样本 | ONGOING | P1（守护） | 已从“建设新入口”转为“长期守住默认 gate 契约 + 约束自动化边界”：`test-data-representatives` 必须继续作为跨机器硬默认入口；任何新样本路径若会把人工枚举、fresh capture、手工环境准备或用户协助写回默认流程，都不应并入日常 gate | `03-L1-IR-RoundTrip.md` / `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-003F | 让全量已采集样本尽可能进入 L1/L2 | ONGOING | P0（唯一实际执行面） | **当前最高优先级。** `ShaderCorpus` 与 `ShaderSourceDiagnostics` failure-path 样本当前都已能进入统一的 `roundtrip / compare / risk` 离线路径；接下来继续把这两类已采集样本稳定纳入同一套结构化报告，同时保持默认构建、测试、验证完全由 agent 独立完成。若某一步不得不要求用户介入，必须先停下汇报并得到确认 | `03-L1-IR-RoundTrip.md` / `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-004 | 最小行为测试（compute-first + render-second） | ONGOING | P1（后置升级口） | 能力已存在，但当前不再是默认主线。只有当 `SV-003F` 的 L1/L2 全量样本证据仍不足、且确有高价值样本需要补行为证据时，才继续推进 | `05-L3-最小行为测试.md` |
| SV-004F | 维持既有白名单行为边界与 oracle 同步护栏 | ONGOING | P1（后置守护） | 继续保留 `test_fast_math_select`、`test_intrinsic_vector_icmp_zext` 的既有自动化行为边界，作为后置参考能力与回归护栏；但它不再代表当前唯一实际执行面，也不应继续压过 `SV-003F` | `05-L3-最小行为测试.md` |
| SV-005 | 真实场景验证流程收口 | TODO | P2 | 把 `.gputrace` / render diff / MCP live 验证收口成严格后置 gate；只有在 `SV-003F` 与 `SV-004` 的纯离线证据仍不足或风险只会在 runtime/live 中暴露时才允许升级，且凡是 GUI / 登录 / 工作区外修改都必须先得到用户确认 | `06-L4-真实场景验证.md` |

### 当前关键状态

- **跨机器硬默认 gate 不变**：`test-data-representatives` 继续是 fresh workspace 下必须可由 agent 自主完成的最小 L1/L2 入口
- **当前唯一实际执行面已改为 `SV-003F`**：主线优先关注“全量已采集样本尽可能进入 L1/L2”，而不是继续把 `SV-004F` 的白名单行为边界当作当前唯一主线
- **`ShaderCorpus` 是当前可直接批量消费的真实样本主入口**：这条路径已可脚本化执行，应优先承担“扩大 L1/L2 真实样本覆盖面”的职责
- **`ShaderSourceDiagnostics` 已具备 agent 可自主的批量入口**：failure-path 样本当前可通过 `--diagnostics-root` 进入同一套离线 L1/L2 报告；它仍然只是补充输入，不应把人工枚举或人工辅助重新写回默认流程
- **`SV-004 / SV-005` 继续后置**：当前若未来确实需要用户介入，必须先把步骤压到最小并征得确认

## 踩坑与经验

- **compile green 不等于语义等价**
- **`.gputrace` 可见源码不等于最终行为无差异**
- **先做离线，再做 live**；live 只用于阶段性确认，不做默认主战场
- **不要把“文本完全一样”误当成“语义一样”**；后续比较应以 canonical summary + 风险分级为主
- **第一版 canonical compare 必须主动降噪**：SSA 名称、metadata 编号、`bufferSize` 缺失、`readonly/readnone` 这类编译器优化后常见变化，不应直接视为 L3
- **要把 `air.fast_*` intrinsic alias 与纯 instruction-level fast-math flag 漂移视为降噪对象**：若 compile option 与 function attr 没变，这类差异更接近 `L1` 噪声，而不应继续把代表集里的默认 debt 放大成 `L2`
- **对环境相关代表集，job count 不能只用单点值判定**：要区分“跨机器都必须成立的硬下界”和“本机样本齐备时的完整代表集”，否则容易把缺样本误报成回归
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **当前最重要的不是继续扩默认 L3，而是把已采集真实样本尽可能纳入 L1/L2**：只要 `ShaderCorpus` / failure-path 样本还没有被尽可能吃进离线主回路，就不应把主文档继续写成“白名单行为样本维护”
- **主文档不要直接暴露会漂移的本机快照**：本机增强入口、历史批量快照、manifest 描述文字与局部样本数量都应下沉到参考文档，主文档只保留当前主线真正依赖的控制面事实
- **若某条新构建/测试/验证方法不是 agent 可独立自动完成的，就不能默认落地**：若确实存在必须由用户介入的步骤，必须先得到用户确认

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“为什么当前主线改为全量样本 L1/L2”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；主线任务与升级顺序的核心参考）
- `03-L1-IR-RoundTrip.md`（**建议读取**；当前主线 `SV-003F` 的详细执行参考）
- `04-L2-CanonicalCompareAndRiskGrading.md`（**建议读取**；当前主线 `SV-003F` 的风险分级与 gate 参考）
- `05-L3-最小行为测试.md`（当前已是后置升级口，按需阅读即可）
- `06-L4-真实场景验证.md`（规划 live / `.gputrace` 时再读，当前**不必须读取**）
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
