## resource-metadata-addrspace：实现结果

## 本轮分析的差异类型

本轮处理的是 `buffer-noalias` 修复后仍大量残留的一类 `L2`：

- `entry 参数语义摘要变化`
- `entry 资源语义摘要变化`

针对单个 case 下钻后，发现它们在一批样本里经常由同一个细节触发：

- original 的 `air.buffer` metadata 没显式写 `air.address_space`
- regenerated 的同一条 `air.buffer` metadata 显式写成了 `air.address_space = 2`

## 单 case 证据

目标 case：

- `build/semantics-validation/roundtrip/shader-source-diagnostics-batch-after-noalias/com.miHoYo.Yuanshen/modules/91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b/original.ll`
- `build/semantics-validation/roundtrip/shader-source-diagnostics-batch-after-noalias/com.miHoYo.Yuanshen/modules/91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b/regenerated.ll`

本轮先用当前 compare 重新提取 summary，确认：

- 函数参数摘要里，第一个 buffer 参数在 original / regenerated 两侧都已经是 `ptr addrspace(2)`
- `parameterAddrspaces` 也一致，说明这不是函数签名级的真实地址空间漂移
- 真正不一致的，是 metadata 摘要字符串里 regenerated 额外带了 `addrspace=2`

也就是说，这批残留更像：

- **compare 口径把“resource metadata 显式化”误当成了 entry/resource 语义变化**

而不是：

- `IRToMSLConverter` 没把 buffer 地址空间回放对

## 本轮实现内容

已在：

- `Scripts/ir_canonical_compare.py`

做一条最小 compare 归一化：

- 对 `air.buffer` / `air.texture` / `air.sampler` 这类 resource metadata，保留结构化 `addressSpace` 字段
- 但不再把 `air.address_space` 拼进 canonical `signature`

这样处理后：

- 真正的参数地址空间变化，仍然会继续由 `parameterSignatures` / `parameterAddrspaces` 命中
- 仅仅是 metadata 显式化造成的 `addrspace=2` 文本差异，不再重复放大成 `entry 参数语义摘要变化` / `entry 资源语义摘要变化`

这条修改的目标不是降低真实风险，而是消掉 compare 自己制造的重复噪声。

## 单 case 验证结果

对目标 case 直接调用新的 canonical compare 后：

- `entryComparison.same = true`
- `entry 参数语义摘要变化` 消失
- `entry 资源语义摘要变化` 消失

该样本仍然保留的主要差异是：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `控制流粗摘要变化`
- `指令族统计变化`

这说明本轮改动命中的确实只是 compare 口径噪声，而不是把真实实现问题“洗掉”。

## 相关测试

已补一条定向测试到：

- `Scripts/test_ir_canonical_compare.py`

覆盖场景：

- 函数参数本身都已经是 `addrspace(2)`
- 但 original / regenerated 的 resource metadata 分别写 `air.address_space = 1/2`

期望：

- compare 结果为 `L0`
- `argSemantics` / `resourceSemantics` 视为一致

同时保留原有测试，继续保证：

- 当函数参数 `addrspace` 真正从 `1 -> 2` 变化时，仍然会被判成高风险

## 当前结论

本轮已经可以明确下结论：

- `buffer-noalias` 之后大量残留的 `entry 参数语义摘要变化`，其中有一批并不是实现问题
- 它们本质上是 `air.buffer` metadata 对 `addrspace=2` 的显式化差异
- 这一类差异更适合在 `ir_canonical_compare.py` 做 compare 归一化，而不是继续改 `IRToMSLConverter`

## 下一步建议

在这条 compare 噪声被消掉之后，下一步更值得继续分析的是：

- `模块级 air intrinsic 使用变化`
- `指令族统计变化`

也就是那些在去掉 entry/resource metadata 噪声后，仍然稳定停留在 `L2` / `L3` 的样本族。
