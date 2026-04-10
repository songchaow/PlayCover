## fast-math-compile-posture：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-7-corpus-20260410-position-invariant/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-8-corpus-20260410-fast-math-compile-posture/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-7-diagnostics-20260410-position-invariant/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-8-diagnostics-20260410-fast-math-compile-posture/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 186 / L2 = 197 / L3 = 54`
- 新：`L1 = 222 / L2 = 208 / L3 = 7`

直接看变化：

- `L3`：`54 -> 7`，减少 `47`
- `L2`：`197 -> 208`，增加 `11`
- `L1`：`186 -> 222`，增加 `36`

### diagnostics

- 旧：`L1 = 12 / L2 = 140 / L3 = 1`
- 新：`L1 = 13 / L2 = 140 / L3 = 0`

直接看变化：

- `L3`：`1 -> 0`，减少 `1`
- `L2`：`140 -> 140`，持平
- `L1`：`12 -> 13`，增加 `1`

## 共有样本口径下的收益

### 1. `fast_math_disable -> fast_math_enable` 这支 blocked family 已被整支收掉

新旧 `blockedSamples` 对比后：

- corpus：移除了 `47` 个 `L3`，新增 `L3 = 0`
- diagnostics：移除了 `1` 个 `L3`，新增 `L3 = 0`

这批被移除的样本全部来自同一类 root cause：

- original IR 带 `air.compile.fast_math_disable`
- round-trip compile 阶段却按默认姿势把 generated MSL 编成 `air.compile.fast_math_enable`

代表样本包括：

- `d48165ab...`
- `fc1d64b2...`
- `1e7adb48...`
- `514db1e4...`
- `43dadd51...`

这些样本修复后的共同特征是：

- `fastMathComparison` 不再出现 `compileOptionsChanged = true`
- 整体风险从 `L3` 降到 `L1/L2`
- `blockedSamples` 中不再保留它们

### 2. 没有新增 `L3` 回归

新旧 blocked 集合对比结果：

- corpus：`added = 0`
- diagnostics：`added = 0`

这说明这轮 compile posture 修复虽然覆盖了 `47 + 1` 个真实 blocked 样本，但没有引入新的 `L3` family。

### 3. `L2/L1` 上升是预期内的 residual 露出，不是回归

和前几轮一样，这次把高优先级 `L3` 收掉之后：

- 一批样本从 blocked 层回落到可继续分析的 `L2/L1`
- 它们主要露出的 residual 是：
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块元数据 targetTriple 变化`
  - `模块级 addrspace 分布变化`
  - `模块级 air intrinsic 使用变化`

因此：

- `L3` 大幅下降
- `L2/L1` 有所上升
- 这更像“之前被 compile posture 错挡在 blocked 层的样本重新回到分析层”，而不是新的回归

## 修复后剩余的 `L3` 家族

### corpus

剩余 `7` 个 `L3` 已全部收敛成同一支：

1. `entry 参数个数变化; entry 参数类型摘要变化; entry 参数语义摘要变化`：`7`

剩余样本包括：

- `4b130757...`
- `38dac53b...`
- `26468546...`
- `8d88ecc7...`
- `34a57bbd...`
- `787d645f...`

### diagnostics

剩余 `L3 = 0`

也就是说，这轮之后：

- diagnostics 端已经没有 blocked 样本
- corpus 端剩下的最高优先级问题也不再是 fast-math，而是 entry 参数家族

## 如何理解这组结果

### 1. 本轮收益来自 compile posture 对齐，而不是 compare 放宽

这轮没有修改 `ir_canonical_compare.py` 口径；收益全部来自编译姿势修正：

- round-trip compile 会先读取 original IR 的 `air.compile.fast_math_*`
- 再决定是否自动补：
  - `-fno-fast-math`
  - `-ffast-math`
- 因而 regenerated IR 的 `compileOptions` 能重新与 original 对齐

### 2. 这是一处小改动，但命中了当前最大的 blocked 杠杆

这轮修改没有触碰 converter 主逻辑，只修 compile 阶段默认姿势；但 full-batch 结果说明：

- corpus `L3` 直接 `54 -> 7`
- diagnostics `L3` 直接 `1 -> 0`
- 且 `added blocked = 0`

这已经说明它就是 `CC-003.7` 之后真正暴露出来的主矛盾。

### 3. fast-math 现在不再是 blocked ceiling

即便修复后仍能看到一些：

- `fast-math 相关属性变化`
- `指令族统计变化`
- `模块元数据 targetTriple 变化`

但这些 residual 现在只停留在 `L1/L2`；当前 corpus blocked ceiling 已经切换到：

- `entry 参数个数变化 + entry 参数类型摘要变化 + entry 参数语义摘要变化`

## 一句话总结

**`CC-003.8` 已确认是一条 compile posture 缺口：original IR 的 `air.compile.fast_math_disable/enable` 需要在 round-trip compile 阶段映射回 Metal 编译参数；修复后 corpus `L3 54 -> 7`、diagnostics `L3 1 -> 0`，且无新增 blocked，剩余最高优先级问题已经收敛为 `entry 参数` family。**
