## constant-struct-reference-dereferenceable：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.6` 里一支高频 `L3`：

- `entry 参数类型摘要变化`

沿着 `c6d1420a...`、`82d1eb85...`、`1cdc9318...` 这类样本下钻后，可以把问题收敛成一条很具体的 converter 缺口：

- original IR 的某些 constant buffer 参数带有 `dereferenceable(N)`
- regenerated IR 会把其中一部分降成只有 `ptr addrspace(2)`
- 差异并不来自 compare 口径，而是来自 **`IRToMSLConverter.swift` 对“哪些 constant buffer struct 应保留为引用 `&`”的判定过窄**

修复前它只把“首字母大写”的类型名当成 struct，因此：

- `UnityPerCamera_Type` 会保留成 `const constant UnityPerCamera_Type&`
- 但 `_ScreenSpaceShadowParams_Type`、`_DirectionalShadowBuffer_Type`、`cb_SSAOBlur_Type`、`cb_TAA_Type` 这类真实用户类型会被误判成普通类型
- 结果生成的 MSL 退化成 `const constant T*`
- Metal 再编译回 AIR 时，这些参数对应的 `dereferenceable(N)` 会丢失，最终在 canonical compare 里被顶成 `entry 参数类型摘要变化`

## 单 case 证据

代表 case：

- 修复前基线：`build/semantics-validation/roundtrip/cc-003-5-1-corpus-20260410-converter-first-single-field-return/compare-summary.json`
- 修复后单 case：`build/semantics-validation/roundtrip/cc-003-6-single-c6d142-dereferenceable-reference/compare-summary.json`

`c6d1420a...` 的轨迹现在可以写成：

- 修复前：`L3`
  - 关键原因：`entry 参数类型摘要变化`
  - 差异：`ptr addrspace(2) dereferenceable(48) -> ptr addrspace(2)`
- 修复后：`L1`
  - `entryComparison` 已变成 **`L0`**
  - `entry 参数类型摘要变化` 完全消失
  - 剩余只剩：
    - `模块级 addrspace 分布变化`
    - `模块元数据 targetTriple 变化`

为了把这条修复进一步收紧到一个最小、可复现的离线样本，本轮还新增了：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_underscore_struct_reference.ll`

并做了两层验证：

1. `corpus_replay_runner.py` 生成的 `generated.metal` 已恢复为：
   - `const constant _ShadowParams_Type& shadowParams [[buffer(0)]]`
   - 不再是 `const constant _ShadowParams_Type* ...`
2. 完整 round-trip 输出：
   - `build/semantics-validation/roundtrip/manual-underscore-struct-reference`
   - `entryComparison = L0`
   - `blockedSamples = []`
   - regenerated IR 中保留 `dereferenceable(4)`

## 本轮实现内容

本轮继续遵守 dashboard 的 converter-first 规则，只改生成侧：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 放宽 `isStructTypeName(...)` 的判定
  - 不再只把“首字母大写”的类型名视为 struct
  - 新规则同时覆盖：
    - `_ScreenSpaceShadowParams_Type`
    - `_DirectionalShadowBuffer_Type`
    - `cb_SSAOBlur_Type`
    - 以及其它 `*_Type` constant buffer 用户类型
  - 因而这些参数在 `generateAllParams(...)` / SSA 参数建模里都能继续走 `const constant T&` 路径
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增 replay 回归：验证 underscore-prefixed struct 会发成引用参数
  - 新增 round-trip 回归：验证 regenerated IR 保住 `dereferenceable(4)`，且不再进入 `blockedSamples`
- `LocalDocs/.../test-data/test_underscore_struct_reference.ll`
  - 新增最小 IR 样本，稳定复现 `_Type` constant buffer 引用保留场景

## 单 case 验证结果

本轮已完成三层验证：

1. `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_keeps_underscore_prefixed_constant_struct_as_reference`
   - 通过
2. `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_roundtrip_runner_preserves_dereferenceable_for_underscore_prefixed_constant_struct`
   - 通过
3. `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../c6d142.../original.ll --output-root build/semantics-validation/roundtrip/cc-003-6-single-c6d142-dereferenceable-reference`
   - 通过
   - `c6d1420a...` 从 `L3 -> L1`
   - `entryComparison`：`L3 -> L0`
   - `blockedSamples = []`
   - gate `PASS`

## 当前结论

本轮已经可以明确下结论：

- 这支 `entry 参数类型摘要变化` 不需要先动 compare
- 它至少有一大支是真实的 converter 参数发射问题：**constant buffer struct 是否保留为引用 `&` 的判定过窄**
- 只要把 `_Foo_Type` / `cb_Foo_Type` 这类用户 struct 也保留在引用路径上，`dereferenceable(N)` 就能从生成侧稳定保住
- 这是一处小改动，但能同时改善一整支高频 blocked family

## 下一步建议

既然这支纯 `entry 参数类型摘要变化` family 已经被收掉，下一步更值得继续分析的是：

- 仍然同时出现在 corpus / diagnostics 的 `模块级 addrspace 分布变化 + 模块级 air intrinsic 使用变化` family
- 以及 corpus 中还剩的 `entry 参数个数变化`（幽灵 `air.position` 参数）family

也就是当前 full-batch 里，已经从 entry 参数类型 `L3` 退去之后真正暴露出来的 residual family。