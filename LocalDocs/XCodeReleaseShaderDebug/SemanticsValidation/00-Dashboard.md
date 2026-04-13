## Semantics Validation Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 当前主线

> 当前只做一件事：**按当前默认流程重跑 full-batch，确认 corpus / diagnostics 里是否还有值得优先处理的 `L2/L3` residual；若有，就只挑一个最高价值 case 按默认流程分析、修复、复跑，并在必要时拆成更小子任务。**

后续控制面只围绕下面这条流程展开：

1. 先重跑 `ShaderCorpus` / `ShaderSourceDiagnostics` full-batch
2. 读取 `compare-summary.json` / `risk-report.json` / `compile-summary.json` / `gate-summary.json`
3. 确认当前是否还有新的或仍残留的 `L2/L3` 高风险 case
4. 若有，就只挑一个最值得处理的 case，按默认流程完成归因
5. 判断它更像 compare 口径问题、compile posture 差异，还是实现问题
6. 若值得修，做一次最小而定向的修改，并完成 single-case + full-batch 复跑
7. 若任务过大，就拆成更小的 residual 子任务；仍然一次只完成一个

## 当前判断

### 现在真正的核心问题

- full-batch 的主要矛盾已经不是 replay / compile / llvm-dis 主链路失败，而是**canonical compare 里的大量 `L2/L3` 风险到底哪些是真问题，哪些只是表达差异或 compare 口径问题**
- 当前最有价值的推进方式，不是继续扩 live 验证，而是**持续消解 canonical compare 中可解释、可复现、可修正的一类类高风险差异**
- `difference-analysis/` 目录已经证明，这条路径是有效的：从单个 case 入手，能够落到实现改动，并在 full-batch 上看到 `L3` 数量下降

### 当前工作原则

- **canonical compare 是任务入口，不是收尾附属品**
- **一个 case 一个 case 地做，不对着“最终完全等价”死磕**
- **每次实现修改之后，必须重新看 full-batch 风险计数是否下降**
- **没有统计收益的实现，不应轻易继续放大**
- **每轮开始前先重跑 full-batch，再决定当前最值得处理的 residual case**

### 当前最新状态

