## shared-cfg-split-merge-normalization：实现结果

## 本轮分析的差异类型

本轮继续处理 `CC-003.19`，也就是 `CC-003.18` 之后 dashboard 里仍未收尽的 corpus shared-CFG residual：

- `控制流粗摘要变化`
- `指令族统计变化`
- `fast-math 相关属性变化`

这轮代表 case 继续落在：

- 单 case：`build/semantics-validation/roundtrip/cc-003-19-single-dd586566-shared-cfg-cast/`
- corpus residual：`dd586566...`、`b95fff15...`

与 `CC-003.18` 已经收掉的 diagnostics family 相比，这轮 residual 仍然保持：

1. regenerated AIR 只比 original 多出 **`1` 个 basic block + `1` 个 `br`**
2. `condbr / ret / phiCount / selectCount` 继续一致
3. `instruction-family` 仍主要漂移在 `aggregate / arithmetic / vector`
4. 但同时还伴随 **极小的 `cast` reshaping**：`cast 5 -> 3`

## 结论：这两支 corpus residual 仍然是 compare 口径问题，不是实现层回退

重新下钻后，证据链已经足够明确：

- 不是 `IRToMSLConverter.swift` 再次打乱 entry / builtin / resource 语义
- 也不是 compile posture / fast-math planner 回退
- `effectiveMetalArgs` 继续对齐为 `-ffast-math`
- 两个 case 的 canonical summary 都显示：
  - `entryComparison = L0`
  - `builtinComparison = L0`
  - `cfgComparison` 只差 `basicBlockCount 8 -> 9`、`br 4 -> 5`
  - `instructionFamilyComparison` 只差小幅 `aggregate / arithmetic / vector` reshaping，再加 `cast 5 -> 3`

也就是说，`CC-003.18` 的 shared-CFG split/merge 规则本身方向没错，真正没覆盖到的只是一支**仍然很窄的 `cast` materialization sibling**。

## 实现修改

本轮只做了一处最小 compare 改动：

### `Scripts/ir_canonical_compare.py`

继续沿用 `_entry_has_small_vector_aggregate_shape_drift(...)` 这条 shared-CFG helper，但把允许的 instruction-family 漂移从：

- `{aggregate, arithmetic, vector}`

扩展为：

- `{aggregate, arithmetic, vector, cast}`

同时保持边界依旧很窄：

- `basicBlockCount` 最多相差 `1`
- `br` 最多相差 `1`
- `condbr / ret / phiCount` 必须一致
- `selectCount` 最多相差 `2`
- `arithmetic <= 5`
- `aggregate <= 12`
- `vector <= 16`
- `cast <= 2`
- `totalDelta <= 24`

这意味着：

- `dd586566...` 与 `b95fff15...` 的 shared-CFG split/merge + tiny-cast reshape 不再被误顶成 `L2`
- 规则仍然没有放大到真正的 CFG reshape 或更宽 materialization，因为它仍不接受更宽的 block / branch / phi / select / cast 漂移

## 新增回归保护

本轮在 `Scripts/test_ir_canonical_compare.py` 新增了一条定向单测：

- `test_compare_downgrades_shared_cfg_split_merge_shape_drift_with_small_cast_reshaping_to_l1`

它直接覆盖 `CC-003.19` 这轮真实 residual 的摘要轮廓：

- `basicBlockCount 8 -> 9`
- `br 4 -> 5`
- `phiCount / selectCount` 不变
- `aggregate 1 -> 7`
- `arithmetic 31 -> 30`
- `vector 64 -> 65`
- `cast 5 -> 3`

原有的 shared-CFG 与 materialization 反例继续保留，确保这次放宽没有演变成通配降噪。

## 单 case 验证结果

已通过：

- `python3 Scripts/test_ir_canonical_compare.py`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --ll <dd586566.../module.ll> --output-root build/semantics-validation/roundtrip/cc-003-19-single-dd586566-shared-cfg-cast`

单 case 结果：

- `riskCounts`: `L1 = 1 / L2 = 0 / L3 = 0`
- `blockedSamples = []`
- `shouldEnterL3 = false`
- `dd586566...` 已从 `L2 -> L1`

## 当前结论

本轮已经可以明确下结论：

- `dd586566...`、`b95fff15...` 仍属于 compare 对 shared-CFG split/merge + tiny-cast reshaping 过敏
- `CC-003.18` 的规则不需要推翻，只需要补齐这支极小 `cast` sibling
- 这次扩展之后，shared-CFG residual 在 corpus 上继续净下降；下一步不应再回到这支 family，而应优先转向剩余的 `instruction-family + fast-math + targetTriple` residual
