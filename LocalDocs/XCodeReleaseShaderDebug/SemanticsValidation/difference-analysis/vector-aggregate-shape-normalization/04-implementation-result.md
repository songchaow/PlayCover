## vector-aggregate-shape-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.11` 在 `CC-003.10` 之后暴露出来的一支高频 diagnostics `L2` residual：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

代表 case 先落在：

- `build/semantics-validation/roundtrip/20260411-134613-09e0290f/com.tencent.tmgp.speedmobile/modules/083c8443bea6e69ebc22eafda7b137ef3bb9149c333149d923be4a77d3e2135f/`
- sibling：`.../1079c7c8462271ae0de025abad26501836fbe9d9001eba4eda5f005bf5c69009/`

这轮重新下钻后，可以把 root cause 收敛成一条更具体的 compare 口径问题：

- 不是 `IRToMSLConverter.swift` 还在把这类 fragment 分支重新线性化
- 也不是 round-trip compile posture 又回退到错误 fast-math 姿势
- 真正的问题是：**当 generated MSL 已经保留真实 `if/else + phi` 结构时，canonical compare 仍把一类很小的 `select + aggregate/vector` 形态漂移继续记成 `instruction-family = L2`**

这类样本的共同形态是：

1. entry / resource / builtin / output 语义完全一致
2. 模块级和函数内 `air intrinsic` 统计一致，没有出现 family 漂移
3. CFG 主骨架一致：
   - `basicBlockCount` 不变
   - `terminatorCounts` 不变
   - `phiCount` 不变
   - 只多出 `selectCount +1` 这类轻微 SSA/aggregate 重排
4. `instruction-family` 只在：
   - `aggregate`
   - `vector`
   - 少量 `arithmetic`
   上出现有限变化

## 单 case 证据

### `083c8443...`

直接对当前 diagnostics artifact 下钻后，可以看到三条关键证据：

1. `generated.metal` 已经是正确的结构化分支，而不是旧的“空壳 `if/else` + 顺排互斥块”
   - 末尾明确存在真实 `if (t218) { ... } else { ... }`
   - `phi_0` 分别在 true / false 分支里赋值后返回
2. original / regenerated IR 的 CFG 粗摘要也基本一致：
   - `basicBlockCount: 4 -> 4`
   - `terminatorCounts: br 2 / condbr 1 / ret 1` 保持不变
   - `phiCount: 1 -> 1`
   - 只剩 `selectCount: 7 -> 8`
3. compare 当前顶成 `L2` 的原因只剩：
   - `aggregate: 1 -> 6`
   - `vector: 72 -> 84`
   - `arithmetic: 38 -> 36`
   - 但 `call / intrinsic / memory / compare / cast` 全部一致

这说明：

- 当前 residual 已经不像“代码发错了”
- 更像是 AIR 在 aggregate / vector materialization 上做了稳定但低风险的重排

### sibling `1079c7c8...`

`1079c7c8...` 呈现出完全同一类证据：

- `generated.metal` 同样保留真实 `if/else + phi_0`
- `CFG` 同样只表现为 `selectCount: 7 -> 8`
- `instruction-family` 同样只在 `aggregate / vector / arithmetic` 上出现有限漂移
- `call / intrinsic / memory / compare / cast` 保持一致

因此这轮命中的不是单一样本偶然现象，而是一支可重复的 compare residual family。

## 本轮实现内容

这轮遵守 dashboard 的“实现优先，但 compare-only 时必须严格定向”原则，没有继续扩大 converter 改动，而是把最小修正落在：

- `Scripts/ir_canonical_compare.py`

具体新增一条更窄的降噪规则：

- 当 entry 语义、resource / builtin / output 语义和 intrinsic 统计都保持一致时
- 若 CFG 只剩：
  - `basicBlockCount` 不变
  - `terminatorCounts` 不变
  - `phiCount` 不变
  - `selectCount` 只变化 `±1`
- 且 `instruction-family` 只在：
  - `aggregate`
  - `vector`
  - 少量 `arithmetic`
  发生有限变化

则把这类 residual 从 `instruction-family = L2` 下调为 `L1`。

这条规则有意保持得很窄：

- 不会触碰 entry/resource 语义变化
- 不会覆盖 intrinsic family 漂移
- 不会覆盖 CFG 主骨架变化
- 不会覆盖大幅 instruction-family 漂移

## 新增回归

本轮在 `Scripts/test_ir_canonical_compare.py` 新增了两条 compare 单测：

1. **正例**：小幅 `select + aggregate/vector` reshaping 应降到 `L1`
2. **反例**：若 `aggregate/vector/arithmetic` 变化过大，即使 CFG 骨架保持一致，也必须继续保留 `L2`

## 单 case 验证结果

### 1. compare 单测

已通过：

- `python3 -m unittest Scripts/test_ir_canonical_compare.py`

### 2. round-trip runner 回归

已通过：

- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

### 3. 真实代表 case

已对 `083c8443...` 重新执行单 case round-trip：

- 输出：`build/semantics-validation/roundtrip/cc-003-11-single-083c-vector-aggregate-shape/`
- 结果：`L2 -> L1`
- `blockedSamples = []`
- compile posture 继续保持：
  - `originalFastMathMode = enable`
  - `effectiveMetalArgs = [-ffast-math]`

修复后单 case 的顶层差异仍然是：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

但它们现在已经全部收敛到 `L1`，不再把样本留在当前 `L2` ceiling。

## 当前结论

本轮已经可以明确下结论：

- `CC-003.10` 之后这支高频 diagnostics family 的主要矛盾，不再是 converter 结构缺口
- 对 `083c8443...`、`1079c7c8...` 这类样本来说，generated MSL 已经保留了正确分支结构
- 当前 residual 更像 **aggregate/vector 形态重排带来的 compare 过敏**，而不是新的实现问题
- 这类 residual 适合在 `ir_canonical_compare.py` 做定向降噪，不值得再扩大 converter 侧修复

## 下一步建议

既然 diagnostics 里这支高频 `CFG + instruction-family + fast-math` family 已大幅回落，下一步更值得继续分析的是：

- corpus 中仍大量停留在 `L2` 的 `指令族统计变化; fast-math 相关属性变化; 模块元数据 targetTriple 变化`
- 以及 diagnostics 中剩余少量 `模块级 air intrinsic 使用变化; 函数内 air intrinsic 调用统计变化; 控制流粗摘要变化` residual
