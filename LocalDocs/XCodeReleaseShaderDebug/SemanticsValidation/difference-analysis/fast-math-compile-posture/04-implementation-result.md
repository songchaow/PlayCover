## fast-math-compile-posture：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.8` 里在 `CC-003.7` 之后暴露出来的一支高频 `L3`：

- `fast-math 相关属性变化`

沿着 `d48165ab...`、`fc1d64b2...`、`1e7adb48...` 这类样本继续下钻后，可以把这支 family 收敛成一条非常具体的 compile posture 缺口：

- original IR 明确带有 `air.compile.fast_math_disable`
- 但 round-trip compile 阶段一直使用裸 `xcrun metal -c`
- 结果 regenerated IR 稳定变成 `air.compile.fast_math_enable`
- canonical compare 因而把这批样本稳定顶成：
  - `fast-math 相关属性变化`
  - 常常再叠加 `模块元数据 targetTriple 变化`
  - 部分样本还会带上 `指令族统计变化`

这条差异并不是 compare 误报，也不是 converter emission 本身的缺口；关键问题在 **generated MSL 再编译回 AIR 时，没有把 original IR 的 fast-math compile posture 一并带回去**。

## 单 case 证据

代表样本：

- `d48165ab...`
- 修复前基线：`build/semantics-validation/roundtrip/cc-003-7-corpus-20260410-position-invariant`
- 修复后单 case：`build/semantics-validation/roundtrip/cc-003-8-single-d48165-fast-math-compile-posture`

`d48165ab...` 的轨迹现在可以写成：

- 修复前：`L3`
  - 关键原因：`fast-math 相关属性变化; 模块元数据 targetTriple 变化`
  - `fastMathComparison`：
    - original：`compileOptions = [air.compile.fast_math_disable]`
    - regenerated：`compileOptions = [air.compile.fast_math_enable]`
- 修复后：`L1`
  - `fastMathComparison` 仍存在，但已经降成低风险 residual：
    - original：`compileOptions = [air.compile.fast_math_disable]`
    - regenerated：`compileOptions = [air.compile.fast_math_disable]`
  - 剩余只剩：
    - `fast-math 相关属性变化`（仅 instruction flags 计数不同）
    - `模块元数据 targetTriple 变化`

单 case 的关键证据链现在很清楚：

1. 原始样本 `original.ll` 明确带有 `!"air.compile.fast_math_disable"`
2. 修复前 round-trip compile 命令没有任何 fast-math 参数
3. 修复后同一个 `generated.metal` 会自动使用：
   - `xcrun --sdk macosx metal -c -fno-fast-math ...`
4. Metal 回编后的 regenerated IR 已重新出现：
   - `!"air.compile.fast_math_disable"`
5. 风险从 `L3 -> L1`

这说明：

- 这批 `L3` 的真正杠杆是 compile posture
- 不是 compare 先升得太高
- 也不是必须再回到 converter 侧硬改表达

## 本轮实现内容

这轮严格按 dashboard 的“先看最小杠杆”规则，没有继续改 `IRToMSLConverter.swift`，而是只修 compile 阶段：

- `Scripts/corpus_replay_runner.py`
  - 新增 `infer_original_ir_fast_math_mode(...)`
  - 新增 `resolve_compile_metal_args(...)`
  - compile `generated.metal` 时，会先读取 original IR：
    - 若看到 `air.compile.fast_math_disable`，自动补 `-fno-fast-math`
    - 若看到 `air.compile.fast_math_enable`，自动补 `-ffast-math`
  - 若用户已经显式传了 `--metal-arg -ffast-math` / `-fno-fast-math`，则保持用户覆盖，不再自动追加
  - compile 结果里额外记录：
    - `originalFastMathMode`
    - `inferredMetalArgs`
    - `effectiveMetalArgs`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增回归：验证能从 original IR 推断 `disable -> -fno-fast-math`
  - 新增回归：验证 `compile_replay_result(...)` 会自动带上 `-fno-fast-math`
  - 新增回归：验证当用户已经显式传入 fast-math 参数时，自动推断不会覆盖用户参数

## 单 case 验证结果

本轮已完成三层验证：

1. 最小 compile posture 实验
   - 对同一个 `generated.metal` 分别执行：
     - 默认 `xcrun metal -c`
     - `xcrun metal -c -fno-fast-math`
     - `xcrun metal -c -ffast-math`
   - 结果明确：
     - 默认 / `-ffast-math`：生成 `air.compile.fast_math_enable`
     - `-fno-fast-math`：生成 `air.compile.fast_math_disable`
2. 单测回归
   - `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
   - 通过
3. 真实代表 case
   - `python3 Scripts/ir_semantics_roundtrip_runner.py --ll .../d48165ab.../original.ll --output-root build/semantics-validation/roundtrip/cc-003-8-single-d48165-fast-math-compile-posture`
   - 通过
   - `d48165ab...`：`L3 -> L1`
   - `fastMathComparison` 已从 compile option 漂移收敛成仅剩 instruction-level residual
   - compile 命令中已自动带出 `-fno-fast-math`

## 当前结论

本轮已经可以明确下结论：

- `CC-003.7` 暴露出来的这支高频 `fast-math` family，核心不是 compare 噪声
- 也不是 converter emission 需要继续放大
- 它首先是一条 **round-trip compile posture 与 original IR 不一致** 的问题
- 只要把 original IR 的 `air.compile.fast_math_disable/enable` 映射回 Metal 编译参数，这支 family 就能从 blocked 层大幅退下去
- 修完之后，残留的 fast-math 差异已经退回 compare 当前定义下的 `L1` instruction-flag residual，不再是 `L3` 杠杆

## 下一步建议

既然这支 compile posture family 已经被收掉，下一步更值得继续分析的是：

- `CC-003.9`：剩余 `7` 个 corpus `L3` 已全部收敛成
  - `entry 参数个数变化`
  - `entry 参数类型摘要变化`
  - `entry 参数语义摘要变化`
- 也就是当前 full-batch 里真正还留在 blocked 层、且已经不再被 fast-math 家族遮挡的 residual family