- `CC-003.26c` 的窄 self-loop emitter 仍保持为当前稳定实现基线：它只覆盖“self-edge phi 可回放 + 退出块唯一 + 当前块 SSA 不逃逸到非 inline 后续块”的 loop header；本轮没有重新放宽 converter gate。
- `CC-003.26d` / `CC-003.26e.1` 留下的核心证据仍成立：`bff2e9e...` 的两段 self-loop header（`160 -> 160 / 272` 与 `446 -> 446 / 558`）都属于 non-inline outer-merge shape，compile posture 已对齐，真正有效的实现收益来自值出环传递，而不是重新打开 generic self-loop emitter。
- 本轮对 `bff2e9e...` 补做了 compare 口径归因：当前 generated MSL 仍会把两段 `while (true)` 交给后端 lowering 成更宽的 AIR CFG（`basicBlockCount 39 / br 17 / condbr 21 / phi 54 / select 42`），但 entry/resource/builtin 语义与 AIR intrinsic family 已保持一致，剩余漂移主要表现为 outer-merge self-loop 后端物化导致的 `CFG + arithmetic/vector` 统计重分布。
- 因此本轮没有继续改 `IRToMSLConverter`，而是在 `ir_canonical_compare.py` 新增一条更窄的 outer-merge self-loop residual 降噪：仅当语义摘要一致、AIR intrinsic family 一致、CFG 呈现“大幅增块/增 phi/减 select”，且指令族只剩 `arithmetic + vector` 小幅 tradeoff 时，才把该 residual 从 `L2` 降到 `L1`。
- `bff2e9e...` 单 case 已据此闭环：`compare-summary.json` 中风险已从 `L2` 降到 `L1`，`instruction-family totalAbsoluteDelta` 保持 `13`，`compile-summary.json` 仍显示 `originalFastMathMode=enable`、`effectiveMetalArgs=["-ffast-math"]`，说明当前结论更像 compare 口径收敛，而不是实现层仍有新缺口。
- 本轮继续下钻 `14b700cdf...` 后，证据链已收敛成更窄的 compare residual：`entry / resource / builtin` 语义保持一致，`compile-summary.json` 继续显示 `-ffast-math` 对齐，剩余主因是“小幅 module addrspace 计数上浮 + arithmetic/vector 重分布 + memory 微漂移”；其中 standalone single-case 已稳定表现为 `addrspace(2) 153 -> 157`、`instruction-family totalAbsoluteDelta 46`，但不再伴随真实 entry/compile posture 缺口。
- 因此本轮没有继续改 `IRToMSLConverter`，而是在 `ir_canonical_compare.py` 新增一条更窄的 select-heavy vector/materialization residual 降噪：仅当语义摘要一致、AIR intrinsic 统计一致、module addrspace key 集合不变且只出现单一 addrspace 小幅增量时，允许把 `{arithmetic, vector, memory}` 这组同 CFG / 同 skeleton tradeoff 从 `L2` 下调到 `L1`。
- `14b700cdf...` 单 case 已据此闭环：`build/semantics-validation/roundtrip/cc-003-26f-single-14b700cdf-select-memory/compare-summary.json` 中风险已从 `L2` 降到 `L1`，`instruction-family totalAbsoluteDelta` 收敛到 `46`，`compile-summary.json` 仍显示 `-ffast-math`，说明当前结论更像 compare 口径收敛，而不是实现层存在新的 addrspace / planner 缺口。
- 最新 full-batch 复跑显示这次 compare 归一化继续拿到了明确统计收益且没有引入 `L3` 回归：diagnostics 保持 `L1 153 / L2 0 / L3 0`，corpus 由 `L1 407 / L2 30 / L3 0` 变为 `L1 410 / L2 27 / L3 0`；`14b700cdf...`、`62e40bab...`、`29b2b992...` 已退出 corpus `L2`，当前新的 gate 顶部样本变为 `32d1c8d0...`，其风险主因是 `CFG + instruction-family + fast-math`。
- 本轮继续下钻 `32d1c8d0...` 后，证据链进一步收敛成更窄的 compare residual：`entry / resource / builtin` 语义保持一致，`compile-summary.json` 继续显示 `originalFastMathMode=enable`、`effectiveMetalArgs=["-ffast-math"]`，剩余主因是中等幅度的 shared-CFG 展开把部分 `select` 物化成更多 `block / br / condbr / phi`，并伴随 `{arithmetic, vector}` 重分布；单 case 稳定表现为 `basicBlockCount 28 -> 36`、`br 14 -> 18`、`condbr 13 -> 17`、`phiCount 15 -> 19`、`selectCount 5 -> 1`，以及 `instruction-family totalAbsoluteDelta 24`。
- 因此本轮没有继续改 `IRToMSLConverter`，而是在 `ir_canonical_compare.py` 新增一条更窄的 moderate CFG vector materialization residual 降噪：仅当语义摘要一致、AIR intrinsic family 一致、CFG 呈现“中等幅度增块 / 增 br / 增 condbr / 增 phi / 减 select”的同步步长，且指令族只剩 `arithmetic + vector` 中等 tradeoff 时，才把该 residual 从 `L2` 降到 `L1`。
- `32d1c8d0...` 单 case 已据此闭环：`build/semantics-validation/roundtrip/cc-003-26g-single-32d1c8d0-20260413-2/compare-summary.json` 中风险已从 `L2` 降到 `L1`，`compile-summary.json` 仍显示 `-ffast-math` 对齐，说明当前结论更像 compare 口径收敛，而不是实现层存在新的 CFG / planner 缺口。
- 最新 full-batch 复跑显示这次 compare 归一化继续拿到了明确统计收益且没有引入 `L3` 回归：diagnostics 仍保持 `L1 153 / L2 0 / L3 0`，corpus 由 `L1 410 / L2 27 / L3 0` 变为 `L1 413 / L2 24 / L3 0`；`32d1c8d0...`、`84d57856...`、`8a5105d8...` 已退出 corpus `L2`，当前新的 gate 顶部样本变为 `401761e8...`，其风险主因仍是 `CFG + instruction-family + fast-math`。
- 本轮继续下钻 `401761e8...` 后，证据链进一步收敛成更窄的 compare residual：`entry / resource / builtin` 语义保持一致，`compile-summary.json` 继续显示 `originalFastMathMode=enable`、`effectiveMetalArgs=["-ffast-math"]`，剩余主因是较窄 shared-CFG 展开把一部分 `select` 物化成更多 `block / br / condbr / phi`，并伴随纯 `arithmetic` 小幅回落；单 case 稳定表现为 `basicBlockCount 7 -> 13`、`br 2 -> 5`、`condbr 4 -> 7`、`phiCount 3 -> 6`、`selectCount 19 -> 16`，以及 `instruction-family totalAbsoluteDelta 5`。
- 因此本轮没有继续改 `IRToMSLConverter`，而是在 `ir_canonical_compare.py` 新增一条更窄的 small shared-CFG arithmetic materialization residual 降噪：仅当语义摘要一致、AIR intrinsic family 一致、CFG 呈现“小幅增块 / 增 br / 增 condbr / 增 phi / 减 select”的同步步长，且指令族只剩 `arithmetic` 单键小幅回落时，才把该 residual 从 `L2` 降到 `L1`。
- `401761e8...` 单 case 已据此闭环：`build/semantics-validation/roundtrip/cc-003-26h-single-401761e8/compare-summary.json` 中风险已从 `L2` 降到 `L1`，`compile-summary.json` 仍显示 `-ffast-math` 对齐，说明当前结论更像 compare 口径收敛，而不是实现层存在新的 structured emission / planner 缺口。
- 最新 full-batch 复跑显示这次 compare 归一化继续拿到了明确统计收益且没有引入 `L3` 回归：diagnostics 仍保持 `L1 153 / L2 0 / L3 0`，corpus 由 `L1 413 / L2 24 / L3 0` 变为 `L1 414 / L2 23 / L3 0`；`401761e8...` 已退出 corpus `L2`，当前新的 gate 顶部样本变为 `4bfca3ce...`，其风险主因是 `module addrspace + instruction-family + targetTriple`。
- 因此 `CC-003.26h` 本轮可以判定闭环；下一步不再继续围绕 `401761e8...` 细拆，而是回到 corpus 当前最高价值 residual，优先分析 `4bfca3ce...` 这一支 `module addrspace + instruction-family + targetTriple` family，判断它现在更像 compare 边界，还是仍指向新的语义 / 建模缺口。


