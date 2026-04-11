## scalar-vector-materialization-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-140813-393615c6/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-152454-3ecc3495/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-140813-e81d755b/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-152454-c0028228/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 308 / L2 = 129 / L3 = 0`
- 新：`L1 = 319 / L2 = 118 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`129 -> 118`，减少 `11`
- `L1`：`308 -> 319`，增加 `11`

### diagnostics

- 旧：`L1 = 143 / L2 = 10 / L3 = 0`
- 新：`L1 = 143 / L2 = 10 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`10 -> 10`，持平
- `L1`：`143 -> 143`，持平

## 共有样本口径下的收益

### 1. corpus 中这支 `instruction-family + fast-math + targetTriple` family 继续回落

对旧批次 `20260411-140813-393615c6` 与新批次 `20260411-152454-3ecc3495` 对比后：

- 旧批次中这支 family 处于 `L2` 的样本数：`43`
- 新批次中这支 family 仍处于 `L2` 的样本数：`34`
- 新批次中这支 family 已回落到 `L1` 的样本数：`9`

代表样本：

- `62316900...`：`L2 -> L1`
- `2984b21c...`：`L2 -> L1`
- `2629c34e...`：`L2 -> L1`

此外，`com.tencent.tmgp.speedmobile` / `com.tencent.tmgp.speedmobile.db` 侧也同步有多例同 family 样本回落到 `L1`。

### 2. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- `blockedSamples` 继续为 `[]`

也就是说，这轮虽然继续调整了 canonical compare 口径，但没有把任何已收敛样本重新推回 blocked 层。

### 3. diagnostics 持平，说明这轮命中的主要是 corpus 中更纯的一支 materialization family

顶层变化很清楚：

- corpus：`L2 -11 / L1 +11`
- diagnostics：`L2 ±0 / L1 ±0`

这说明本轮命中的不是更宽的 compare 放松，而是针对 corpus 中“CFG 不变，但 scalar/vector materialization 继续轻微重排”的那支更纯 residual family。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因仍然不是 blocked / `L3`：

- corpus：`summary = new L2 sample ...06c5f51f...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 profile 仍然没有维护新的 `L2` debt 基线，因此 residual 分布继续重排时，`unexpectedL2SampleKeys` 仍会触发 warning。

换句话说：

- 这轮 warning 仍然是 `L2` 清单重排后的 profile 提醒
- 不是新的高风险回归
- 从 `riskCounts`、`L3` 与 `blockedSamples` 看，这轮依然是净收益

## 修复后剩余最高优先级问题

### corpus

当前更值得继续分析的是：

1. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`
2. 剩余尚未回落的 `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`

### diagnostics

当前剩余 `L2` 与上一轮保持一致，仍然主要收缩在两支 residual：

1. 少量 `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`
2. 少量 `模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化; 控制流粗摘要变化`

## 一句话总结

**`CC-003.12` 已确认是一条 compare 口径问题：当 entry/resource/builtin/intrinsic 语义与 CFG 都已经一致时，少量 scalar/vector/aggregate materialization reshaping 不应继续记为 `L2`；修复后 corpus `L2 129 -> 118`、这支 triad family `43 -> 34`，diagnostics 保持不回退，`L3 / blocked` 继续为 `0`。**
