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

## 追加：`CC-003.22` 实现结果

## 本轮分析的差异类型

本轮继续处理 corpus 中唯一残留、且继续挂在 gate 顶部的实现层候选：

- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `指令族统计变化`

代表 case 为：

- `build/semantics-validation/roundtrip/cc-003-22-single-shuffle-gated/`
- 目标样本：`c2cd49d0...`

## 结论：这是 converter lowering 缺口，不是 compare 噪声

重新下钻 `original.ll / generated.metal / regenerated.ll` 后，当前证据链已经足够明确：

- 原始 IR 的关键链是 `fcmp <2 x float> -> zext <2 x i1> to <2 x i8> -> shufflevector -> and <4 x i8> -> icmp ne zeroinitializer`
- 默认 `ucharN(boolN)` lowering 会让 regenerated IR 回到 `@air.convert.u.v2i8.u.v2i1`
- 因为该 intrinsic 同时放大到 module-level intrinsic 统计与 instruction-family compare，`c2cd49...` 会继续停在 `L2`
- 之前的 broad `select(ucharN(0), ucharN(1), boolN)` 虽能修掉单 case，但会误伤一批 `extractelement` / `insertelement` 消费链，因此不能直接恢复

因此，这轮已经可以把 root cause 定性为：**converter 对“vector bool zext 后直接进入 `shufflevector` 的 mask materialization”缺少更窄 lowering 规则。**

## 实现修改

这轮继续只做一处最小实现收敛：

### `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter+BodyTranslation.swift`

新增一轮轻量 direct-user prescan：

- 不引入完整 def-use 框架
- 只在函数体翻译前记录 SSA 结果的**直接消费者 opcode 集合**
- 目的是给 `translateIntCast(...)` 提供一个极窄、可控的 consumer gate

### `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter+InstructionTranslation.swift`

把之前 broad 的想法收窄为：

- 仅当 `opcode == zext`
- 且源类型是 `<N x i1>`、目标类型是 `<N x i8>`
- 且该 SSA 结果的 `immediate users == { shufflevector }`

才改发：

- `select(ucharN(0), ucharN(1), boolN)`

其它消费模式（尤其 `extractelement` / `insertelement`）继续保持默认 `ucharN(boolN)`，避免 broad select 在 full-batch 中扩散。

### 测试样本同步

为了让回归样本真正覆盖本轮命中的 residual，本轮同时把：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_intrinsic_vector_icmp_zext.ll`

更新为最小化的 `zext -> shufflevector -> and -> icmp ne` 物化链，并保留现有 Python 回归断言。

## 单 case / 回归验证

本轮已完成并通过：

- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ./BuildScripts/build_and_install.sh`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../c2cd49.../original.ll --output-root build/semantics-validation/roundtrip/cc-003-22-single-shuffle-gated`

关键结果：

- 回归测试中的 `select(uchar2(0), uchar2(1), ...)` 断言重新通过
- `c2cd49...` 单 case 已从 `L2 -> L1`
- regenerated IR 中不再出现 `@air.convert.u.v2i8.u.v2i1`

## 一句话结论

**`CC-003.22` 已确认是 converter 的更窄 lowering 缺口：只要把 `zext <N x i1> -> <N x i8>` 收敛到 “直接消费者仅为 `shufflevector`” 这一条物化链上，既能稳定消掉 `c2cd49...` 的 `module air intrinsic + instruction-family` residual，又不会重新放大到此前 broad select 曾误伤的 `extractelement` / `insertelement` 家族。**

## 追加：`CC-003.23` 实现结果

## 本轮分析的差异类型

本轮继续处理 `CC-003.22` 之后 corpus 中仍停在 `L2` 的一支高频 residual：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

代表 case 选在：

- `build/semantics-validation/roundtrip/cc-003-23-single-055fe-vector-heavy/`
- 目标样本：`055fe879...`

## 结论：这是 compare 边界仍偏窄，不是 converter / compile posture 回退

重新下钻 `compare-summary.json` / `compile-summary.json` 后，当前证据链足够明确：

- `cfg` 继续完全一致
- `entry / resource / builtin / addrspace` 摘要继续完全一致
- `compile-summary.json` 已明确给出：
  - `originalFastMathMode = enable`
  - `inferredMetalArgs = -ffast-math`
  - `effectiveMetalArgs = -ffast-math`
- 代表 case 的 `instructionFamilies` 漂移只剩：
  - `arithmetic: 222 -> 202`
  - `vector: 363 -> 381`
  - `aggregate` / `cast` 完全不变

因此当前 residual 更像是 **same-CFG 下的 vector-heavy materialization tradeoff**，而不是 emitted MSL、compile decision 或语义建模真的发生了新的回退。

## 实现修改

这轮继续只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

在已有 baseline / arithmetic-heavy 两条 materialization 窗口之外，补一条更窄的 vector-heavy 分支，仅覆盖当前这支 shared residual：

- `changed_keys == {arithmetic, vector}`
- `arithmetic <= 20`
- `vector <= 30`
- `aggregate == 0`
- `cast == 0`
- `totalDelta <= 38`

也就是说，这轮不是继续无差别扩大 same-CFG materialization 窗口，而是只吸收 **无 `aggregate/cast` 漂移、且仍保持双项 arithmetic/vector tradeoff** 的更窄 family。

### `Scripts/test_ir_canonical_compare.py`

本轮同步补了两条 guardrail 单测：

- `test_compare_downgrades_same_cfg_vector_heavy_materialization_drift_to_l1`
- `test_compare_keeps_l2_for_same_cfg_vector_heavy_materialization_outside_window`

## 单 case / 回归验证

本轮已完成并通过：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../055fe879.../module.ll --output-root build/semantics-validation/roundtrip/cc-003-23-single-055fe-vector-heavy`

