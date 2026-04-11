## sampler-state-global-preservation：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.13` 在 `CC-003.12` 之后当前最值得下钻的一支 corpus `L2` residual：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- 常伴随 `控制流粗摘要变化` / `指令族统计变化`

代表 case 先落在：

- `build/semantics-validation/roundtrip/20260411-152454-3ecc3495/com.miHoYo.Yuanshen/modules/293ec561067f16e66e9282142cf70e4a9f5136f6e448e66338c56ca210319853/`
- sibling：`.../3f5bb2d411555e718aa40db5ec2a406acdf013351d45035922a4ab82c9696f28/`
- sibling：`.../06c5f51fc0009d377fcf5b0b52136ee7a72e3e70e6496d0efe9589ef40eb1843/`

这轮重新下钻后，可以把 root cause 收敛成一条更具体的 converter 缺口：

- 不是 `compile-summary.json` 对应的 fast-math / planner 姿势回退
- 也不是 `ir_canonical_compare.py` 单纯把 compare 噪声放大
- 真正的问题是：**`IRToMSLConverter.swift` 在解析 `@__air_sampler_state*` 这类 internal sampler-state global 时，把它错误回退成 entry sampler 参数，导致 emitted MSL 虽然已经发出了 `constexpr sampler __air_sampler_state(...)`，但真正的 `sample_compare` 调用并没有使用它**

这会直接带来三层后果：

1. `generated.metal` 里出现“全局 sampler-state 已发射，但 `sample_compare` 仍绑定到 `sampler_CameraDepthTexture` / 其它 entry sampler”的错配
2. Metal 再编译后，regenerated AIR 把原来指向 `@__air_sampler_state` 的第二个操作数改写成 sampler 参数 `%2`
3. canonical compare 稳定看到：
   - 模块级 `addrspace` 计数变化
   - 模块级 `air intrinsic` 使用分布变化
   - 函数内 `air intrinsic` 调用统计变化

## 单 case 证据

### `293ec561...`

这一轮对 `293ec561...` 复核后，证据链已经足够明确：

1. compile posture 已经对齐，不是 planner / fast-math root cause：
   - 当前批次 `compile-summary.json` 对应 case 使用 `-ffast-math`
   - Oracle 复核结论明确是 `fast_math_aligned`
2. original IR 明确使用了 internal sampler-state global，而不是 entry sampler：
   - `original.ll` 中 `@__air_sampler_state` 定义为 `internal addrspace(2) constant`
   - `air.sample_compare_depth_2d.f32` 调用第二个操作数指向 `@__air_sampler_state`
3. 旧版 generated MSL 已发出 `constexpr sampler __air_sampler_state(...)`，但真正调用仍错误使用 entry sampler：
   - 旧 `generated.metal`：`_ShadowMapTexture.sample_compare(sampler_CameraDepthTexture, ...)`
4. 修复后 regenerated IR 已恢复成 global sampler-state operand：
   - 新 `regenerated.ll` 中 `air.sample_compare_depth_2d.f32` 的第二个操作数重新回到 `@__air_sampler_state`

也就是说，这里不是 compare 在“数错一支 intrinsic family”，而是 converter 真的把 first-class sampler-state 语义弄丢了。

## 本轮实现内容

本轮遵守 dashboard 的 implementation-first 原则，只做一处最小 converter 修正与一条最小回归：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
  - 给函数体翻译上下文补充 `emittedSamplerStateGlobals`
  - 当 `resolveIROperand` 遇到 `@__air_sampler_state*` 且该 symbol 已被模块级发射成 `constexpr sampler` 时，不再 fallback 到 entry sampler 参数
  - 因而 sample / sample_compare 现在会真正引用 emitted global sampler-state，而不是错误重绑定到 `%2` 对应的 sampler 参数
- `Scripts/test_ir_semantics_roundtrip_runner.py`
  - 新增定向 replay 回归：`test_corpus_replay_runner_preserves_internal_sampler_state_globals`
  - 固定验证 `test_sampler_state_globals.ll` 会生成：
    - `constexpr sampler __air_sampler_state(...)`
    - `constexpr sampler __air_sampler_state_1(...)`
    - `historyTexture.sample(__air_sampler_state, ...)`
    - `shadowTexture.sample_compare(__air_sampler_state_1, ...)`

这次改动保持得很窄：

- 不改变普通 sampler 参数解析
- 不改变 texture 参数绑定
- 不改变 compare risk 口径
- 只影响“已经被模块级发射成 `constexpr sampler` 的 internal sampler-state global”这一路

## 单 case 验证结果

### 1. 定向 replay 回归

已通过：

- `python3 -m unittest Scripts.test_ir_semantics_roundtrip_runner.IRSemanticsRoundtripRunnerTests.test_corpus_replay_runner_preserves_internal_sampler_state_globals`
- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/test_ir_canonical_compare.py`

新增最小 fixture 已明确验证：

- internal `@__air_sampler_state` global 会保持为 `constexpr sampler`
- `sample_compare` 调用会引用 emitted global，而不是误绑定到 entry sampler

### 2. 真实样本单 case

#### `293ec561...`

- 输出：`build/semantics-validation/roundtrip/cc-003-13-single-293ec561-sampler-state/`
- compile posture：继续保持对齐
- 修复命中证据：
  - `generated.metal` 里的 `sample_compare` 已改成 `__air_sampler_state`
  - `regenerated.ll` 中对应调用第二个操作数已从 `%2 -> @__air_sampler_state`
  - `!air.sampler_states` 也重新落回 regenerated IR
- 顶层风险：当前仍为 `L2`

当前单 case 没有直接 `L2 -> L1`，但 residual 已明显换形：

- 旧问题里的“sampler-state operand 被错误替换”已经消失
- 当前残留更多收缩为：
  - `air.discard_fragment` 缺失
  - `fast_floor / fast_fract / fast_fmin` 一类 intrinsic reshaping
  - 以及由此带出的 `CFG / instruction-family` 差异

这说明这轮已经把 `CC-003.13` 里的第一处真实 converter 结构缺口命中并修正，但它还不是这整支 family 的最后一个 root cause。

## 当前结论

本轮已经可以明确下结论：

- `CC-003.13` 不是纯 compare 噪声
- 至少其中一支高频 residual 的真实矛盾，是 converter **没有保住 internal sampler-state global 到 MSL / regenerated AIR 的一等语义**
- 这轮修复后，代表 case `293ec561...` 的 sampler-state operand 已经重新对齐，证明当前 family 里确实存在真实实现缺口，而不只是 compare 口径问题
- 但从单 case 与 full-batch 结果看，这支 family 仍然叠着别的 residual mechanism；仅修 sampler-state global 还不足以让整支 family 从 `L2` ceiling 大范围回落

## 下一步建议

既然这轮已经确认 `module addrspace + air intrinsic` family 至少部分是 converter 真缺口，下一步更值得继续下钻的是：

- 同一 family 中 residual 仍然残留的 `air.discard_fragment` / `fast_floor` / `fast_fract` / `fast_fmin` reshaping 是否也是 emitted MSL 语义差异
- 继续优先沿 `293ec561...` / `3f5bb2d...` / `06c5f51f...` 这支重复 family 做更细的 emitted-MSL-to-regenerated-AIR 闭环
- 在确认剩余差异都只剩 optimizer-only reshaping 之前，不应过早把这支 family 直接下放为 compare noise
