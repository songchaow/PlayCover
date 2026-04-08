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

- 没有离线 **IR round-trip** 验证
- 没有统一的 **canonical compare / 风险分级**
- 没有稳定的 **最小行为测试体系**
- 没有把 **真实场景验证** 收敛成自动化优先、低人工依赖的后置 gate

因此需要在本目录下建立一套**循序渐进、自动化优先、可按人力/上下文预算逐步停下**的语义验证体系。

> 注：以上四条是本专项立项时的原始缺口描述。结合 2026-04-08 最近三次提交回看，前两条（L1/L2）已经完成首版落地；当前 active gap 已切换到“如何把 L1/L2 变成稳定日常 gate，并为 L3/L4 做好入口控制”。

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

> **背景**：前置任务已经把采集、replay、compile 与运行时验证链路逐步铺开；当前这里最值得继续推进的任务仍然是 `SV-003`，因为它能把已落地的 L1/L2 变成真正可复用、可止损、可日常执行的证据链。

**`SV-003`：把已落地的 L1/L2 能力继续接入更稳定的 `test-data/` 日常 gate，并扩到代表性 `ShaderCorpus` 样本。**

`SV-002` 已在本轮完成，当前已新增/打通：

- 已新增 `Scripts/ir_semantics_roundtrip_runner.py`
- 已新增 `Scripts/ir_canonical_compare.py`
- 已新增 `Scripts/test_ir_canonical_compare.py`
- 已更新 `Scripts/test_ir_semantics_roundtrip_runner.py`
- `roundtrip runner` 当前已支持：
  - `--ll` 显式样本
  - `--corpus-root`
  - `--bundle-id`
  - `--module-key`
  - `--limit`
  - `--allow-failures`
  - 自动解析 `llvm-dis` 路径（优先 PlayCover 容器，再尝试 PATH / Homebrew / 系统路径）
- `roundtrip runner` 当前默认会一起产出：
  - `replay-summary.json`
  - `compile-summary.json`
  - `roundtrip-summary.json`
  - `compare-summary.json`
  - `risk-report.json`
  - `high-risk-samples.json`
  - `gate-summary.json`
- 已对 `test-data/` 跑通首轮 L1/L2 批量报告：`build/semantics-validation/roundtrip/test-data-batch/`
- 本轮已为 `SV-003` 落地固定入口：
  - `--preset test-data-representatives`
  - `--preset test-data-batch`
  - `--preset local-corpus-representatives`
  - `--preset daily-default`
- 本轮已新增第一版 stable gate 收口：
  - `--gate-profile <name>`（可显式指定 gate profile；若 preset 存在同名 profile，则自动复用）
  - `--enforce-gate`（仅当出现新增 round-trip / L3 回归时阻断退出）
  - `gate-summary.json`（输出 `pass / warn / fail`、活跃已知 debt 与新增回归样本）
- 当前固定输出目录已收口到：
  - `build/semantics-validation/roundtrip/test-data-representatives/`
  - `build/semantics-validation/roundtrip/test-data-batch/`
  - `build/semantics-validation/roundtrip/local-corpus-representatives/`
  - `build/semantics-validation/roundtrip/daily-default/`
- 本轮已验证：
  - `test-data-representatives`：`8` 个样本中 `7` 个 round-trip 成功、`1` 个 compile 失败，风险分布 `L0 = 1 / L1 = 1 / L2 = 5 / L3 = 1`
  - `local-corpus-representatives`：当前固定 `5` 个本地 `ShaderCorpus` 代表样本全部 round-trip 成功，风险分布 `L0 = 0 / L1 = 0 / L2 = 1 / L3 = 4`
  - `daily-default`：`13` 个样本中 `12` 个 round-trip 成功、`1` 个 compile 失败，风险分布 `L0 = 1 / L1 = 1 / L2 = 6 / L3 = 5`
  - 三个代表 preset 在加上 `--enforce-gate` 后，当前都能稳定输出 `WARN`（保留已知 debt），不会把现有基线误判成 `FAIL`

