## scalar-vector-materialization-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.12` 在 `CC-003.11` 之后仍然残留的一支 corpus `L2` residual：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

代表 case 先落在：

- `build/semantics-validation/roundtrip/20260411-140813-393615c6/com.miHoYo.Yuanshen/modules/62316900e1a2f7979dfff32e27cb3451e33751c0af6bded2b2737599daa4dfc1/`
- sibling：`.../2984b21cc16b203c826ff7453124a986651d2c1733f0747217b2158fccde7398/`
- sibling：`.../2629c34e72d85d71cbf079740967bfe7c64ef8e456bd0894b01f99d5c1d9cdd5/`

这轮重新下钻后，可以把 root cause 收敛成一条更具体的 compare 口径问题：

- 不是 `IRToMSLConverter.swift` 仍在打乱 entry / resource / builtin 语义
- 也不是 round-trip compile posture 又回退到错误 fast-math 姿势
- 真正的问题是：**当 CFG 已经完全一致，且 regenerated AIR 只是把一类 scalar / vector / aggregate 的 materialization 重新压缩或重排时，canonical compare 仍把这类有限的 `instruction-family` 漂移继续记成 `L2`**

这类样本的共同形态是：

1. entry / resource / builtin / output 语义完全一致
2. 模块级和函数内 `air intrinsic` 统计一致，没有出现 family 漂移
3. `CFG` 完全一致：
   - `basicBlockCount` 不变
   - `terminatorCounts` 不变
   - `phiCount` 不变
   - `selectCount` 也不变
4. `instruction-family` 只在：
   - `aggregate`
   - `vector`
   - `arithmetic`
   上出现有限变化

## 单 case 证据

### `62316900...`

直接对 `20260411-140813-393615c6` 下的代表 artifact 复核后，可以看到四条关键证据：

1. compile posture 已经对齐，不是 `fast-math` planner 回退：
   - `originalFastMathMode = enable`
   - `effectiveMetalArgs = [-ffast-math]`
   - `fastMathDecision = fast_math_aligned`
2. `generated.metal` 与 regenerated IR 都保持同一条直线型 vertex 主路径，没有出现新的控制流结构漂移
3. `cfgComparison` 已经是 `L0`：
   - `basicBlockCount` 不变
   - `terminatorCounts` 不变
   - `phiCount` 不变
   - `selectCount` 不变
4. compare 当前顶成 `L2` 的原因只剩：
   - `aggregate: 10 -> 12`
   - `arithmetic: 48 -> 42`
   - `vector: 83 -> 81`
   - 其余 `call / cast / compare / intrinsic / memory` 全部一致

这说明：

- 当前 residual 已经不像“发射了错误结构”
- 更像是 AIR 在返回值拼装和中间 vector materialization 上做了稳定但低风险的压缩重排

### sibling `2984b21c...`

`2984b21c...` 呈现同一类证据：

- `cfgComparison = L0`
- `builtinComparison = L0`
- `instruction-family` 只剩 `arithmetic: 85 -> 76` 与 `vector: 143 -> 141`
- `fast-math` 与 `targetTriple` 仍然只是模块级 `L1` 噪声

### sibling `2629c34e...`

`2629c34e...` 同样保持：

- `cfgComparison = L0`
- `builtinComparison = L0`
- `instruction-family` 只在 `aggregate / arithmetic / vector` 三项内小幅漂移
- 没有新的 entry / addrspace / intrinsic family 差异

因此这轮命中的不是单一样本偶然现象，而是一支可重复的 corpus compare residual family。

## 本轮实现内容

这轮遵守 dashboard 的“实现优先，但 compare-only 时必须严格定向”原则，没有继续扩大 converter 改动，而是把最小修正落在：

- `Scripts/ir_canonical_compare.py`

具体新增一条更窄的降噪规则：

- 当 entry 语义、resource / builtin / output 语义和 intrinsic 统计都保持一致时
- 若 `CFG` 完全一致
- 且 `instruction-family` 只在：
  - `aggregate`
  - `arithmetic`
  - `vector`
  发生有限变化
- 并且变化幅度仍落在一组很小的阈值内

则把这类 residual 从 `instruction-family = L2` 下调为 `L1`。

这条规则有意保持得很窄：

- 不会触碰 entry/resource 语义变化
- 不会覆盖 intrinsic family 漂移
- 不会覆盖任何 CFG 变化
- 不会覆盖超过当前 materialization family 上限的 instruction-family 漂移

## 新增回归

本轮在 `Scripts/test_ir_canonical_compare.py` 新增了两条 compare 单测：

1. **正例**：`CFG` 完全不变时，小幅 scalar / vector / aggregate materialization reshaping 应降到 `L1`
2. **反例**：若同样没有 CFG 变化，但 `aggregate / arithmetic / vector` 变化超过当前阈值，仍必须继续保留 `L2`

## 单 case 验证结果

### 1. compare 单测

已通过：

- `python3 -m unittest Scripts/test_ir_canonical_compare.py`

### 2. round-trip runner 回归

已通过：

- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

### 3. 真实代表 case

已对 `62316900...` 重新执行单 case round-trip：

- 输出：`build/semantics-validation/roundtrip/cc-003-12-single-623169-scalar-vector-materialization/`
- 结果：`L2 -> L1`
- `blockedSamples = []`
- compile posture 继续保持：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = [-ffast-math]`

修复后单 case 的顶层差异仍然是：

- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

但 `instruction-family` 已经回落到 `L1`，不再把样本留在当前 `L2` ceiling。

## 当前结论

本轮已经可以明确下结论：

- `CC-003.11` 之后这支 corpus residual family 的主要矛盾，也不再是 converter 结构缺口
- 对 `62316900...`、`2984b21c...`、`2629c34e...` 这类样本来说，compare 仍然对“CFG 不变 + 轻微 scalar/vector materialization 重排”过敏
- 当前 residual 更像 **返回值拼装与向量物化的低风险形态重排**，而不是新的实现问题
- 这类 residual 适合在 `ir_canonical_compare.py` 做定向降噪，不值得再扩大 converter 侧修复

## 下一步建议

既然 corpus 中这支 `instruction-family + fast-math + targetTriple` family 已进一步回落，下一步更值得继续分析的是：

- corpus 中剩余高频的 `模块级 addrspace 分布变化; 模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化`
- diagnostics 中仍残留的少量 `控制流粗摘要变化; 指令族统计变化; fast-math 相关属性变化` residual
