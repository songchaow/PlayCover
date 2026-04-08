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
- 如何基于现有 **gate-summary / risk-report / preset-manifest**，明确写清楚 **停在 L2 / 升级到 L3 / 升级到 L4** 的机器可执行边界
- 如何在不引入人工依赖的前提下，只从最有信息量的样本里为 **L3 最小行为测试** 开一个足够小的入口
- 如何把 **真实场景验证** 保持为自动化优先、低人工依赖、且必须按需征得用户确认的严格后置 gate

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：立项初版关于“缺少 L1/L2”的历史表述已经下沉到 `01-现状调研与缺口.md` 与 `07-首轮基线与历史进展归档.md`；当前 dashboard 只保留 active gap 与当前控制面。

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

> **背景**：`SV-003` 的第一轮收口与 `SV-006` 的 `layeredDecision` 控制面已经落地后，本目录主线已经不是“继续扩入口”，而是“把升级/止损规则真正驱动成最小行为证据”。当前应把 `SV-003` 继续当作长期守护约束，把 `SV-004` 明确为唯一主线执行面：先用纯离线、compute-first、agent 可自主完成的方式解释已有 `L2` 候选里的真实信息量，再决定是否需要 render-second 或更后置的 `SV-005`。

**`SV-004`：在 `SV-006` 已明确升级边界的前提下，只从活跃 `L2` 候选集中挑极少量最有信息量的样本进入 compute-first 的最小行为测试，并优先把第一批 fail/deferred 证据收口成 machine-actionable 结论。**

当前最该优先继续推进的事，已经收窄为四条：

1. **继续把 `test-data-representatives` 视为跨机器硬默认 gate，但把它保持为所有升级动作的稳定前提，而不是下一阶段的唯一交付物**
   - 它仍是最稳定、最不依赖外部环境的日常 gate
   - 任何新增命令、样本或行为测试入口，都不应破坏这条默认路径的 agent 自主执行性
2. **让 `SV-004` 继续围绕收缩后的首批证据推进：确认 `test_casts` 已完成收口，并只维护剩余活跃候选的 compute-first / render-second 边界**
   - 当前硬默认 gate 的 `overallDecision` 仍稳定为 `promote_l2_candidates_to_l3`
   - 首版入口已落地到 `Scripts/ir_semantics_behavior_runner.py` + `Scripts/metal_compute_behavior_runner.swift`
   - 本轮已把 `test_casts` 的分歧收口成 machine-actionable 结论：根因是 `IRToMSLConverter` 对 `air.convert.u.*` / `air.convert.*.u.*` 的 unsigned 语义恢复不足；修复后它已从活跃 `L2` 候选退出，并通过定向行为复核
   - 当前默认候选只剩 `test_fast_math_select` 与 `test_intrinsic_vector_icmp_zext`；其中后者因为是 fragment 样本，继续后置到 render-second；`test_struct_array_field` 继续作为 blocked sample 停在离线层，不直接抬进行为测试或 live
3. **继续把 `daily-default` / `local-corpus-representatives` 明确为“本机已有样本时的增强入口”，而不是日常强依赖**
   - 这两条入口可以帮助分层，但不能倒逼 fresh capture、人工准备环境或用户协助成为默认前提
   - `minimumExpectedJobCount + expectedJobCount` 的双边界仍应继续保留，防止缺少本地样本时误报回归
4. **继续把进入 L4 的触发条件和用户确认边界保持为严格后置 gate**
   - 只有当 L3 证据不足、或风险只会在 runtime / live 结构里暴露时，才允许升级
   - 若涉及 GUI / 登录 / 工作区外修改，必须先得到用户确认

当前已确认、且和当前控制面直接相关的结果可概括为：

