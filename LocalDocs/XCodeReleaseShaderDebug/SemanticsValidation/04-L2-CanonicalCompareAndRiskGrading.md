## L2：Canonical Compare + 风险分级

## 文档职责

本文只记录 L2 的**比较口径、风险分级、降噪策略、报告结构、gate 语义与证据边界**。

**任务状态、进展、优先级、TODO、完成判定与默认执行顺序统一只在 `00-Dashboard.md` 维护。** 本页不重复动态控制面信息。

## 目标

在 L1 已产出的 `original.ll` / `regenerated.ll` 以及相关 compile 报告基础上，建立一套**结构化 compare + 风险分级**，回答：

- 哪些差异只是编译器、metadata 或表面形态变化
- 哪些差异可能影响语义，应优先复核
- 哪些问题更像 compile posture / aggregate 证据问题，哪些更像 converter / compare 问题
- 哪些结果适合继续沉淀为 gate 事实，哪些只适合作为观察信号

L2 的目标是提供**可批量运行、可解释、可回归的语义风险筛查器**。

## canonical summary 的比较维度

### Entry 面

比较：

- entry 函数集合
- shader 类型（`vertex / fragment / kernel`）
- entry 名称
- 返回类型摘要
- 参数个数与参数类型摘要
- entry 参数语义摘要
- entry 输出语义摘要

### 类型 / 地址空间面

比较：

- 参数 `addrspace` 摘要
- 模块级 `addrspace` 分布
- entry 资源参数中的关键地址空间信息

### Builtin / Resource 面

比较：

- `!air.vertex / !air.fragment / !air.kernel` 元数据里的参数语义
- buffer / texture / sampler / stage-in / builtin 摘要
- 模块级 `air.*` intrinsic 使用统计
- 函数内 `air.*` intrinsic 调用统计

### 控制流 / 指令族面

比较：

- basic block 数量
- terminator 分布（`ret / br / condbr / switch ...`）
- `phi / select` 统计
- instruction family 统计：
  - arithmetic
  - compare
  - cast
  - memory
  - vector
  - aggregate
  - intrinsic / call

### compile posture / 关键属性面

比较：

- `fast-math` 相关 compile option
- function attr 中的 `fast-math` 相关 key
- 指令级 `fast / nnan / ninf / nsz / arcp / contract / afn / reassoc` 统计
- L1 compile 报告中的：
  - `originalFastMathMode`
  - `inferredMetalArgs`
  - `effectiveMetalArgs`
- aggregate compile summary 中的：
  - `fastMathMode`
  - `fastMathDecision`
  - `usesExplicitCompileOptions`
  - `compileOptionsFastMathEnabled`
  - `explicitOverrideSource`
- `target triple / data layout`（可记录，但通常不单独作为阻断依据）

## 风险分级口径

### L0：低风险 / 近似一致

特征：

- canonical summary 基本一致
- 没有关键 entry、地址空间、builtin、resource 差异
- compile posture 证据未显示关键漂移
- 可视为低风险结果

### L1：可接受差异

特征：

- 存在局部结构波动
- 主要属于统计层、优化层或表现层差异
- compile posture 已对齐，残余主要停留在低风险统计项
- 适合记录与观察，不应轻易放大为阻断

### L2：中风险 / 需复核

特征：

- builtin、resource、CFG、fast-math、instruction family、compile posture 等维度出现可疑变化
- 需要继续在离线层做聚类、解释或补充证据
- 是否升级到更高层，应由 dashboard 的决策面统一裁定

### L3：高风险 / 结构性不一致

特征：

- entry 集合变化
- 参数 / 返回关键摘要变化
- 参数 `addrspace` 关键项变化
- round-trip 主链路失败
- 或 compile posture / aggregate runtime-like 证据已经明确显示关键决策不一致

这类样本应先回到低层修清结构风险，再决定是否继续升级。

## 主动降噪策略

为了让 L2 更像“风险筛查器”而不是“文本 diff 放大器”，默认应弱化或忽略以下差异：

