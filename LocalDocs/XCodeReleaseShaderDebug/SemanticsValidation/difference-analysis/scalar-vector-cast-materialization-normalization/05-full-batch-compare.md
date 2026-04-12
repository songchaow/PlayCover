## scalar-vector-cast-materialization-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-20-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-21-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-20-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-21-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 391 / L2 = 46 / L3 = 0`
- 新：`L1 = 391 / L2 = 46 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`46 -> 46`，持平
- `L1`：`391 -> 391`，持平

### diagnostics

- 旧：`L1 = 151 / L2 = 2 / L3 = 0`
- 新：`L1 = 153 / L2 = 0 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`2 -> 0`，减少 `2`
- `L1`：`151 -> 153`，增加 `2`

## 共有样本口径下的收益

### 1. diagnostics 中最后一支纯 materialization family 已清零

对旧批次与本轮新批次对比后：

- diagnostics 中 `指令族统计变化 + fast-math 相关属性变化 + 模块元数据 targetTriple 变化`：`2 -> 0`

也就是说，本轮净消掉了 diagnostics 中该 family 的全部剩余 `L2`。

### 2. 目标 case 已明确回落

这轮 dashboard 指向的两支 diagnostics residual 都已从 `L2 -> L1`：

- `69e4179e...`
- `d8c964c5...`

两支单 case 输出分别是：

- `build/semantics-validation/roundtrip/cc-003-21-single-69e4179e-arithmetic-heavy/risk-report.json`
- `build/semantics-validation/roundtrip/cc-003-21-single-d8c964c5-arithmetic-heavy/risk-report.json`

并且新 diagnostics full-batch `build/semantics-validation/roundtrip/cc-003-21-full-diagnostics/risk-report.json` 中，这两支 sample 已不再出现在 `samplesForL3` 列表里。

### 3. 没有新增 `L3` / blocked / corpus 回退

新旧风险集合对比后可以直接确认：

- diagnostics：没有 `new-only` 的 `L2` 样本
- corpus：没有 `new-only` 的 `L2` 样本
- 两条 full-batch 的 `L3` 继续都是 `0`
- `blockedSamples` 继续为空

因此这轮收益不是“diagnostics 清零，但 corpus 换出新的 L2”，而是 diagnostics family 的净清零，同时 corpus 保持不回退。

## 其它 residual 如何理解

### diagnostics

本轮之后，diagnostics 已无 `L2 / L3` residual：

- `L2 = 0`
- `L3 = 0`
- `blockedSamples = []`

这说明 diagnostics 侧的 pure materialization 边界已经收尽，后续主线无需继续优先从 diagnostics 选 case。

### corpus

本轮之后，corpus 剩余 `L2` 主要仍是：

1. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`12`
2. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`11`
3. `模块级 addrspace 分布变化; 指令族统计变化; fast-math 相关属性变化`：`9`
4. `指令族统计变化; 模块元数据 targetTriple 变化`：`8`
5. `模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化; 指令族统计变化`：`1`

可以看到：

- diagnostics 清零后，主矛盾已经完全回到 corpus residual
- `c2cd49...` 这类 `module air intrinsic + instruction-family` residual 继续是最值得优先下钻的实现层候选
- 这也说明 compare 在 pure materialization 侧已经接近可接受边界，下一步不应继续无差别放宽

## gate 如何理解

两条 full-batch 的 `gate-summary.json` 中：

- diagnostics：已经从 `WARN` 回到 `PASS`
- corpus：仍是 `WARN`，summary 指向 `c2cd49d0...`

因此当前 gate 剩余压力已不再来自 diagnostics，而是 corpus 中尚未收敛的 `module air intrinsic + instruction-family` family。

## 修复后下一步最值得继续分析的 case

`CC-003.21` 完成后，当前最值得继续下钻的是 corpus 中仍然挂在 gate 顶部的实现层候选：

- `c2cd49d0...`

原因是：

- diagnostics 已无 `L2 / L3`
- `c2cd49d0...` 已带上 `module air intrinsic` 变化，更像下一轮应优先验证是否已触到 converter / lowering / metadata 建模问题，而不是继续放宽 compare

## 一句话总结

**`CC-003.21` 的 compare 扩展带来了明确且干净的统计收益：在不新增 `L3` / blocked / new-only `L2`、且 corpus 完全不回退的前提下，diagnostics `L2 2 -> 0`、`L1 151 -> 153`，并把 dashboard 指向的 `69e4179e...` 与 `d8c964c5...` 两支 residual 全部稳定降到 `L1`。**

## 追加：`CC-003.22` full-batch 对比

### 对比批次

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-21-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-22-full-corpus-shuffle-gated/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-21-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-22-full-diagnostics-shuffle-gated/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 391 / L2 = 46 / L3 = 0`
- 新：`L1 = 392 / L2 = 45 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`46 -> 45`，减少 `1`
- `L1`：`391 -> 392`，增加 `1`

