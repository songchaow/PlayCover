## fragment-stage-in-semantics-preservation：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-15-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-16-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-15-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-16-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 355 / L2 = 82 / L3 = 0`
- 新：`L1 = 356 / L2 = 81 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，继续为零
- `L2`：`82 -> 81`，下降 `1`
- `L1`：`355 -> 356`，上升 `1`

### diagnostics

- 旧：`L1 = 145 / L2 = 8 / L3 = 0`
- 新：`L1 = 145 / L2 = 8 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，继续为零
- `L2`：`8 -> 8`，持平
- `L1`：`145 -> 145`，持平

## 共有样本口径下的结论

### 1. 这轮收益主要体现在 corpus，diagnostics 保持稳定

这轮不是只在单 case 上降级：

- 代表 case `823dcdf7...`：`L2 -> L1`
- corpus：`L2 82 -> 81`
- diagnostics：`L2 8 -> 8`
- 两边 `L3` 都继续保持 `0`

这说明这次修复命中的确实是 corpus 中那条独立的 entry residual，而不是只改出一个孤立样本。

### 2. `823dcdf7...` 已从 full-batch 的 `L2` 集合降出

对 `cc-003-16-full-corpus/compare-summary.json` 复核后：

- `823dcdf7...` 的 `riskLevel` 已变成 `L1`
- `riskReason` 只剩：
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块元数据 targetTriple 变化`
- 原来的：
  - `entry 参数语义摘要变化`
  - `entry builtin / stage-in 摘要变化`
  已经不再出现

因此这轮不是“只让单 case 产物看起来更像”，而是这条 family 在 full-batch 口径下也已经真正降级。

### 3. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- 两边 `blockedSamples` 继续为 `[]`

所以这轮修复只是把 fragment `stage_in` 语义恢复正确，没有把任何已收敛 family 推回 blocked 层。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但含义继续只是“还有活跃 `L2` debt 没有 profile baseline”，不是这轮引入了新的 `L3`：

- corpus：`summary = new L2 sample ...3a9cedb0...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 warning 仍表示剩余 residual family 待继续收敛，而不是本轮 stage-in 修复引入了新的结构性失败。

## 修复后剩余最高优先级问题

这轮之后，下一步优先级已经收敛到两类：

1. `instruction-family + fast-math + targetTriple` shared residual
2. `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化`

此前单独挂着的 corpus entry residual `823dcdf7...` 已经不再是独立优先项。

## 一句话总结

**这轮修复确认：corpus 中最后一支独立的 `entry 参数语义摘要变化; entry builtin / stage-in 摘要变化` residual 不是 compare 噪声，而是 converter 丢失了 fragment `stage_in` 字段语义。把 `[[user(TEXCOORD*)]]` 和 `[[flat]] / [[center_perspective]]` 回发到 `generated.metal` 之后，代表 case `823dcdf7...` 从 `L2 -> L1`，full-batch 也把 corpus 顶层计数从 `L2 82 -> 81`，同时 diagnostics 维持稳定、两边继续保持 `L3 = 0` 且没有新增 blocked。**
