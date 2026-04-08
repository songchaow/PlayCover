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

- 如何把已落地的 **L1/L2 默认 gate** 继续保持为稳定前提，而不是在后续升级中被重新带偏到高人工成本流程
- 如何基于现有 **gate-summary / risk-report / behavior-summary**，明确写清楚 **停在 L2 / 升级到 L3 / 升级到 L4** 的机器可执行边界
- 如何在不引入人工依赖的前提下，只从最有信息量的样本里为 **L3 最小行为测试** 维持一个足够小、足够稳的入口
- 如何把 **真实场景验证** 保持为自动化优先、低人工依赖、且必须按需征得用户确认的严格后置 gate

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：立项初版关于“缺少 L1/L2”的历史表述已经下沉到 `01-现状调研与缺口.md` 与 `07-首轮基线与历史进展归档.md`；当前 dashboard 只保留 active gap 与当前控制面。
>
> 当前事实优先级统一为：**`gate-summary.json` > `risk-report.json` > `behavior-summary.json` / `behavior-summary.*.json` > `roundtrip-summary.json` > `preset-manifest.json` 的描述文字。** 其中应优先读取 `gate-summary.json` 里的 `status` / `activeKnownDebt` / `improvements` / `layeredDecision` 等结构字段；`preset-manifest.json` 与 `gate profile` 的说明文字仍有契约价值，但若这些描述文字滞后，不应再拿它们驱动当前主线判断。

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

> **背景**：`SV-003` 的第一轮收口与 `SV-006` 的 `layeredDecision` 控制面已经落地后，本目录主线已经不是“继续扩入口”，而是“把升级/止损规则真正驱动成最小行为证据”。当前应把 `SV-003` 继续当作长期守护约束，把 `SV-004` 明确为唯一主线执行面；而 `SV-004` 内部的当前实际子任务已经收敛为 `SV-004F`：维持 `pass/pass` 默认行为边界、固定输出目录与 sample oracle ↔ `.ll` 同步护栏。只有当这条纯离线、agent 可自主完成的证据链仍不足以解释风险时，才考虑更后置的 `SV-005`。

**`SV-004`：在 `SV-006` 已明确升级边界的前提下，只围绕跨机器硬默认 gate 里的活跃候选维护最小行为证据；当前默认执行面稳定为 `test_fast_math_select = pass`、`test_intrinsic_vector_icmp_zext = pass`。当前不再以扩样为默认目标，而是以 `SV-004F` 持续守住这条最小默认边界。**

当前最该优先继续推进的事，已经收敛为三条：

1. **继续把 `test-data-representatives` 视为跨机器硬默认 gate，并把它保持为所有升级动作的稳定前提**
   - 当前主线判断统一优先依据 `gate-summary.json`、`risk-report.json`、`behavior-summary.json`
   - 任何新增命令、样本或验证步骤，都不应破坏这条默认路径的 agent 自主执行性
2. **把 `SV-004F` 作为当前唯一实际执行面：只维护 `pass/pass` 默认行为边界、固定输出目录与 oracle ↔ `.ll` 同步护栏**
   - 默认执行面只保留 `test_fast_math_select`（compute-first）与 `test_intrinsic_vector_icmp_zext`（render-second）
   - `SV-004` 的第一阶段目标已经达成；当前继续保留 `ONGOING`，仅表示 `SV-004F` 这条守护任务仍在持续
   - `test_casts` 的详细修复经过、`test_intrinsic_vector_icmp_zext` 的旧 fail 收口过程，以及更早的批量背景统一下沉到 `07-首轮基线与历史进展归档.md` 与 `08-当前代表集与Gate契约参考.md`（参考信息，当前主线推进**不必须读取**）
   - `test_struct_array_field` 继续作为 blocked sample 停在离线层，不直接抬进行为测试或 live
3. **继续把 `SV-005` 保持为严格后置 gate**
   - 只有当 L3 证据不足、或风险只会在 runtime / live 结构里暴露时，才允许升级
   - 若涉及 GUI / 登录 / 工作区外修改，必须先得到用户确认

