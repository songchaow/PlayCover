## shared-cfg-split-merge-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-115627-6476094c/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260412-134516-658749ab/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-115627-549ca063/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260412-134516-dd2b4154/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 367 / L2 = 70 / L3 = 0`
- 新：`L1 = 369 / L2 = 68 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`70 -> 68`，减少 `2`
- `L1`：`367 -> 369`，增加 `2`

### diagnostics

- 旧：`L1 = 150 / L2 = 3 / L3 = 0`
- 新：`L1 = 150 / L2 = 3 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`3 -> 3`，持平
- `L1`：`150 -> 150`，持平

## 这轮命中的 shared-CFG residual

`CC-003.19` 这轮针对的就是 corpus 中最后两支仍停留在 shared-CFG family 的 residual：

- `dd586566...`
- `b95fff15...`

它们在旧批次里都还是：

- `riskLevel = L2`
- `riskReason = 控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`

而在新批次里都已经变成：

- `riskLevel = L1`
- `cfgComparison = L1`
- `instructionFamilyComparison = L1`

也就是说，这轮收益非常集中且可解释：

- corpus `L2` 恰好净下降 `2`
- 正好对应这两支 targeted residual 的 `L2 -> L1`

## 代表样本如何变化

### 单 case

- `build/semantics-validation/roundtrip/cc-003-19-single-dd586566-shared-cfg-cast/risk-report.json`
- `dd586566...` 已从 `L2 -> L1`
- `riskCounts = L1 1 / L2 0 / L3 0`

### corpus full-batch

新批次 `build/semantics-validation/roundtrip/20260412-134516-658749ab/risk-report.json` 中可以直接看到：

- `dd586566...`：`L1`
- `b95fff15...`：`L1`

因此 `CC-003.18` 之后残留的 shared-CFG corpus sibling 已被这一轮 compare 规则完全收掉。

### diagnostics full-batch

diagnostics 顶层计数保持：

- `L1 = 150 / L2 = 3 / L3 = 0`

说明这次规则扩展没有引入新的 diagnostics 回归，也没有额外制造新的 `L2` 波动。

## 回归情况

本轮两条 full-batch 继续保持：

- 没有新增 `L3`
- 没有新增 blocked
- diagnostics 没有新的 shared-CFG `L2` 回归

`gate-summary` 仍然是 `WARN`，但原因已经回到其它 residual，例如：

- `5780e492...`
- `edca6ad0...`
- diagnostics 中 3 个仍未收尽的 `instruction-family + fast-math + targetTriple` case

## 下一步最值得继续分析的 case

`CC-003.19` 完成后，shared-CFG split/merge 这支 family 先告一段落。下一步应优先转向当前剩余的：

- `instruction-family + fast-math + targetTriple`

建议先看：

- `5780e492...`
- `edca6ad0...`

当前证据说明：

- shared-CFG residual 已经不再是 corpus 里的主矛盾
- 下一轮更值得继续拆的是纯 `instruction-family` / materialization residual，而不是继续放宽 shared-CFG compare 边界
