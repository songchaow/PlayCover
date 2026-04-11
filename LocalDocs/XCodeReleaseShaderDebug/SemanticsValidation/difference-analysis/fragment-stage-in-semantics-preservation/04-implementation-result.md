## fragment-stage-in-semantics-preservation：实现结果

## 本轮分析的差异类型

本轮处理的是 `CC-003.15` 之后 dashboard 明确优先的最后一支 corpus entry residual：

- `entry 参数语义摘要变化`
- `entry builtin / stage-in 摘要变化`

代表 case 落在：

- corpus：`build/semantics-validation/roundtrip/cc-003-15-full-corpus/com.miHoYo.Yuanshen/modules/823dcdf727869f21c460e3cae4217997263c4749dc6f9ccf3f6b581cbc71cf2e/`
- 单 case 复跑：`build/semantics-validation/roundtrip/cc-003-16-single-823dcdf7-stage-in-semantics/`

这轮重新下钻后，可以把 root cause 收敛成一条很具体的 converter 缺口：

- 不是 `compile-summary.json` 所显示的 fast-math / planner posture 回退
- 也不是 `ir_canonical_compare.py` 对 entry 语义做了不对称降噪
- 真正的问题是：**`IRToMSLConverter.swift` 在生成 fragment `stage_in` 结构体字段时，只保留了字段名和类型，没有把 AIR metadata 里的 `user(TEXCOORD*)` 语义以及 `air.flat / air.center / air.perspective` 这类插值 qualifier 回发到 MSL**

这会直接带来两层后果：

1. 修复前 `generated.metal` 的 `XlatMtlMain_StageIn` 只有：
   - `float2 TEXCOORD0;`
   - `float4 TEXCOORD1;`
   - `float4 TEXCOORD2;`
2. Metal 再编译回 AIR 后，编译器会把缺失语义的字段自动降回：
   - `generated(9TEXCOORD0Dv2_f)`
   - `generated(9TEXCOORD1Dv4_f)`
   - `generated(9TEXCOORD2Dv4_f)`
   并且把原本两路 `flat` 输入稳定漂成默认的 `air.center + air.perspective`

## 单 case 证据

### `823dcdf7...`

对 `cc-003-16-single-823dcdf7-stage-in-semantics` 的结构化产物复核后，证据链已经足够明确：

1. compile posture 继续对齐，不是 planner root cause：
   - `originalFastMathMode = enable`
   - `effectiveMetalArgs = -ffast-math`
   - compile / llvm-dis 都成功
2. 修复后 `generated.metal` 已重新发出完整 `stage_in` 字段属性：
   - `float2 TEXCOORD0 [[user(TEXCOORD0)]] [[center_perspective]];`
   - `float4 TEXCOORD1 [[user(TEXCOORD1)]] [[flat]];`
   - `float4 TEXCOORD2 [[user(TEXCOORD2)]] [[flat]];`
3. 修复后 `regenerated.ll` 的 AIR metadata 已重新对齐 original：
   - `!"user(TEXCOORD0)" + !"air.center" + !"air.perspective"`
   - `!"user(TEXCOORD1)" + !"air.flat"`
   - `!"user(TEXCOORD2)" + !"air.flat"`
4. 单 case 顶层结果已降为：
   - `riskLevel = L1`
   - `entryComparison = L0`
   - `builtinComparison = L0`
   - `blockedSamples = []`

也就是说，这里不是 compare 在“误报一条 entry family”，而是 converter 真的把 first-class fragment stage-in 语义弄丢了。

## 本轮实现内容

这轮继续遵守 dashboard 的 converter-first 规则，把最小修正落在：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_fragment_stage_in_semantics.ll`

具体做法是：

1. 在 metadata 参数模型里新增两类一等信息：
   - `stageInAttribute`：保存 `user(TEXCOORD0)` 这类语义字符串
   - `qualifiers`：保存 `air.flat / air.center / air.perspective / air.no_perspective / air.centroid / air.sample`
2. 在 `ParsedParameter` 中继续透传这些字段
3. 新增 `stageInFieldAttributes(...)` / `interpolationAttribute(...)`，把 fragment `stage_in` 字段重新发成：
   - `[[user(...)]]`
   - `[[flat]]`
   - `[[center_perspective]]`
   - 以及后续同类样本可复用的 `centroid/sample/no_perspective` 组合
4. 新增最小 fixture 与两条回归：
   - replay 回归：验证 `generated.metal` 的 `stage_in` 字段语义存在
   - round-trip 回归：验证 regenerated AIR 不再出现 `entry 参数语义摘要变化` / `entry builtin / stage-in 摘要变化`

这次改动保持得很窄：

- 不改变 resource / sampler / texture 绑定逻辑
- 不改变 `ir_canonical_compare.py` 风险口径
- 不改变 fast-math / compile posture 推断
- 只影响 fragment `stage_in` 字段语义的发射保真

## 单 case 验证结果

### 1. Python / round-trip 回归

已通过：

- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/test_ir_canonical_compare.py`

其中本轮新增并命中的定向回归为：

- `test_corpus_replay_runner_preserves_fragment_stage_in_semantics`
- `test_roundtrip_runner_preserves_fragment_stage_in_semantics`

相邻旧回归：

- `test_corpus_replay_runner_does_not_invent_fragment_position_input`
- `test_roundtrip_runner_preserves_zero_input_fragment_signature`

也继续通过，说明这次修复没有把 `CC-003.9` 的 fragment `[[position]]` 修复打回去。

### 2. BuildScripts 构建验证

已执行：

- `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES ./BuildScripts/build_and_install.sh`

构建、安装与 ad-hoc 重签名均通过。

### 3. 真实代表 case

已对 `823dcdf7...` 重新执行单 case round-trip：

- 输出：`build/semantics-validation/roundtrip/cc-003-16-single-823dcdf7-stage-in-semantics/`
- 结果：`L2 -> L1`
- `entryComparison = L0`
- `builtinComparison = L0`
- `blockedSamples = []`
- `shouldEnterL3 = false`

修复后单 case 顶层仅剩：

- `指令族统计变化`
- `fast-math 相关属性变化`
- `模块元数据 targetTriple 变化`

## 当前结论

本轮已经可以明确下结论：

- 这支 `entry 参数语义 / stage-in` residual 不是 compare 噪声
- 它是一支真实的 converter 缺口：**fragment `stage_in` 字段上的 user 语义与插值 qualifier 没有被保真回发到 MSL**
- 只要把 `user(TEXCOORD*)` 和 `flat / center_perspective` 等字段属性发回去，entry 相关差异就会一起消失
- 这是一处很小的修改，但正好命中了 corpus 中最后一支独立的 entry residual family

## 下一步建议

这轮之后，更值得优先继续分析的是：

- diagnostics / corpus 共同剩余的 `instruction-family + fast-math + targetTriple` family
- 以及 residual `控制流粗摘要变化 + 指令族统计变化 + fast-math 相关属性变化`