当前已确认、且和当前控制面直接相关的结果可概括为：

- `test-data-representatives` 当前保持 `8/8` round-trip 成功，风险分布为 `L0 = 2 / L1 = 3 / L2 = 2 / L3 = 1`，`gate-summary.json = WARN`
- `layeredDecision.overallDecision` 继续为 `promote_l2_candidates_to_l3`；当前 `l3Plan.candidateSampleKeys` 仍是 `test_fast_math_select`、`test_intrinsic_vector_icmp_zext`
- `test_casts` 当前已进入 `resolvedL2SampleKeys`，`test_struct_array_field` 当前仍是 `blocked sample`
- `behavior-summary.json` 当前状态为 `pass`：默认实际执行 `2` 个样本，且结果均为 `pass`
- `layeredDecision.l4Plan` 当前已能正确消费同目录 `behavior-summary.json`：`missingBehaviorEvidenceSampleKeys` 为空，后置阻塞只剩真实仍未解除的 blocked sample
- 更细的本机增强入口、baseline snapshot、preset / gate 细节、定向 `test_casts` 复核，以及旧 fail 解释均已下沉到 `07-首轮基线与历史进展归档.md` 与 `08-当前代表集与Gate契约参考.md`（均为参考，当前主线推进**不必须读取**）

因此当前最高优先级已经进一步收窄为：**继续守住 `test-data-representatives` 的默认 gate、`SV-004F` 的 `pass/pass` 最小行为边界，以及 sample oracle 与 `.ll` 的同步性；只要本地离线证据已经足够，就不要为了覆盖率去抢跑 `SV-005` 或盲目扩样。**

### 当前不该抢跑的事

在 `SV-004` 的首版 behavior harness 已落地、且当前默认执行边界已经收口为 `pass/pass`、live 仍保持严格后置 gate 前，默认**不要**把精力放到：

- 为覆盖率而扩样
- 大规模 live `.gputrace` 验证或高成本 GUI/Accessibility 操作
- 需要用户频繁登录 / 摆场景 / 点按钮的流程
- 因为当前机器缺少本地样本，就把 fresh capture / 手工准备环境写回日常 gate
- 仅因为 `preset-manifest.json` 或 gate profile 的旧描述文字滞后，就反推当前活跃 debt 仍是旧口径

除非它们是为解除当前最高优先级阻塞所**绝对必要**的最小步骤，且已获得用户确认。

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：文档、离线脚本、`IRToMSLConverter`、compare 逻辑、最小样本。

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

- 其它 preset 变体（`daily-default` / `local-corpus-representatives` / `test-data-batch`）、baseline snapshot 保存/复用，以及固定输出目录约定，统一下沉到 `08-当前代表集与Gate契约参考.md`（工作参考，当前主线推进**不必须读取**）；主文档只保留日常硬默认入口，避免把本机快照与较早批量口径重新暴露回控制面

### `SV-004` 当前最小行为验证

适用于：需要把 `layeredDecision.l3Plan.candidateSampleKeys` 里的活跃 `L2` 候选推进到第一批本地行为证据时；当前默认会覆盖 compute-first 与已准入的最小 render-second。

```bash
python3 Scripts/test_ir_semantics_behavior_runner.py
python3 Scripts/ir_semantics_behavior_runner.py --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json
```

当前首轮口径：

- 默认直接复用固定输出目录里的 `gate-summary.json` / `roundtrip-summary.json`
- 默认会把 `behavior-summary.json` 与 `behavior-artifacts/` 直接写回同一 `outputRoot`，即 `build/semantics-validation/roundtrip/test-data-representatives/`
- 当前默认执行样本已稳定为 `test_fast_math_select` 与 `test_intrinsic_vector_icmp_zext`
- 当前默认观测结果为：`test_fast_math_select = pass`、`test_intrinsic_vector_icmp_zext = pass`
- 若需要复核本轮修复是否真正消除了历史 fail evidence，可用 `--sample-key test_casts --report-file build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.test-casts-verification.json` 定向生成复核报告；当前结果已是 `pass`
- 更细的 artifact 字段、前置产物契约与定向复核入口说明，统一见 `05-L3-最小行为测试.md` 与 `08-当前代表集与Gate契约参考.md`（均为工作参考；当前主线推进前者**建议读取**，后者**不必须读取**）

