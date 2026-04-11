## fragment-entry-ghost-position：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-8-corpus-20260410-fast-math-compile-posture/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-9-corpus-20260411-fragment-entry-ghost-position/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-8-diagnostics-20260410-fast-math-compile-posture/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-9-diagnostics-20260411-fragment-entry-ghost-position/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 222 / L2 = 208 / L3 = 7`
- 新：`L1 = 229 / L2 = 208 / L3 = 0`

直接看变化：

- `L3`：`7 -> 0`，减少 `7`
- `L2`：`208 -> 208`，持平
- `L1`：`222 -> 229`，增加 `7`

### diagnostics

- 旧：`L1 = 13 / L2 = 140 / L3 = 0`
- 新：`L1 = 13 / L2 = 140 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`140 -> 140`，持平
- `L1`：`13 -> 13`，持平

## 共有样本口径下的收益

### 1. `entry 参数` 这支 blocked family 已被整支收掉

新旧 `blockedSamples` 对比后：

- corpus：移除了全部 `7` 个 blocked 样本
- diagnostics：原本就没有 blocked 样本，仍保持 `0`

这批被移除的样本全部来自同一类 root cause：

- original IR 的 fragment entry 没有输入参数
- generated MSL 却被额外写进 `float4 position [[position]]`
- regenerated IR 因而凭空多出一个 `<4 x float>` entry 参数

代表样本包括：

- `4b130757...`
- `38dac53b...`
- `26468546...`
- `8d88ecc7...`
- `34a57bbd...`
- `787d645f...`

这些样本修复后的共同特征是：

- `entryComparison` 不再出现 `parameterCount` / `parameterSignatures` / `argSemantics` 漂移
- corpus `blockedSamples` 已为空
- 全量 `L3` 归零

### 2. 没有新增 `L3` 回归

新旧结果对比后：

- corpus：`L3 added = 0`
- diagnostics：`L3 added = 0`

这说明本轮修复虽然收掉了最后一支 corpus blocked family，但没有把其它样本重新推回 `L3`。

### 3. `L1` 上升是 blocked family 下沉，不是新回归

和前几轮一样，这次把最后一支 `L3` 收掉之后：

- corpus 有 `7` 个样本从 blocked 层回落到可接受层
- 体现在顶层计数上就是：
  - `L3 -7`
  - `L1 +7`
  - `L2` 不变

因此这里更像“blocked 解除后回到正常 residual 分布”，而不是产生了新的高风险家族。

## 修复后剩余最高优先级问题

### corpus

修复后剩余最高优先级已经不再是 blocked `L3`，而是若干 `L2` residual family，主要包括：

1. `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`
2. `控制流粗摘要变化; 指令族统计变化`
3. `指令族统计变化; fast-math 相关属性变化`

### diagnostics

diagnostics 顶层计数保持不变：

- `L1 13 / L2 140 / L3 0`

也就是说，这轮收益集中在 corpus 最后一支 blocked family，不影响 diagnostics 的已收敛状态。

## 如何理解这组结果

### 1. 本轮收益来自 converter 参数建模修正，而不是 compare 放宽

这轮没有修改 `ir_canonical_compare.py` 口径；收益全部来自生成侧修正：

- fragment `[[position]]` 不再作为无条件默认 builtin 注入
- 只有当 metadata 或原始 IR 参数列表确实给出这类 entry builtin 时，才继续发射
- 因而 regenerated IR 不会再凭空多出一个 entry 参数

### 2. 这是一个小改动，但正好命中了 `CC-003.8` 之后剩余的全部 blocked family

这轮修改没有触碰 compare、planner 或 aggregate compile，只修了 entry 参数默认注入逻辑；但 full-batch 结果说明：

- corpus `L3` 直接 `7 -> 0`
- diagnostics `L3` 维持 `0`
- `blockedSamples` 清零

这已经说明它就是 `CC-003.8` 之后剩余 blocked ceiling 的真实 root cause。

### 3. 当前 ceiling 已经从 `L3` 切换到 `L2` residual

现在即便 gate summary 仍提示有新的 `unexpectedL2SampleKeys`，其本质也已经不是 blocked family，而是已存在 residual 在新的 full-batch 快照中重新暴露。

当前更值得继续分析的是：

- `addrspace + air intrinsic`
- `CFG + instruction-family`

而不是再回头处理 entry 参数 ghost family。

## 一句话总结

**`CC-003.9` 已确认是一条 converter entry-parameter 建模缺口：fragment `[[position]]` 不能作为无条件默认 builtin 注入；修复后 corpus `L3 7 -> 0`、`blockedSamples` 清零、diagnostics 继续保持 `L3 = 0`，当前主矛盾已经切换到 `L2` residual family。**
