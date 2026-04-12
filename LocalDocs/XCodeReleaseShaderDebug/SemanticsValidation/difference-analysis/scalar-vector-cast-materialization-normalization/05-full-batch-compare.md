## scalar-vector-cast-materialization-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-16-full-corpus/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-17-final-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/cc-003-16-full-diagnostics/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-17-final-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 356 / L2 = 81 / L3 = 0`
- 新：`L1 = 362 / L2 = 75 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`81 -> 75`，减少 `6`
- `L1`：`356 -> 362`，增加 `6`

### diagnostics

- 旧：`L1 = 145 / L2 = 8 / L3 = 0`
- 新：`L1 = 147 / L2 = 6 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`8 -> 6`，减少 `2`
- `L1`：`145 -> 147`，增加 `2`

## 共有样本口径下的收益

### 1. 主 family `instruction-family + fast-math + targetTriple` 继续下降

对 `CC-003.16` 与本轮新批次对比后：

- corpus 中这支 family：`39 -> 33`
- diagnostics 中这支 family：`5 -> 3`

也就是说，本轮净消掉了：

- corpus：`6` 个该 family 的 `L2`
- diagnostics：`2` 个该 family 的 `L2`

### 2. 明确回落的代表样本

这轮从 `L2 -> L1` 的代表样本包括：

#### corpus

- `3a9cedb...`（`com.miHoYo.Yuanshen`）
- `40ad0ed7...`（`com.tencent.tmgp.speedmobile.db`）
- `0967ecd5...`（`com.tencent.tmgp.speedmobile`）
- `336727ca...`（`com.tencent.tmgp.speedmobile`）
- `bb394bf7...`（`com.tencent.tmgp.speedmobile`）
- `e96ae8db...`（`com.tencent.tmgp.speedmobile`）

#### diagnostics

- `376c8b2c...`（`com.tencent.tmgp.speedmobile`）
- `b976c62f...`（`com.tencent.tmgp.speedmobile`）

### 3. 没有新增 `L3` / blocked / new-only L2 回归

新旧风险集合对比后可以直接确认：

- corpus：没有 `new-only` 的 `L2` 样本
- diagnostics：没有 `new-only` 的 `L2` 样本
- 两条 full-batch 的 `L3` 继续都是 `0`
- `blockedSamples` 继续没有新增

这说明本轮不是简单地“把一部分旧 `L2` 换成另一批新的 `L2`”，而是确实做到了**净下降且无回归**。

## 其它 residual 如何理解

### corpus

本轮之后，corpus 的剩余 `L2` 主要是：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`33`
2. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`19`
3. `模块级 addrspace 分布变化; 指令族统计变化; fast-math 相关属性变化`：`9`

可以看到：

- 我们刚处理的主 family 已明显下降，但还没有清零
- shared CFG family 仍完整保留，说明它更像下一轮应优先拆的目标
- `addrspace + instruction-family + fast-math` 这一支也没有被误吸进去，说明本轮规则仍保持了边界

### diagnostics

diagnostics 剩余的 `L2` 已收缩为两支：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`3`
2. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`3`

这说明 diagnostics 里“纯 materialization + targetTriple”的那支 residual 也已经进一步收敛，但 shared CFG residual 还没有动到。

## gate 如何理解

两条 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因仍然不是 `L3` 或 blocked：

- corpus：summary 指向 `...5780e492...`
- diagnostics：summary 指向 `...1228fae7...`

这仍然是 `allowedL2SampleKeys` / debt profile 没有随 residual 分布同步更新导致的提示，不是新增高风险回归。

## 修复后下一步最值得继续分析的 case

当前最值得继续下钻的仍然是 shared CFG 这支 residual family：

- corpus：`dd586566...`、`b95fff15...`
- diagnostics：`f5adb68d...`、`9b33afe9...`

它们的共同标签仍是：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

与本轮已收掉的“同 CFG materialization” family 不同，这支 residual 还伴随 `basicBlockCount / br` 层面的轻微 split/merge 漂移，因此应该作为下一轮优先目标。

## 一句话总结

**`CC-003.17` 证明这轮 compare 扩展有明确统计收益：在不新增 `L3` / blocked / new-only `L2` 的前提下，corpus `L2 81 -> 75`、diagnostics `L2 8 -> 6`，其中主 family `instruction-family + fast-math + targetTriple` 在 corpus `39 -> 33`、diagnostics `5 -> 3`。**