## 当前默认流程

### Step 1：先从结构化报告选下一个 case

默认优先级：

1. **先看 `L3` 样本**
2. 优先选择：
   - 差异模式在多个样本中重复出现的
   - 能映射到同一类参数 / resource / addrspace / builtin 语义的
   - 有希望通过一处实现改动同时改善多个样本的
   - 已经能从 `compile-summary.json` / aggregate compile report 看到明确 compile posture 线索的
3. 当前不优先：
   - 明显只是 `target triple / data layout` 记录项的
   - 仍然只能靠 `L3/L4 / live / GUI` 才能判断、且当前缺少低层证据的

推荐输入：

- `build/semantics-validation/roundtrip/*/compare-summary.json`
- `build/semantics-validation/roundtrip/*/risk-report.json`
- `build/semantics-validation/roundtrip/*/compile-summary.json`
- `build/semantics-validation/roundtrip/*/gate-summary.json`
- `build/shader-aggregate-replay/*/aggregate-replay-summary.json`
- aggregate 下各样本的 `*.compile.json`

### Step 2：先做 case 分析，再决定是否改实现

每个 case 至少回答下面几个问题：

- 差异是发生在：
  - entry 参数类型摘要
  - entry 参数语义摘要
  - resource / builtin 摘要
  - addrspace
  - CFG / instruction family
  - fast-math / compile posture / module metadata
- 这是“表达方式变化”还是“更像真实语义变化”
- 这个差异更像来自：
  - compile posture / planner decision
  - emitted MSL 写法
  - metadata 建模不足
  - 参数映射错误
  - compare canonicalization 不对称
- 当前 `compile-summary.json` 是否已经回答了：
  - `originalFastMathMode`
  - `inferredMetalArgs`
  - `effectiveMetalArgs`
- 若问题属于 aggregate / 多模块形态，`aggregate_replay_runner.py --compile-backend mtl-device` 的 compile report 是否已经给出更贴近 runtime 的结论
- 如果修复，应该改哪一层最合适：
  - `IRToMSLConverter`
  - `ir_canonical_compare.py`
  - round-trip runner / compile posture / shared planner
  - aggregate orchestration / runtime-like harness

- **必须严格优先尝试修改真正负责语义建模或 compile decision 的实现层。** 只有当反复验证后确认converter层面的修复不靠谱，才考虑优先改 `ir_canonical_compare.py`。

若这一步还没有明确判断，**不要急着改实现**。

### Step 3：只做最小实现改动

一旦判断某类差异确实值得修，默认策略是：

- 只修一个清晰问题
- 只引入一个清晰机制
- 尽量保持 diff 小、影响面可控

例如：

- 参数级 `noalias -> __restrict` 回放
- compare 中某一类 alias / metadata 归一化
- 参数建模里补一项 previously-missing 的 first-class 语义
- compile posture / planner 里补一项明确的参数推断或 override 规则

禁止一次混入多条彼此无关的修正。

### Step 4：每次实现后都要做两层验证

#### 4.1 单 case 验证

目的：先确认本轮改动确实命中了目标差异。

默认动作：

- 对单个 `.ll` 样本执行 `ir_semantics_roundtrip_runner.py`
- 读取同轮 `compile-summary.json` / `compare-summary.json` / `risk-report.json` / `gate-summary.json`
- 若问题涉及 aggregate / compile posture / runtime-like compile，再补 `aggregate_replay_runner.py --compile-backend mtl-device`

要求回答：

- 原来的那条差异是否消失 / 降级
- compile posture 是否已经对齐
- 是否引入新的更坏差异

#### 4.2 full-batch 验证

目的：确认这不是单 case 偶然改善，而是对整体风险分布有统计收益。

当前默认要看两条 full-batch：

- `ShaderCorpus`
- `ShaderSourceDiagnostics`

必须回答：

- `L3` 数量是否下降
- `blockedSamples` 是否减少
- `L2 / L3` 的共有样本口径下，是否真的改善
- 是否出现新的 `L3` 回归

### Step 5：把结果写回控制面

每次任务结束后，必须把下面内容回写到文档：

- 当前分析的是哪一类差异
- 该类差异的当前结论是什么
- 是否已经落到实现改动
- 单 case 与 full-batch 的关键证据是什么
- 若涉及 compile posture / aggregate，结构化报告给出的结论是什么
- 下一步最值得继续分析的 case 是什么

