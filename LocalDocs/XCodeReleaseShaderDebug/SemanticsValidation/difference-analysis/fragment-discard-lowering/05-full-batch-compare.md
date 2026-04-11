## fragment-discard-lowering：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-13-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-13b-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-13-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-13b-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 319 / L2 = 118 / L3 = 0`
- 新：`L1 = 354 / L2 = 83 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，继续为零
- `L2`：`118 -> 83`，下降 `35`
- `L1`：`319 -> 354`，上升 `35`

### diagnostics

- 旧：`L1 = 143 / L2 = 10 / L3 = 0`
- 新：`L1 = 143 / L2 = 10 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`10 -> 10`，持平
- `L1`：`143 -> 143`，持平

## 共有样本口径下的结论

### 1. 这轮带来了明确的 corpus 统计收益，而且没有新增回归

和上一轮 sampler-state 修复不同，这轮 fragment discard lowering 已经体现在顶层计数上：

- corpus：`L2 118 -> 83`
- diagnostics：`L2 10 -> 10`
- 两边 `L3` 都继续为 `0`

这说明 `air.discard_fragment` 的真实 lowering 缺口不只影响单个 case，而是会成批影响 corpus 中一支重复 residual family。

### 2. 代表 case 已经从高风险层降级

单 case `293ec561...`：

- 旧：`L2`
- 新：`L1`

因此这轮不是“只改了 emitted MSL 但 compare 统计不买账”，而是单 case 与 full-batch 两层证据都已经对齐。

### 3. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- `blockedSamples` 继续为 `[]`

所以这轮动了 fragment termination lowering，但没有把任何已收敛 family 推回 blocked 层。

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因已经切换到新的 residual family：

- corpus：`summary = new L2 sample ...3a9cedb0...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 warning 的含义仍然是：profile 里没有维护 expected `L2` debt 基线，而不是出现新的 `L3` 或 blocked regression。

## 修复后剩余最高优先级问题

这轮之后，下一步重点已经从 `module addrspace + air intrinsic` family 转向新的 shared residual：

### corpus

优先级更高的是：

1. `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化`
2. `指令族统计变化 + fast-math 相关属性变化 + 模块元数据 targetTriple 变化`
3. 仍然唯一挂着 `entry 参数语义摘要变化; entry builtin / stage-in 摘要变化` 的 `823dcdf7...`

### diagnostics

优先级更高的是：

1. 与 corpus 重叠的 `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化` family
2. diagnostics 里仍然稳定残留的 `1228fae7...` 等 `instruction-family + fast-math + targetTriple` family

## 一句话总结

**这轮修复确认：`air.discard_fragment` 不是 compare 口径问题，而是 converter 的真实 lowering 缺口。补齐真实 `discard_fragment();` 发射后，代表 case `293ec561...` 从 `L2 -> L1`，full-batch 也把 corpus 顶层计数从 `L2 118 -> 83`，同时 diagnostics 继续保持 `L2 10 / L3 0`，且没有新增 `L3 / blocked`。**