- `test-data-representatives`：当前最新代表产物保持 `8/8` round-trip 成功，风险分布已收敛为 `L0 = 2 / L1 = 3 / L2 = 2 / L3 = 1`，`gate-summary.json` 继续稳定为 `WARN`
- 同一份代表产物里，`layeredDecision.overallDecision = promote_l2_candidates_to_l3` 保持不变，但 `l3Plan.candidateSampleKeys` 已收缩为 `test_fast_math_select`、`test_intrinsic_vector_icmp_zext`
- `gate-summary.json` 当前已把 `test_casts` 记为 `resolvedL2SampleKeys`，说明它不再属于活跃 `L2` debt，而是本轮已收口的已知改进
- `behavior-summary.json` 的当前默认执行面也随之收缩：compute-first 只实际执行 `test_fast_math_select`，并将 `test_intrinsic_vector_icmp_zext` 结构化后置到 render-second
- 定向复核产物 `behavior-summary.test-casts-verification.json` 已显示 `test_casts` 的 scalar / vector `2/2` case 全部通过；因此这条证据已从“可复现 fail”收口为“已定位根因并完成最小修复验证”
- `Scripts/test_ir_semantics_behavior_runner.py` 已为 candidate 选择、defer 边界与 `behavior-summary.json` 汇总补齐纯逻辑单测，降低 `SV-004` 后续维护时的静默漂移风险
- `blockedSamples` 当前仍只包含 `test_struct_array_field`，它会继续被 `stopAtL2` / `l4Plan` 明确挡在离线层与后置 gate 之前
- `daily-default`：当前最新增强产物是 `13/13` round-trip 成功，风险分布 `L0 = 1 / L1 = 3 / L2 = 5 / L3 = 4`，`gate-summary.json` 为稳定 `WARN`
- `local-corpus-representatives`：当前固定 `5` 个本地 `ShaderCorpus` 代表样本全部 round-trip 成功，风险分布 `L0 = 0 / L1 = 0 / L2 = 1 / L3 = 4`，`gate-summary.json` 为稳定 `WARN`
- 仓库里保留的 `test-data-batch` 目录当前仍是一份较早批量参考快照：`27` 个样本中 `26` 个 round-trip 成功、`1` 个 compile 失败，风险分布 `L0 = 1 / L1 = 3 / L2 = 3 / L3 = 20`；它只承担**参考批量基线**角色，不能再用来描述当前默认 gate 的 active 口径
- 更细的 preset contract、gate profile、baseline snapshot 与 manifest 摘要已下沉到 `08-当前代表集与Gate契约参考.md`（工作参考，当前主线推进**不必须读取**）

因此当前最高优先级已经切换为 `SV-004`，因为它直接决定：

- `SV-006` 产出的 `layeredDecision` 能否真正喂给第一批 compute-first 行为测试，而不是停留在文档层
- 是否能只从最有信息量的极少量样本起步，而不是被批量 `L3` 噪声带偏
- `SV-005` 能否继续保持严格后置，而不把 live / 人工依赖重新写回默认主线
- `SV-003` 的既有默认入口，能否继续作为所有升级动作的稳定基础

### 当前不该抢跑的事

在 `SV-004` 的首版 compute-only behavior harness 已落地、但 render-second / live 后置链路仍未形成前，默认**不要**把精力放到：

- 大规模 live `.gputrace` 验证
- 高成本 GUI/Accessibility 操作
- 需要用户频繁登录/摆场景/点按钮的流程
- 工作区外静态分析、外部二进制 patch、手动逆向
- 因为本地暂时没有现成 `ShaderCorpus` 样本，就把“fresh capture / 手工准备环境”硬写进日常 gate

除非它们是为解除当前最高优先级阻塞所**绝对必要**的最小步骤，且已获得用户确认。

## 构建与验证方法

> 原则：**默认 gate 必须是 agent 可独立、自动完成的。** 若某步必须人工介入，先压缩到最小，再明确向用户汇报并等待确认。

### 日常默认验证（优先）

适用于：文档、离线脚本、`IRToMSLConverter`、compare 逻辑、最小样本。

- 已有离线 replay / compile：

```bash
python3 Scripts/corpus_replay_runner.py --compile --ll <sample.ll>
```

