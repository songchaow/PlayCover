## buffer-noalias：full-batch canonical compare 复跑结果

## 目的

回答一个更实际的问题：

- `noalias -> __restrict` 的实现不只对单个 case 有效，是否也能让 full-batch 层面的 `L3` 数量下降

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/shader-corpus-batch/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/shader-corpus-batch-after-noalias/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch-after-noalias/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L3 = 264 / 372`
- 新：`L3 = 251 / 437`

直接看绝对数量：

- `264 -> 251`，减少 `13`

直接看占比：

- `70.97% -> 57.44%`

需要注意：

- 新旧 batch 的总 job 数不同，说明样本面本身发生了增长
- 所以只看绝对数量还不够，必须结合共有样本一起看

### diagnostics

- 旧：`L3 = 148 / 152`
- 新：`L3 = 146 / 153`

直接看绝对数量：

- `148 -> 146`，减少 `2`

直接看占比：

- `97.37% -> 95.42%`

同样需要注意：

- diagnostics 的样本总数也有微小变化

## 共有样本口径下的变化

为避免被样本集增减干扰，本轮又按共有样本做了一次对比。

### corpus 共有样本

- 共有样本数：`349`
- 旧口径下 `L3`：`252`
- 新口径下 `L3`：`198`

变化：

- 有 `54` 个样本从 `L3` 降出
- 没有样本从非 `L3` 升成 `L3`

这说明：

- 对于 corpus 这条 success-path full-batch，修复效果是明确而且显著的

### diagnostics 共有样本

- 共有样本数：`152`
- 旧口径下 `L3`：`148`
- 新口径下 `L3`：`146`

变化：

- 有 `2` 个样本从 `L3` 降出
- 没有样本从非 `L3` 升成 `L3`

这说明：

- 对 diagnostics 这条 failure-path 补充入口，也有正向收益
- 但收益明显弱于 corpus

## 如何理解这组结果

这组数据说明三件事：

### 1. 这不是单个 case 的偶然改善

如果只有 `91c464...` 这一个样本改善，而其它样本不动，那么 full-batch 结果不会出现这种幅度的整体下降。

而现在共有样本里：

- corpus 有 `54` 个样本从 `L3` 降出
- diagnostics 有 `2` 个样本从 `L3` 降出

这说明当前实现命中的是一类模式，而不是单个特例。

### 2. 这条实现没有制造新的 `L3`

在共有样本口径下：

- `worsened_to_l3 = 0`

这很关键。

说明当前实现至少在这次 full-batch 复跑中，没有把别的样本推向更坏的风险等级。

### 3. 它能明显降低 `L3`，但不会单独把问题清空

虽然 `L3` 确实下降了，但仍然大量存在。

这和单 case 观察是一致的：

- `noalias -> __restrict` 能解决“entry 参数类型摘要变化”这一层
- 但它解决不了所有 entry 参数语义差异、资源语义差异、CFG / intrinsic / addrspace 变化

所以它的定位更像：

- **有效削减一类 `L3` 噪声 / 结构性差异**
- 而不是“一刀清空 full-batch 的所有高风险”

## 当前结论

如果问题是：

- “整体 `L3` 的数量是不是也降了？”

答案是：

- **是的，降了，而且在共有样本口径下也成立。**

更具体地说：

- corpus 共有样本里：`252 -> 198`，减少 `54`
- diagnostics 共有样本里：`148 -> 146`，减少 `2`
- 没有观察到新的 `L3` 回归

## 一句话总结

**这条 `noalias -> __restrict` 实现已经从“单 case 局部优化”升级成“对 full-batch 有统计意义的正向改进”，但它仍然只是降低一类 `L3`，不是消灭全部 `L3`。**
