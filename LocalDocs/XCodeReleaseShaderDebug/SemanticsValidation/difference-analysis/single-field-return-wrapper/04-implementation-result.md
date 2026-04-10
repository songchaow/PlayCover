## single-field-return-wrapper：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.5` 里一支高频 `L3`：

- `entry 返回类型摘要变化`

下钻 `083c8443...` 这类样本后，可以看到 original / regenerated 的 `outputSemantics` 并没有真的变化；真正变化的是 **single-field entry output 的返回包装形态**：

- original 常见形态：`<{ <4 x half> }>`、`<{ <4 x float> }>`
- regenerated 常见形态：`<4 x half>`、`<4 x float>`

这轮重新按 dashboard 规则做了 converter-first 复核后，可以把问题进一步收紧成：

- 不是所有 single-output entry 都应该保留 wrapper
- 真正需要保留的是：**original IR 本身已经是 single-field aggregate return 的那一支**
- 当前 `IRToMSLConverter.swift` 在 entry return type 选择时，把这类 wrapped return 也提前塌成了裸返回类型，导致 round-trip 后 `returnSignature` 从源头漂移

## 单 case 证据

代表 case：

- 修复前：`build/semantics-validation/roundtrip/cc-003-5-single-speedmobile-return-wrapper-083c-v1/compare-summary.json`
- converter-first 修复后：`build/semantics-validation/roundtrip/cc-003-5-1-single-speedmobile-return-wrapper-083c-converter-first/compare-summary.json`

`083c8443...` 的轨迹现在可以清楚写成：

- 修复前：`L3`
  - 关键原因：`entry 返回类型摘要变化`
  - 差异：`<{ <4 x half> }> -> <4 x half>`
- converter-first 修复后：`L2`
  - regenerated `returnSignature` 已恢复成 `<{ <4 x half> }>`
  - `entry 返回类型摘要变化` 消失
  - 剩余只剩：
    - `控制流粗摘要变化`
    - `指令族统计变化`
    - `fast-math 相关属性变化`

为了把这类修复再压缩到一个最小、可复现的离线样本，本轮还直接用：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fragment_packed_return.ll`

做了两层验证：

1. `corpus_replay_runner.py` 生成的 `generated.metal` 已恢复为：
   - `struct Test_fragment_packed_Out { float4 color [[color(0)]]; };`
   - `fragment Test_fragment_packed_Out test_fragment_packed(...)`
2. 完整 round-trip 输出：
- `build/semantics-validation/roundtrip/manual-test-fragment-packed-return-converter-first`
- 结果为 **`L0`**，gate `PASS`


## 本轮实现内容

本轮这次没有再改 compare 规则，而是把修复落实在生成侧：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 新增 `shouldUseEntryOutputStruct(...)`
  - 新增 `unwrapSingleFieldAggregateIRType(...)`
  - 对 single-output entry，不再一律降成裸返回类型；只有当 original IR 不是 wrapped return 时才维持原有裸返回策略
  - 当 original IR 已经是 single-field aggregate return 时，保留 synthetic output struct 返回形态
  - `generateEntryOutputStructDefinition(...)` 也同步改成：只有 entry 的最终返回类型确实选择了 synthetic struct 时才生成对应定义
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增 converter-first 回归：
    - 检查 `test_fragment_packed_return.ll` 生成的 MSL 里确实恢复了 single-field output struct
    - 检查完整 round-trip 后该样本为 `L0`
- `Scripts/ir_semantics_roundtrip_runner.py`
  - 基于最新 converter-first full-batch 结果，再次收紧 `LOCAL_SHADERCORPUS_REPRESENTATIVE_CONTRACT`，移除已稳定降到 `L1` 的 `1f5e65...` blocked 白名单

## 单 case 验证结果

本轮已完成三层验证：

1. `python3 -m unittest Scripts/test_ir_semantics_roundtrip_runner.py -k fragment_output_wrapper`
   - 通过
2. `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../module.ll --output-root build/semantics-validation/roundtrip/cc-003-5-1-single-speedmobile-return-wrapper-083c-converter-first`
   - 通过
   - `083c8443...` 从 `L3 -> L2`
   - `blockedSamples = []`
3. `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../test_fragment_packed_return.ll --output-root build/semantics-validation/roundtrip/manual-test-fragment-packed-return-after-compare-fix`
   - 通过
   - 最小样本达到 **`L0`**
   - gate `PASS`

## 当前结论

本轮已经可以明确下结论：

- `CC-003.5` 里这支高频 `entry 返回类型摘要变化` 并不需要先动 compare
- 它至少有一大支是真实的 converter 选择问题：**single-field wrapped return 被过早塌成了裸返回类型**
- 按 converter-first 修完之后，single-field return wrapper family 可以直接从生成侧被收敛掉
- 在这个前提下，compare 继续保留原有更严格的 `returnSignature` 判定也能拿到正确收益

## 下一步建议

既然这支高频 blocked family 已经通过 converter-first 收敛，下一步更值得继续分析的是：

- 仍然停留在 `L3` 的真实 `entry 参数类型摘要变化`
- `模块级 addrspace 分布变化`
- `控制流粗摘要变化`

也就是当前最新 full-batch 里还没有被这次生成侧修复解释掉的 residual family。