- 已有 PlayTools 构建守门（**仅在改动涉及 `IRToMSLConverter` / PlayTools 构建产物时执行**；文档整理或纯 compare/gate 调整不必附带重建）：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

- **跨机器硬默认 gate**（优先保证这条始终可由 agent 自主执行）：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

- **本机已有 `ShaderCorpus` 样本时的一键增强入口**（runner 内建 daily preset，但不是跨机器硬默认）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset daily-default --allow-failures --enforce-gate
```

- 若只想看本机已存在的本地 `ShaderCorpus` 代表集，使用固定本地入口：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset local-corpus-representatives --allow-failures
```

- 若需要完整 `test-data/` 批量基线，使用固定全量入口（参考批量，不属于日常默认 gate）：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-batch --allow-failures
```

- 若要把固定 preset 的当前结果固化成可复用 baseline：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate --save-baseline build/semantics-validation/roundtrip/test-data-representatives
```

- 后续对同一固定输出目录再次执行时，若目录下已存在 `baseline.json`，runner 会默认自动复用它做 replay baseline diff；也可用 `--baseline-report <path>` 显式指定其他 baseline

### `SV-004` 首版 compute-first 行为验证

适用于：需要把 `layeredDecision.l3Plan.candidateSampleKeys` 里的活跃 `L2` 候选推进到第一批本地行为证据时。

```bash
python3 Scripts/test_ir_semantics_behavior_runner.py
python3 Scripts/ir_semantics_behavior_runner.py --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json
```

当前首轮口径：

- 默认直接复用固定输出目录里的 `gate-summary.json` / `roundtrip-summary.json`
- 当前默认执行样本已收缩为 `test_fast_math_select`
- `test_intrinsic_vector_icmp_zext` 因为是 fragment 样本，会被结构化记为 deferred，而不会误抬进 compute-only harness
- 当前默认观测结果为：`test_fast_math_select = pass`、`test_intrinsic_vector_icmp_zext = deferred`
- 若需要复核本轮修复是否真正消除了历史 fail evidence，可用 `--sample-key test_casts` 定向生成 `behavior-summary.test-casts-verification.json`；当前结果已是 `pass`

这条命令的前置依赖是**已存在的** L1/L2 固定产物：

- `replay-summary.json`
- `compile-summary.json`
- `roundtrip-summary.json`
- `compare-summary.json`
- `risk-report.json`
- `high-risk-samples.json`
- `gate-summary.json`
- `preset-manifest.json`

这条命令本身新增产物：

- `behavior-summary.json`
- `behavior-artifacts/<sample>.spec.json`
- `behavior-artifacts/<sample>.result.json`

补充约束：

