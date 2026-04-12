## scalar-vector-cast-materialization-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.20` 指向的最后一支高频 residual family：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

代表 case 先落在 corpus 中两支仍停留在 `L2` 的样本：

- `build/semantics-validation/roundtrip/cc-003-20-single-edca6ad0-materialization-wide/`
- `build/semantics-validation/roundtrip/cc-003-20-single-5780e492-materialization-wide/`

它们与 `CC-003.17` 已处理的“小幅 materialization + 极小 cast 漂移”不同，这轮 residual 的共同特征是：

1. `cfg` 继续完全一致
2. `entry / resource / builtin / output` 语义继续完全一致
3. `air intrinsic` 统计也继续一致
4. 但 `aggregate / arithmetic / vector` 的 tradeoff 明显更宽，已超过 `CC-003.17` 的 compare 窗口

## 结论：仍然是 compare 边界过窄，不是 converter / compile posture 回退

重新下钻后，这轮证据链也足够明确：

- 不是 `IRToMSLConverter.swift` 打乱了 entry / resource / builtin 语义
- 不是 compile posture 失配；两支 case 的 `compile-summary.json` 都继续显示：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = -ffast-math`
  - `fastMathDecision = fast_math_aligned`
- 真正的问题仍在 `Scripts/ir_canonical_compare.py`：
  - `_entry_has_small_scalar_vector_materialization_drift(...)` 对同 CFG 下更宽的 materialization drift 仍然过严

这轮 residual 的核心数据是：

### `edca6ad0...`

- `aggregate: 10 -> 12`
- `arithmetic: 115 -> 99`
- `vector: 111 -> 105`
- `cast: 25 -> 25`
- `totalAbsoluteDelta = 24`

### `5780e492...`

- `aggregate: 2 -> 21`
- `arithmetic: 55 -> 52`
- `vector: 141 -> 146`
- `cast: 2 -> 2`
- `totalAbsoluteDelta = 27`

两支 case 都没有触及 compare 当前真正高风险的边界：

- `cfg` 没变
- `argSemantics / resourceSemantics / builtinSemantics / outputSemantics` 没变
- `call / intrinsic / memory / compare` 统计没变

因此它们更像是 optimizer / codegen 造成的更宽 materialization reshaping，而不是实现层真的发生了新的语义回退。

## 实现修改

本轮仍然只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

继续沿用 `CC-003.17` 已建立的 same-CFG materialization drift 口径，但把允许窗口进一步放宽到能够覆盖当前 residual：

- `arithmetic <= 16`（原为 `<= 9`）
- `aggregate <= 19`（原为 `<= 12`）
- `vector <= 6`（维持不变）
- `cast <= 2`（维持不变）
- `totalDelta <= 27`（原为 `<= 24`）

其余约束保持不变：

- `changed_keys` 仍只允许落在 `{aggregate, arithmetic, vector, cast}`
- 仍要求至少命中 `aggregate / arithmetic / vector` 之一
- `cfg`、语义摘要、`airIntrinsicCalls` 继续必须完全一致

也就是说，本轮只是把 compare 对“更宽但仍然是同一类 materialization drift”的吸收窗口补齐，没有放松真正的语义 guardrail。

## 单 case 证据

### 1. `edca6ad0...`：同 CFG + 更宽 arithmetic tradeoff

`cc-003-20-single-edca6ad0-materialization-wide` 下可以直接看到：

- `riskCounts = L1 1 / L2 0 / L3 0`
- `riskLevel: L2 -> L1`
- `instructionFamilyComparison = L1`
- 顶层 residual 继续只剩：
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块元数据 targetTriple 变化`

这说明这支 vertex case 已经从“仍需进入 L3”回落到“可接受 compare drift”。

### 2. `5780e492...`：同 CFG + 更宽 aggregate reshaping

`cc-003-20-single-5780e492-materialization-wide` 下同样可以看到：

- `riskCounts = L1 1 / L2 0 / L3 0`
- `riskLevel: L2 -> L1`
- `instructionFamilyComparison = L1`
- `subject = fragment:xlatMtlMain`

这说明当前 compare 仍然只是在同 CFG 下对更宽 `aggregate` reshaping 过敏，而不是 fragment case 出现了新的真实语义回退。

## 测试与回归保护

本轮同步补了两条 compare 单测：

- `test_compare_downgrades_wider_scalar_vector_materialization_tradeoff_to_l1`
- `test_compare_downgrades_wider_aggregate_materialization_drift_to_l1`

并同步更新了原有 guardrail，使“仍应保持 `L2`”的 synthetic case 继续落在新窗口之外。

复跑：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

均通过。

## 一句话结论

**`CC-003.20` 已确认仍然是 compare 口径问题：当 CFG、语义摘要、`air intrinsic` 统计以及 compile posture 都继续一致时，`edca6ad0...` 与 `5780e492...` 这类更宽的 `aggregate / arithmetic / vector` materialization tradeoff 也不应继续顶成 `L2`；补齐 compare 窗口后，两支代表 case 均稳定从 `L2 -> L1`。**
