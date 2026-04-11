## fragment-discard-lowering：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.13` 在 sampler-state operand 对齐之后继续残留的一支高频 residual mechanism：

- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `控制流粗摘要变化`
- 常伴随 `指令族统计变化` / `fast-math 相关属性变化`

代表 case 继续沿：

- `build/semantics-validation/roundtrip/cc-003-13b-single-293ec561-discard-fragment/com.miHoYo.Yuanshen/modules/293ec561067f16e66e9282142cf70e4a9f5136f6e448e66338c56ca210319853/`

这轮重新下钻后，可以把 root cause 进一步收敛成一条明确的 converter 缺口：

- 不是 `compile-summary.json` 对应的 planner / fast-math posture 回退
- 也不是 `ir_canonical_compare.py` 单纯把分支 reshape 放大
- 真正的问题是：**`IRToMSLConverter.swift` 对 `air.discard_fragment()` 没有 first-class MSL lowering，只发出 `/* air.discard_fragment() */` 注释占位，导致 Metal 重编译后整支 fragment 分支被线性化，`discard_fragment` 调用本身也从 regenerated AIR 中消失**

## 单 case 证据

### `293ec561...`

本轮对 `293ec561...` 的 emitted-MSL → regenerated-AIR 闭环复核后，证据链已经足够明确：

1. 修复前 `generated.metal` 在两个分支点都只留下了 `/* air.discard_fragment() */`
2. 修复前 regenerated AIR 不再包含 `air.discard_fragment`，同时 CFG 从 `5` 个 basic blocks 线性化为 `1` 个 basic block
3. 只要把这一路改成真实的 `discard_fragment();`，重新 round-trip 后 regenerated AIR 就恢复了 `air.discard_fragment: 2`
4. 同一 real sample `293ec561...` 的顶层风险直接从 `L2 -> L1`

也就是说，这里不是 compare 对 optimizer reshape 过敏，而是 converter 的 emitted MSL 真的把 fragment termination 语义降成了注释。

## 本轮实现内容

本轮继续遵守 dashboard 的 implementation-first 原则，只做一处最小 converter 修正与一条最小回归：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 给 `air.discard_fragment` 增加正式映射
  - emitted MSL 不再输出 `/* air.discard_fragment() */` 占位，而是输出真实 `discard_fragment();`
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fragment_discard.ll`
  - 新增最小 fragment fixture，固定覆盖 `fcmp + br + air.discard_fragment + merge` 形态
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增定向 replay 回归：`test_corpus_replay_runner_emits_real_fragment_discard`
  - 固定验证 converter 会发出真实 `discard_fragment();`，而不是 placeholder comment

这次改动保持得很窄：

- 不改变 `sample_compare` / sampler-state 逻辑
- 不改变 compare risk 口径
- 不改变普通 control-flow emission
- 只影响 `air.discard_fragment` 这一路 builtin lowering

## 单 case 验证结果

### 1. 定向回归

已通过：

- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_emits_real_fragment_discard`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/test_ir_canonical_compare.py`

新增最小 fixture 已明确验证：

- fragment discard 会被发射为真实 `discard_fragment();`
- emitted MSL 不再包含 `/* air.discard_fragment() */`

### 2. 真实样本单 case

#### `293ec561...`

- 输出：`build/semantics-validation/roundtrip/cc-003-13b-single-293ec561-discard-fragment/`
- compile posture：继续保持对齐
- 修复命中证据：
  - `generated.metal` 两处 discard 分支都已改成真实 `discard_fragment();`
  - `regenerated.ll` 中 `air.discard_fragment` 已恢复为 `2`
  - CFG 不再从 `5 BB -> 1 BB` 被整段线性化
- 顶层风险：`L2 -> L1`

当前代表 case 仍有 residual，但它已经从“高风险 family”降到“可接受 residual”：

- sampler-state operand 丢失已在上一轮修掉
- discard lowering 缺口这轮也已修掉
- 剩余差异主要收缩到 `fast_floor / fast_fract / fast_fmin` 一类 intrinsic reshaping 与轻量 instruction-family 漂移

## 当前结论

本轮已经可以明确下结论：

- `CC-003.13` 这支 family 至少还叠着第二处真实 converter 缺口
- 这处缺口不是 compare noise，而是 converter **没有把 `air.discard_fragment` 保成真实 fragment termination**
- 修复后代表 case `293ec561...` 已经从 `L2` 降到 `L1`，证明这支 family 中相当一部分统计噪声来自真实 emitted-MSL 语义丢失

## 下一步建议

这轮之后，下一步更值得继续下钻的是剩余高频 shared family：

- `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化`
- `指令族统计变化 + fast-math 相关属性变化 + 模块元数据 targetTriple 变化`

优先级上，先看 diagnostics / corpus 里都重复出现、且仍能落到 `fragment:xlatMtlMain` 的 shared family，例如：

- diagnostics：`25eef20f...` / `4f0656e...`
- corpus：`dd586566...` / `b95fff15...`

原因是这类 residual 已经同时出现在 corpus 与 diagnostics，两边都有统计收益空间，而且现在更像是 discard 修完之后暴露出来的下一层 emitted-MSL / regenerated-AIR reshape 机制。
