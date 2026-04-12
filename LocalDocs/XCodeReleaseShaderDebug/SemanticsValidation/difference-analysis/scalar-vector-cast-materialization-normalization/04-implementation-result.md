## scalar-vector-cast-materialization-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.16` 之后 dashboard 仍明确优先的一支 residual family：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

但与 `CC-003.12` 已处理的“同 CFG + 少量 scalar/vector/aggregate materialization 重排”相比，这轮残留多了两个新的形态：

1. 同 CFG 下，除了 `aggregate / arithmetic / vector` 变化外，还会多出**极小的 `cast` 漂移**
2. `aggregate` 的重排幅度比 `CC-003.12` 略大，但仍然没有触及 entry/resource/builtin/intrinsic 语义

代表 case 先落在：

- corpus：`build/semantics-validation/roundtrip/cc-003-17b-single-3a9cedb-materialization-cast/`
- diagnostics：`build/semantics-validation/roundtrip/cc-003-17b-single-376c8b2c-materialization-wide/`
- corpus 回归保护：`build/semantics-validation/roundtrip/cc-003-17b-single-2984b21c-materialization-arithmetic/`

## 结论：这轮仍然是 compare 口径问题，不是实现层回退

重新下钻后，证据链已经足够明确：

- 不是 `IRToMSLConverter.swift` 再次打乱 entry / resource / builtin 语义
- 也不是 shared planner 或 fast-math compile posture 回退
- 真正的问题是：**`ir_canonical_compare.py` 中“同 CFG materialization drift” 的降噪条件仍过窄，无法覆盖一批实际仍然只是 optimizer / codegen 物化重排的残留 case**

旧规则的问题点有两个：

1. `changed_keys` 只允许 `{aggregate, arithmetic, vector}`，因此 `3a9cedb...` 这类再伴随 `cast: 5 -> 3` 的 case 仍会被顶成 `L2`
2. `aggregate <= 4` 的上限过窄，因此 `376c8b2c...` 这类 `aggregate: 1 -> 12`、但 CFG / 语义 / intrinsic 统计完全一致的 case 也被继续记成 `L2`

另外，这轮实现过程中还暴露出一个重要回归点：

- 我第一次放宽规则时把 `arithmetic` 上限误收紧到 `<= 6`
- 结果把 `CC-003.12` 已经收掉的 `2984b21c...`、`2629c34e...` 这类 `arithmetic` 差值更高、但仍属于同 family 的 case 又抬回了 `L2`
- 因此最终落地时必须把 `arithmetic` 上限恢复到兼容旧 family 的范围

## 实现修改

最终只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

把 `_entry_has_small_scalar_vector_materialization_drift(...)` 扩展为：

- 继续要求：
  - `argSemantics / resourceSemantics / builtinSemantics / outputSemantics` 完全一致
  - 函数内 `airIntrinsicCalls` 归一化后完全一致
  - `cfg` 完全一致
- 允许的 `instructionFamilies` 漂移键从：
  - `{aggregate, arithmetic, vector}`
  扩展为：
  - `{aggregate, arithmetic, vector, cast}`
- 同时新增/调整上限：
  - `cast <= 2`
  - `aggregate <= 12`
  - `arithmetic <= 9`
  - `vector <= 6`
  - `totalDelta <= 24`
- 另外要求 `changed_keys` 里至少仍包含 `aggregate / arithmetic / vector` 之一，避免把纯 `cast` 漂移单独误吸进去

这意味着：

- `3a9cedb...` 的“小幅 cast + 轻微 materialization reshaping” 不再被误判成 `L2`
- `376c8b2c...` 的“更宽 aggregate reshaping” 也能被稳定降到 `L1`
- `2984b21c...` / `2629c34e...` 这类 `CC-003.12` 已收敛 case 不会被重新抬回 `L2`

## 单 case 证据

### 1. `3a9cedb...`：同 CFG + 小幅 cast 漂移

`cc-003-17b-single-3a9cedb-materialization-cast` 下可以看到：

- compile posture 对齐：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = -ffast-math`
  - `fastMathDecision = fast_math_aligned`
- `entryComparison = L0`
- `builtinComparison = L0`
- `cfgComparison = L0`
- `instructionFamilyComparison = L1`
- 顶层风险：`L2 -> L1`

这支 case 的核心差异是：

- `aggregate: 1 -> 4`
- `arithmetic: 26 -> 25`
- `cast: 5 -> 3`
- `vector: 53 -> 52`

也就是说，它并没有触及真实语义层，只是在同 CFG 下多出极小的 cast/materialization reshaping。

### 2. `376c8b2c...`：同 CFG + 更宽 aggregate reshaping

`cc-003-17b-single-376c8b2c-materialization-wide` 下可以看到：

- compile posture 同样对齐：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = -ffast-math`
  - `fastMathDecision = fast_math_aligned`
- `entryComparison = L0`
- `builtinComparison = L0`
- `cfgComparison = L0`
- `instructionFamilyComparison = L1`
- 顶层风险：`L2 -> L1`

关键差异集中在：

- `aggregate: 1 -> 12`
- `arithmetic: 53 -> 47`
- `vector: 127 -> 132`

虽然 `aggregate` 幅度比 `CC-003.12` 旧阈值更大，但 CFG、语义和 intrinsic 统计完全一致，因此更像 compare 仍对 materialization reshaping 过敏，而不是实现层真的回退。

### 3. `2984b21c...`：高 arithmetic tradeoff 的旧 family 回归保护

`cc-003-17b-single-2984b21c-materialization-arithmetic` 用来确认这轮不会打破 `CC-003.12` 的既有收益：

- compile posture 继续对齐：`originalFastMathMode = enable`、`effectiveMetalArgs = -ffast-math`
- `entryComparison = L0`
- `builtinComparison = L0`
- `cfgComparison = L0`
- `instructionFamilyComparison = L1`
- 顶层风险继续保持：`L2 -> L1`

这说明最终阈值既覆盖了这轮新增变体，也没有回退掉之前已收敛的 materialization family。

## 测试与回归保护

本轮同步补了三条 compare 单测：

- `test_compare_downgrades_small_scalar_vector_materialization_drift_with_cast_reshaping_to_l1`
- `test_compare_downgrades_wider_scalar_vector_materialization_drift_to_l1`
- `test_compare_downgrades_scalar_vector_materialization_drift_with_high_arithmetic_tradeoff_to_l1`

并复跑：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

均通过。

## 一句话结论

**`CC-003.17` 已确认是 compare 口径问题：当 CFG、语义与 `air intrinsic` 统计已经一致时，同 CFG 下少量 `aggregate / arithmetic / vector` 重排即使再伴随极小 `cast` 漂移，也不应继续记为 `L2`；修复后 `3a9cedb...`、`376c8b2c...`、`2984b21c...` 均稳定回落到 `L1`。**
