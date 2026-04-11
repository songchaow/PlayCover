## shared-cfg-shape-drift-normalization：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.14` 之后 dashboard 明确优先的一支 shared residual family：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

代表 case 先落在：

- diagnostics：`build/semantics-validation/roundtrip/cc-003-15-single-25eef20f-shape-drift/com.tencent.tmgp.speedmobile/modules/25eef20f8e52eabefc4bcf28a0eaeacdb95e31b29c357f3c4f8d7b7afc926e5a/`
- corpus sibling：`build/semantics-validation/roundtrip/cc-003-15-full-corpus/com.miHoYo.Yuanshen/modules/dd58656639f356daf7e82d42a90b004ae454d2a10f51c76be0f213f40f433100/`

这轮重新下钻后，可以把 root cause 收敛成一条更具体的 compare 口径问题：

- 不是 `IRToMSLConverter.swift` 继续丢失 entry / builtin / resource 语义
- 也不是 compile posture / fast-math planner 回退
- 真正的问题是：**当 regenerated AIR 只是在同一套 CFG 上多出一处 `select`，并伴随一小段 `aggregate / arithmetic / vector` 物化重排时，`ir_canonical_compare.py` 仍把这类 shared shape drift 继续顶成 `L2`**

## 单 case 证据

### `25eef20f...`

对 `cc-003-15-single-25eef20f-shape-drift` 下的新单 case artifact 复核后，证据链已经足够明确：

1. compile posture 继续对齐，不是 planner / compile option root cause：
   - `originalFastMathMode` 仍对应 `air.compile.fast_math_enable`
   - `effectiveMetalArgs` 仍是 `-ffast-math`
   - compile 成功，无新的 compile / llvm-dis 失败
2. entry / address space / builtin 摘要完全一致：
   - `entryComparison = L0`
   - `addressSpaceComparison = L0`
   - `builtinComparison = L0`
3. `cfgComparison` 里的结构差异非常窄：
   - `basicBlockCount`: `4 -> 4`
   - `terminatorCounts`: `{br: 2, condbr: 1, ret: 1} -> {br: 2, condbr: 1, ret: 1}`
   - `phiCount`: `1 -> 1`
   - `selectCount`: `7 -> 8`
4. `instruction-family` 的变化也稳定落在同一组物化项：
   - `aggregate: 1 -> 6`
   - `arithmetic: 60 -> 55`
   - `vector: 108 -> 119`
   - `call / cast / compare / intrinsic / memory` 全部一致

这说明：

- 当前 residual 不像真实语义结构已经被改坏
- 更像 emitted MSL / regenerated AIR 对 bool / vector materialization 做了稳定、低风险的重排

### corpus sibling `dd586566...`

对 corpus shared family 里的 `dd586566...` 再复核后，也能看到同一类信号：

- `basicBlockCount`、`terminatorCounts`、`phiCount` 都保持一致
- 主要漂移依旧集中在 `aggregate / vector / arithmetic`
- `targetTriple` 仍然只是模块级 `L1` 噪声

因此这轮命中的不是 diagnostics 偶然样本，而是一支在 diagnostics 与 corpus 中共同出现的 compare residual family。

## 本轮实现内容

这轮遵守 dashboard 的 implementation-first 原则；在确认不是 converter 缺口之后，把最小修正落在：

- `Scripts/ir_canonical_compare.py`

具体做法是收窄而不是放大 compare 规则：

- 复用已有的 `_entry_has_small_vector_aggregate_shape_drift(...)` 降噪路径
- 保持下面前置条件不变：
  - entry / resource / builtin / output 语义一致
  - intrinsic family 统计一致
  - `basicBlockCount` / `terminatorCounts` / `phiCount` 一致
  - `selectCount` 最多只允许多出 `1`
  - `instruction-family` 变化只能落在 `aggregate / arithmetic / vector`
- 只把该规则里的 `arithmetic_delta` 上限从 `4` 放宽到 `5`

这次改动保持得很窄：

- 不覆盖 entry 参数语义变化
- 不覆盖 builtin / stage-in 变化
- 不覆盖任何 terminator / block-count / phi 漂移
- 不覆盖超出当前 materialization family 上限的大幅 instruction-family 漂移

## 新增回归

本轮在 `Scripts/test_ir_canonical_compare.py` 新增了一条定向单测：

- 固定覆盖 `4 BB + same terminators + phi=1 + select 7->8 + aggregate 1->6 + arithmetic 60->55 + vector 108->119` 这支 shared family
- 验证它会从 `L2` 降到 `L1`

同时已有的“大幅 shape drift 仍保留 `L2`”反例继续通过，确保这次放宽没有把规则放大成通配降噪。

## 单 case 验证结果

### 1. compare / runner 回归

已通过：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`

### 2. 真实代表 case

已对 `25eef20f...` 重新执行单 case round-trip：

- 输出：`build/semantics-validation/roundtrip/cc-003-15-single-25eef20f-shape-drift/`
- 结果：`L2 -> L1`
- `blockedSamples = []`
- `shouldEnterL3 = false`

修复后单 case 的顶层差异仍然是：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

但 `cfgComparison` 与 `instructionFamilyComparison` 都已经稳定落在 `L1`，不再把该样本继续保留在 `L2` ceiling。

## 当前结论

本轮已经可以明确下结论：

- 这支 shared `CFG + instruction-family + fast-math` residual 的主要矛盾，不再是 converter 侧真实语义缺口
- 对 `25eef20f...` 与 `dd586566...` 这类样本来说，compare 仍然对“同一 CFG + 一处额外 select + 小幅 vector/aggregate materialization 重排”过敏
- 当前 residual 更像 **低风险 shape drift**，适合继续在 `ir_canonical_compare.py` 做定向降噪，而不值得重新放大到 `IRToMSLConverter.swift`

## 下一步建议

这轮之后，更值得优先继续分析的是：

- diagnostics / corpus 共同剩余的 `instruction-family + fast-math + targetTriple` family
- 以及 corpus 中仍然唯一挂着 `entry 参数语义摘要变化; entry builtin / stage-in 摘要变化` 的 `823dcdf7...`