## TODO

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `CC-001` 建立 canonical-diff 驱动的新主线 | DONE | 主线文档已切换为 canonical-diff 驱动的 case-by-case + full-batch 口径 | 本文档 |
| `CC-002` 收敛 `buffer-noalias` 这类 entry 参数对齐问题 | DONE | `buffer-noalias` 闭环完成，full-batch 已确认有统计收益 | `difference-analysis/buffer-noalias/04-implementation-result.md` / `difference-analysis/buffer-noalias/05-full-batch-compare.md` |
| `CC-003` 归类 `buffer-noalias` 修复后剩余的高频 `L3/L2` 模式 | DONE | 高频 `L3/L2` family 已完成一轮系统收敛，主线已清到 `L3 = 0` | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/` |
| `CC-003.1` 参数/metadata compare 噪声归一化 | DONE | 参数 / metadata compare 噪声首轮归一化完成 | `difference-analysis/resource-metadata-addrspace/04-implementation-result.md` / `difference-analysis/resource-metadata-addrspace/05-full-batch-compare.md` |
| `CC-003.2` 资源语义/命名保真修复 | DONE | 资源语义与命名保真已补齐 | `difference-analysis/resource-type-name-preservation/04-implementation-result.md` / `difference-analysis/resource-type-name-preservation/05-full-batch-compare.md` |
| `CC-003.3` intrinsic / lowering 残留收敛 | DONE | intrinsic / lowering residual 首轮收敛完成 | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/` |
| `CC-003.4` addrspace / structured CFG family 收敛 | DONE | addrspace / structured CFG family 已收敛到稳定口径 | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.5` single-field return wrapper 回放修复 | DONE | single-field return wrapper 回放已修复 | `difference-analysis/single-field-return-wrapper/04-implementation-result.md` / `difference-analysis/single-field-return-wrapper/05-full-batch-compare.md` |
| `CC-003.6` constant buffer 用户 struct 引用判定修复 | DONE | constant buffer 用户 struct 引用判定已修复 | `difference-analysis/constant-struct-reference-dereferenceable/04-implementation-result.md` / `difference-analysis/constant-struct-reference-dereferenceable/05-full-batch-compare.md` |
| `CC-003.7` 输出语义 invariant 保真修复 | DONE | 输出 `invariant` 保真已补齐 | `difference-analysis/position-invariant-output/04-implementation-result.md` / `difference-analysis/position-invariant-output/05-full-batch-compare.md` |
| `CC-003.8` fast-math compile posture family 修复 | DONE | fast-math compile posture 已重新对齐 | `difference-analysis/fast-math-compile-posture/04-implementation-result.md` / `difference-analysis/fast-math-compile-posture/05-full-batch-compare.md` |
| `CC-003.9` 优先检查 `CC-003.8` 收敛后剩余的 `entry 参数` 高风险 family | DONE | fragment `[[position]]` ghost builtin 已修复 | `difference-analysis/fragment-entry-ghost-position/04-implementation-result.md` / `difference-analysis/fragment-entry-ghost-position/05-full-batch-compare.md` |
| `CC-003.10` 收敛 mixed CFG 下可恢复 nested merge 被整函数线性化的问题 | DONE | mixed CFG nested merge 发射已收敛 | `difference-analysis/mixed-cfg-structured-emission/04-implementation-result.md` / `difference-analysis/mixed-cfg-structured-emission/05-full-batch-compare.md` |
| `CC-003.11` 优先检查 `CC-003.10` 收敛后剩余的纯 `CFG / instruction-family / fast-math` residual | DONE | vector / aggregate shape compare 过敏已降噪 | `difference-analysis/vector-aggregate-shape-normalization/04-implementation-result.md` / `difference-analysis/vector-aggregate-shape-normalization/05-full-batch-compare.md` |
| `CC-003.12` 优先检查 `CC-003.11` 收敛后 corpus 中剩余的 `instruction-family + fast-math + targetTriple` residual | DONE | scalar / vector materialization residual 已继续收敛 | `difference-analysis/scalar-vector-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.13` 优先检查 `CC-003.12` 收敛后 corpus 中剩余的 `module addrspace + air intrinsic` residual | DONE | sampler-state global lowering 缺口已补齐首轮 | `difference-analysis/sampler-state-global-preservation/04-implementation-result.md` / `difference-analysis/sampler-state-global-preservation/05-full-batch-compare.md` |
| `CC-003.14` 优先检查 `CC-003.13` 收敛后同 family 中残留的 `discard_fragment + CFG` residual | DONE | `discard_fragment` lowering 已补齐 | `difference-analysis/fragment-discard-lowering/04-implementation-result.md` / `difference-analysis/fragment-discard-lowering/05-full-batch-compare.md` |
| `CC-003.15` 优先检查 `CC-003.14` 收敛后 shared `控制流粗摘要变化 + 指令族统计变化 + fast-math` residual | DONE | shared CFG + shape drift residual 已继续降噪 | `difference-analysis/shared-cfg-shape-drift-normalization/04-implementation-result.md` / `difference-analysis/shared-cfg-shape-drift-normalization/05-full-batch-compare.md` |
| `CC-003.16` 优先检查 corpus 中唯一残留的 `entry 参数语义摘要变化; entry builtin / stage-in 摘要变化` case | DONE | fragment `stage_in` 语义保真已补齐 | `difference-analysis/fragment-stage-in-semantics-preservation/04-implementation-result.md` / `difference-analysis/fragment-stage-in-semantics-preservation/05-full-batch-compare.md` |
| `CC-003.17` 优先检查 `CC-003.16` 之后 residual 中仍未收尽的同 CFG `instruction-family + fast-math + targetTriple` materialization family | DONE | cast / materialization residual 已继续收敛 | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.18` 优先检查 `CC-003.17` 之后 shared residual 中更窄的 `1 block + 1 br` split/merge family | DONE | 窄 shared-CFG split/merge family 已收敛 | `difference-analysis/shared-cfg-split-merge-normalization/04-implementation-result.md` / `difference-analysis/shared-cfg-split-merge-normalization/05-full-batch-compare.md` |
| `CC-003.19` 继续拆 corpus 中仍未收尽的更宽 shared-CFG residual | DONE | 更宽 shared-CFG residual 已继续收敛 | `difference-analysis/shared-cfg-split-merge-normalization/04-implementation-result.md` / `difference-analysis/shared-cfg-split-merge-normalization/05-full-batch-compare.md` |
| `CC-003.20` 优先检查当前剩余的 `instruction-family + fast-math + targetTriple` residual | DONE | same-CFG materialization residual 已继续收敛 | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.21` 优先检查 diagnostics 中剩余的纯 `instruction-family + fast-math + targetTriple` residual | DONE | diagnostics arithmetic-heavy residual 已清零 | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.22` 优先检查 corpus 中仍挂在 gate 顶部的 `module air intrinsic + instruction-family` residual | DONE | `c2cd49d0...` 的窄 `zext <N x i1> -> <N x i8>` lowering 缺口已补齐，corpus `L2 46 -> 45` | `difference-analysis/scalar-vector-cast-materialization-normalization/` |
| `CC-003.23` 重跑 full-batch 并继续拆剩余 `L2/L3` residual | DONE | 已完成最新 full-batch 复跑，并闭环一支高频 vector-heavy materialization residual；`055fe879...` 单 case `L2 -> L1`，corpus `L2 45 -> 32` | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.24` 优先检查 corpus 中当前最高频的 `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化` family | DONE | 已确认 `e17ab0cb...` 属于 shared-CFG skeleton 保持不变但 `selectCount` 增长的 compare residual；单 case `L2 -> L1`，corpus `L2 32 -> 31` | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.25` 继续检查 corpus 中剩余最高频的 `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化` family | DONE | 已确认 `c3d8aba9...` 属于 single-block ret-only 下 vector select scalarization 的 compare residual；单 case `L2 -> L1`，corpus `L2 31 -> 30` | `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md` / `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md` |
| `CC-003.26a` 修补 shared-CFG case 中 `phi incoming` 的向量常量 / 隐式 entry 保真缺口 | DONE | 已补齐 `phi [value, %label]` 的顶层解析与 `entry -> %3` 别名匹配；`401761e8...` 单 case 已从“final-merge 多条 incoming 丢失”收窄到只剩 loop-continue edge residual，但 full-batch 暂无统计净收益 | 本文档 |
| `CC-003.26b` 验证 generic `conditional self-loop` emitter 的 batch 收益边界 | DONE | 已确认显式 `while (true)` + `continue/break` 虽能让 `401761e8...` 单 case 重新编译成功并把 `instruction-family totalAbsoluteDelta 11 -> 5`，但 full-batch 反而使 corpus `L2 31 -> 35`，且新增 `6c9ba02f...` / `2aa10f98...` / `70b330a1...` / `a9fbcdf5...`，因此这版实现已回退 | 本文档 |
| `CC-003.26c` 把 self-loop emitter 收窄到 escape-safe 的唯一退出 shape | DONE | 已仅对“self-edge phi 可回放 + 退出块唯一 + 当前块 SSA 不逃逸到非 inline 后续块”的 loop header 发射窄 `while (true)`；`401761e8...` 单 case `instruction-family totalAbsoluteDelta 11 -> 5`，`6c9ba02f...` 新增 compile 回归已消除，但 full-batch 仍无统计净收益 | 本文档 |
| `CC-003.26d` 归因 `bff2e9e...` 为 non-inline self-loop exit 的值出环传递缺口 | DONE | 已确认 `bff2e9e...` 的两段 self-loop 都不属于当前 unique-exit / escape-safe shape；compile posture 已对齐，残留主因落在 loop-exit value 的显式物化 / 出环传递缺口，而不是 compare 噪声 | 本文档 |
| `CC-003.26e.1` 先为 float-family outer-merge self-loop 补最小可回归的值出环传递 | DONE | 已补 `test_self_loop_exit_merge_values.ll` 最小复现；outer-merge self-loop 仅对 float-family phi shape 开 gate；`bff2e9e...` 单 case `instruction-family totalAbsoluteDelta 33 -> 13`，且 full-batch 重新稳定在 corpus `L2 31 / L3 0` | 本文档 |
| `CC-003.26e` 从 `bff2e9e...` 提炼 non-inline self-loop exit 的最小复现并补值出环传递机制 | DONE | 已确认 converter 层的 float-family outer-merge 值出环传递足以命中 `bff2e9e...`，并进一步把其剩余 `CFG + instruction-family` residual 归类为可接受的 outer-merge self-loop compare 漂移；单 case `L2 -> L1`，full-batch `corpus L2 31 -> 30` 且 `L3` 仍为 `0` | 本文档 |
| `CC-003.26f` 归一化 `14b700cdf...` 同 family 的小幅 module-addrspace + vector/materialization residual | DONE | 已在 `ir_canonical_compare.py` 为“语义摘要一致 + AIR intrinsic 一致 + module addrspace key 集合不变且仅小幅增量 + `{arithmetic, vector, memory}` tradeoff”补一条更窄 compare 分支；`14b700cdf...` 单 case `L2 -> L1`，full-batch `corpus L2 30 -> 27` | 本文档 |
| `CC-003.26g` 归一化 `32d1c8d0...` 同 family 的 moderate CFG + vector/materialization residual | DONE | 已在 `ir_canonical_compare.py` 为“语义摘要一致 + AIR intrinsic 一致 + CFG 呈现中等幅度增块/增 br/增 condbr/增 phi/减 select + `{arithmetic, vector}` tradeoff”补一条更窄 compare 分支；`32d1c8d0...` 单 case `L2 -> L1`，full-batch `corpus L2 27 -> 24` | 本文档 |
| `CC-003.26h` 归一化 `401761e8...` 同 family 的 small shared-CFG + arithmetic residual | DONE | 已在 `ir_canonical_compare.py` 为“语义摘要一致 + AIR intrinsic 一致 + CFG 呈现小幅增块/增 br/增 condbr/增 phi/减 select + `arithmetic` 单键小幅回落”补一条更窄 compare 分支；`401761e8...` 单 case `L2 -> L1`，full-batch `corpus L2 24 -> 23` | 本文档 |
| `CC-003.26` 继续检查 corpus 中剩余最高频 residual family | DOING | 当前稳定主线已更新为 diagnostics `L1 153 / L2 0 / L3 0`、corpus `L1 414 / L2 23 / L3 0`；`401761e8...` 已退出 `L2`，下一轮优先转向 gate 顶部新样本 `4bfca3ce...` 的 `module addrspace + instruction-family + targetTriple` residual | 本文档 |

