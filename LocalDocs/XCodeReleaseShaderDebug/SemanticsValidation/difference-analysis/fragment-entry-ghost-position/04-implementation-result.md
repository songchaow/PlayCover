## fragment-entry-ghost-position：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.9` 里最后一支 corpus `L3`：

- `entry 参数个数变化`
- `entry 参数类型摘要变化`
- `entry 参数语义摘要变化`

沿着 `4b130757...`、`38dac53b...`、`26468546...`、`8d88ecc7...`、`34a57bbd...`、`787d645f...` 这组样本下钻后，可以把问题收敛成一条很具体的 converter 缺口：

- original IR 的 fragment entry 本身没有输入参数
- metadata 里也没有 `air.position` / `air.fragment_input` 这类 entry 输入
- regenerated IR 却稳定多出一个 `<4 x float>` 参数
- 追到生成侧后发现，问题不是 compare 口径，而是 **`IRToMSLConverter.swift` 把 fragment `[[position]]` 当成了无条件默认 builtin**

这会让零输入 fragment 在生成的 MSL 中被错误写成：

- `fragment ... xlatMtlMain(float4 position [[position]])`

Metal 再编译回 AIR 后，canonical compare 就会稳定看到：

- `entry 参数个数变化`
- `entry 参数类型摘要变化`
- `entry 参数语义摘要变化`

## 单 case 证据

代表 case：

- 修复前基线：`build/semantics-validation/roundtrip/cc-003-8-corpus-20260410-fast-math-compile-posture/com.miHoYo.Yuanshen/modules/4b1307572452282105ba597fffadd9cd2dac4911274dd5c987642474a46f6f96/`
- 修复后单 case：`build/semantics-validation/roundtrip/cc-003-9-single-4b130757-fragment-entry-ghost-position/`

`4b130757...` 的轨迹现在可以写成：

- 修复前：`L3`
  - 关键原因：`entry 参数个数变化; entry 参数类型摘要变化; entry 参数语义摘要变化`
  - 生成的 MSL 会凭空带上 `float4 position [[position]]`
- 修复后：`L1`
  - `entryComparison` 已回到 **`L0`**
  - `blockedSamples = []`
  - 剩余只剩：
    - `模块元数据 targetTriple 变化`

修复后同轮结构化报告已经明确显示：

- `compare-summary.json`：`entryComparison.same = true`
- `risk-report.json`：`L3 = 0`
- `gate-summary.json`：`PASS`

为了把这条修复收紧成一个最小、稳定的离线回归，本轮还新增了：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fragment_no_entry_input.ll`

这个样本固定复现“零输入 fragment 不应被补 ghost `[[position]]`”的形态。

## 本轮实现内容

本轮继续遵守 dashboard 的 converter-first 规则，只改生成侧：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 去掉 fragment entry 的无条件默认 builtin
  - `[[position]]` 只在两种情况下发射：
    - AIR metadata 明确给出 `air.position`
    - 原始 IR 参数列表本身确实存在对应 builtin 参数，且补参推断命中
  - 因而零输入 fragment 不再被凭空补出一个 ghost entry 参数
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增 replay 回归：验证零输入 fragment 生成的 MSL 不含 `[[position]]`
  - 新增 round-trip 回归：验证 canonical compare 不再出现 `entry 参数个数/类型/语义` 三连漂移
- `LocalDocs/.../test-data/test_fragment_no_entry_input.ll`
  - 新增最小 IR 样本，稳定复现本轮 family

## 单 case 验证结果

本轮已完成四层验证：

1. `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_does_not_invent_fragment_position_input`
   - 通过
2. `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_roundtrip_runner_preserves_zero_input_fragment_signature`
   - 通过
3. 现有相邻 fragment 回归：
   - `test_corpus_replay_runner_preserves_single_field_fragment_output_wrapper`
   - `test_roundtrip_runner_preserves_single_field_fragment_output_wrapper`
   - 均通过
4. `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../4b130757.../module.ll --output-root build/semantics-validation/roundtrip/cc-003-9-single-4b130757-fragment-entry-ghost-position`
   - 通过
   - `4b130757...` 从 `L3 -> L1`
   - `entryComparison`：`L3 -> L0`
   - `blockedSamples = []`
   - gate `PASS`

## 当前结论

本轮已经可以明确下结论：

- 这支 `entry 参数` family 不需要先动 compare
- 它是一支真实的 converter 入口参数建模缺口：**fragment `[[position]]` 被误当成无条件默认 builtin**
- 只要去掉这条 ghost 默认注入，让 `[[position]]` 回到“有显式证据才发射”的路径，零输入 fragment 的 `entry 参数个数/类型/语义` 漂移就会一起消失
- 这是一处很小的修改，但正好命中了 `CC-003.8` 之后剩余的全部 corpus blocked family

## 下一步建议

既然 `CC-003.9` 已经把最后一支 corpus `L3` 收掉，下一步更值得继续分析的是：

- `模块级 addrspace 分布变化 + 模块级 air intrinsic 使用变化`
- `控制流粗摘要变化 + 指令族统计变化`

也就是当前 full-batch 中已经暴露出来、但仍停留在 `L2` 的 residual family。