- `SV-004` 当前必须继续保持“单命令、本地、无 UI、无工作区外修改、agent 可独立执行”的自动化边界；若新增方法做不到这点，就不能写回日常默认流程
- `ShaderCorpus` 日常 gate 默认只复用**当前机器上已经存在**的本地样本
- 若当前机器上没有合适样本，不应自动升级成需要用户介入的 fresh capture 流程；这时应优先退回 `test-data-representatives` 或停在离线层汇报
- `daily-default` / `local-corpus-representatives` 的定位是“增强证据”，不是把人工准备环境重新引回默认 gate
- 对这两个 preset，`gate profile` 应区分 `minimumExpectedJobCount`（硬下界）与 `expectedJobCount`（完整代表集）；低于下界或超出代表集边界才记为 `FAIL`，仅缺少部分本地代表样本时记为 `WARN`
- `SV-003` 当前已完成“固定样本集 + 固定命令 + 固定输出目录 + `gate-summary.json` / `--enforce-gate`”的首轮收口；剩余工作已收窄到继续维护代表集，并按后续经验继续细化升级边界

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
2. 严格按优先级选取最高优先级的 **一个** 未完成任务执行
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新子任务到 TODO，再只完成其中一个
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-000 | 现状调研与缺口梳理 | ✅ DONE | - | 已确认当前没有严格语义闭环，且 active gap 已从“有没有 L1/L2”切换到“怎样把它们稳定纳入默认 gate” | `01-现状调研与缺口.md` |
| SV-001 | 离线 IR round-trip harness | ✅ DONE | - | 已新增 `Scripts/ir_semantics_roundtrip_runner.py`；L1 当前的剩余价值主要体现在为 `SV-003` 提供固定入口与固定报告目录 | `03-L1-IR-RoundTrip.md` |
| SV-002 | Canonical compare + 风险分级 | ✅ DONE | - | 已新增 `Scripts/ir_canonical_compare.py`；L2 当前的剩余价值主要体现在为 `SV-003 / SV-006` 提供 `gate-summary.json` 与升级分流依据 | `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-003 | 把 L1/L2 接入 `test-data/` 与 `ShaderCorpus` | ONGOING | P0（守护） | 已从“建设新入口”转为“持续守住默认 gate 契约”：`test-data-representatives` 必须继续作为跨机器硬默认入口，`daily-default / local-corpus-representatives` 只保留为本地增强入口；代表集变化时同步维护 gate profile / baseline / manifest | `08-当前代表集与Gate契约参考.md` |
| SV-003A | 收紧默认 gate 的契约测试护栏 | ✅ DONE | - | 已为 `build_compare_result` / `build_preset_manifest` / `sample_identity` / gate job-count 边界与 known-debt improvement 补齐关键纯逻辑单测，降低默认入口语义漂移时的静默回归风险 | `00-Dashboard.md` |
| SV-003B | 把代表集边界显式写入 `preset-manifest.json` | ✅ DONE | - | 已让 manifest 同步记录 preset 期望代表集、已匹配样本、缺失本地代表样本与意外新增 discovered jobs，降低 `daily-default / local-corpus-representatives` 在跨机器执行时的心智负担 | `00-Dashboard.md` |
| SV-003C | 收口代表集与 gate 契约的单一来源 | ✅ DONE | - | 已把 `test-data` / `ShaderCorpus` 代表样本及其 `allowed failure / allowed L2 / allowed blocked` 元数据收口到 runner 内的单一契约定义，`preset` / `gate profile` / manifest 期望边界统一从该定义推导，并补充同步性单测 | `00-Dashboard.md` |
| SV-003D | 收敛 `test_struct_array_field` 并同步 debt 形态 | ✅ DONE | - | 已修复 direct entry metadata / `struct_type_info` 误解析与 buffer addrspace 回退问题，使该样本从 compile blocker 收敛为 round-trip 成功；同步把 `test-data` 代表 gate 合同从 allowed compile failure 切换为 allowed blocked sample，恢复 `test-data-representatives --enforce-gate` 的稳定 `WARN` | `00-Dashboard.md` |
| SV-006 | 分层 gate 与止损策略 | ✅ DONE | - | 已把 `risk-report.json` 里的 `samplesForL3` / `blockedSamples` 收口为 `gate-summary.json` 内的 `layeredDecision`：明确产出 `overallDecision`、`stopAtL2`、`l3Plan`、`l4Plan`，使“停在 L2 / 升级到 L3 / 延后到 L4”的边界机器可读且默认仍保持 automation-first | `02-总体技术路线.md` |
| SV-004 | 最小行为测试（compute-first） | ONGOING | P0（主线） | **当前主线。** 首版 compute-only harness 已能直接复用 `layeredDecision.l3Plan.candidateSampleKeys` 生成 `behavior-summary.json`；本轮已把 `test_casts` 从“行为 fail + 活跃 L2 候选”收口为“已修复并完成定向复核”，当前默认执行面已收缩为 `test_fast_math_select = pass` 与 `test_intrinsic_vector_icmp_zext = deferred` | `05-L3-最小行为测试.md` |
| SV-004A | 落地首版 compute-only behavior harness | ✅ DONE | - | 已新增 `Scripts/ir_semantics_behavior_runner.py`、`Scripts/metal_compute_behavior_runner.swift` 与 `Scripts/test_ir_semantics_behavior_runner.py`，让 `SV-004` 可以直接消费 `gate-summary.json` 的活跃 `L2` 候选并产出结构化 `behavior-summary.json` | `05-L3-最小行为测试.md` |
| SV-004B | 解释并收口 `test_casts` 的 fail evidence | ✅ DONE | - | 已定位根因在 `IRToMSLConverter` 对 `air.convert` 的 unsigned 语义恢复不足；修复后 `test_casts` 已通过定向 `behavior-summary.test-casts-verification.json` 复核，并从 `gate-summary.json` 的活跃 `L2` 候选退出 | `05-L3-最小行为测试.md` |
| SV-004C | 维持收缩后的 L3 候选边界 | ✅ DONE | - | 已把默认执行面稳定收口为 `test_fast_math_select = pass`、`test_intrinsic_vector_icmp_zext = deferred`：`build_behavior_plan()` 会按 `executionKind` / `shape-drift` 护栏只放行 compute 候选，`Scripts/test_ir_semantics_behavior_runner.py` 也已补齐针对当前收缩边界的纯逻辑回归测试；`test_casts` 仅保留为显式 `--sample-key` 的定向复核入口 | `05-L3-最小行为测试.md` |
| SV-005 | 真实场景验证流程收口 | TODO | P2 | 把 `.gputrace` / render diff / MCP live 验证收口成严格后置 gate；只有在 `SV-004` 证据仍不足或风险只会在 runtime/live 中暴露时才允许升级，且不得回流为日常默认流程 | `06-L4-真实场景验证.md` |

### 当前关键卡点

- **首版行为级 oracle 已落地，且首个 fail evidence 已完成收口**：`test_fast_math_select` 已通过 reference-vs-generated 对跑，`test_casts` 已通过修复 `IRToMSLConverter` 的 `air.convert` unsigned 语义恢复逻辑完成收敛，而 `test_intrinsic_vector_icmp_zext` 仍因 fragment 形态后置到 render-second；`SV-004` 当前已进入“维持收缩后的候选边界、避免抢跑更高成本验证”的阶段
- **`SV-003` 现在更像长期守护约束，而不是新的功能建设任务**：必须持续保证 `test-data-representatives` 是跨机器硬默认，`daily-default / local-corpus-representatives` 只是本地增强入口，避免把人工准备环境重新写回日常 gate
- **`test_struct_array_field` 的当前口径必须和较早批量快照分开**：在硬默认 gate 中它已是 blocked sample，但仓库里保留的 `test-data-batch` 参考快照仍把它记成 compile failure；若不分层表述，文档就会继续自相矛盾
- **真实场景验证成本高且可能引入人工步骤**：`SV-006` 已把 L4 明确收口为后置 gate，但若未来确实需要用户介入，仍必须先压缩到最小步骤并征得确认

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
- **要区分“背景问题”和“当前主线”**：本目录当前最该做的是守住稳定离线 gate，并优先把首批 `L3` fail/deferred evidence 收口清楚，而不是过早切到更高成本的运行时验证

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“为什么当前主线仍停在离线层”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；主线任务与升级顺序的核心参考）
- `03-L1-IR-RoundTrip.md`（做 L1 / runner / preset 维护时再读，当前日常推进**不必须读取**）
- `04-L2-CanonicalCompareAndRiskGrading.md`（做 compare / gate / 风险分级时再读，当前日常推进**不必须读取**）
- `05-L3-最小行为测试.md`（**建议读取**；当前主线 `SV-004` 的详细执行面）
- `06-L4-真实场景验证.md`（规划 live / `.gputrace` 时再读，当前**不必须读取**）
- `07-首轮基线与历史进展归档.md`（历史归档与样本名单参考，**不必须读取**）
- `08-当前代表集与Gate契约参考.md`（维护 preset / gate / manifest 细节时再读，当前主线推进**不必须读取**）

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
