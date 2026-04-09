## L2：Canonical Compare + 风险分级

## 目标

在 L1 已产出的 `original.ll` / `regenerated.ll` 基础上，建立一套**结构化 compare + 风险分级**，回答：

- 哪些差异只是编译器 / metadata / 表面形态变化
- 哪些差异可能影响语义，应优先进入后续复核
- 哪些样本已经可以继续沉淀到日常 gate，哪些样本暂时不应进入当前默认边界

这层的目标仍然不是形式化证明，而是先得到一个**可批量运行、可解释、可回归**的语义风险筛查器。

若只是理解当前主线优先级，优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`；本文件更偏向 L2 口径、报告结构与 gate 语义的工作参考，当前日常推进**不必须读取**。

## 当前实现状态

**`SV-002` 已完成。**

当前已落地：

- 新增 `Scripts/ir_canonical_compare.py`
- 已让 `Scripts/ir_semantics_roundtrip_runner.py` 在完成 `roundtrip` 后自动继续执行 L2
- 已新增 `Scripts/test_ir_canonical_compare.py`
- 已更新 `Scripts/test_ir_semantics_roundtrip_runner.py`

当前 `roundtrip runner` 默认会产出：

- `roundtrip-summary.json`
- `compare-summary.json`
- `risk-report.json`
- `high-risk-samples.json`
- `gate-summary.json`
- `preset-manifest.json`

对固定输出目录，当前还支持：

- 用 `--save-baseline` 保存 replay baseline snapshot
- 在目录下已有 `baseline.json` 时自动复用它做 replay baseline diff（也可显式用 `--baseline-report` 覆盖）

当前状态需要明确区分两件事：

- **L2 能力是否存在**：已经存在，且已在 `test-data/` 与代表 preset 上跑通
- **L2 当前在做什么**：重点不再是“再造 compare”，而是把同一套 `gate-summary.json` / `risk-report.json` / `--gate-profile` / `--enforce-gate` 语义稳定扩展到尽可能多的已采集 corpus 样本，并继续维持 `PASS / WARN / FAIL` 的自动化边界。其中应优先看 `gate-summary.json` 的结构字段，而不是沿用 gate profile 的旧描述文字；若某条新路径仍要求人工批量枚举 `ShaderSourceDiagnostics` 样本，就还不能视为已经收口

## 已实现的 canonical summary

### Entry 面

当前会提取并比较：

- entry 函数集合
- shader 类型（`vertex / fragment / kernel`）
- entry 名称
- 返回类型摘要
- 参数个数
- 参数类型摘要
- entry 参数语义摘要
- entry 输出语义摘要

### 类型 / 地址空间面

当前会提取并比较：

- 参数 `addrspace` 摘要
- 模块级 `addrspace` 分布
- entry 资源参数中的关键地址空间信息

### Builtin / Resource 面

当前会提取并比较：

- `!air.vertex / !air.fragment / !air.kernel` 元数据里的参数语义
- buffer / texture / sampler / stage-in / builtin 摘要
- 模块级 `air.*` intrinsic 使用统计
- 函数内 `air.*` intrinsic 调用统计

### 控制流 / 指令族面

当前会提取并比较：

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

### 关键属性面

当前会提取并比较：

- `fast-math` 相关 compile option
- function attr 里的 `fast-math` 相关 key
- 指令级 `fast / nnan / ninf / nsz / arcp / contract / afn / reassoc` 统计
- `target triple / data layout`（仅记录，默认不单独作为阻断）

## 当前风险分级口径

### L0：低风险 / 近似一致

特征：

- canonical summary 基本一致
- 没有关键 entry / 地址空间 / builtin / resource 差异
- 无需立即升级

### L1：可接受差异

特征：

- 存在局部结构波动
- 主要是统计层或优化层差异
- 默认记录，但不阻塞

### L2：中风险 / 需复核

特征：

- builtin / resource / CFG / fast-math / instruction family 中有可疑变化
- 默认先停留在当前 L1/L2 主线内复核其分布与边界
- 是否升级到 L3 由后续用户决策决定；当前不把升级写回默认任务

### L3：高风险 / 结构性不一致

特征：

- entry 集合变化
- 参数 / 返回关键摘要变化
- 参数 `addrspace` 关键项变化
- 或 round-trip 主链路本身失败

这类样本默认视为**不应直接进入后续路径**，应先在 L1/L2 层修清结构风险。

## 第一版主动降噪策略

为了让 L2 更像“风险筛查器”而不是“文本 diff 放大器”，当前已明确**弱化或忽略**以下差异：

- SSA 名称变化
- metadata 编号变化
- 注释 / 空行 / 格式变化
- 某些声明顺序变化
- `bufferSize` 缺失这类 metadata 省略
- `readonly / writeonly / readnone / dereferenceable / align / nocapture / noundef` 这类参数修饰噪声
- `air.fast_*` 与对应 `air.*` intrinsic alias 的名称差异
- 仅发生在 instruction-level、且未伴随 compile option / function attr 漂移的 fast-math flag 变化

当前仍然对下面差异保持敏感：

- entry 集合与 shader type
- 参数 / 返回关键摘要
- 参数 `addrspace`
- entry 参数语义与输出语义
- builtin / resource 摘要
- CFG 粗结构
- fast-math 相关差异

## 批量验证结果

### `test-data/` 首轮 L2 报告

`test-data-batch` 目录继续保留为一份**较早的批量参考快照**，但已经**不是**当前默认 gate 的 active 口径；它当前主要承担失败聚类、历史对照与降噪回看价值。

处理原则：

- 当前 active 口径统一回到 `test-data-representatives` 的固定输出目录与 `08-当前代表集与Gate契约参考.md`
- 更细的旧分布、旧 compile failure 背景与样本名单统一下沉到 `07-首轮基线与历史进展归档.md`（历史参考，当前日常推进**不必须读取**）

### 当前代表样本

当前 L2 只继续向主线暴露四条 active 事实：

- **代表 preset 的当前边界契约应以 `gate-summary.json` / `risk-report.json` 为准；`preset-manifest.json` 更适合描述发现与 artifact 锚点，不应单独充当 active debt 事实来源**
- **同一套 L2 报告语义应继续覆盖 `test-data-representatives`、`ShaderCorpus` 与 `ShaderSourceDiagnostics` 补充输入**；当前最高优先级不是重写代表集 debt 描述，而是把更多已采集样本纳入同样的结构化判断
- **当 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 命中相同 `bundleId + moduleKey` 时，L2 的 `comparisonKey / sampleKey` 必须继续保留来源区分**；否则 failure-path 结果会污染 success-path 的 gate 事实
- **更细的当前样本键、数值、artifact 锚点与契约摘要统一下沉到 `08-当前代表集与Gate契约参考.md`；旧 fail 解释与历史分布统一下沉到 `07-首轮基线与历史进展归档.md`（均为参考，当前主线推进**不必须读取**）**

## 报告结构

### `compare-summary.json`

每个样本当前至少包含：

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

当前用于输出：

- 批量 `riskCounts`
- `samplesForL3`
- `blockedSamples`
- 每个样本的精简风险摘要与建议动作

### `high-risk-samples.json`

当前用于快速列出：

- `L2`
- `L3`

样本，便于后续聚类或选取代表集。

### `gate-summary.json`

当前用于输出：

- 当前这次运行是 `pass / warn / fail`
- 哪些已知 `L2 / L3 / round-trip failure` 仍然存在
- 哪些 debt 已被结构化记为 improvement（如 `resolvedL2SampleKeys`）
- 是否出现了超出当前代表集 profile 的新增 blocker / 新增 `L3`
- `layeredDecision`：当前是否应继续停在 L1/L2 离线层
- 在 `--enforce-gate` 模式下是否应阻断退出

## 已验证测试

当前已覆盖真实样本提取、合成正向 / 反向样本以及 `roundtrip runner` 集成测试三类关键路径；更细的测试入口可直接参考 `Scripts/test_ir_canonical_compare.py` 与 `Scripts/test_ir_semantics_roundtrip_runner.py`。

## 当前边界

第一版仍然有明确边界：

- 不是形式化语义证明器
- 不是完整 IR AST / CFG 等价器
- 还不能回答“行为是否一致”
- 当前批量大盘仍可能很噪，但当前阶段不因此直接扩大到后置 live 验证
- 当前已经有第一版机器可执行的升级/止损边界：代表 preset 会通过 `gate-summary.json` / `--enforce-gate` 将“已知 debt”与“新增回归”区分开；更细的历史相位变化已下沉到 `07-首轮基线与历史进展归档.md`（历史参考，**不必须读取**）

## 对下一步的直接启示

`SV-002` 完成后，当前最合理的下一步不是直接跳到后置层，而是：

1. 持续守住 `test-data-representatives` 这个跨机器硬默认入口不回退
2. 把 `ShaderCorpus` 全量已采集样本尽可能纳入同一套 `compare-summary / risk-report / gate-summary` 语义
3. 继续使用 `--diagnostics-root` 批量补充 failure-path 样本，但不把人工批量枚举写回默认流程
4. 继续把当前默认目标停留在“全量 corpus 的 L1/L2 测试”，而不是把 L3/L4 重新写回主线

## 完成标准回顾

`SV-002` 已完成；原定的 5 条完成标准（自动提取 canonical summary、输出结构化 compare、形成 4 档风险分级、在 `test-data/` 跑通批量报告、给出升级指向）当前均已满足。
