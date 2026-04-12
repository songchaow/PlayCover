## shared-cfg-split-merge-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-17-final-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260412-115627-6476094c/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-17-final-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260412-115627-549ca063/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 362 / L2 = 75 / L3 = 0`
- 新：`L1 = 367 / L2 = 70 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`75 -> 70`，减少 `5`
- `L1`：`362 -> 367`，增加 `5`

### diagnostics

- 旧：`L1 = 147 / L2 = 6 / L3 = 0`
- 新：`L1 = 150 / L2 = 3 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`6 -> 3`，减少 `3`
- `L1`：`147 -> 150`，增加 `3`

## shared-CFG family 的统计收益

本轮真正命中的就是 dashboard 当前主线里那支 shared residual：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

按 `risk-report.json` 中 `L2` 样本口径对比：

- corpus：`19 -> 14`
- diagnostics：`3 -> 0`

也就是说：

- diagnostics 中这支 shared-CFG family 已被**清零**
- corpus 中这支 family 也继续净下降，但还剩更宽的 residual 没有收尽

## 代表样本如何变化

### diagnostics

这轮明确回落到 `L1` 的代表样本包括：

- `f5adb68d...`
- `9b33afe9...`

它们都不再出现在新批次 diagnostics 的 `L2` 样本里。

### corpus

corpus 顶层 `L2` 也净下降了 `5`，但 `dd586566...` 与 `b95fff15...` 仍然保留在 shared-CFG family 中：

- `dd586566...`：仍为 `L2`
- `b95fff15...`：仍为 `L2`

这说明 corpus 里剩下的 residual 已经超出了本轮“1 block + 1 br + 小幅 materialization drift”规则能安全覆盖的范围。

## 回归情况

本轮两条 full-batch 继续保持：

- 没有新增 `L3`
- 没有新增 blocked
- diagnostics 没有新的 shared-CFG `L2` 回归

`gate-summary` 仍然是 `WARN`，但原因已经主要回到剩余的 `instruction-family + fast-math + targetTriple` residual，以及 corpus 中仍未收尽的更宽 shared-CFG family，而不是本轮刚处理的 diagnostics residual。

## 下一步最值得继续分析的 case

本轮之后，下一步应继续优先拆 corpus 中仍残留的 shared-CFG residual：

- `dd586566...`
- `b95fff15...`

当前证据说明：

- diagnostics 侧的“窄 split/merge” family 已经被本轮 compare 规则收掉
- corpus 里剩下的 shared-CFG case 更像**更宽的 block/branch reshape**，需要重新下钻 compare-summary，再决定它们仍属 compare 噪声，还是已经碰到不该继续放宽的边界
