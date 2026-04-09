## phi-diamond-cfg-reconstruction：实现结果

## 本轮分析的差异类型

本轮从 `CC-003.4` 当前 diagnostics 剩余的 `L2` 样本入手，先选了：

- `build/semantics-validation/roundtrip/20260410-021241-267e605b/com.miHoYo.Yuanshen/modules/f26d32229cb34fad3a73609dc80215abfdb35069e4cf950a92df773818f17c5e/original.ll`

它在最新 full-batch 里已经不再表现为 entry/resource metadata 漂移，而是收敛成：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `指令族统计变化`

## 单 case 证据

先直接回放当前样本的 `generated.metal`，发现主入口 `xlatMtlMain` 在 `_UseParticleInstancing` 这一处原本应当分叉的控制流上，生成结果只有：

- 一个空的 `if/else` 骨架
- 随后把 true / false 两边基本块的语句按线性顺序全部发出来
- 最后用后出现的赋值覆盖前面的 phi 变量

这说明该样本的主要矛盾至少有一部分不是 compare 口径噪声，而是：

- `IRToMSLConverter.swift` 在 `br + phi` 的 diamond CFG 上没有真正把基本块结构回放成 MSL 控制流

## 本轮实现内容

已在：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`

补上最小一层的 structured CFG 发射：

- 对带 `phi` 的简单 diamond 分支，先按基本块切分函数体
- 当检测到 `condbr -> true/false -> common merge` 模式时，发射真实的 `if/else` 代码块
- 仍然沿用现有 phi 变量方案，但把 merge 前的 phi 赋值保留在对应分支体里，而不是只发空注释
- 同时给 `SSAContext.emit` 增加统一缩进，避免 block 内语句继续手写空格

## 定向回归

已新增：

- `LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_phi_branch.ll`
- `Scripts/test_ir_semantics_roundtrip_runner.py` 中的 replay 回归

回归目标是一个最小 `condbr + phi + merge` kernel，验证生成的 `generated.metal` 至少满足：

- 有真实 `if (...) { ... } else { ... }`
- 两个分支内分别写入同一个 phi 目标变量
- merge 后使用该 phi 变量

## 单 case 验证结果

本轮已完成两层最小验证：

1. `python3 -m unittest Scripts/test_ir_semantics_roundtrip_runner.py -k phi_branch`
   - 通过
2. `python3 Scripts/corpus_replay_runner.py --ll .../f26d322.../original.ll --output-file /tmp/f26d322.generated.metal`
   - 生成结果里 `_UseParticleInstancing` 对应的 entry 分支已经恢复为真实 `if/else`

修复后，`f26d322...` 的单 case full round-trip 仍是 `L2`，但残留已经收敛为：

- `模块级 addrspace 分布变化`
- `模块级 air intrinsic 使用变化`
- `函数内 air intrinsic 调用统计变化`
- `指令族统计变化`

也就是说，本轮已把这支样本里最直接的一处 converter CFG 回放缺口补上，但还没有把整条 `CC-003.4` 闭环做完。

## 当前结论

本轮可以先明确两点：

- `CC-003.4` 这组 diagnostics `L2` 里，至少有一部分不是 compare 纯噪声，而是 converter 对 diamond CFG 的真实回放缺口
- 这类问题值得优先在 `IRToMSLConverter.swift` 修，而不是先放宽 `ir_canonical_compare.py`

## 下一步建议

当前更值得继续沿同一条样本线下钻的是：

- `f26d322...` 里 helper `_ZN11_fract_impl...` 这类嵌套分支仍未被结构化发射的问题
- 或者，在确认 generated MSL / regenerated IR 已经稳定后，再评估剩余 `fract.v2f32 / floor / fmin` 模式是否属于 compare 口径上的 lowering 噪声
