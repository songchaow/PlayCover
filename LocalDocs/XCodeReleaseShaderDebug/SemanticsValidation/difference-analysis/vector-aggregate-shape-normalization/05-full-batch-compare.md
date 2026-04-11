## vector-aggregate-shape-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-134613-22123b43/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-140813-393615c6/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-134613-09e0290f/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-140813-e81d755b/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 241 / L2 = 196 / L3 = 0`
- 新：`L1 = 308 / L2 = 129 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`196 -> 129`，减少 `67`
- `L1`：`241 -> 308`，增加 `67`

### diagnostics

- 旧：`L1 = 18 / L2 = 135 / L3 = 0`
- 新：`L1 = 143 / L2 = 10 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`135 -> 10`，减少 `125`
- `L1`：`18 -> 143`，增加 `125`

## 共有样本口径下的收益

### 1. diagnostics 里的高频 `CFG + instruction-family + fast-math` family 基本被整支降到 `L1`

对旧批次 `20260411-134613-09e0290f` 与新批次 `20260411-140813-e81d755b` 对比后：

- 旧批次中这支 family 处于 `L2` 的样本数：`126`
- 新批次中这支 family 仍处于 `L2` 的样本数：`2`
- 新批次中这支 family 已回落到 `L1` 的样本数：`129`

代表样本：

- `083c8443...`：`L2 -> L1`
- `1079c7c8...`：`L2 -> L1`

这与单 case 观察一致：

- compare 不再把“语义不变 + intrinsic 不变 + CFG 主骨架不变，只剩小幅 aggregate/vector/select 重排”的样本继续卡在 `L2`

### 2. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- `blockedSamples` 继续为 `[]`

也就是说，这轮虽然直接调整了 canonical compare 口径，但没有把任何已收敛样本重新推回 blocked 层。

### 3. diagnostics 收益远大于 corpus，说明这轮命中的主要是那支重复 fragment family

顶层变化很清楚：

- diagnostics：`L2 -125 / L1 +125`
- corpus：`L2 -67 / L1 +67`

这说明本轮命中的不是一条“泛化到所有 residual”的宽松规则，而是对 diagnostics 中大量重复出现的那类小型 fragment compare residual 特别有效；在 corpus 侧也有收益，但明显不是当前全部 `L2` 的唯一 root cause。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因已经不再是 blocked / `L3`：

- corpus：`summary = new L2 sample ...06c5f51f...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 profile 仍然没有维护新的 `L2` debt 基线，因此当 residual 分布大幅重排时，`unexpectedL2SampleKeys` 仍会触发 warning。

换句话说：

- 这轮 warning 是 `L2` 清单重排后的 profile 提醒
- 不是新的高风险回归
- 从 `riskCounts`、`L3` 与 `blockedSamples` 看，这轮是显著净收益

## 修复后剩余最高优先级问题

### corpus

当前更值得继续分析的是：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`
2. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`

### diagnostics

当前剩余的 `L2` 已经收缩到少量更纯的 residual：

1. 仍残留的少数 `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`
2. 少量 `模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化; 控制流粗摘要变化`

## 一句话总结

**`CC-003.11` 已确认是一条 compare 口径问题：当 generated MSL 已经保留真实 `if/else + phi` 结构，且 entry/resource/intrinsic 语义都一致时，小幅 `select + aggregate/vector` reshaping 不应继续记为 `L2`；修复后 corpus `L2 196 -> 129`、diagnostics `L2 135 -> 10`，`L3 / blocked` 继续保持 `0`。**