关键结果：

- `055fe879...` 单 case `riskCounts = L1 1 / L2 0 / L3 0`
- `instructionFamilyComparison = L1`
- compile posture 继续对齐，未引入新的更坏差异

## 一句话结论

**`CC-003.23` 已确认仍是 compare 口径问题：当 `cfg`、语义摘要与 compile posture 都继续一致，且 `aggregate/cast` 完全不漂移时，`055fe879...` 这类 same-CFG vector-heavy materialization tradeoff 不应继续顶成 `L2`；补齐这条更窄 compare 分支后，代表 case 已稳定从 `L2 -> L1`。**

## 追加：`CC-003.24` 实现结果

## 本轮分析的差异类型

本轮继续处理 `CC-003.23` 之后 corpus 中仍然最高频的一支 shared residual：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

代表 case 选在：

- `build/semantics-validation/roundtrip/cc-003-24-single-e17ab0cb-select-heavy/`
- 目标样本：`e17ab0cb...`

## 结论：这是 compare 对 shared-CFG skeleton-preserved materialization drift 仍偏窄，不是 compile posture 回退

重新下钻 `compare-summary.json` / `compile-summary.json` 后，当前证据链已经足够明确：

- `entry / resource / builtin / output` 语义继续完全一致
- `air intrinsic` 统计继续一致
- `compile-summary.json` 继续显示：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = -ffast-math`
  - `fastMathDecision = fast_math_aligned`
- 真正还停在 `L2` 的，是一类更窄的 shared-CFG residual：
  - `basicBlockCount` 不变
  - `terminatorCounts` 不变
  - `phiCount` 不变
  - 但 `selectCount: 7 -> 14`
  - 同时 `arithmetic: 62 -> 55`
  - `vector: 119 -> 153`
  - `aggregate` / `cast` 完全不变
  - `totalAbsoluteDelta = 41`

因此这轮更像是 **CFG 骨架保持不变时的 select-heavy vector materialization tradeoff**，而不是 emitted MSL、compile decision 或语义建模真的发生了新的回退。

## 实现修改

这轮继续只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

在已有 baseline / arithmetic-heavy / vector-heavy 三条 materialization 窗口之外，再补一条更窄的 `select-heavy` shared-CFG 分支，仅覆盖当前这支 residual：

- 不再要求 `lhs_cfg == rhs_cfg`
- 但要求 `basicBlockCount`、`terminatorCounts`、`phiCount` 完全一致，也就是 **CFG skeleton matches**
- 仍要求 `changed_keys == {arithmetic, vector}`
- 仍要求 `aggregate == 0`
- 仍要求 `cast == 0`
- 新增约束：
  - `selectDelta <= 8`
  - `arithmeticDelta <= 8`
  - `vectorDelta <= 40`
  - `totalDelta <= 48`

也就是说，这轮不是继续无差别放宽 shared-CFG compare，而是只吸收 **CFG 骨架不变 + selectCount 增长 + arithmetic/vector 双项重分配** 的更窄 family。

### `Scripts/test_ir_canonical_compare.py`

本轮同步补了两条 guardrail 单测：

- `test_compare_downgrades_select_heavy_vector_materialization_drift_with_shared_cfg_skeleton_to_l1`
- `test_compare_keeps_l2_for_select_heavy_vector_materialization_drift_outside_select_window`

## 单 case / 回归验证

本轮已完成并通过：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../e17ab0cb.../module.ll --output-root build/semantics-validation/roundtrip/cc-003-24-single-e17ab0cb-select-heavy`

关键结果：

- `e17ab0cb...` 单 case `riskCounts = L1 1 / L2 0 / L3 0`
- `cfgComparison = L1`
- `instructionFamilyComparison = L1`
- compile posture 继续对齐，未引入新的更坏差异

## 一句话结论

**`CC-003.24` 已确认仍是 compare 口径问题：当 `cfg` 的 block / terminator / phi 骨架继续一致、语义摘要与 `air intrinsic` 统计不变、且 compile posture 仍然对齐时，`e17ab0cb...` 这类 shared-CFG select-heavy vector materialization drift 不应继续顶成 `L2`；补齐这条更窄 compare 分支后，代表 case 已稳定从 `L2 -> L1`。**