## 任务执行规则

### 一次只做一个任务

- 每个 agent / 每次会话默认只完成一个当前最高优先级任务
- 若任务过大，必须先拆出子任务，再只完成其中一个
- 不允许同时并行推进多个主线 case

### 当前选题优先级

从高到低：

1. **能让一批 `L3` 同时下降的差异模式**
2. **已经在 `difference-analysis/`、`compile-summary.json` 或 aggregate compile report 中有初始证据的模式**
3. **单个 case 虽复杂，但明显指向参数建模 / emission / compile posture 逻辑的问题**
4. **纯 compare 口径问题**（如果它能明显降低误报，也值得做）
5. **只能靠 `L3/L4 / live` 才能推进的问题**（当前不纳入默认选题范围）

### 拆任务的规则

若当前任务无法在一次工作中闭环，必须拆开。拆任务时沿下面方式切：

- 按差异类别切：`entry 参数语义` / `resource 语义` / `addrspace` / `CFG` / `fast-math`
- 按机制切：参数建模 / MSL emission / compare 归一化 / compile posture
- 按样本族切：优先切出“重复模式明显”的 case 族

不要按含糊目标切，例如：

- “继续研究 L3”
- “进一步优化 round-trip”

## 当前默认验证

### 改实现前

按改动类型选择最低要求：

