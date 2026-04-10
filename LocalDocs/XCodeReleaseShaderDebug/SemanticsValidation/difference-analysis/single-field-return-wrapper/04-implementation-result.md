## single-field-return-wrapper：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.5` 里一支高频 `L3`：

- `entry 返回类型摘要变化`

下钻 `083c8443...` 这类样本后，可以看到 original / regenerated 的 `outputSemantics` 并没有真的变化；真正变化的是 **single-field entry output 的返回包装形态**：

- original 常见形态：`<{ <4 x half> }>`、`<{ <4 x float> }>`
- regenerated 常见形态：`<4 x half>`、`<4 x float>`

也就是说，这支 residual 的主矛盾不是“entry first-class 输出语义真的变了”，而是：

- original AIR 往往把单字段输出保留成 packed single-field wrapper
- regenerated AIR 更倾向直接返回该字段自身类型
- 当 `outputSemantics` 完全一致且只存在一个 output 时，直接按 `returnSignature` 文本做 `L3` 判定会把大量 blocked 样本误判成结构性不一致

## 单 case 证据

代表 case：

- `build/semantics-validation/roundtrip/cc-003-5-single-speedmobile-return-wrapper-083c-v1/compare-summary.json`
- `build/semantics-validation/roundtrip/cc-003-5-single-speedmobile-return-wrapper-083c-v2/compare-summary.json`

`083c8443...` 在修正前后有一条很稳定的轨迹：

- `v1`：`L3`
  - 关键原因：`entry 返回类型摘要变化`
  - 差异：`<{ <4 x half> }> -> <4 x half>`
- `v2`：`L2`
  - `entry 返回类型摘要变化` 消失
  - 剩余只剩：
    - `控制流粗摘要变化`
    - `指令族统计变化`
    - `fast-math 相关属性变化`

为了把这类等价性再压缩到一个最小、可复现的离线样本，本轮还直接用：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fragment_packed_return.ll`

重跑一条最小 round-trip：

- 输出：`build/semantics-validation/roundtrip/manual-test-fragment-packed-return-after-compare-fix`
- 结果：`L1`，gate `PASS`
- 这说明当前仓库状态下，这个最小 single-field packed return 样本已经不再被视作 `L3` blocker

## 本轮实现内容

本轮没有再去扩大 `IRToMSLConverter.swift` 的发射逻辑，而是把闭环补在 compare / gate 这一层：

- `Scripts/ir_canonical_compare.py`
  - 新增 `_unwrap_single_field_aggregate_signature(...)`
  - 新增 `_single_output_return_wrapper_equivalent(...)`
  - 当且仅当满足下面条件时，不再把 `returnSignature` 文本差异判成 `L3`：
    - original / regenerated 的 `outputSemantics` 完全一致
    - 且只存在一个 output
    - 且差异只是 `single-field wrapper <-> bare return type` 的形态变化
- `Scripts/test_ir_canonical_compare.py`
  - 新增 single-field return wrapper 的等价 / 非等价边界单测
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增端到端 round-trip 回归，确认 `test_fragment_packed_return.ll` 会被降成非阻断 `L1`
- `Scripts/ir_semantics_roundtrip_runner.py`
  - 收紧 `LOCAL_SHADERCORPUS_REPRESENTATIVE_CONTRACT`，移除已在最新 full-batch 中降到 `L1` 的 `1f5e65...` blocked 白名单

## 单 case 验证结果

本轮已完成三层最小验证：

1. `python3 -m unittest Scripts/test_ir_canonical_compare.py`
   - 通过
2. `python3 -m unittest Scripts/test_ir_semantics_roundtrip_runner.py`
   - 通过
3. `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../test_fragment_packed_return.ll --output-root build/semantics-validation/roundtrip/manual-test-fragment-packed-return-after-compare-fix`
   - 通过
   - 结果从 `L3 -> L1`
   - `blockedSamples = []`
   - gate `PASS`

## 当前结论

本轮已经可以明确下结论：

- `CC-003.5` 里一大支 `entry 返回类型摘要变化` 不是 entry 输出语义真的变了
- 它本质上是 **single-field wrapper return vs bare return** 的 compare 口径问题
- 这类问题更适合在 `ir_canonical_compare.py` 做定向等价判定，而不是反过来强迫 converter 回到更重的 synthetic wrapper 发射
- 在 compare 补齐后，原本大量 `L3` blocked 样本被重新释放成可继续分析的 `L2/L1` residual

## 下一步建议

既然这支高频 blocked family 已经被打散，下一步更值得继续分析的是：

- 仍然停留在 `L3` 的真实 `entry 参数类型摘要变化`
- `模块级 addrspace 分布变化`
- `控制流粗摘要变化`

也就是当前最新 full-batch 里还没有被 `single-field return wrapper` 规则解释掉的 residual family。