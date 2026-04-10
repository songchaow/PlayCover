## constant-struct-reference-dereferenceable：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-5-1-corpus-20260410-converter-first-single-field-return/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-6-corpus-20260410-dereferenceable-reference/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-5-1-diagnostics-20260410-converter-first-single-field-return/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-6-diagnostics-20260410-dereferenceable-reference/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 176 / L2 = 191 / L3 = 70`
- 新：`L1 = 186 / L2 = 197 / L3 = 54`

直接看变化：

- `L3`：`70 -> 54`，减少 `16`
- `L2`：`191 -> 197`，增加 `6`
- `L1`：`176 -> 186`，增加 `10`

### diagnostics

- 旧：`L1 = 9 / L2 = 140 / L3 = 4`
- 新：`L1 = 12 / L2 = 140 / L3 = 1`

直接看变化：

- `L3`：`4 -> 1`，减少 `3`
- `L2`：`140 -> 140`，持平
- `L1`：`9 -> 12`，增加 `3`

## 共有样本口径下的收益

### 1. 纯 `entry 参数类型摘要变化` 这支 `L3` family 已被整支收掉

新旧 `blockedSamples` 对比后：

- corpus：移除了 `16` 个 `L3`，新增 `L3 = 0`
- diagnostics：移除了 `3` 个 `L3`，新增 `L3 = 0`

被移除的样本全部来自同一类 root cause：

- `entry 参数类型摘要变化; ...`

代表样本包括：

- `c6d1420a...`
- `82d1eb85...`
- `a93ca739...`
- `1cdc9318...`
- `29b821c6...`

这些样本修复后的共同特征是：

- `entryComparison` 从 `L3` 降到 `L0`
- 整体风险降成 `L1/L2`
- `blockedSamples` 中不再保留它们

### 2. 没有新增 `L3` 回归

新旧集合对比结果：

- corpus：`added = 0`
- diagnostics：`added = 0`

这说明这轮“放宽 struct 判定”的影响面虽然覆盖 20+ 个真实样本，但没有引入新的 blocked family。

### 3. `L2/L1` 上升是预期内的 residual 露出，不是回归

和前几轮一样，这次修完高优先级 `L3` 之后：

- 一部分样本从 blocked 层回落到可继续分析的 `L2/L1`
- 它们主要露出的 residual 是：
  - `模块级 addrspace 分布变化`
  - `模块级 air intrinsic 使用变化`
  - `函数内 air intrinsic 调用统计变化`
  - `指令族统计变化`
  - `模块元数据 targetTriple 变化`

因此：

- `L3` 明显下降
- `L2/L1` 小幅上升
- 这更像是“被错误挡在 blocked 层的样本重新回到分析层”，而不是新的回归

## 修复后剩余的 `L3` 家族

### corpus

剩余 `54` 个 `L3` 主要分成三支：

1. `entry 输出语义摘要变化; 指令族统计变化; fast-math 相关属性变化`：`21`
2. `entry 输出语义摘要变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`15`
3. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`：`11`
4. `entry 参数个数变化; entry 参数类型摘要变化; entry 参数语义摘要变化`：`7`

### diagnostics

剩余 `1` 个 `L3`：

- `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`

## 如何理解这组结果

### 1. 本轮收益来自 converter 参数发射修正，而不是 compare 放宽

这轮没有修改 compare 口径；收益全部来自生成侧：

- `IRToMSLConverter.swift` 不再把 `_Foo_Type` / `cb_Foo_Type` constant buffer 误降成 `*`
- round-trip 后的 AIR 因而重新保住了 `dereferenceable(N)`
- `entry 参数类型摘要变化` 从源头消失

### 2. 这是一处小修复，但命中了高频真实 family

这轮改动只是一条 struct 判定规则的扩展，但它同时覆盖了：

- underscore-prefixed struct
- `cb_*_Type` struct
- 跨 corpus / diagnostics 的重复样本

因此统计收益非常直接：

- corpus `L3 -16`
- diagnostics `L3 -3`
- 新增 `L3 = 0`

## 当前结论

如果问题是：

- “`entry 参数类型摘要变化` 里这支 `dereferenceable(N)` 漂移，是否值得优先在 converter 里修？”

答案现在已经明确：

- **值得，而且 converter-first 的收益非常明确。**

## 一句话总结

**`constant struct reference / dereferenceable` 这条修正确认：当前残留 `L3` 里有一整支高频 `entry 参数类型摘要变化` 并不是 compare 噪声，而是 `IRToMSLConverter.swift` 对用户 struct 的引用判定过窄；修复后 corpus `L3 70 -> 54`、diagnostics `L3 4 -> 1`，且无新增 `L3`。**