### diagnostics

- 旧：`L1 = 153 / L2 = 0 / L3 = 0`
- 新：`L1 = 153 / L2 = 0 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`0 -> 0`，持平
- `L1`：`153 -> 153`，持平

## 这轮 full-batch 说明了什么

### 1. 目标 residual 已被真实移除

比较 `high-risk-samples.json` 后可以直接确认：

- 被移除的高风险样本只有：`bundle:com.miHoYo.Yuanshen::module:c2cd49d0...`
- 新批次没有新增高风险样本

也就是说，这轮 corpus `L2 46 -> 45` 不是偶然波动，而是 dashboard 目标样本被精准拿掉后的净收益。

### 2. diagnostics 完全不回退

新旧 diagnostics full-batch 对比显示：

- `L2 / L3` 都继续保持 `0`
- 不存在新的 diagnostics residual family

这说明本轮 converter narrowing 没有把问题重新扩散回 diagnostics 代表集。

### 3. broad patch 的 6 个回归没有回归

和此前 broad `select(...)` 试探不同，这轮新策略只命中 `immediate users == { shufflevector }` 的极窄路径，因此：

- 先前 `extractelement` / `insertelement` 家族引出的新增 `L2` 没有重新出现
- corpus 风险集合没有出现新的 high-risk sample
- `L3` / `blockedSamples` 继续保持稳定

## gate 如何理解

两条新 `gate-summary.json` 中：

- diagnostics：继续 `PASS`
- corpus：仍是 `WARN`，但顶层计数已经从 `L2 46 -> 45`

同时，新旧高风险集合 diff 已明确显示：**真正发生的变化只有 `c2cd49...` 被移除**。因此这轮 `WARN` 反映的是剩余 residual 还未清空，而不是本轮修复引入了新的高风险集合回退。

## 修复后下一步最值得继续分析的 case

`CC-003.22` 收尾后，当前最高优先级 TODO 已回到：

- `CC-003.23`：按默认流程重跑 full-batch，确认是否仍有值得继续拆解的 `L2/L3` residual；若有，就只挑一个最高价值 case 继续闭环

原因是：

- diagnostics 已持续保持 `L2 = 0 / L3 = 0`
- corpus 中这支 `module air intrinsic + instruction-family` residual 已被收掉
- 下一步更有价值的是先确认最新 residual 分布，再决定后续最值得继续推进的单 case

## 一句话总结

**`CC-003.22` 的 converter 窄化修复带来了干净且可解释的统计收益：在 diagnostics 完全不回退、且没有新增高风险样本的前提下，corpus `L2 46 -> 45`、`L1 391 -> 392`，并把此前持续挂在 gate 顶部的 `c2cd49d0...` 从高风险集合中稳定移除。**

## 追加：`CC-003.23` full-batch 对比

### 对比批次

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-23-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-23-final-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-23-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-23-final-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 392 / L2 = 45 / L3 = 0`
- 新：`L1 = 405 / L2 = 32 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`45 -> 32`，减少 `13`
- `L1`：`392 -> 405`，增加 `13`

### diagnostics

- 旧：`L1 = 153 / L2 = 0 / L3 = 0`
- 新：`L1 = 153 / L2 = 0 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`0 -> 0`，持平
- `L1`：`153 -> 153`，持平

## 这轮 full-batch 说明了什么

### 1. 目标 family 获得了真实且成批的统计收益

新旧 `compare-summary.json` 对比后可以直接确认：