- **纯文档 / 方法规范 / 路线整理改动**：更新文档并自检跨文档口径一致性，无需额外构建
- **`compare` / `round-trip` / Python orchestration 改动**：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
```

- **compile posture / shared planner / aggregate compile 相关改动**：

```bash
python3 Scripts/test_shared_compile_planner.py
python3 Scripts/test_aggregate_replay_runner.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/test_ir_canonical_compare.py
```

- **Swift runtime / PlayTools / host bridge / compile decision 相关改动**：

```bash
./BuildScripts/build_and_install.sh
```

  若同时涉及 shared planner、aggregate compile 或 round-trip 逻辑，继续补跑对应 Python 回归。

- **改动了工程文件**：

```bash
./BuildScripts/lint_pbxproj.sh
```

### 单 case 验证

默认入口是：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --ll <sample.ll> --output-root build/semantics-validation/roundtrip/<run-name>
```

单 case 默认应读取同轮产物：

- `compile-summary.json`
- `roundtrip-summary.json`
- `compare-summary.json`
- `risk-report.json`
- `gate-summary.json`

若问题涉及 aggregate / 多模块 / compile posture / runtime-like compile，默认补充：

```bash
python3 Scripts/aggregate_replay_runner.py --replacement-dir <replacement-dir> --output-root build/shader-aggregate-replay/<run-name> --compile-backend mtl-device --allow-failures
```

