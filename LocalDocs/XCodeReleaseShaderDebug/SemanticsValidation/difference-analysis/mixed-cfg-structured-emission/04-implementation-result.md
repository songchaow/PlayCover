## mixed-cfg-structured-emission：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.9` 之后当前最高频的一支 corpus `L2` residual：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- 常伴随 `控制流粗摘要变化` / `指令族统计变化`

代表 case 先落在：

- `build/semantics-validation/roundtrip/cc-003-9-corpus-20260411-fragment-entry-ghost-position/com.miHoYo.Yuanshen/modules/ab9230e922b6572b97809292189fd16029456a811802958f3944441311696657/`
- sibling：`.../0d2cd9c9abb7540aaf876d0da4a0f8ecd8b2fe50c1380fcb63e61ea59904ff5c/`

这轮重新下钻后可以把 root cause 收敛得比 `CC-003.4` 更具体：

- 不是 `ir_canonical_compare.py` 又多报了一层噪声
- 也不是 `air.address_space` metadata 单独显式化
- 真正的问题是 **`IRToMSLConverter.swift` 对 mixed CFG 的进入条件过宽保守**：只要整函数里存在一个“不是简单 diamond”的条件分支，就整函数退回线性 BB 发射
- 退回线性模式后，局部本来可以结构化恢复的 nested merge / common merge 也会一起失去结构，只剩空的 `if/else` 壳子，随后把互斥 BB 按源码顺序顺排出来

这会直接带来两层后果：

1. `generated.metal` 里出现“空 `if/else` + 顺序发射互斥块 + phi 被后一路覆盖”的形态
2. Metal 再编译后，canonical compare 会稳定看到：
   - CFG 粗摘要漂移
   - 指令族统计漂移
   - 一部分由控制流重排带出的 `air intrinsic` / `addrspace` 分布漂移

## 单 case 证据

`ab9230...` 修复前的 `generated.metal` 可以直接看到：

- `if (t186) { // → BB228 } else { // → BB220 }`
- 但 `BB220` / `BB228` 仍被顺序发射
- `phi_0` 先被 `BB220` 赋值，又立刻被 `BB228` 覆盖

也就是说，问题不是 compare 在“数错 CFG”，而是 converter 确实没有把 `BB194` 里的 nested common merge 结构恢复出来。

## 本轮实现内容

本轮继续遵守 dashboard 的 implementation-first 原则，只改 converter 与最小回归：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 去掉“整函数所有条件分支都必须是简单 diamond 才允许进入 structured emission”的全局门槛
  - 改成只要 CFG successor 都能落到已知 BB，就进入现有的 structured emitter
  - 具体的“能不能结构化恢复某个分支”，继续交给已有的局部 `emitStructuredConditionalBranch` / fallback scheduler 判定
  - 因而 mixed CFG 里的可恢复 nested merge 不再被无关的其它 partial / loop CFG 拖回整函数线性化
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增 mixed CFG 回归：验证“后面存在 unstructured tail”时，前面的 nested common merge 仍然会被结构化发射
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_nested_common_merge_with_unstructured_tail.ll`
  - 新增最小 IR fixture，固定复现“局部 nested merge 本可恢复，但整函数含 partial CFG 时旧门槛会误降级”的形态

## 单 case 验证结果

### 1. 定向 replay 回归

已通过：

- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_preserves_phi_branch_structure`
- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_keeps_simple_diamond_when_later_cfg_is_not_structured`
- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_keeps_nested_common_merge_inside_branch_scope`
- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_keeps_nested_common_merge_when_later_cfg_is_unstructured`

新增 mixed-CFG fixture 已明确验证：

- 前段 nested common merge 仍会发成真实 `if/else`
- `phi_0 = 1 / 2`、`phi_1 = phi_0 / 4` 都保留在正确分支位置
- 不再出现 `// → BB20` / `// → BB30` 这种“结构化本可恢复却只剩注释”的退化结果

### 2. 真实样本单 case

#### `ab9230...`

- 输入：`build/semantics-validation/roundtrip/cc-003-9-corpus-20260411-fragment-entry-ghost-position/.../ab9230.../original.ll`
- 输出：`build/semantics-validation/roundtrip/cc-003-10-single-ab9230-structured-cfg/`
- 结果：`L2 -> L1`
- `blockedSamples = []`
- 原来的 `模块级 addrspace 分布变化` 与 `控制流粗摘要变化` 已消失
- 剩余只剩：
  - `模块级 air intrinsic 使用变化`
  - `函数内 air intrinsic 调用统计变化`
  - `指令族统计变化`
  - `fast-math / targetTriple` 低风险残留

#### sibling `0d2cd9...`

- 输出：`build/semantics-validation/roundtrip/cc-003-10-single-0d2cd9-structured-cfg/`
- 结果同样是：`L2 -> L1`
- 说明这次命中的不是单一样本偶然改善，而是当前这支 family 的可复用 root cause

## 当前结论

本轮已经可以明确下结论：

- 这支 residual family 的主要矛盾不是 compare 口径，而是 converter 的 **structured CFG 入口条件过窄**
- mixed CFG 函数里，本来可恢复的局部 nested merge 不应因为函数后面还有 partial / loop CFG 就被整函数退回线性 BB 发射
- 把 structured emission 从“全函数必须规整”放宽为“局部可恢复就结构化、其余继续 fallback”，能稳定收掉当前这支 `addrspace + air intrinsic + CFG/instruction-family` residual family 的大头

## 下一步建议

既然这轮已经把当前 highest-frequency 的 mixed-CFG family 明显压下去，下一步更值得继续分析的是：

- 剩余的 `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化`
- 以及 corpus 里已经不再带 `addrspace`，但仍停留在 `instruction-family + targetTriple` 的 residual family