- SSA 名称变化
- metadata 编号变化
- 注释 / 空行 / 格式变化
- 某些声明顺序变化
- `bufferSize` 缺失这类 metadata 省略
- 仅体现在 resource metadata 的 `air.address_space` 显式化、且函数参数 `addrspace` 摘要未变化时的差异
- `readonly / writeonly / readnone / dereferenceable / align / nocapture / noundef` 等参数修饰噪声
- `air.fast_*` 与对应 `air.*` intrinsic alias 的名称差异
- 仅发生在 instruction-level、且未伴随 compile option / planner decision 漂移的 fast-math flag 变化

默认仍应保持敏感的差异包括：

- entry 集合与 shader type
- 参数 / 返回关键摘要
- 参数 `addrspace`
- entry 参数语义与输出语义
- builtin / resource 摘要
- CFG 粗结构
- compile posture 与 fast-math 相关差异

## 报告结构

### `compare-summary.json`

每个样本建议至少包含：

- `comparisonKey`
- `riskLevel`
- `riskReason`
- `recommendedAction`
- `differences`
- `entryComparison`
- `addressSpaceComparison`
- `builtinComparison`
- `cfgComparison`
- `instructionFamilyComparison`
- `fastMathComparison`
- `moduleMetadataComparison`
- `originalSummary`
- `regeneratedSummary`

### `risk-report.json`

建议包含：

- 批量 `riskCounts`
- `samplesForL3`
- `blockedSamples`
- 每个样本的精简风险摘要与建议动作
- 是否需要补 compile posture / aggregate runtime-like 证据

### `high-risk-samples.json`

建议快速列出：

- `L2` 样本
- `L3` 样本

以便后续聚类或挑选复核样本。

### `gate-summary.json`

建议表达：

- 运行整体状态（如 `pass / warn / fail`）
- 仍存在的已知 `L2 / L3 / round-trip failure`
- 已被结构化记为 improvement 的 debt
- 是否出现 profile 之外的新 blocker 或新高风险
- `roundtripReportPath` / `outputRoot` 等下游消费锚点
- `layeredDecision`：
  - 是否继续停留在当前层
  - 是否建议升级到 L3 或 L4
  - 若升级，候选样本与原因是什么
- 在 `--enforce-gate` 模式下是否应阻断退出

## compile posture 证据如何进入 L2 判断

当样本差异涉及 compile posture 时，L2 默认应优先回答：

1. `compile-summary.json` 的 `originalFastMathMode` / `inferredMetalArgs` / `effectiveMetalArgs` 是否已经对齐
2. 如果是 aggregate 问题，`aggregate_replay_runner.py --compile-backend mtl-device` 的 compile summary 是否与 `xcrun` / planner 预期一致
3. 如果 compile posture 已对齐，剩余差异是否更像 compare 噪声或 converter emission 问题

也就是说，L2 不只消费 `original.ll` / `regenerated.ll`，还会消费**与 compare 同一轮的 compile 报告**来解释 root cause。

## 契约引用

以下契约已统一收口到 `08-当前代表集与Gate契约参考.md`，本页不再重复展开：

- `gate-summary.json`、`risk-report.json`、`compare-summary.json`、`compile-summary.json`、`preset-manifest.json` 的事实优先级
- `comparisonKey` / `sampleKey` 等 source-aware 身份规则
- `preset-manifest.json` 与其它报告之间的职责划分

## L2 的边界

L2 不是：

- 形式化语义证明器
- 完整 IR AST / CFG 等价器
- 行为级测试
- live / GUI 验证
- runtime 主路径本身

L2 的价值在于：

- 把结构化差异变成机器可读风险
- 把 compile posture / aggregate 证据纳入同一解释框架
- 为是否升级到 L3/L4 提供依据
- 让回归判断能够依赖报告，而不是依赖人工口头解释

## 与相邻文档的关系

- L1 输入与产物：`03-L1-IR-RoundTrip.md`
- L3 方法与 harness：`05-L3-最小行为测试.md`
- gate / preset / manifest / compile 契约：`08-当前代表集与Gate契约参考.md`
- 动态控制面：`00-Dashboard.md`
- aggregate runtime-like compile 方法：`06-L4-真实场景验证.md` 与 `RuntimeTesttimeAlign/00-Dashboard.md`