## single-field-return-wrapper：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-4-5-2-corpus-20260410-direct-merge-phi-fix/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-5-1-corpus-20260410-converter-first-single-field-return/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-4-5-2-diagnostics-20260410-direct-merge-phi-fix/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-5-1-diagnostics-20260410-converter-first-single-field-return/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 102 / L2 = 84 / L3 = 251`
- 新：`L1 = 176 / L2 = 191 / L3 = 70`

直接看变化：

- `L3`：`251 -> 70`，减少 `181`
- `L2`：`84 -> 191`，增加 `107`
- `L1`：`102 -> 176`，增加 `74`

### diagnostics

- 旧：`L1 = 7 / L2 = 0 / L3 = 146`
- 新：`L1 = 9 / L2 = 140 / L3 = 4`

直接看变化：

- `L3`：`146 -> 4`，减少 `142`
- `L2`：`0 -> 140`，增加 `140`
- `L1`：`7 -> 9`，增加 `2`

## 如何理解这组结果

### 1. 这轮收益来自 converter-first，而不是 compare 降噪

这轮最关键的一点是：

- compare 规则保持原状
- 但 diagnostics 仍有 `142` 个样本从 `L3 -> L2/L1`
- corpus 仍有 `181` 个样本从 `L3 -> L2/L1`
- 这些样本全部移除了 `entry 返回类型摘要变化`
- 没有新增 `L3`

这说明当前收益已经不能再解释成“compare 放宽了口径”，而是：

- `IRToMSLConverter.swift` 从源头保住了 original IR 中那支 single-field wrapped return 的返回形态

### 2. `L2` 上升仍然是预期结果，不是回归

和之前一样，这轮之后：

- 很多原先被 `entry 返回类型摘要变化` 顶成 `L3` 的样本，重新露出了真正剩余的 residual
- 这些 residual 依然主要集中在：
  - `控制流粗摘要变化`
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块级 addrspace 分布变化`
  - `模块级 air intrinsic 使用变化`

因此 `L2` 增加依旧意味着：

- 被错误挡在 blocked 层的一批样本，现在重新进入了当前主线可以继续 case-by-case 下钻的分析层

### 3. converter-first 版本的收益还略好于 compare-first

和我上一版 compare-first 实验残留的统计相比，本轮 converter-first 结果更干净一点：

- corpus：`L1 174 / L2 192 / L3 71` → **`L1 176 / L2 191 / L3 70`**
- diagnostics：`L1 8 / L2 141 / L3 4` → **`L1 9 / L2 140 / L3 4`**

也就是说：

- 在遵守 dashboard 规则、优先修 converter 的前提下
- 不但没有损失收益，反而额外多收回了 `1` 个 corpus `L3` 与 `1` 个 diagnostics `L2`

### 4. representative gate 可以收紧

本轮 converter-first corpus full-batch 里：

- `bundle:com.tencent.tmgp.speedmobile.db::module:1f5e65cd9f685b3673dd6fac9b81e3af82b5a6d436f8f1824919726483c967ad`
- 已稳定是 `L1`
- 风险原因只剩：`指令族统计变化; 模块元数据 targetTriple 变化`

因此本轮再次移除了它在 `LOCAL_SHADERCORPUS_REPRESENTATIVE_CONTRACT` 中的 `allowedBlocked` 白名单，让 gate 和最新真实状态重新对齐。

## 当前结论

如果问题是：

- “这轮 single-field return wrapper 修正，到底应不应该优先做 converter？”

答案现在已经明确：

- **应该，而且事实证明 converter-first 是更符合规则、也更有效的一条路径。**

## 一句话总结

**`single-field return wrapper` 这条修正确认：当前主线里一大支 `entry 返回类型摘要变化` 至少有很大一部分不是 compare 口径问题，而是 `IRToMSLConverter.swift` 把 original IR 的 single-field wrapped return 过早塌成了裸返回类型；按 converter-first 修复后，diagnostics `L3 146 -> 4`、corpus `L3 251 -> 70`，且无新增 `L3`。**
