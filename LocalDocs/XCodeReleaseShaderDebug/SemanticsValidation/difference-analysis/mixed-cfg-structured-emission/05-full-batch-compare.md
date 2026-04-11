## mixed-cfg-structured-emission：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-9-corpus-20260411-fragment-entry-ghost-position/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-134613-22123b43/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-9-diagnostics-20260411-fragment-entry-ghost-position/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/20260411-134613-09e0290f/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 229 / L2 = 208 / L3 = 0`
- 新：`L1 = 241 / L2 = 196 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`208 -> 196`，减少 `12`
- `L1`：`229 -> 241`，增加 `12`

### diagnostics

- 旧：`L1 = 13 / L2 = 140 / L3 = 0`
- 新：`L1 = 18 / L2 = 135 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`140 -> 135`，减少 `5`
- `L1`：`13 -> 18`，增加 `5`

## 共有样本口径下的收益

### 1. `addrspace + air intrinsic + mixed CFG` family 明显下降

直接按 `high-risk-samples.json` 里的 risk reason 聚合：

- corpus 中 `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`
  - `69 -> 50`
  - 减少 `19`
- diagnostics 中带 `addrspace` 的当前 residual（旧批次主要是 `模块级 addrspace 分布变化; 控制流粗摘要变化; 指令族统计变化`）
  - `20 -> 1`
  - 减少 `19`

这和单 case 观察是对齐的：

- mixed CFG 被正确结构化后，`addrspace` / `air intrinsic` / CFG 统计不再被同一条线性化缺口反复放大

### 2. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- `blockedSamples` 继续为 `[]`

也就是说，这轮虽然动了 converter 的 CFG 发射入口条件，但没有把已收敛的高风险样本重新推回 blocked 层。

### 3. 顶层收益体现为 `L2 -> L1` 下沉，而不是掩盖问题

这轮顶层计数的形态很清楚：

- corpus：`L2 -12 / L1 +12`
- diagnostics：`L2 -5 / L1 +5`

同时代表样本 `ab9230...`、`0d2cd9...` 的单 case 都是：

- `L2 -> L1`
- `addrspace` / `CFG` 主差异消失
- 只剩低风险 intrinsic / instruction-family residual

因此这里不是“compare 被放宽”，而是把真实 converter 结构缺口修掉后，样本自然回落到更合理的 residual 层级。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因不是新的 `L3` 或 blocked：

- corpus：`summary = new L2 sample ...06c5f51f...`
- diagnostics：`summary = new L2 sample ...00a46768...`

当前 profile 没有维护 expected `L2` debt 基线，所以只要 residual 族重新洗牌，就会继续显示 `unexpectedL2SampleKeys`。

换句话说：

- 这轮 warning 是“L2 清单重排后的 profile 口径提醒”
- 不是高风险回归
- 从风险计数与 blocked/L3 角度看，这轮是净收益

## 修复后剩余最高优先级问题

这轮之后，当前主矛盾继续从 `addrspace + air intrinsic` 往下收缩到更纯的 residual：

### corpus

优先级更高的是：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`
2. 仍然残留的少数 `模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化; 控制流粗摘要变化`

### diagnostics

优先级更高的是：

1. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`
2. 剩余唯一带 `addrspace` 的样本，值得单独判断是继续存在真实结构缺口，还是已切换成新的更小 family

## 一句话总结

**这轮修复确认：mixed CFG 的 residual family 主要是 converter 的 structured-CFG 入口条件过窄，而不是 compare 噪声；把局部可恢复的 nested merge 从“整函数线性化”里解放出来后，corpus `L2 208 -> 196`、diagnostics `L2 140 -> 135`，`L3 / blocked` 继续保持为 `0`。**
