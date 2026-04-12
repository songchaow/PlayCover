## scalar-vector-cast-materialization-normalization：full-batch canonical compare 复跑结果

## 本轮复跑输出

### corpus full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-134516-658749ab/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-20-full-corpus/risk-report.json`

### diagnostics full-batch

- 旧结果：`build/semantics-validation/roundtrip/20260412-134516-dd2b4154/risk-report.json`
- 新结果：`build/semantics-validation/roundtrip/cc-003-20-full-diagnostics/risk-report.json`

## 顶层计数变化

### corpus

- 旧：`L1 = 369 / L2 = 68 / L3 = 0`
- 新：`L1 = 391 / L2 = 46 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`68 -> 46`，减少 `22`
- `L1`：`369 -> 391`，增加 `22`

### diagnostics

- 旧：`L1 = 150 / L2 = 3 / L3 = 0`
- 新：`L1 = 151 / L2 = 2 / L3 = 0`

直接看变化：

- `L3`：`0 -> 0`，持平
- `L2`：`3 -> 2`，减少 `1`
- `L1`：`150 -> 151`，增加 `1`

## 共有样本口径下的收益

### 1. 主 family `instruction-family + fast-math + targetTriple` 明显继续下降

对旧批次与本轮新批次对比后：

- corpus 中这支 family：`33 -> 11`
- diagnostics 中这支 family：`3 -> 2`

也就是说，本轮净消掉了：

- corpus：`22` 个该 family 的 `L2`
- diagnostics：`1` 个该 family 的 `L2`

### 2. 目标 case 已明确回落

这轮 dashboard 指向的两支 corpus residual 都已从 `L2 -> L1`：

- `edca6ad0...`
- `5780e492...`

两支单 case 输出分别是：

- `build/semantics-validation/roundtrip/cc-003-20-single-edca6ad0-materialization-wide/risk-report.json`
- `build/semantics-validation/roundtrip/cc-003-20-single-5780e492-materialization-wide/risk-report.json`

并且新 corpus full-batch `build/semantics-validation/roundtrip/cc-003-20-full-corpus/risk-report.json` 中，这两支 sample 已不再出现在 `samplesForL3` 列表里。

### 3. 没有新增 `L3` / blocked / shared-CFG 回退

新旧风险集合对比后可以直接确认：

- corpus：没有 `new-only` 的 `L2` 样本
- diagnostics：没有 `new-only` 的 `L2` 样本
- 两条 full-batch 的 `L3` 继续都是 `0`
- `blockedSamples` 继续为空

因此这轮收益不是“换一批新的 `L2`”，而是主 family 的净下降。

## 其它 residual 如何理解

### corpus

本轮之后，corpus 剩余 `L2` 主要是：

1. `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化`：`12`
2. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`11`
3. `模块级 addrspace 分布变化; 指令族统计变化; fast-math 相关属性变化`：`9`
4. `指令族统计变化; 模块元数据 targetTriple 变化`：`8`

可以看到：

- 纯 materialization family 已从 corpus 主矛盾退到只剩 `11`
- shared-CFG residual 仍有 `12`，说明 compare 在 CFG 侧已经接近边界后，新的优先项可能不再是继续无差别放宽 materialization
- `c2cd49...` 这类 `module air intrinsic + instruction-family` residual 也仍然存在，应作为新的实现层候选

### diagnostics

diagnostics 剩余 `L2` 只剩一支 family：

1. `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`：`2`

当前两支 residual 是：

- `69e4179e...`
- `d8c964c5...`

这说明 diagnostics 里的 shared-CFG residual 已经不再是当前主矛盾，继续拆纯 materialization 的剩余边界会更直接。

## gate 如何理解

两条 full-batch 的 `gate-summary.json` 仍然是 `WARN`，但原因仍然不是 `L3` 或 blocked：

- corpus：summary 指向 `c2cd49d0...`
- diagnostics：summary 指向 `69e4179e...`

这仍然是 gate profile / allowed debt 没有同步更新的提示，不是新增 `L3` 或 blocked 回归。

## 修复后下一步最值得继续分析的 case

`CC-003.20` 完成后，当前最值得继续下钻的是剩余更硬的 residual 边界：

- diagnostics：`69e4179e...`、`d8c964c5...`
- corpus：`c2cd49d0...`

其中：

- diagnostics 两支仍然属于纯 `instruction-family + fast-math + targetTriple` residual，适合继续判断 compare 还能否安全吸收
- `c2cd49d0...` 已经带上 `module air intrinsic` 变化，更像下一轮应优先验证是否已触到实现层问题，而不是单纯继续放宽 compare

## 一句话总结

**`CC-003.20` 的 compare 扩展带来了明确统计收益：在不新增 `L3` / blocked / new-only `L2` 的前提下，corpus `L2 68 -> 46`、diagnostics `L2 3 -> 2`，并把 dashboard 指向的 `edca6ad0...` 与 `5780e492...` 两支残留 case 全部稳定降到 `L1`。**
