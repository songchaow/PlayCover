## single-field-return-wrapper：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-4-5-2-corpus-20260410-direct-merge-phi-fix/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-5-1-corpus-20260410-single-field-return-compare-normalization/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-4-5-2-diagnostics-20260410-direct-merge-phi-fix/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-5-1-diagnostics-20260410-single-field-return-compare-normalization/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 102 / L2 = 84 / L3 = 251`
- 新：`L1 = 174 / L2 = 192 / L3 = 71`

直接看变化：

- `L3`：`251 -> 71`，减少 `180`
- `L2`：`84 -> 192`，增加 `108`
- `L1`：`102 -> 174`，增加 `72`

### diagnostics

- 旧：`L1 = 7 / L2 = 0 / L3 = 146`
- 新：`L1 = 8 / L2 = 141 / L3 = 4`

直接看变化：

- `L3`：`146 -> 4`，减少 `142`
- `L2`：`0 -> 141`，增加 `141`
- `L1`：`7 -> 8`，增加 `1`

## 如何理解这组结果

### 1. 这轮收益的核心不是“让 residual 消失”，而是“把一整支误判的 blocked family 释放出来”

本轮最重要的变化不是单纯看 `L2` 有没有下降，而是：

- diagnostics 有 `142` 个样本从 `L3 -> L2/L1`
- corpus 有 `180` 个样本从 `L3 -> L2/L1`
- 这 `322` 个样本全部移除了 `entry 返回类型摘要变化`
- 没有新增 `L3`

这说明当前 compare 规则终于把 **single-field return wrapper** 这支高频误报从 blocked 层拿掉了。

### 2. `L2` 大幅上升是预期结果，不是回归

这轮之后：

- 很多原先被 `entry 返回类型摘要变化` 顶成 `L3` 的样本，重新露出了它们真正剩下的 residual
- 这些 residual 更常见的形态是：
  - `控制流粗摘要变化`
  - `指令族统计变化`
  - `fast-math 相关属性变化`
  - `模块级 addrspace 分布变化`
  - `模块级 air intrinsic 使用变化`

也就是说，`L2` 增加并不代表新增问题，而是说明：

- 原本被 `L3` 掩盖的一批可分析 residual，现在终于进入了当前主线允许继续 case-by-case 下钻的范围

### 3. representative gate 也可以收紧

本轮最新 corpus full-batch 里：

- `bundle:com.tencent.tmgp.speedmobile.db::module:1f5e65cd9f685b3673dd6fac9b81e3af82b5a6d436f8f1824919726483c967ad`
- 已经稳定是 `L1`
- 风险原因只剩：`指令族统计变化; 模块元数据 targetTriple 变化`

因此本轮同步移除了它在 `LOCAL_SHADERCORPUS_REPRESENTATIVE_CONTRACT` 中的 `allowedBlocked` 白名单，让 gate 重新对齐当前真实状态。

## 当前结论

如果问题是：

- “这轮 compare 修正有没有统计收益？”

答案是：

- **有，而且收益非常明确：它把 single-field return wrapper 这支高频 `L3` blocked family 大规模降回 `L2/L1`，没有新增 `L3`，并让后续分析重新回到真实 residual 上。**

## 一句话总结

**`single-field return wrapper` 这条修正确认：当前主线里一大支 `entry 返回类型摘要变化` 不是实现 bug，而是 compare 过度依赖 raw `returnSignature` 文本；补齐等价判定后，diagnostics `L3 146 -> 4`、corpus `L3 251 -> 71`，后续主线应转向剩余仍为 `L3` 的真实 `entry 参数类型 / addrspace / CFG` 家族。**
