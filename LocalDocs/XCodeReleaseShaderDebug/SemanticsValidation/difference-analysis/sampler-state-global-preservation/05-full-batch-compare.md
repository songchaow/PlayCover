## sampler-state-global-preservation：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-152454-3ecc3495/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-13-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260411-152454-c0028228/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-13-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 319 / L2 = 118 / L3 = 0`
- 新：`L1 = 319 / L2 = 118 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`118 -> 118`，持平
- `L1`：`319 -> 319`，持平

### diagnostics

- 旧：`L1 = 143 / L2 = 10 / L3 = 0`
- 新：`L1 = 143 / L2 = 10 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`10 -> 10`，持平
- `L1`：`143 -> 143`，持平

## 共有样本口径下的结论

### 1. 这轮没有带来顶层风险计数下降，但也没有新增回归

直接按 `high-risk-samples.json` 中当前目标 family 聚合：

- corpus 中 `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`
  - `50 -> 50`
  - 持平
- diagnostics 中同 family：
  - `1 -> 1`
  - 持平

也就是说，这轮命中的是真实 converter 缺口，但它不是当前这支 family 的唯一 root cause。

### 2. 没有新增 `L3` / blocked 回归

新旧结果对比后：

- corpus：`L3` 继续为 `0`
- diagnostics：`L3` 继续为 `0`
- `blockedSamples` 继续为 `[]`

因此这轮虽然动了 converter 的 sampler-state lowering，但没有把任何已收敛样本重新推回 blocked 层。

### 3. 这轮收益主要体现在“确认 root cause”，而不是立刻体现在顶层计数

单看顶层计数，这轮是持平的；但结合单 case 可以明确看到：

- `293ec561...` 的 `generated.metal` 已不再把 `sample_compare` 错绑到 `sampler_CameraDepthTexture`
- `regenerated.ll` 也已经重新恢复 `@__air_sampler_state`
- 所以当前 family 至少有一部分，已经被证实是 converter 真缺口，而不是 compare 口径问题

换句话说：

- 这轮的主要产出不是“马上减少 1 个 family 计数”
- 而是把 `CC-003.13` 从“怀疑 compare noise”明确推进到“确认存在真实 lowering 缺口”
- 为下一轮继续拆解这支 family 剩余 residual 提供了确定方向

## gate 如何理解

两个 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因没有变化：

- corpus：`summary = new L2 sample ...06c5f51f...`
- diagnostics：`summary = new L2 sample ...1228fae7...`

当前 profile 仍然没有维护 expected `L2` debt 基线，因此 residual 族只要没有清零，就会继续显示 `unexpectedL2SampleKeys`。

换句话说：

- 这轮 warning 不是新的高风险回归
- 而是当前 residual 仍未完全收敛时的 profile 提醒
- 从 `riskCounts`、`L3` 与 `blockedSamples` 看，这轮至少确认了修复安全、没有副作用

## 修复后剩余最高优先级问题

这轮之后，`CC-003.13` 的下一步重点已经更清晰：

### corpus

优先级更高的是：

1. 继续下钻 `293ec561...` / `3f5bb2d...` / `06c5f51f...` 中 residual 仍然残留的 `air intrinsic` reshaping
2. 判断 `air.discard_fragment` 缺失与 `fast_floor / fast_fract / fast_fmin` 漂移，究竟是 emitted MSL 写法问题还是 compare 可降噪对象

### diagnostics

优先级更高的是：

1. 当前唯一残留的 `module addrspace + air intrinsic` family case
2. 与 corpus 同类样本是否共享同一 emitted-MSL mechanism

## 一句话总结

**这轮修复确认：`CC-003.13` 不是纯 compare 噪声；converter 确实存在 `@__air_sampler_state` internal global 被错误回退成 sampler 参数的 lowering 缺口。修复后单 case 的 sampler-state operand 已重新对齐，full-batch 顶层计数保持 `corpus L2 118 / diagnostics L2 10` 且无新增 `L3 / blocked`，说明修复安全，但这支 family 仍有下一层 residual 需要继续拆解。**