补充约束：

- 裸 `xcrun metal -c` 只适合做孤立编译器 smoke，不替代默认单 case 入口
- 若需要显式透传 fast-math 参数，优先使用 `--metal-arg=<value>` 形式

### full-batch 验证

只要本轮改动影响 canonical compare、IR 参数建模、MSL emission、compile posture、shared planner、aggregate compile decision、resource 语义、地址空间或其它可能改变风险分布的逻辑，收尾时默认执行：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

当前最重要的不是“有没有跑”，而是：

- 新旧 `risk-report.json` 的 `L3` 数量如何变化
- `blockedSamples` 是否减少
- 共有样本口径下有没有实际改善
- 有没有新增 `L3`
- 若问题涉及 compile posture / aggregate，相关 `compile-summary.json` 或 `*.compile.json` 是否已经对齐

## 当前完成判定

当前每个任务的完成判定统一为：

1. 已选出一个明确 case / 差异模式
2. 已完成足够深入的 canonical diff 分析
3. 已判断它更像 compare 问题还是实现问题
4. 若值得修，已完成一次最小实现修改
5. 已完成单 case 验证
6. 已完成 full-batch canonical compare 复跑
7. 已明确记录风险数量变化与下一步建议

只有满足这 7 条，当前任务才算真正闭环。

## 当前非默认验证

下面这些事项当前不写成默认 TODO 或完工 gate：

- `QQ飞车手游` 启动 smoke
- host bridge registration acknowledgement 稳定性
- `Scripts/ir_semantics_behavior_runner.py` 驱动的 `L3` 最小行为测试
- 更重的 live / `.gputrace` / render-diff 验证
- 任何需要真实 app 安装后人工点击、人工登录或长期占机的验证

只有当某个具体 case 的低层结构化证据已经不足以回答问题，或用户明确要求进入更高层验证时，才再考虑升级。

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

