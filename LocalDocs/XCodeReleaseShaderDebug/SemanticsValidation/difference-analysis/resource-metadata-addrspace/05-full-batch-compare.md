## resource-metadata-addrspace：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/shader-corpus-batch-after-noalias/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/shader-corpus-batch-after-resource-addrspace-normalization/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch-after-noalias/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch-after-resource-addrspace-normalization/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 4 / L2 = 182 / L3 = 251`
- 新：`L1 = 68 / L2 = 118 / L3 = 251`

直接看变化：

- `L3`：`251 -> 251`，不变
- `L2`：`182 -> 118`，减少 `64`
- `L1`：`4 -> 68`，增加 `64`

### diagnostics

- 旧：`L1 = 0 / L2 = 7 / L3 = 146`
- 新：`L1 = 2 / L2 = 5 / L3 = 146`

直接看变化：

- `L3`：`146 -> 146`，不变
- `L2`：`7 -> 5`，减少 `2`
- `L1`：`0 -> 2`，增加 `2`

## 共有样本口径下的变化

### corpus 共有样本

- 共有样本数：`437`
- 改善样本数：`64`
- 恶化样本数：`0`
- `L2 -> L1`：`64`
- 新增 `L3`：`0`

### diagnostics 共有样本

- 共有样本数：`153`
- 改善样本数：`2`
- 恶化样本数：`0`
- `L2 -> L1`：`2`
- 新增 `L3`：`0`

## 如何理解这组结果

这组结果说明三件事：

### 1. 这次命中的是 compare 噪声，而不是结构性 `L3`

如果这轮修的是实现问题，最期待看到的是：

- 一批样本从 `L3` 降出

但现在实际看到的是：

- `L3` 完全不变
- 一批样本从 `L2` 降到 `L1`

这和单 case 观察是吻合的：

- 本轮主要消掉的是 `entry 参数语义摘要变化` / `entry 资源语义摘要变化` 里的 compare 口径噪声

### 2. 这条归一化有批量收益，而且没有引入回归

在共有样本口径下：

- corpus 改善 `64` 个样本
- diagnostics 改善 `2` 个样本
- `worsened = 0`
- `new L3 = 0`

说明这不是单 case 偶然，也没有把其它样本推向更坏的等级。

### 3. 当前主矛盾已经进一步收敛到更“硬”的残留模式

去掉这层 metadata 噪声后，仍然留在高风险里的，更多是：

- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `指令族统计变化`
- `entry 返回类型摘要变化`

这说明下一刀更值得继续看这些差异，而不是继续围着 resource metadata 的 `addrspace=2` 文本显式化打转。

## 当前结论

如果问题是：

- “这轮 compare 归一化有没有实际收益？”

答案是：

- **有，而且收益的形态非常清楚：它没有降低 `L3`，但稳定地把一批误报 `L2` 降成了 `L1`。**

更具体地说：

- corpus：`64` 个共有样本从 `L2 -> L1`
- diagnostics：`2` 个共有样本从 `L2 -> L1`
- 没有新增 `L3`
- 没有任何样本恶化

## 一句话总结

**`resource metadata addrspace` 这条归一化已经证明：它属于“降低 canonical compare 误报”的有效修正，而不是“改变真实 round-trip 实现质量”的修正。**
