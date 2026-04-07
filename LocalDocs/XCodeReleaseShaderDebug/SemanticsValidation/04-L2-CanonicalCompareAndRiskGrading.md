## L2：Canonical Compare + 风险分级

## 目标

在 L1 的 `original.ll` 与 `regenerated.ll` 基础上，建立一套**结构化 compare**，回答：

- 哪些差异只是表面形式变化
- 哪些差异可能影响语义
- 哪些样本值得继续进入 L3/L4

这层的目标不是做形式化证明，而是先做一个**可批量运行、可解释、可分级**的语义风险筛查器。

## 为什么不能只做文本 diff

直接比较 `.ll` 文本会产生很多噪声：

- SSA 名称变化
- metadata 编号变化
- 声明顺序变化
- 某些无关注释或格式差异

因此需要比较的是 **canonical summary**，而不是原始文本本身。

## 第一版建议比较项

### 1. Entry 面

- entry 函数集合
- entry 名称
- shader 类型（vertex / fragment / kernel）
- entry 参数个数与顺序
- entry 返回类型摘要

### 2. 类型与地址空间面

- 参数类型摘要
- 指针/聚合类型摘要
- `addrspace` 分布
- `thread / device / constant / threadgroup` 等关键地址空间映射

### 3. Builtin / Resource 面

- `air.*` / intrinsic 使用集合
- texture / sampler / buffer / stage-in / builtin 参数摘要
- 关键资源访问模式摘要

### 4. 控制流面

- basic block 数量
- terminator 分布（ret / br / condbr / switch 等）
- phi / select 统计
- CFG 粗摘要

### 5. 指令族统计

- arithmetic
- compare
- cast
- memory
- vector ops
- aggregate ops
- intrinsic calls

### 6. 关键属性面

- fast-math 标记
- 关键 function attrs
- target triple / data layout（只做记录，不必都作为失败条件）

## 风险分级建议

### L0：低风险 / 近似一致

特征：

- entry / shader type / 参数返回摘要一致
- 地址空间一致
- builtin / resource 摘要一致
- CFG 与 instruction family 仅有轻微无害波动

### L1：可接受差异

特征：

- 存在一些结构变化，但没有触及关键语义面
- 需要记录，但默认不阻塞

### L2：中风险 / 需复核

特征：

- builtin/resource/CFG/fast-math 中有可疑变化
- 或 entry 类型一致但关键统计明显偏移

这类样本优先进入 L3。

### L3：高风险 / 结构性不一致

特征：

- entry 集合变化
- shader type 变化
- 参数/返回关键类型不一致
- 地址空间关键项不一致
- builtin/resource 面明显不匹配

这类样本默认视为 round-trip 失败样本，不直接进入 live。

## 第一版实现建议

### Step 1：先做 summary extractor

建议先实现：

- `extract_ir_summary(original.ll)`
- `extract_ir_summary(regenerated.ll)`

输出结构化 JSON，而不是先写复杂 diff。

### Step 2：再做 summary comparator

建议输出：

- `same`
- `changed`
- `severity`
- `reason`
- `details`

### Step 3：最后生成 risk report

将 compare 结果汇总成：

- 样本级风险
- 批量统计
- 高风险样本列表
- 常见差异类型聚类

## 比较策略建议

### 应忽略或弱化的差异

- SSA 名称
- metadata 编号
- 注释/空行/格式
- 某些非关键声明顺序

### 必须保留敏感性的差异

- entry 函数集合与 shader type
- 参数与返回关键摘要
- 地址空间
- builtin / resource 语义
- CFG 粗结构
- fast-math / 关键 attrs

## 验证样本建议

### 正向样本

先用 round-trip 成功、看起来最简单的 `test-data/` 样本，验证：

- compare 不会误报过多
- summary 提取逻辑能稳定工作

### 反向样本

建议人工构造几组最小差异对，用于验证 compare 的敏感性：

- 只改 SSA 名称 → 应为低风险
- 改 `addrspace` → 应升为高风险
- 改 entry shader type → 应升为高风险
- 改 builtin/resource 摘要 → 应升为中高风险

## 报告建议

建议产物：

- `compare-summary.json`
- `risk-report.json`
- `high-risk-samples.json`

每个样本至少应有：

- `comparisonKey`
- `riskLevel`
- `riskReason`
- `differences`
- `entryComparison`
- `addressSpaceComparison`
- `builtinComparison`
- `cfgComparison`
- `instructionFamilyComparison`

## 完成标准

满足以下条件后，可认为 `SV-002` 基本完成：

1. 对 round-trip 成功样本可自动提取 canonical summary
2. 能输出结构化 compare，而不是仅有文本 diff
3. 能把结果分成至少 4 档风险级别
4. 至少在 `test-data/` 上跑通并产出批量报告
5. 能明确给出哪些样本应进入 L3/L4

## 设计边界

- 第一版不追求形式化语义证明
- 第一版不要求完整 IR AST 等价器
- 第一版优先做 **summary compare + 风险筛查**
- 若后续发现 summary compare 不足，再决定是否升级到更细粒度的 AST/CFG compare