- `指令族统计变化; 模块元数据 targetTriple 变化`：`8 -> 0`
- `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`11 -> 6`

并且本轮共净移除了 `13` 个 corpus `L2` 样本，说明这次 compare 收敛不是只命中单个 case，而是确实吸收了一批同 family residual。

### 2. diagnostics 完全不回退

新旧 diagnostics full-batch 对比显示：

- `L2 / L3` 继续保持 `0`
- 不存在新的 diagnostics residual family
- `blockedSamples` 继续为空

这说明本轮 vector-heavy compare 分支没有把问题重新扩散回 diagnostics。

### 3. 没有新增 `L3` / blocked / 更坏 residual

这轮新旧 full-batch 对比后可以直接确认：

- corpus / diagnostics 的 `L3` 继续都是 `0`
- `blockedSamples` 继续为空
- 新批次没有出现新的更坏风险层级

因此这轮收益是**净收益**，而不是把旧的 `L2` 换成新的 `L3` 或 blocked 回归。

## 剩余 residual 如何理解

### corpus

本轮之后，corpus 剩余 `L2` 主要收缩为：

1. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`12`
2. `模块级 addrspace 分布变化; 指令族统计变化; fast-math 相关属性变化`：`9`
3. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`6`
4. `模块级 addrspace 分布变化; 控制流粗摘要变化; 指令族统计变化`：`4`
5. `模块级 addrspace 分布变化; 指令族统计变化; 模块元数据 targetTriple 变化`：`1`

这说明：

- same-CFG pure materialization 这条 residual 已进一步显著收窄
- 当前主矛盾已经转回 shared CFG / addrspace 相关 family
- 后续不应继续优先放宽 materialization compare，而应优先分析新的最高频 shared residual

### diagnostics

本轮之后，diagnostics 仍然没有 `L2 / L3` residual：

- `L2 = 0`
- `L3 = 0`
- `blockedSamples = []`

## 修复后下一步最值得继续分析的 case

`CC-003.23` 收尾后，当前最值得继续下钻的是 corpus 中最高频的 shared residual：

- `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`
- 当前计数：`12`
- 可从 `e17ab0cb...` 这类代表样本开始

原因是：

- 当前它已经成为剩余 `L2` 中最大的重复 family
- 它比继续扩大 materialization compare 更像需要回到 shared CFG / emission / compare 边界重新归因的一支 residual

## 一句话总结

**`CC-003.23` 的 vector-heavy compare 收敛带来了显著且干净的 full-batch 收益：在 diagnostics 完全不回退、且没有新增 `L3` / blocked 的前提下，corpus `L2 45 -> 32`、`L1 392 -> 405`，并把 same-CFG materialization 主线再向前推进了一大步。**

## 追加：`CC-003.24` full-batch 对比

### 对比批次

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-231811-3afc7608/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-24-full-corpus-select-heavy/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-231855-c8a5e561/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-24-full-diagnostics-select-heavy/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 405 / L2 = 32 / L3 = 0`
- 新：`L1 = 406 / L2 = 31 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`32 -> 31`，减少 `1`
- `L1`：`405 -> 406`，增加 `1`

### diagnostics

- 旧：`L1 = 153 / L2 = 0 / L3 = 0`
- 新：`L1 = 153 / L2 = 0 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`0 -> 0`，持平
- `L1`：`153 -> 153`，持平

## 这轮 full-batch 说明了什么

### 1. 目标样本被精准移除，且没有换入新的 `L2`

新旧 `risk-report.json` 对比后可以直接确认：

- 被移除的高风险样本只有：`bundle:com.papegames.lysk::module:e17ab0cb...`
- 新批次没有新增 `L2` 样本

也就是说，这轮 corpus `L2 32 -> 31` 不是偶然波动，而是 dashboard 目标样本被精准拿掉后的净收益。

### 2. 最高频 shared residual 获得了真实收缩

新旧 family 计数对比后可以直接确认：

- `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`12 -> 11`

这说明本轮 compare 收敛已经命中当前最大的 shared residual family，而不只是碰巧让单样本回落。

### 3. diagnostics 完全不回退

新旧 diagnostics full-batch 对比显示：

- `L2 / L3` 继续保持 `0`
- 不存在新的 diagnostics residual family
- `blockedSamples` 继续为空

这说明本轮 shared-CFG select-heavy compare 分支没有把问题重新扩散回 diagnostics。

### 4. 没有新增 `L3` / blocked / 更坏 residual

这轮新旧 full-batch 对比后可以直接确认：

- corpus / diagnostics 的 `L3` 继续都是 `0`
- `blockedSamples` 继续为空
- 新批次没有出现新的更坏风险层级

因此这轮收益仍然是**净收益**，而不是把旧的 `L2` 换成新的 `L3` 或 blocked 回归。

## gate 如何理解

两条新 `gate-summary.json` 中：

- diagnostics：继续 `PASS`
- corpus：仍是 `WARN`

但这轮 corpus `WARN` 主要仍是 generic gate 对当前活跃 `L2` 集的默认提示；真正看新旧 `risk-report.json` diff，可以确认：

- 没有新增 `L2`
- 只有 `e17ab0cb...` 被移除

因此这轮 `WARN` 反映的是剩余 residual 尚未清空，而不是本轮 compare 扩展引入了新的风险集合回退。

## 修复后下一步最值得继续分析的 case

`CC-003.24` 收尾后，当前最值得继续下钻的仍是 corpus 中剩余最高频的 shared residual：

- `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`
- 当前计数：`11`
- 可从 `c3d8aba9...` 这类代表样本开始

原因是：

- 这支 family 仍然是 corpus 当前最大的重复 residual
- `e17ab0cb...` 已证明其中至少有一部分仍属于 compare 边界过窄
- 下一步最有价值的是继续确认剩余样本里，哪些还能被 shared-CFG compare 解释，哪些已经开始逼近实现问题

## 一句话总结

**`CC-003.24` 的 select-heavy shared-CFG compare 收敛带来了干净且可解释的 full-batch 收益：在 diagnostics 完全不回退、且没有新增 `L3` / blocked / new-only `L2` 的前提下，corpus `L2 32 -> 31`、`L1 405 -> 406`，并把当前最高频 shared residual family 从 `12 -> 11` 再向前推进了一步。**
