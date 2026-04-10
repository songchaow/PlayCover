## position-invariant-output：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.7` 里一支高频 `L3`：

- `entry 输出语义摘要变化`

从 `cc-003-6-corpus-20260410-dereferenceable-reference` 的最新 canonical compare 下钻后，可以把这支 family 收敛成一条非常具体的 converter 缺口：

- original IR 的 vertex 输出里，`air.position` 带有 `air.invariant`
- regenerated IR 里，这个 qualifier 会丢失
- canonical compare 因而稳定出现：
  - `kind=air.position|type=float4|qualifiers=air.invariant`
  - `-> kind=air.position|type=float4`

代表 case：

- `fc1d64b2...`
- 所在批次：`build/semantics-validation/roundtrip/cc-003-6-corpus-20260410-dereferenceable-reference`

这支差异并不是 compare 口径噪声；继续下钻 `original.ll` / `generated.metal` / `regenerated.ll` 后，可以确认真正缺口在生成侧：

- `IRToMSLConverter.swift` 的 `parseMetadataReturnNode(...)` 只解析 `air.arg_type_name` / `air.arg_name` / `air.location_index`
- 像 `air.invariant` 这样的返回 qualifier 会在 metadata 解析阶段被直接跳过
- 后续生成 entry output struct 时，`air.position` 固定只发 `[[position]]`
- Metal 再编译回 AIR 后，自然不可能重新生成 `air.invariant`

## 单 case 证据

代表样本 `fc1d64b2...` 的关键变化现在可以写成：

- 修复前：
  - `entryComparison = L3`
  - 关键差异：`entry 输出语义摘要变化`
  - `outputSemantics`：
    - original：`kind=air.position|type=float4|qualifiers=air.invariant`
    - regenerated：`kind=air.position|type=float4`
- 修复后单 case：`build/semantics-validation/roundtrip/cc-003-7-single-fc1d64-position-invariant`
  - `entryComparison = L0`
  - `entry 输出语义摘要变化` 完全消失
  - `outputSemantics` 已重新对齐为：
    - `kind=air.position|type=float4|qualifiers=air.invariant`
    - `kind=air.vertex_output|type=half2`

需要注意的是：

- 这个代表 case 的 **entry 语义问题已经被实打实修掉**
- 但整体风险仍然是 `L3`
- 剩余原因不再是 entry 输出语义，而是：
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块元数据 targetTriple 变化`

也就是说，这轮修复命中了真实问题，但它不是这批样本最后的 blocked ceiling。

## 本轮实现内容

本轮继续遵守 dashboard 的 converter-first 规则，只改生成侧：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 给 `MetadataReturnInfo` 增加 `qualifiers`
  - 在 `parseMetadataReturnNode(...)` 中保留 `air.invariant` 这类返回 qualifier
  - 在 entry output struct 发射时，若 `air.position` 带有 `air.invariant`，则生成：
    - `[[position, invariant]]`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增 replay 回归：验证生成的 `generated.metal` 会发出 `float4 position [[position, invariant]];`
  - 新增 round-trip 回归：验证 regenerated IR 保住 `air.invariant`，且 `entry 输出语义摘要变化` 不再出现
- `LocalDocs/.../test-data/test_vertex_position_invariant.ll`
  - 新增最小 vertex 多输出样本，稳定复现 `air.position + air.invariant` 场景

## 单 case 验证结果

本轮完成了两层最小验证和一层真实样本验证：

1. 最小 replay 回归
   - `generated.metal` 中已出现：`float4 position [[position, invariant]];`
2. 最小 round-trip 回归
   - 新样本 round-trip 后：
     - `riskLevel = L0`
     - `entryComparison = L0`
     - regenerated IR 保留 `air.invariant`
3. 真实代表 case
   - `build/semantics-validation/roundtrip/cc-003-7-single-fc1d64-position-invariant`
   - `entryComparison`：`L3 -> L0`
   - `entry 输出语义摘要变化`：已消失
   - 但整体风险仍为 `L3`，因为 residual 已切换到 `fast-math` family

## 当前结论

本轮已经可以明确下结论：

- 这支 `entry 输出语义摘要变化` 里，至少有一整支高频 case 不是 compare 噪声
- 它是真实的 converter metadata / emission 缺口：`air.position` 的 `air.invariant` 在返回 metadata 解析与 MSL 发射之间丢失了
- 这条链路现在已经被修正，而且最小样本与真实样本都能闭环复现
- 但 **对当前 corpus blocked 计数来说，这支差异不是最终杠杆**：修掉以后，同一批样本会立刻暴露成 `fast-math` compile posture family

## 下一步建议

既然这支 `entry 输出语义摘要变化` 已经被收掉，但 top-level `L3` 计数没有下降，下一步更值得继续分析的是：

- `CC-003.8`：围绕这 36 个 corpus 样本继续下钻 `fast-math 相关属性变化`
  - 判断它更像 compile posture 差异、converter emission 影响，还是 compare 口径问题
- 其次再回到仍然同时出现在 corpus / diagnostics 的：
  - `模块级 addrspace 分布变化 + 模块级 air intrinsic 使用变化`
- 最后才是：
  - `entry 参数个数变化` family
