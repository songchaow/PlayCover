## buffer-noalias：最小实验结果

## 实验目标

回答两个问题：

1. `noalias` 与 `"air-buffer-no-alias"` 的差异，是否可以通过修改 emitted MSL 的写法来主动对齐
2. 这种对齐是否只在最小样本里成立，还是在真实 shader 副本上也成立

## 实验环境

- `metal`: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal`
- `clang`: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang`
- `metal version`: `Apple metal version 32023.620 (metalfe-32023.620)`

实验文件目录：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/`

## 实验一：baseline `constant &`

源文件：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_default.metal`

MSL 入口形态：

- `constant Uniforms& u [[buffer(0)]]`

编译后 IR 结果：

- 入口参数是 `ptr addrspace(2) nocapture noundef readonly align 16 dereferenceable(16) "air-buffer-no-alias" %1`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_default_text.ll:9`

结论：

- 默认 `constant &` 并不会生成参数级 `noalias`
- 它更偏向生成 `"air-buffer-no-alias"`

## 实验二：baseline `constant *`

源文件：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_pointer.metal`

MSL 入口形态：

- `constant Uniforms* u [[buffer(0)]]`

编译后 IR 结果：

- 入口参数是 `ptr addrspace(2) nocapture noundef readonly "air-buffer-no-alias" %1`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_pointer.ll:9`

结论：

- 把 `&` 改成 `*` 并不能把 alias 表达切换成参数级 `noalias`
- 它仍然是 `"air-buffer-no-alias"` 路线

## 实验三：`constant * __restrict`

源文件：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_restrict_ptr.metal`

MSL 入口形态：

- `constant Uniforms* __restrict u [[buffer(0)]]`

编译后 IR 结果：

- 入口参数变成 `ptr addrspace(2) noalias nocapture noundef readonly %1`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_restrict_ptr.ll:9`

结论：

- `__restrict` 会显式把 constant buffer 参数推成参数级 `noalias`
- 这是一次明确可复现的表达切换

## 实验四：`constant & __restrict`

源文件：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_restrict_ref.metal`

MSL 入口形态：

- `constant Uniforms& __restrict u [[buffer(0)]]`

编译后 IR 结果：

- 入口参数变成 `ptr addrspace(2) noalias nocapture noundef readonly align 16 dereferenceable(16) %1`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_restrict_ref.ll:9`

结论：

- 即使保留 `&` 形式，只要加上 `__restrict`，也能把 alias 表达推到参数级 `noalias`
- 这一点和当前真实 case 的原始 IR 更接近

## 实验五：kernel 中的 `device* + constant* __restrict`

源文件：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_device_restrict_ptr.metal`

编译后 IR 结果：

- 输出 buffer 仍然是 `"air-buffer-no-alias"`
- constant uniforms buffer 变成参数级 `noalias`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/minimal_device_restrict_ptr.ll:9`

结论：

- `__restrict` 的效果是**参数级别、逐形参**的
- 它不会自动把所有 buffer 都一起变成 `noalias`
- 这意味着后续如果要对齐，只能按参数策略做，而不是寄希望于一次全局 posture 自动对齐

## 实验六：真实 shader 副本，只改第一个 buffer 参数

源文件副本：

- `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_restrict_first_buffer.metal`

改动内容：

- 仅把第一个参数从 `const constant FGlobals_Type& FGlobals [[buffer(0)]]`
- 改为 `const constant FGlobals_Type& __restrict FGlobals [[buffer(0)]]`

编译后 IR 结果：

- 真实 shader 入口的第一个参数变成了：
- `ptr addrspace(2) noalias nocapture noundef readonly align 16 dereferenceable(992) %0`
- 见 `LocalDocs/XCodeReleaseShaderDebug/SemanticsValidation/difference-analysis/buffer-noalias/experiments/real_case_restrict_first_buffer.ll:9`

结论：

- 这说明该思路不仅在玩具样本上成立，在真实 case 的 shader 副本上也成立
- 也就是说：**如果我们愿意改 emitted MSL 形态，确实有办法把回生成 IR 的第一个 constant buffer 参数拉回参数级 `noalias` 表达**

## 实验七：target / 编译姿势的影响

补充实验文件：

- `minimal_default.ios.ll`
- `minimal_restrict_ptr.ios.ll`
- `minimal_restrict_ref.ios.ll`

结果：

- 默认写法仍然是 `"air-buffer-no-alias"`
- 加 `__restrict` 后仍然是参数级 `noalias`

结论：

- 至少在这组实验里，**决定 alias 表达形式的主要因素不是平台 target，而是 MSL 参数写法本身是否带 `__restrict`**
- target / posture 可能仍会影响别的 metadata 细节，但对这条关键差异来说，不是主导因子

## 当前可确认结论

基于这组实验，当前已经可以确认三件事：

1. `"air-buffer-no-alias"` 并不是不可控的编译器随机行为
2. 仅改 emitted MSL 的参数写法，就能把 alias 表达切换到参数级 `noalias`
3. 对于当前真实 case，这种对齐在技术上是可行的

因此，后续已经不必再纠结“这是不是完全不可能对齐”。

**它是可以对齐的，问题只剩下：值不值得、以及该以什么策略对齐。**
