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
