## shared-cfg-shape-drift-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-13b-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-15-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-13b-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-15-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 354 / L2 = 83 / L3 = 0`
- 新：`L1 = 355 / L2 = 82 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，继续为零
- `L2`：`83 -> 82`，下降 `1`
- `L1`：`354 -> 355`，上升 `1`

### diagnostics

- 旧：`L1 = 143 / L2 = 10 / L3 = 0`
- 新：`L1 = 145 / L2 = 8 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，继续为零
- `L2`：`10 -> 8`，下降 `2`
- `L1`：`143 -> 145`，上升 `2`

## 共有样本口径下的结论

### 1. 这轮带来了 diagnostics 主导、corpus 也可见的统计收益

这轮不是只在单 case 上降级：

- corpus：`L2 83 -> 82`
- diagnostics：`L2 10 -> 8`
- 两边 `L3` 都继续保持 `0`

这说明 compare 对 shared shape drift 的过敏，确实在 diagnostics 与 corpus 两条 full-batch 上同时存在，只是 diagnostics 的收益更显著。

### 2. 代表 case 已经从 `L2` 降到 `L1`

单 case `25eef20f...`：

- 旧：`L2`
- 新：`L1`

因此这轮不是“只改了测试阈值但真实样本不买账”，而是代表 case 与 full-batch 两层证据都已经对齐。

### 3. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- 两边 `blockedSamples` 继续为 `[]`

因此这轮只是在 compare 口径上更准确地区分 shared shape drift，没有把任何已收敛 family 推回 blocked 层。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但含义继续只是“仍有活跃 `L2` debt 没有 profile baseline”，不是新 `L3` 回归：

- corpus：`summary = new L2 sample ...3a9cedb0...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 warning 仍然表示还有 residual family 待继续收敛，而不是当前这轮引入了新的结构性失败。

## 修复后剩余最高优先级问题

这轮之后，下一步优先级已经更集中到两类：

1. `instruction-family + fast-math + targetTriple` shared residual
2. corpus 中唯一仍然挂着 `entry 参数语义摘要变化; entry builtin / stage-in 摘要变化` 的 `823dcdf7...`

相比之下，这轮处理的 shared `CFG + instruction-family + fast-math` family 已经证明至少有一部分只是 compare 对低风险 shape drift 的放大。

## 一句话总结

**这轮修复确认：diagnostics / corpus 里重复出现的一支 `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化` residual，至少其一部分不是新的 converter 缺口，而是 compare 对“同一 CFG + 一处额外 select + 小幅 vector/aggregate materialization 重排”过敏。把这支规则定向降噪后，代表 case `25eef20f...` 从 `L2 -> L1`，full-batch 也把 corpus 顶层计数从 `L2 83 -> 82`、diagnostics 从 `L2 10 -> 8`，同时两边继续保持 `L3 = 0` 且没有新增 blocked。**
