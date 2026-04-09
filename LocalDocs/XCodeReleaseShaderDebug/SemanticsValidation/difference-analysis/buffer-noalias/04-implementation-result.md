## buffer-noalias：实现结果

## 本轮实现内容

已在：

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`

增加一条定向回放逻辑：

- 从原始 IR entry 参数文本中识别是否显式带有 `noalias`
- 将这一信息挂到内部参数模型 `ParsedParameter`
- 在生成 MSL buffer 参数时，如果该参数来自原始 IR 的 `noalias`，则发射 `__restrict`

本轮实现不是全局一刀切，而是：

- **仅当原始 IR 参数本身明确带 `noalias` 时，才补 `__restrict`**

## 真实 case 验证结果

目标 case：

- `build/semantics-validation/roundtrip/shader-source-diagnostics-batch/com.miHoYo.Yuanshen/modules/91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b/original.ll`

### 1. 生成的 MSL 已发生预期变化

新的 generated MSL 位于：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.metal`

其入口第一个参数现在是：

- `const constant FGlobals_Type& __restrict FGlobals [[buffer(0)]]`

见：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.metal:80`

### 2. 重编译后的 LLVM IR 已恢复参数级 `noalias`

重编译后的 LLVM IR 位于：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.ll`

其入口第一个参数现在是：

- `ptr addrspace(2) noalias nocapture noundef readonly align 16 dereferenceable(992) %0`

见：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.ll:9`

### 3. 风险评估结果已明显改善

compare 结果位于：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.compare.json`

核心结果：

- `riskLevel`: `L2`
- 原先触发 `L3` 的 `entry 参数类型摘要变化` 已消失
- 当前仍剩：`entry 参数语义摘要变化`

见：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.compare.json:4`
- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.compare.json:13`

## 还剩下的 entry 参数相关风险是什么

当前已经不再有：

- `entry 参数类型摘要变化`

但仍然有：

- `entry 参数语义摘要变化`

具体差异在第一个 buffer 参数上表现为：

- original：没有显式 `addrspace=2`
- regenerated：显式写成 `addrspace=2`

见：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.compare.json:16`
- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_generated_after_fix.compare.json:44`

所以当前答案不是：

- “entry 参数相关风险已经全部没有了”

而是：

- “原先由 `noalias` / `air-buffer-no-alias` 触发的 entry 参数类型风险已经消失了”
- “但 entry 参数语义层仍有一条残留差异”

## 这说明什么

这次实现验证了两件关键事实：

1. `noalias -> __restrict` 的定向回放是可行的
2. 这条实现可以直接消掉原来的 `entry 参数类型摘要变化` 风险

同时也说明：

- 当前 case 的剩余 entry 风险已经不再是 `noalias` 本身
- 后续如果要继续把风险从 `L2` 压到更低，需要继续处理参数语义摘要里的 `addrspace=2` 显式化问题

## 当前结论

本轮实现已经证明：

- **这条 `noalias` 对齐路径不仅能做，而且已经对真实 case 生效**
- **但它只能解决 entry 参数风险中的“类型摘要”这一层，不能单独消灭全部 entry 参数相关风险**