补充约束：

- `SV-004` 当前必须继续保持“单命令、本地、无 UI、无工作区外修改、agent 可独立执行”的自动化边界；若新增方法做不到这点，就不能写回日常默认流程
- `ShaderCorpus` 日常 gate 默认只复用**当前机器上已经存在**的本地样本
- 若当前机器上没有合适样本，不应自动升级成需要用户介入的 fresh capture 流程；这时应优先退回 `test-data-representatives` 或停在离线层汇报
- `daily-default` / `local-corpus-representatives` 的定位是“增强证据”，不是把人工准备环境重新引回默认 gate
- 对这两个 preset，`gate profile` 应区分 `minimumExpectedJobCount`（硬下界）与 `expectedJobCount`（完整代表集）；低于下界或超出代表集边界才记为 `FAIL`，仅缺少部分本地代表样本时记为 `WARN`
- `SV-003` 当前已完成“固定样本集 + 固定命令 + 固定输出目录 + `gate-summary.json` / `--enforce-gate`”的首轮收口；剩余工作已收窄到继续维护代表集，并按后续经验继续细化升级边界
- 当前首个 fragment 候选已证明可以满足“offscreen、单命令、本地、无 UI、无工作区外修改”并进入 render-second；后续若要扩到更多 fragment 样本，也必须继续满足这条准入契约，否则仍应明确 deferred，而不是默认升级到 live

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
2. 严格按优先级选取最高优先级的 **一个** 未完成任务执行；若存在更细的未完成子任务，优先以子任务为实际执行面
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新子任务到 TODO，再只完成其中一个
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-000 | 现状调研与缺口梳理 | ✅ DONE | - | 已确认当前没有严格语义闭环，且 active gap 已从“有没有 L1/L2”切换到“怎样把它们稳定纳入默认 gate” | `01-现状调研与缺口.md` |
| SV-001 | 离线 IR round-trip harness | ✅ DONE | - | 已新增 `Scripts/ir_semantics_roundtrip_runner.py`；L1 当前的剩余价值主要体现在为 `SV-003` 提供固定入口与固定报告目录 | `03-L1-IR-RoundTrip.md` |
| SV-002 | Canonical compare + 风险分级 | ✅ DONE | - | 已新增 `Scripts/ir_canonical_compare.py`；L2 当前的剩余价值主要体现在为 `SV-003 / SV-006` 提供 `gate-summary.json` 与升级分流依据 | `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-003 | 把 L1/L2 接入 `test-data/` 与 `ShaderCorpus` | ONGOING | P1（守护） | 已从“建设新入口”转为“持续守住默认 gate 契约”：`test-data-representatives` 必须继续作为跨机器硬默认入口，`daily-default / local-corpus-representatives` 只保留为本地增强入口；代表集变化时同步维护 gate profile / baseline / manifest，并以 `gate-summary.json` / `risk-report.json` 作为当前事实口径 | `08-当前代表集与Gate契约参考.md` |
| SV-003A | 收紧默认 gate 的契约测试护栏 | ✅ DONE | - | 已为 `build_compare_result` / `build_preset_manifest` / `sample_identity` / gate job-count 边界与 known-debt improvement 补齐关键纯逻辑单测，降低默认入口语义漂移时的静默回归风险 | `00-Dashboard.md` |
| SV-003B | 把代表集边界显式写入 `preset-manifest.json` | ✅ DONE | - | 已让 manifest 同步记录 preset 期望代表集、已匹配样本、缺失本地代表样本与意外新增 discovered jobs，降低 `daily-default / local-corpus-representatives` 在跨机器执行时的心智负担 | `00-Dashboard.md` |
| SV-003C | 收口代表集与 gate 契约的单一来源 | ✅ DONE | - | 已把 `test-data` / `ShaderCorpus` 代表样本及其 `allowed failure / allowed L2 / allowed blocked` 元数据收口到 runner 内的单一契约定义，`preset` / `gate profile` / manifest 期望边界统一从该定义推导，并补充同步性单测 | `00-Dashboard.md` |
| SV-003D | 收敛 `test_struct_array_field` 并同步 debt 形态 | ✅ DONE | - | 已修复 direct entry metadata / `struct_type_info` 误解析与 buffer addrspace 回退问题，使该样本从 compile blocker 收敛为 round-trip 成功；同步把 `test-data` 代表 gate 合同从 allowed compile failure 切换为 allowed blocked sample，恢复 `test-data-representatives --enforce-gate` 的稳定 `WARN` | `00-Dashboard.md` |
| SV-006 | 分层 gate 与止损策略 | ✅ DONE | - | 已把 `risk-report.json` 里的 `samplesForL3` / `blockedSamples` 收口为 `gate-summary.json` 内的 `layeredDecision`：明确产出 `overallDecision`、`stopAtL2`、`l3Plan`、`l4Plan`，使“停在 L2 / 升级到 L3 / 延后到 L4”的边界机器可读且默认仍保持 automation-first | `02-总体技术路线.md` |
| SV-004 | 最小行为测试（compute-first + render-second） | ONGOING | P0（主线集合） | **当前主线集合。** 首版 compute-first 与最小 offscreen render-second 已落地，`SV-004` 第一阶段目标已经达成；当前继续保留 `ONGOING`，仅表示以下面的 `SV-004F` 作为唯一实际执行面，持续维持收缩后的默认行为证据边界 | `05-L3-最小行为测试.md` |
| SV-004A | 落地首版 compute-only behavior harness | ✅ DONE | - | 已新增 `Scripts/ir_semantics_behavior_runner.py`、`Scripts/metal_compute_behavior_runner.swift` 与 `Scripts/test_ir_semantics_behavior_runner.py`，让 `SV-004` 可以直接消费 `gate-summary.json` 的活跃 `L2` 候选并产出结构化 `behavior-summary.json` | `05-L3-最小行为测试.md` |
| SV-004B | 解释并收口 `test_casts` 的 fail evidence | ✅ DONE | - | 已定位根因在 `IRToMSLConverter` 对 `air.convert` 的 unsigned 语义恢复不足；修复后 `test_casts` 已通过定向 `behavior-summary.test-casts-verification.json` 复核，并从 `gate-summary.json` 的活跃 `L2` 候选退出 | `05-L3-最小行为测试.md` |
| SV-004C | 维持收缩后的 L3 候选边界 | ✅ DONE | - | 已先把默认执行面稳定收口为 compute-first 主入口：`build_behavior_plan()` 会按 `executionKind` / `shape-drift` 护栏只放行 compute 候选，`Scripts/test_ir_semantics_behavior_runner.py` 也已补齐针对该收缩边界的纯逻辑回归测试；`test_casts` 仅保留为显式 `--sample-key` 的定向复核入口。随后 `SV-004D` 再把 `test_intrinsic_vector_icmp_zext` 从 `deferred` 推进为已准入的 render-second 执行面 | `05-L3-最小行为测试.md` |
| SV-004D | 收口剩余 fragment 候选的 render-second 准入契约 | ✅ DONE | - | 已新增 `Scripts/metal_fragment_behavior_runner.swift`，并让 `Scripts/ir_semantics_behavior_runner.py` / `Scripts/test_ir_semantics_behavior_runner.py` 共同支持最小 offscreen render-second；`test_intrinsic_vector_icmp_zext` 现已通过固定 `4x4` `rgba16Float` 离屏 render 进入实际执行面，随后 `SV-004E` 再把旧 `fail` 收口为 sample oracle 漂移 | `05-L3-最小行为测试.md` |
| SV-004E | 解释 render-second 下的 fragment fail evidence | ✅ DONE | - | 已确认 `test_intrinsic_vector_icmp_zext` 的旧 `fail` 并不是 `IRToMSLConverter` lowering 偏移，而是 `test-data` reference sample 与 `.ll` 输出语义漂移；把 `cmp/zext` 真正接回可观察输出并复跑后，`behavior-summary.json` 与 artifact 已回到稳定 `pass` | `05-L3-最小行为测试.md` |
| SV-004F | 维持默认行为边界与 oracle 同步护栏 | ONGOING | P0（当前执行面） | 继续把 `test_fast_math_select = pass`、`test_intrinsic_vector_icmp_zext = pass`、固定输出目录，以及 reference/generated MSL ↔ `.ll` 的同步校验保持为默认 L3 边界；除非新增候选仍满足单命令、本地、无 UI、无工作区外修改，否则不扩样、不抢跑 `SV-005` | `05-L3-最小行为测试.md` |
| SV-005 | 真实场景验证流程收口 | TODO | P2 | 把 `.gputrace` / render diff / MCP live 验证收口成严格后置 gate；只有在 `SV-004F` 的纯离线证据仍不足或风险只会在 runtime/live 中暴露时才允许升级，且不得回流为日常默认流程 | `06-L4-真实场景验证.md` |

### 当前关键状态

- **默认离线控制面已经收口**：`test-data-representatives` 继续是跨机器硬默认 gate；`daily-default / local-corpus-representatives` 继续只作为本机增强入口
- **`SV-004` 的第一阶段目标已经达成**：当前继续保留 `ONGOING`，仅表示 `SV-004F` 这条守护任务仍在持续；默认执行面固定为 `test_fast_math_select` + `test_intrinsic_vector_icmp_zext`
- **当前事实来源必须分层**：`gate-summary.json` > `risk-report.json` > `behavior-summary.json` / `behavior-summary.*.json` > `roundtrip-summary.json` > `preset-manifest.json` 的描述文字
- **真实场景验证仍是后置 gate**：若未来确实需要用户介入，必须先把步骤压到最小并征得确认

## 踩坑与经验

- **compile green 不等于语义等价**
- **`.gputrace` 可见源码不等于最终行为无差异**
- **先做离线，再做 live**；live 只用于阶段性确认，不做默认主战场
- **不要把“文本完全一样”误当成“语义一样”**；后续比较应以 canonical summary + 风险分级为主
- **第一版 canonical compare 必须主动降噪**：SSA 名称、metadata 编号、`bufferSize` 缺失、`readonly/readnone` 这类编译器优化后常见变化，不应直接视为 L3
- **要把 `air.fast_*` intrinsic alias 与纯 instruction-level fast-math flag 漂移视为降噪对象**：若 compile option 与 function attr 没变，这类差异更接近 `L1` 噪声，而不应继续把代表集里的默认 debt 放大成 `L2`
- **对环境相关代表集，job count 不能只用单点值判定**：要区分“跨机器都必须成立的硬下界”和“本机样本齐备时的完整代表集”，否则容易把缺样本误报成回归
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **L3 第一版优先复用 reference MSL vs generated MSL 对跑，比一上来就建立完整 CPU oracle 更容易在低人力预算下落地**
- **要区分“背景问题”和“当前主线”**：本目录当前最该做的是守住稳定离线 gate，并只对少量高价值候选维持最小升级判断、优先维护已收口的 fragment 行为边界，而不是过早切到更高成本的运行时验证
- **主文档不要直接暴露会漂移的本机快照**：本机增强入口、历史批量快照、manifest 描述文字等都应下沉到参考文档，主文档只保留当前主线真正依赖的控制面事实

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“为什么当前主线仍停在离线层”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；主线任务与升级顺序的核心参考）
- `03-L1-IR-RoundTrip.md`（做 L1 / runner / preset 维护时再读，当前日常推进**不必须读取**）
- `04-L2-CanonicalCompareAndRiskGrading.md`（做 compare / gate / 风险分级时再读，当前日常推进**不必须读取**）
- `05-L3-最小行为测试.md`（**建议读取**；当前主线 `SV-004` 的详细执行面）
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
