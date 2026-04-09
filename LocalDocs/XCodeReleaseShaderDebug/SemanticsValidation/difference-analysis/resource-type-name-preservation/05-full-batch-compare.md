## resource-type-name-preservation：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260410-014309-1e7e0844/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260410-021241-f86da25c/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260410-014309-f66c9eb1/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260410-021241-267e605b/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 79 / L2 = 107 / L3 = 251`
- 新：`L1 = 80 / L2 = 106 / L3 = 251`

直接看变化：

- `L3`：`251 -> 251`，不变
- `L2`：`107 -> 106`，减少 `1`
- `L1`：`79 -> 80`，增加 `1`

### diagnostics

- 旧：`L1 = 4 / L2 = 3 / L3 = 146`
- 新：`L1 = 5 / L2 = 2 / L3 = 146`

直接看变化：

- `L3`：`146 -> 146`，不变
- `L2`：`3 -> 2`，减少 `1`
- `L1`：`4 -> 5`，增加 `1`

## 如何理解这组结果

这组结果说明三件事：

### 1. 这次命中的是 converter 的真实命名漂移，而不是 compare 误报

如果只是 compare 口径调整，更常见的形态是：

- 同一批样本批量 `L2 -> L1`

但本轮实际收益更像一次定向实现修复：

- diagnostics 明确消掉了 `c66b9d4...` 这一类 `entry 参数语义摘要变化 + entry 资源语义摘要变化`
- 同时让 `f26d322...` 也不再继续带着同类 entry/resource 语义差异

### 2. 收益不大，但闭环很干净

在当前这一轮：

- corpus 改善 `1` 个样本
- diagnostics 改善 `1` 个样本
- 没有新增 `L3`
- 没有恶化样本

这和单 case 证据一致：命中的不是一个高频大类，而是 `CC-003.2` 剩余家族里一条较窄但真实的 converter 问题。

### 3. `entry 资源语义摘要变化` 已经不再是当前主矛盾

修完之后，diagnostics 剩余的 `L2` 只剩：

- `91c46448...`
- `f26d322...`

它们现在都统一收敛到：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`

也就是说，`entry 资源语义摘要变化` 这一分支已经从当前 diagnostics 的 `L2` 集合中退出。

## 当前结论

如果问题是：

- “这轮 converter 修正有没有实际收益？”

答案是：

- **有，而且收益形态很清楚：它把一个真实的 type-name 漂移 case 从 `L2` 收回到 `L1`，同时没有引入新的 `L3`。**

## 一句话总结

**`resource type name preservation` 这条修正确认：`CC-003.2` 剩余的一支并非 compare 误报，而是 `IRToMSLConverter` 对用户类型名大小写处理过度；修完后，当前主线可以转回更硬的 `module addrspace / air intrinsic` 残留模式。**