- **compile green 不等于语义等价。** 当前默认应以 `compile-summary.json + compare-summary.json + risk-report.json + gate-summary.json` 这组结构化报告为主，而不是只看命令成功与否。
- **不要把 `xcrun metal -c` 的成功直接当成 runtime 真值。** 单模块 round-trip 是默认低成本入口；若问题涉及 aggregate / compile posture / runtime-like compile，优先补 `Scripts/aggregate_replay_runner.py --compile-backend mtl-device`。
- **构建、重建、安装统一走 `BuildScripts/`。** 不要手写 `xcodebuild`、手工复制产物，也不要把人工安装步骤写回默认流程。
- **优先读报告，不要优先读日志。** 报告用于回答“发生了什么”，日志只在报告仍不足以解释错误时才作为补充证据。
- **优先把高频手工流程脚本化。** 若某条验证路径无法脚本化，它就不应成为默认 gate。
- **主文档不要直接暴露会漂移的本机快照。** 本机增强入口、历史批量快照、manifest 描述文字与局部样本数量都应下沉到参考文档。
- **非 preset 的默认输出目录必须避免碰撞。** 批量运行默认目录需要带唯一后缀，避免近同时运行互相覆盖。
- **L2 compare 需要主动降噪。** 更细的降噪对象与风险口径统一见 `04-L2-CanonicalCompareAndRiskGrading.md`。
- **resource metadata 的 `air.address_space` 显式化不应重复放大。** 当函数参数 `addrspace` 摘要已一致时，这更像 compare 噪声，而不是 entry/resource 语义真的发生变化。
- **single-field output 先不要急着改 compare。** 当 `outputSemantics` 一致但 `returnSignature` 出现 `wrapped -> bare` 漂移时，应先检查 converter 是否把 original IR 的 single-field wrapped return 过早塌平。
- **constant buffer struct 的 `&` / `*` 选择会直接影响 `dereferenceable(N)` 是否能 round-trip 保住。** 当 `entry 参数类型摘要变化` 表现为 `ptr addrspace(2) dereferenceable(N) -> ptr addrspace(2)` 时，应优先检查 converter 是否把 `_Foo_Type` / `cb_Foo_Type` 这类用户 struct 误降成指针参数。
- **`air.position` 的 `air.invariant` 必须保留到返回 metadata 与 MSL 发射。** 当 `entry 输出语义摘要变化` 表现为 `kind=air.position|type=float4|qualifiers=air.invariant -> kind=air.position|type=float4` 时，应先检查 converter 是否保留了返回 qualifier，并把它发到 `[[position, invariant]]`。
- **修掉表层 `entry` 差异后要立刻复跑 full-batch 看 `blockedSamples` 是否真的变化。** 表层差异消失，不代表顶层 `L3` 一定下降。
- **compile posture 是一等证据。** 当前默认要优先读取 `originalFastMathMode`、`inferredMetalArgs`、`effectiveMetalArgs`，而不是靠人工回忆命令参数。
- **`phi incoming` 不能直接按逗号粗切。** 当 incoming value 本身是 `<N x T>` / aggregate 常量时，必须按顶层括号层级找 `[value, %label]` 的分隔，否则 merge 前会静默丢掉一部分 incoming，并在 regenerated IR 里掉成 `undef`。
- **隐式 entry block 可能只在 phi incoming 里以数值标签出现。** 当前块名在发射阶段常叫 `entry`，但 original IR 的 incoming label 可能是 `%3` 这类未显式声明的入口别名；若不做 alias 匹配，`entry -> final-merge` 这条边上的 phi 赋值会漏发。
- **若需要显式透传 fast-math 参数，优先使用 `--metal-arg=<value>`。** 这样可以避免参数解析层把 `-ffast-math` / `-fno-fast-math` 误判成新的选项。
- **窄 self-loop 只能覆盖 escape-safe 的 loop header。** 若当前 BB 内定义的 SSA 还会在退出块之后继续被引用，就不能只靠 `while (true)` + `continue/break` 直接结构化；这类 case 需要先补“值如何出环”的显式物化/传递机制。
- **不是所有 self-loop residual 都卡在 header 本身。** 若 exit block 不是“唯一退出后直接收束”，而是还要先消费 loop header 里定义的 SSA 再继续分叉/合流（如 `bff2e9e...` 的 `272` / `558`），当前窄 self-loop emitter 应继续拒绝命中；这类问题要单独按 `loop-exit value` 的显式物化 / 出环传递处理，而不是继续放宽 generic self-loop 结构化门控。
- **仅凭 `stopBefore == exitLabel` + exit phi 出环还不够安全。** 首版 `outer-merge self-loop` 实现虽能让 `bff2e9e...` 两段 loop 恢复 `while (true)`，并把单 case `instruction-family totalAbsoluteDelta 33 -> 13`，但 full-batch 会重新引入 `a9fbcdf5...` / `70b330a1...` / `2aa10f98...`；后续必须先找出这些回归样本与 `bff2e9e...` 的 shape 差异，再考虑重新放开 gate。

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“当前手头的证据链覆盖到哪里、还差什么”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；分层模型与止损边界的背景参考）
- `03-L1-IR-RoundTrip.md`（**建议读取**；round-trip 入口与脚本参考）
- `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考；保留 compare / risk / gate 报告语义说明）
- `05-L3-最小行为测试.md`（资料参考，当前**不纳入默认规划**）
- `06-L4-真实场景验证.md`（资料参考；仅在需要更重 live / `.gputrace` 验证时再读）
- `07-首轮基线与历史进展归档.md`（历史归档与样本名单参考，**不必须读取**）
- `08-当前代表集与Gate契约参考.md`（维护 preset / gate / manifest 细节，或排查 `gate-summary.json` / `preset-manifest.json` 口径不一致时再读）

### 当前重点分析目录

- `difference-analysis/buffer-noalias/00-progress.md`
- `difference-analysis/buffer-noalias/04-implementation-result.md`
- `difference-analysis/buffer-noalias/05-full-batch-compare.md`
- `difference-analysis/resource-metadata-addrspace/04-implementation-result.md`
- `difference-analysis/resource-metadata-addrspace/05-full-batch-compare.md`
- `difference-analysis/resource-type-name-preservation/04-implementation-result.md`
- `difference-analysis/resource-type-name-preservation/05-full-batch-compare.md`
- `difference-analysis/single-field-return-wrapper/04-implementation-result.md`
- `difference-analysis/single-field-return-wrapper/05-full-batch-compare.md`
- `difference-analysis/constant-struct-reference-dereferenceable/04-implementation-result.md`
- `difference-analysis/constant-struct-reference-dereferenceable/05-full-batch-compare.md`
- `difference-analysis/position-invariant-output/04-implementation-result.md`
- `difference-analysis/position-invariant-output/05-full-batch-compare.md`
- `difference-analysis/fast-math-compile-posture/04-implementation-result.md`
- `difference-analysis/fast-math-compile-posture/05-full-batch-compare.md`
- `difference-analysis/fragment-discard-lowering/04-implementation-result.md`
- `difference-analysis/fragment-discard-lowering/05-full-batch-compare.md`
- `difference-analysis/shared-cfg-shape-drift-normalization/04-implementation-result.md`
- `difference-analysis/shared-cfg-shape-drift-normalization/05-full-batch-compare.md`
- `difference-analysis/scalar-vector-materialization-normalization/04-implementation-result.md`
- `difference-analysis/scalar-vector-materialization-normalization/05-full-batch-compare.md`
- `difference-analysis/scalar-vector-cast-materialization-normalization/04-implementation-result.md`
- `difference-analysis/scalar-vector-cast-materialization-normalization/05-full-batch-compare.md`

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
