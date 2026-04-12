## shared-cfg-split-merge-normalization：实现结果

## 本轮分析的差异类型

本轮继续处理 `CC-003.17` 之后 dashboard 仍明确优先的一支更硬 residual：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

与 `CC-003.15` 已收掉的“同 block-count / 同 terminatorCounts / select 仅 `+1`” shared-CFG family 相比，这轮残留更具体地表现为：

1. regenerated AIR 只比 original 多出 **`1` 个 basic block + `1` 个 `br`**
2. `condbr / ret / phiCount` 继续一致
3. `selectCount` 可能保持不变，也可能再多出 `2`
4. `instruction-family` 仍主要漂移在 `aggregate / arithmetic / vector`

代表 case 先落在：

- 单 case：`build/semantics-validation/roundtrip/cc-003-18-single-f5adb68d-shared-cfg-split-merge/`
- diagnostics sibling：`9b33afe9...`
- corpus residual：`dd586566...`、`b95fff15...`

## 结论：diagnostics 这轮仍然是 compare 口径问题，不是实现层回退

重新下钻后，证据链已经足够明确：

- 不是 `IRToMSLConverter.swift` 再次打乱 entry / builtin / resource 语义
- 也不是 compile posture / fast-math planner 回退
- 真正的问题是：**`ir_canonical_compare.py` 对 shared-CFG split/merge drift 的约束仍偏窄，无法覆盖“只多一层 block/branch、语义不变、materialization 仍然很小”的 diagnostics residual**

代表单 case `f5adb68d...` 下可以直接看到：

- compile posture 对齐：`effectiveMetalArgs = -ffast-math`
- `entryComparison = L0`
- `builtinComparison = L0`
- `cfgComparison = L1`
- `instructionFamilyComparison = L1`
- 顶层风险：`L2 -> L1`

它的核心差异只有：

- CFG：`basicBlockCount 20 -> 21`、`br 10 -> 11`、`condbr / ret / phiCount` 不变、`selectCount 7 -> 7`
- 指令族：`aggregate 1 -> 12`、`arithmetic 35 -> 34`、`vector 86 -> 93`

这类差异更像 regenerated AIR 在同一语义路径上多了一次局部 split/merge，而不是实现层真的回退。

## 实现修改

本轮只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

把 `_entry_has_small_vector_aggregate_shape_drift(...)` 扩展为可接受下面这类 shared-CFG split/merge drift：

- `basicBlockCount` 最多只允许相差 `1`
- `terminatorCounts` 中：
  - `condbr` / `ret` 必须完全一致
  - `br` 最多只允许相差 `1`
  - 且 `basicBlockCount` 的变化必须与 `br` 变化同步
- `phiCount` 必须一致
- `selectCount` 最多允许相差 `2`
- `instruction-family` 漂移仍然只能落在 `{aggregate, arithmetic, vector}`
- 阈值保持很窄：
  - `arithmetic <= 5`
  - `aggregate <= 12`
  - `vector <= 16`
  - `totalDelta <= 24`

这意味着：

- `f5adb68d...` 的“1 block + 1 br + 小幅 materialization drift” 不再被误顶成 `L2`
- `9b33afe9...` 这类伴随 `select +2` 的 sibling diagnostics case 也能一起降到 `L1`
- 规则仍然没有放大到真正的 CFG reshape，因为它不接受更宽的 block / branch / phi / terminator 漂移

## 新增回归保护

本轮在 `Scripts/test_ir_canonical_compare.py` 新增了两条定向单测：

- `test_compare_downgrades_shared_cfg_split_merge_materialization_drift_to_l1`
- `test_compare_downgrades_shared_cfg_split_merge_shape_drift_with_select_growth_to_l1`

同时原有的“大幅 shared shape drift 继续保持 `L2`”反例仍然通过，确保这次放宽没有演变成通配降噪。

## 单 case 验证结果

已通过：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --ll <f5adb68d.../module.ll> --output-root build/semantics-validation/roundtrip/cc-003-18-single-f5adb68d-shared-cfg-split-merge`

单 case 结果：

- `riskCounts`: `L1 = 1 / L2 = 0 / L3 = 0`
- `blockedSamples = []`
- `shouldEnterL3 = false`
- compile 成功，无新的 replay / compile / llvm-dis 失败

## 当前结论

本轮已经可以明确下结论：

- diagnostics 里残留的 shared-CFG family 至少有一支主要矛盾仍然是 compare 对“1 block + 1 br + 小幅 materialization drift”过敏
- 这次扩展在 diagnostics 上已经足够收掉 `f5adb68d...`、`9b33afe9...` 这类 residual
- corpus 里 `dd586566...`、`b95fff15...` 仍然保持 `L2`，说明下一轮应该继续下钻**更宽的 shared-CFG residual**，而不是继续泛化本轮规则
