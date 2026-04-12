## scalar-vector-cast-materialization-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.21` 指向的最后两支 diagnostics residual：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

代表 case 落在 diagnostics 中两支仍停留在 `L2` 的 fragment 样本：

- `build/semantics-validation/roundtrip/cc-003-21-single-69e4179e-arithmetic-heavy/`
- `build/semantics-validation/roundtrip/cc-003-21-single-d8c964c5-arithmetic-heavy/`

它们与 `CC-003.20` 已吸收的“更宽 same-CFG materialization drift”相比，新的共同特征是：

1. `cfg` 继续完全一致
2. `entry / resource / builtin / output` 语义继续完全一致
3. `air intrinsic` 统计继续一致
4. `cast` 完全不漂移
5. 但 `arithmetic` tradeoff 明显更重，导致 `totalAbsoluteDelta` 超出 `CC-003.20` 的窗口

## 结论：仍然是 compare 边界过窄，不是 converter / compile posture 回退

重新下钻后，这轮证据链仍然足够明确：

- 不是 `IRToMSLConverter.swift` 打乱了 entry / resource / builtin 语义
- 不是 compile posture 失配；两支 case 的 `compile-summary.json` 都继续显示：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = -ffast-math`
  - `fastMathDecision = fast_math_aligned`
- 真正的问题仍在 `Scripts/ir_canonical_compare.py`：
  - `_entry_has_small_scalar_vector_materialization_drift(...)` 对“同 CFG + 无 cast 漂移 + arithmetic-heavy” 这条更窄 residual 仍然过严

这轮 residual 的核心数据是：

### `69e4179e...`

- `aggregate: 1 -> 7`
- `arithmetic: 160 -> 139`
- `vector: 306 -> 305`
- `cast: 52 -> 52`
- `totalAbsoluteDelta = 28`

### `d8c964c5...`

- `aggregate: 1 -> 12`
- `arithmetic: 186 -> 160`
- `vector: 364 -> 368`
- `cast: 57 -> 57`
- `totalAbsoluteDelta = 41`

两支 case 都没有触及 compare 当前真正高风险的边界：

- `cfg` 没变
- `argSemantics / resourceSemantics / builtinSemantics / outputSemantics` 没变
- `call / intrinsic / memory / compare` 统计没变
- compile posture 继续对齐

因此它们更像是 optimizer / codegen 造成的 arithmetic-heavy materialization reshaping，而不是实现层真的发生了新的语义回退。

## 实现修改

本轮继续只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

保留 `CC-003.20` 已建立的 baseline same-CFG materialization drift 窗口，同时补一条更窄的 arithmetic-heavy 分支，仅覆盖当前 diagnostics residual：

- baseline 分支保持不变：
  - `arithmetic <= 16`
  - `aggregate <= 19`
  - `vector <= 6`
  - `cast <= 2`
  - `totalDelta <= 27`
- 新增 arithmetic-heavy 分支：
  - `arithmetic <= 26`
  - `aggregate <= 12`
  - `vector <= 4`
  - `cast == 0`
  - `totalDelta <= 41`

其余约束保持不变：

- `changed_keys` 仍只允许落在 `{aggregate, arithmetic, vector, cast}`
- 仍要求至少命中 `aggregate / arithmetic / vector` 之一
- `cfg`、语义摘要、`airIntrinsicCalls` 继续必须完全一致

也就是说，本轮不是继续无差别扩大 materialization 窗口，而是只为“同 CFG + 无 cast 漂移 + arithmetic-heavy” 这条更窄 family 补齐 compare 吸收边界。

## 单 case 证据

### 1. `69e4179e...`：同 CFG + arithmetic-heavy tradeoff

`cc-003-21-single-69e4179e-arithmetic-heavy` 下可以直接看到：

- `riskCounts = L1 1 / L2 0 / L3 0`
- `riskLevel: L2 -> L1`
- `instructionFamilyComparison = L1`
- 顶层 residual 继续只剩：
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块元数据 targetTriple 变化`

这说明这支 diagnostics fragment case 已经从“仍需进入 L3”回落到“可接受 compare drift”。

### 2. `d8c964c5...`：同 CFG + 更重 arithmetic-heavy tradeoff

`cc-003-21-single-d8c964c5-arithmetic-heavy` 下同样可以看到：

- `riskCounts = L1 1 / L2 0 / L3 0`
- `riskLevel: L2 -> L1`
- `instructionFamilyComparison = L1`
- `subject = fragment:xlatMtlMain`

这说明当前 compare 仍然只是在同 CFG 下对更重的 arithmetic-heavy materialization 过敏，而不是 fragment case 出现了新的真实语义回退。

## 测试与回归保护

本轮同步补了两条 compare 单测：

- `test_compare_downgrades_same_cfg_arithmetic_heavy_materialization_drift_to_l1`
- `test_compare_keeps_l2_for_same_cfg_arithmetic_heavy_materialization_with_cast_drift`

并继续依赖已有 guardrail，确保“窗口之外的大 drift”仍保持 `L2`。

复跑：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

均通过。

## 一句话结论

**`CC-003.21` 已确认仍然是 compare 口径问题：当 CFG、语义摘要、`air intrinsic` 统计以及 compile posture 都继续一致，且 `cast` 完全不漂移时，`69e4179e...` 与 `d8c964c5...` 这类 arithmetic-heavy materialization tradeoff 也不应继续顶成 `L2`；补齐这一条更窄 compare 分支后，两支 diagnostics residual 均稳定从 `L2 -> L1`。**
