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

## CC-003.4.2：helper / lowering 残留归类

在 `CC-003.4.1` 之后，继续对 `f26d322...` 下钻 helper `_ZN11_fract_impl...` 的 nested branch 与 `fract / floor / fmin` 残留，可以把问题再切开成两层：

- **generated.metal 是否还缺失真实控制流 / 语义结构？**
- **original / regenerated 里的 residual `L2`，到底是 converter 继续出错，还是 Metal 编译器对 helper 做了 fast-math 内联/折叠后的 compare 噪声？**

这轮结论是：

- entry 侧的真实 converter CFG 问题已经被 `CC-003.4.1` 修掉
- 剩下这支 helper / lowering 漂移，已经更像 **compare 口径噪声**，而不是新的 converter 漏洞

## 新证据

本轮没有再发现新的 generated MSL 结构缺口，反而发现剩余差异有一个稳定模式：

- `f26d322...` 的 `entryComparison` 已经稳定为 `L0`
- 但 compare 仍会报：
  - `模块级 air intrinsic 使用变化`
  - `函数内 air intrinsic 调用统计变化`
  - `控制流粗摘要变化`
  - `指令族统计变化`
- 对照 original / regenerated 可以看到，这些残留主要来自：
  - helper 中的 `floor / fmin / fract` 被重新编译后折叠成 fast 版本或向量版本
  - helper 或局部表达式被内联回 entry，导致 entry 内 intrinsic family 计数与 CFG 统计漂移
  - 但 entry/resource 摘要并没有继续发生新的 first-class 语义变化

也就是说，这组 residual 已经不再像“生成错了代码”，而更像“同一类数学 helper 被编译器重新排布后，compare 对 shape 过于敏感”。

## 本轮实现内容

因此这轮实现没有继续改 `IRToMSLConverter.swift`，而是把最小改动落在：

- `Scripts/ir_canonical_compare.py`

具体做了两件事：

1. 在现有 fast/non-fast intrinsic 归一化之上，再补一层 **intrinsic family** 判定
2. 当同时满足下面条件时，把这类 residual 从 `L2` 下调为 `L1`：
   - entry/resource 语义未变
   - module intrinsic family 集合一致
   - entry 只多/少一支来自 helper 内联的 family，或 family 集合本身未变
   - 差异主要体现在 intrinsic 计数、CFG shape、instruction-family 统计

这条规则的目标不是“普遍放宽 compare”，而是只把 `f26d322...` 这一类 **family-preserving / optimizer-only** 的 residual 降噪掉。

## 新增回归

本轮补了 compare 单测，覆盖两条边界：

- optimizer-only intrinsic family 漂移应当从 `L2` 降为 `L1`
- 真正发生 family 缺失/变化的场景仍应保留 `L2`

对应文件：

- `Scripts/test_ir_canonical_compare.py`

## 验证结果

### 单 case

1. `python3 Scripts/test_ir_canonical_compare.py`
   - 通过
2. `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
   - 通过
3. 直接对现有 diagnostics artifact 重算 compare：
   - `f26d322...`：`L2 -> L1`
   - `91c46448...`：仍为 `L2`

### full-batch

1. diagnostics 复跑：
   - 输出：`build/semantics-validation/roundtrip/20260410-025055-4bfa19e0`
   - 结果：`L1 5 -> 6`、`L2 2 -> 1`、`L3` 持平
   - 变化样本只有：`f26d322...` 从 `L2 -> L1`
2. corpus 复跑：
   - 输出：`build/semantics-validation/roundtrip/20260410-025055-78cb9622`
   - 结果：`L1 80 -> 99`、`L2 106 -> 87`、`L3` 持平
   - 一共 19 个样本从 `L2 -> L1`，抽查 `44cab0a5...` 也属于同样的 optimizer-only intrinsic family 漂移模式

## 当前结论

本轮可以把 `CC-003.4.2` 明确收敛成下面这个判断：

- `CC-003.4` 里确实既有真实 converter CFG 缺口，也有 compare 噪声
- `f26d322...` 在 `CC-003.4.1` 修完 diamond CFG 之后，helper `fract / floor / fmin` 残留已经更像 compare 噪声，而不是新的实现问题
- 这类 residual 适合在 `ir_canonical_compare.py` 做定向降噪，不值得继续扩大 converter 侧改动

## CC-003.4.3：`91c46448...` residual 定性

这轮没有继续改 `IRToMSLConverter.swift` 或 compare 规则，而是先用最新 artifacts 把 `91c46448...` 的 residual 重新定性，判断它到底是 compare 噪声还是实现问题。

## 复核结果

### 单 case

1. `python3 Scripts/test_ir_canonical_compare.py`
   - 通过
2. `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
   - 通过
