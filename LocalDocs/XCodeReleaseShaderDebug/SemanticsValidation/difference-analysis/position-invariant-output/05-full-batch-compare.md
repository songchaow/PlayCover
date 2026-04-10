## position-invariant-output：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-6-corpus-20260410-dereferenceable-reference/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-7-corpus-20260410-position-invariant/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-6-diagnostics-20260410-dereferenceable-reference/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-7-diagnostics-20260410-position-invariant/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 186 / L2 = 197 / L3 = 54`
- 新：`L1 = 186 / L2 = 197 / L3 = 54`

直接看变化：

- `L3`：`54 -> 54`，**持平**
- `L2`：`197 -> 197`，持平
- `L1`：`186 -> 186`，持平

### diagnostics

- 旧：`L1 = 12 / L2 = 140 / L3 = 1`
- 新：`L1 = 12 / L2 = 140 / L3 = 1`

直接看变化：

- `L3`：`1 -> 1`，持平
- `L2`：`140 -> 140`，持平
- `L1`：`12 -> 12`，持平

## 这轮到底改变了什么

### 1. corpus 里的 `entry 输出语义摘要变化` 已被整支收掉

对比新旧 `compare-summary.json`：

- corpus 中 `entry 输出语义摘要变化` 的出现次数：`36 -> 0`
- diagnostics 中该差异：旧 `0` / 新 `0`

也就是说，本轮实现确实把 dashboard 里这一支高频 corpus family 从 compare 明细里完全清空了。

### 2. 但 blocked 样本集合完全没变

新旧 `risk-report.json` 的 `blockedSamples` 对比：

- corpus：`54 -> 54`
  - `removed = 0`
  - `added = 0`
  - `same = 54`
- diagnostics：`1 -> 1`
  - `removed = 0`
  - `added = 0`
  - `same = 1`

所以这轮不是“L3 集合下降了但又被别的回归补回来”，而是：

- **同一批 blocked 样本还在**
- 只是它们的 top-level 风险原因发生了重排

### 3. old/new 风险原因迁移

### corpus：修复前

剩余 `54` 个 `L3` 主要分成四支：

1. `entry 输出语义摘要变化; 指令族统计变化; fast-math 相关属性变化`：`21`
2. `entry 输出语义摘要变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`15`
3. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`：`11`
4. `entry 参数个数变化; entry 参数类型摘要变化; entry 参数语义摘要变化`：`7`

### corpus：修复后

修掉 invariant 之后，同一批 `54` 个 `L3` 变成：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`21`
2. `fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`15`
3. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`：`11`
4. `entry 参数个数变化; entry 参数类型摘要变化; entry 参数语义摘要变化`：`7`

可以把这组迁移理解成：

- 旧的 `36` 个 `entry 输出语义摘要变化` case 确实被清掉了
- 但它们并没有从 blocked 层降出去
- 它们立刻暴露成更底层的 `fast-math` / `instruction-family` / `targetTriple` residual

### diagnostics

diagnostics 本轮没有 `entry 输出语义摘要变化` family，因此新旧结果完全一致：

- 唯一剩余 `L3` 仍是：
  - `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`

## 如何理解这组结果

### 1. 本轮修复是“真实语义保真修复”，不是 compare 降噪

这轮没有修改 compare 口径；收益全部来自生成侧：

- `IRToMSLConverter.swift` 重新保住了 `air.position` 的 `air.invariant`
- single-case 里 `entryComparison` 的确从 `L3 -> L0`
- corpus compare 明细里 `entry 输出语义摘要变化 36 -> 0`

这说明本轮结论是成立的：

- **`air.invariant` 丢失是真问题，而且已经被修掉。**

### 2. 但它不是当前 blocked 计数的真正杠杆

full-batch 的结果同样说明另一件事：

- 对当前 corpus 来说，`entry 输出语义摘要变化` 更像是这 36 个 case 的“表层症状”
- 真正决定它们仍然被卡在 `L3` 的，是更底层的 `fast-math` compile posture family

因此这轮任务的意义是：

- **完成了一次必要的 root-cause 剥离**
- 但没有带来 top-level 风险计数收益

### 3. 这轮实现应该保留，但不该继续在同一方向放大

根据 dashboard 的止损原则，这轮 full-batch 结果给出的信号非常明确：

- 这条 invariant 修复本身是正确且值得保留的
- 但如果目标是继续降低 `L3` 数量，下一步就不该继续围绕 `entry 输出语义摘要变化` 放大
- 应当直接转向它背后暴露出的 `fast-math` family

## 当前结论

如果问题是：

- “这支 `entry 输出语义摘要变化` 是否真实存在 converter 缺口？”

答案现在已经明确：

- **是，而且已经修掉。**

如果问题是：

- “修掉它以后，full-batch `L3` 数会不会立刻下降？”

答案同样已经明确：

- **不会。当前 blocked ceiling 还在更后面的 `fast-math` family。**

## 一句话总结

**`air.position` 的 `air.invariant` 保真问题已经通过 converter-first 被修掉，corpus compare 中 `entry 输出语义摘要变化 36 -> 0`；但 corpus / diagnostics 的 blocked 集合与顶层 `L3` 计数都保持不变，说明这轮修复更多是在剥离表层差异，真正的下一刀应转向暴露出来的 `fast-math` compile posture family。**
