## L2：Canonical Compare + 风险分级

## 目标

在 L1 已产出的 `original.ll` / `regenerated.ll` 基础上，建立一套**结构化 compare + 风险分级**，回答：

- 哪些差异只是编译器 / metadata / 表面形态变化
- 哪些差异可能影响语义，应优先进入后续复核
- 哪些样本已经可以继续沉淀到日常 gate，哪些样本暂时不应进入 live

这层的目标仍然不是形式化证明，而是先得到一个**可批量运行、可解释、可回归**的语义风险筛查器。

若只是理解当前主线优先级，优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`；本文件更偏向 L2 口径、报告结构与 gate 语义的工作参考。

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
- **L2 是否已经变成稳定日常入口**：已经完成第一版收口；当前重点不再是“再造 compare”，而是继续维护 `gate-summary.json` / `--gate-profile` / `--enforce-gate` 对应的代表集边界，让 `PASS / WARN / FAIL` 的语义长期稳定

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
- 无需立即进入 L3

### L1：可接受差异

特征：

- 存在局部结构波动
- 主要是统计层或优化层差异
- 默认记录，但不阻塞

### L2：中风险 / 需复核

特征：

- builtin / resource / CFG / fast-math / instruction family 中有可疑变化
- 默认优先进入 L3 最小行为测试
- 不建议直接跳到 live

### L3：高风险 / 结构性不一致

特征：

- entry 集合变化
- 参数 / 返回关键摘要变化
- 参数 `addrspace` 关键项变化
- 或 round-trip 主链路本身失败

这类样本默认视为**不应直接进入 live**。

## 第一版主动降噪策略

为了让 L2 更像“风险筛查器”而不是“文本 diff 放大器”，当前已明确**弱化或忽略**以下差异：

- SSA 名称变化
- metadata 编号变化
- 注释 / 空行 / 格式变化
- 某些声明顺序变化
- `bufferSize` 缺失这类 metadata 省略
- `readonly / writeonly / readnone / dereferenceable / align / nocapture / noundef` 这类参数修饰噪声

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

输出目录：`build/semantics-validation/roundtrip/test-data-batch/`

当前结果：

- `27` 个样本中 `26` 个 round-trip 成功
- `1` 个样本在 compile 阶段失败：`test_struct_array_field`
- 风险分布：
  - `L0 = 1`
  - `L1 = 1`
  - `L2 = 5`
  - `L3 = 20`

### 当前代表样本

- 当前保留在主文档中的 active 信息只有两点：
  - **首个 compile blocker**：`test_struct_array_field`
  - **当前 `L2` 样本已经足够说明“需要后续 L3 入口”，但还不应直接全量升级到 live**
- 更细的首轮代表样本名单已下沉到 `07-首轮基线与历史进展归档.md`（历史参考，**不必须读取**）

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
- 是否出现了超出当前代表集 profile 的新增 blocker / 新增 `L3`
- 在 `--enforce-gate` 模式下是否应阻断退出

## 已验证测试

当前已覆盖：

- 真实样本提取测试：`test_vertex_draw_builtins.ll`
- 合成正向样本：只改 SSA 名称 → 维持低风险
- 合成反向样本：改 `addrspace` → 升为高风险
- `roundtrip runner` 集成测试：验证 L1/L2 报告会一起产出

## 当前边界

第一版仍然有明确边界：

- 不是形式化语义证明器
- 不是完整 IR AST / CFG 等价器
- 还不能回答“行为是否一致”
- 当前 `L3` 样本较多，说明还需要后续 `SV-003` 做代表集扩展、聚类与日常 gate 收敛
- 当前已经有第一版机器可执行的升级/止损边界：代表 preset 会通过 `gate-summary.json` / `--enforce-gate` 将“已知 debt”与“新增回归”区分开；但更广义的分层策略（`SV-006`）仍需继续整理与扩展

## 对下一步的直接启示

`SV-002` 完成后，当前最合理的下一步不是直接跳到 live，而是：

1. 继续推进 `SV-003`，优先维护 `test-data-representatives` 这个跨机器硬默认入口，再把 `ShaderCorpus` 作为本地增强证据接入
2. 推进 `SV-006`，把“停在 L2”与“必须进 L3/L4”的边界写清楚，但不抢在代表集稳定之前发散
3. 对当前 `L2` 样本先做聚类，再从稳定代表集里优先准备少量 `L3` 最小行为测试入口
4. 对 compile blocker `test_struct_array_field` 保持单独跟踪

## 完成标准回顾

原定完成标准为：

1. 对 round-trip 成功样本可自动提取 canonical summary
2. 能输出结构化 compare，而不是仅有文本 diff
3. 能把结果分成至少 4 档风险级别
4. 至少在 `test-data/` 上跑通并产出批量报告
5. 能明确给出哪些样本应进入 L3/L4

**当前以上 5 条均已满足，因此 `SV-002` 可视为完成。**