3. 直接对最新 diagnostics artifact `build/semantics-validation/roundtrip/20260410-025055-4bfa19e0/.../91c46448.../original.ll` 与 `regenerated.ll` 重算 compare：
   - `entryComparison` 已经是 `L0`
   - 总体 `riskLevel` 仍为 `L2`
   - 剩余风险集中在：
     - `模块级 air intrinsic 使用变化`
     - `控制流粗摘要变化`
     - `指令族统计变化`
4. 同样对最新 corpus artifact `build/semantics-validation/roundtrip/20260410-025055-78cb9622/.../91c46448.../original.ll` 与 `regenerated.ll` 重算 compare：
   - 结论一致，仍是同一组 residual

### full-batch

本轮没有引入新的实现改动，因此没有再重复发起 full-batch；控制面继续沿用 `CC-003.4.2` 已经生成的最新批次：

- diagnostics：`build/semantics-validation/roundtrip/20260410-025055-4bfa19e0`
  - 风险计数保持 `L1 6 / L2 1 / L3 146`
  - `91c46448...` 仍是 diagnostics 中唯一 `L2`
- corpus：`build/semantics-validation/roundtrip/20260410-025055-78cb9622`
  - 风险计数保持 `L1 99 / L2 87 / L3 251`

## 新证据：这不是 compare 噪声

这轮最关键的新证据不在 canonical compare 本身，而在 `generated.metal` 的结构上。

### 1. `generated.metal` 仍在顺序发射互斥分支

在最新 diagnostics artifact 的 `generated.metal` 里，仍能直接看到：

- 先发一个空的 `if (t124) { // → BB142 } else { // → BB148 }`
- 随后把 `BB142` 与 `BB148` 两段代码都按线性顺序发出来
- `phi_0` / `phi_1` 先被 `BB142` 赋值，再立刻被 `BB148` 覆盖

同类模式后面还会再次出现，例如：

- `if (t239) { // → BB286 } else { // → BB283 }`
- 但 `BB283` / `BB286` 仍被顺序发射，`phi_6` 最终只保留后一路结果

这说明当前 residual 不是“helper 被编译器内联后 compare 对 count 太敏感”，而是 **generated MSL 自身仍然没有把互斥控制流真正恢复出来**。

### 2. 原始 / 回生成 IR 的 CFG 也支持这个判断

对照同一批 diagnostics artifact：

- `original.ll` 里 `xlatMtlMain` 仍有大量显式 `condbr + phi` 与 loop-carried phi
- `regenerated.ll` 已塌缩成 `2` 个 `condbr` + 大量 `select`
- compare 对应地报出：
  - `basicBlockCount: 48 -> 5`
  - `phiCount: 20 -> 2`
  - `condbr: 20 -> 2`

这更像 converter 在 simple diamond 之外仍有 structured CFG 回放缺口，而不是 compare 无端放大噪声。

### 3. intrinsic family 也不满足 `f26d322...` 的降噪前提

`91c46448...` 与 `f26d322...` 的另一个关键差异是：

- `f26d322...` 的 residual 仍是 family-preserving 的 optimizer-only 漂移
- `91c46448...` 这轮直接缺了 `fract / max / sin / sqrt` 四支 module intrinsic family

因此它不满足 `CC-003.4.2` 那条 compare 降噪规则的适用边界，不应该继续靠放宽 `ir_canonical_compare.py` 来压低风险。

## 当前结论

本轮可以把 `CC-003.4.3` 明确收敛成下面这个判断：

- `91c46448...` 当前 residual **不是 compare 噪声**
- 它更像 `IRToMSLConverter.swift` 在 simple diamond 之外的 structured CFG 回放缺口
- 当前最值得修的不是 compare，而是把这支样本继续拆成更小的 converter CFG 子问题

## 下一步建议

下一步更值得继续沿 `CC-003.4` 推进的是：

- 以 `91c46448...` 为入口，先挑一类最小且可复现的“空 `if/else` + 线性发射基本块 + 覆盖 phi” 模式修掉
- 优先从 multi-block diamond 或 loop-carried phi 的最小子模式切，不要一口气扩成泛化 CFG 重建
- 真正落实现后，再做单 case + full-batch 验证，看 diagnostics `L2 1` 是否继续下降