当前 `test-data/` 首轮基线可概括为：

- **27 个样本中 26 个 round-trip 成功，1 个在 compile 阶段失败，llvm-dis 阶段 0 失败**
- **L2 风险分布：L0 = 1，L1 = 1，L2 = 5，L3 = 20**
- 详细样本名单、首次 smoke 目录和阶段性提交脉络已下沉到 `07-首轮基线与历史进展归档.md`

因此当前最高优先级已经切换到 `SV-003`，因为它：

- 能把已经落地的 L1/L2 从“单轮专项结果”推进到“可持续复用的日常 gate”
- 能把 `test-data/` 从“首轮跑通”推进到“固定代表集 + 固定命令 + 固定报告目录”的低心智负担工作流
- 是把 `test-data/` 经验扩展到代表性 `ShaderCorpus` 样本的最直接下一步
- 能帮助区分哪些 `L2/L3` 样本值得进一步聚类、收敛或进入 L3
- 能把前面已经铺好的能力沉淀成更低成本的离线风险筛查入口

### 当前不该抢跑的事

在 `SV-003` 未完成前，默认**不要**把精力放到：

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

- 已有 PlayTools 构建守门：

```bash
FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh
```

- 本专项当前默认 gate：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
python3 Scripts/ir_semantics_roundtrip_runner.py --preset daily-default --allow-failures --enforce-gate
```

- 若需要完整 `test-data/` 批量基线，使用固定全量入口：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-batch --allow-failures
```

- 若只想看本机已存在的本地 `ShaderCorpus` 代表集，使用固定本地入口：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset local-corpus-representatives --allow-failures
```

默认会继续产出：

- `replay-summary.json`
- `compile-summary.json`
- `roundtrip-summary.json`
- `compare-summary.json`
- `risk-report.json`
- `high-risk-samples.json`
- `gate-summary.json`

补充约束：

- `ShaderCorpus` 日常 gate 默认只复用**当前机器上已经存在**的本地样本
- 若当前机器上没有合适样本，不应自动升级成需要用户介入的 fresh capture 流程；这时应优先退回 `test-data/` 或停在离线层汇报
- `SV-003` 当前已完成“固定样本集 + 固定命令 + 固定输出目录 + `gate-summary.json` / `--enforce-gate`”的首轮收口；剩余工作已收窄到继续维护代表集，并按后续经验继续细化升级边界

### 运行时链路验证（只在必要时）

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

**禁止**手写 `xcodebuild` 替代标准脚本。

### 真实场景验证（后置 gate）

仅当 L1/L2 已基本收敛，且需要确认“真实 shader / 真实场景下没有明显退化”时才启用。

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
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。确保留给人工手动操作的步骤是最少最简单的状态。如果已达到该状态，则立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分到 TODO，再只完成其中一个
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## TODO 状态

| # | 任务 | 状态 | 优先级 | 说明 | 详细文档 |
|---|---|---|---|---|---|
| SV-000 | 现状调研与缺口梳理 | ✅ DONE | - | 已确认当前没有严格语义闭环，已形成总体路线 | `01-现状调研与缺口.md` |
| SV-001 | 离线 IR round-trip harness | ✅ DONE | - | 已新增 `Scripts/ir_semantics_roundtrip_runner.py`，并在 `test-data/` 首轮批量报告中得到 `26 / 27` round-trip 成功 | `03-L1-IR-RoundTrip.md` |
| SV-002 | Canonical compare + 风险分级 | ✅ DONE | - | 已新增 `Scripts/ir_canonical_compare.py`，并在 `test-data/` 上产出 `compare-summary.json / risk-report.json / high-risk-samples.json` | `04-L2-CanonicalCompareAndRiskGrading.md` |
| SV-003 | 把 L1/L2 接入 `test-data/` 与 `ShaderCorpus` | TODO | P0 | 已落地 preset 化固定入口、首组本地 `ShaderCorpus` 代表样本，以及 `gate-summary.json` / `--enforce-gate`；剩余工作是继续维护代表集 | `02-总体技术路线.md` |
| SV-004 | 最小行为测试（compute-first） | TODO | P2 | 优先建立 compute 输出对比，再决定是否补离屏 render | `05-L3-最小行为测试.md` |
| SV-005 | 真实场景验证流程收口 | TODO | P3 | 把 `.gputrace` / render diff / MCP live 验证收口成后置 gate | `06-L4-真实场景验证.md` |
| SV-006 | 分层 gate 与止损策略 | TODO | P1 | 明确“什么时候可以先停在 L2，什么时候必须升级到 L3/L4”的预算与升级规则 | `02-总体技术路线.md` |

### 当前关键卡点

- **`SV-003` 已完成首轮 preset + gate 收口，但还没有完全结束**：当前已经有 `test-data-representatives / test-data-batch / local-corpus-representatives / daily-default` 固定入口，以及 `gate-summary.json` / `--enforce-gate` 第一版 gate profile；剩余缺口是继续维护代表集，并在后续经验积累中继续细化升级边界
- **`test_struct_array_field` 仍是当前首个 compile-stage blocker**：当前 `test-data/` 批量 round-trip 中，27 个样本里仍只有它在 `generated.metal -> generated.air` 阶段失败
- **L2 已落地，但 `test-data/` 里仍有较多 `L3` 结构性不一致样本**：当前批量分布为 `L0 = 1 / L1 = 1 / L2 = 5 / L3 = 20`，下一步需要结合 `SV-003` 做样本聚类与代表集扩展
- **没有行为级 oracle**：当前报告能筛查风险，但还不能判断行为是否一致；`L2` 样本仍需后续 `L3` 最小行为测试承接
- **真实场景验证成本高**：应当继续严格后置，不能在 `SV-003 / SV-006 / SV-004` 未收敛时抢跑

## 踩坑与经验

- **compile green 不等于语义等价**
- **`.gputrace` 可见源码不等于最终行为无差异**
- **先做离线，再做 live**；live 只用于阶段性确认，不做默认主战场
- **不要把“文本完全一样”误当成“语义一样”**；后续比较应以 canonical summary + 风险分级为主
- **第一版 canonical compare 必须主动降噪**：SSA 名称、metadata 编号、`bufferSize` 缺失、`readonly/readnone` 这类编译器优化后常见变化，不应直接视为 L3
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **要区分“背景问题”和“当前主线”**：本目录当前最该做的是把 L1/L2 收口成稳定离线 gate，而不是过早切到更高成本的运行时验证

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`
- `02-总体技术路线.md`
- `03-L1-IR-RoundTrip.md`
- `04-L2-CanonicalCompareAndRiskGrading.md`
- `05-L3-最小行为测试.md`
- `06-L4-真实场景验证.md`
- `07-首轮基线与历史进展归档.md`

### 背景参考

- `../RoadE-HookMakeLibraryWithSrc/00-Dashboard.md`
- `../RoadE-HookMakeLibraryWithSrc/E-004-MetallibSourceExtraction.md`
- `../RoadE-HookMakeLibraryWithSrc/E-005-OfflineReplayBatchCompileDiff.md`
- `../RoadE-HookMakeLibraryWithSrc/E-006d-GenshinRenderingNondeterminism.md`
- `../RoadE-HookMakeLibraryWithSrc/E-006d-RenderingPathDiffReference.md`
- `../RoadE-HookMakeLibraryWithSrc/E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md`

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Scripts/corpus_replay_runner.py`
- `Scripts/ir_semantics_roundtrip_runner.py`
- `Scripts/ir_canonical_compare.py`
- `Scripts/test_ir_canonical_compare.py`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
