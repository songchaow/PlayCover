## Shader L3 个案分析：buffer `noalias` 差异的根因判断

## 目的

这篇文档用于沉淀一个具体但很典型的判断方法：

- 当一个 shader round-trip 样本被打成 `L3` 时，如何区分它到底更像是**反编译 / 翻译器实现问题**，还是**canonical compare 口径问题**
- 当差异集中在 entry buffer 参数的 `noalias` / alias 信息时，应该如何沿着实现链路追根
- 如何避免把“表达方式变化”过早误判成“真实语义损坏”

这不是一篇泛泛的风险分级介绍，而是一篇围绕一个真实样本展开的 case study。

## 样本

本次分析使用的目标样本是：

- `bundle:com.miHoYo.Yuanshen::module:91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b`

对应文件位置：

- 原始 IR：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch/com.miHoYo.Yuanshen/modules/91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b/original.ll`
- 回生成 IR：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch/com.miHoYo.Yuanshen/modules/91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b/regenerated.ll`
- compare 摘要：`build/semantics-validation/roundtrip/shader-source-diagnostics-batch/compare-summary.json`

该样本被判成 `L3`，核心风险理由之一是：

- `entry 参数类型摘要变化`

而最值得追踪的一处差异，正是第一个 constant buffer 参数。

## 先看差异本身

原始 IR 入口的第一个参数是：

- `ptr addrspace(2) noalias readonly dereferenceable(992) %0`

回生成 IR 入口的第一个参数是：

- `ptr addrspace(2) nocapture noundef readonly align 16 dereferenceable(992) "air-buffer-no-alias" %0`

表面上看，变化很多：

- 原始有 `noalias`
- 回生成没有显式 `noalias`
- 回生成多了 `nocapture`
- 回生成多了 `noundef`
- 回生成多了 `align 16`
- 回生成多了字符串属性 `"air-buffer-no-alias"`

但如果直接把这些全部当成“语义变化”，判断会过于草率。

## 一、为什么这个差异不能直接判成“翻译器 bug”

### 1. 回生成侧并不是完全没有 alias 信息

虽然 regenerated IR 没有把第一个参数直接写成 `noalias`，但它并不是“完全失去 alias 信息”。

在 regenerated IR 中，entry 参数本身带有：

- `"air-buffer-no-alias"`

同时函数体内还能看到大量：

- `!alias.scope`
- `!noalias`

也就是说，Metal 重新编译后的 AIR 仍然在使用另一套 alias 信息表达方式。

因此，这里更像是：

- **原始 AIR** 用参数级 `noalias` 表达
- **回生成 AIR** 更偏向用 `"air-buffer-no-alias"` + 指令级 `!alias.scope / !noalias` 表达

这首先说明一件事：

**看到 `noalias` 文本消失，并不能自动推出 alias 语义已经消失。**

### 2. 这个 shader 的 MSL 入口仍然明确恢复成了同一个 buffer(0)

生成出来的 MSL 中，第一个参数仍然是：

- `const constant FGlobals_Type& FGlobals [[buffer(0)]]`

这说明至少在“它是一个 read-only constant buffer，并且绑定在 `buffer(0)`”这一层，恢复结果是稳定的。

如果这里连 buffer 类型、buffer 索引、只读属性都错了，那才更像是明显的反编译 / lower bug。

而当前样本并不是这种情况。

## 二、它能否追溯到我们实现中的限制

可以，但要说清楚“追溯到哪一层”。

### 1. `IRToMSLConverter` 的参数模型没有显式保存 `noalias`

在 `IRToMSLConverter.swift` 里，entry 参数最终会落到 `ParsedParameter` 和 `PointerInfo` 这样的内部结构中。

这些结构主要保留：

- address space
- buffer index
- pointer 指向类型
- 是否只读
- metadata 的 kind / type name / arg name

但没有单独字段专门表示：

- `noalias`
- alias scope
- noalias domain

这意味着：

**从我们自己的中间参数模型看，`noalias` 不是 first-class 语义。**

也就是说，转换器不会把“原始 AIR entry 参数上写了 `noalias`”这个事实，稳定地保存在自己的结构里。

### 2. MSL 发射阶段也没有显式发出 `restrict`

对 constant struct buffer，当前实现会生成：

- `const constant StructType& uniforms [[buffer(N)]]`

而不是：

- 某种带显式 `restrict` / `noalias` 提示的 MSL 参数形式

所以从实现角度说，当前 round-trip 的确**没有显式回放原始参数级 `noalias` 文本形态**。

### 3. 这属于“信息建模不足”，但还不能直接等于“语义破坏”

这里最重要的判断是：

- **实现没有显式保存 `noalias`**，这是真的
- 但 **回生成后的 AIR 仍然可能以另一种方式表达 alias 约束**，这也是真的

所以更准确的说法不是：

- “我们的反编译器把 alias 语义搞丢了”

而是：

- “我们的实现没有把 alias 信息作为 round-trip 的稳定显式语义来建模，因此最终 IR 文本形态会漂移”

这两者差别很大。

## 三、为什么这个 `L3` 更像 compare 口径问题

这是本 case 最关键的结论。

### 1. compare 明确会主动降噪很多参数修饰词

`ir_canonical_compare.py` 的设计目标之一，是把 compare 做成“风险筛查器”，而不是“文本 diff 放大器”。

文档里已经明确说了，应默认弱化或忽略以下差异：

- `readonly / writeonly / readnone / dereferenceable / align / nocapture / noundef` 等参数修饰噪声

这说明 compare 本来的哲学是：

- 不希望把普通 ABI / 编译器噪声误报成高风险结构差异

### 2. 实现里也确实在清洗这些噪声

`_sanitize_param_signature()` 会去掉：

- 参数名
- 字符串属性
- `nocapture`
- `noundef`
- `readonly`
- `writeonly`
- `readnone`
- `dereferenceable(...)`
- `align N`

也就是说，在 compare 看来，下面这些变化原则上都不该单独造成高风险：

- `nocapture` 有无
- `noundef` 有无
- `readonly` 有无
- `align 16` 有无
- `"air-buffer-no-alias"` 这种字符串属性有无

### 3. 但 `noalias` 没被一起归一化

问题就在这里。

对于这个样本，清洗之后：

- original 参数摘要仍保留 `noalias`
- regenerated 参数摘要里的 `"air-buffer-no-alias"` 被当字符串属性剥掉了

于是最终形成的 canonical parameter signature 是：

- original：`ptr addrspace(2) noalias dereferenceable(992)`
- regenerated：`ptr addrspace(2) dereferenceable(992)`

这说明 compare 的当前 canonicalization 是**不对称的**：

- 它保留了 original 风格里的 `noalias`
- 却没有把 regenerated 风格里的 `"air-buffer-no-alias"` 重新折叠成等价的 `noalias`

### 4. compare 又把 `parameterSignatures` 直接作为 `L3`

更进一步，`_compare_entry_summaries()` 对 `parameterSignatures` 的比较是：

- 只要数组不完全相等，就记成 `entry 参数类型摘要变化`
- 严重级别直接是 `L3`

所以这里的 `L3` 触发链路其实是：

1. canonical compare 打算降噪
2. 但对 `noalias` 与 `"air-buffer-no-alias"` 没做等价归一
3. 导致 parameter signature 文本仍然不相等
4. `parameterSignatures !=` 直接升级为 `L3`

这更像 compare 策略问题，而不是一个已经坐实的 shader 语义损坏。

## 四、这个 case 更合理的工程判断

### 结论一句话版

**这个差异可以追溯到我们实现中“未显式建模 alias/noalias”的限制，但这条具体 `L3` 更主要是 canonical compare 对 alias 表达形式归一化不充分造成的。**

### 更细一点地说

#### 1. 能归到实现层的部分

- `IRToMSLConverter` 没把 `noalias` 作为 first-class 参数语义保存
- MSL 发射阶段也没有主动输出等价 alias 提示
- 所以 round-trip 后的 AIR 形态不可能稳定复现“原始 entry 参数文本上的 `noalias`”

#### 2. 更像 compare 层问题的部分

- compare 自己已经决定把大量参数修饰词当噪声
- 但它没有把 `noalias` 与 `"air-buffer-no-alias"` 视为等价表达
- 最终把“表达方式差异”放大成了 `L3`

#### 3. 还不能轻易下的结论

目前证据**不足以直接证明**：

- 这个 shader 的真实运行语义已经因为 alias 信息而发生破坏

因为 regenerated IR 侧仍然存在 alias 相关信息，只是表达层级变了。

## 五、这个个案给后续分析带来的方法论

以后看到类似样本，不建议直接问：

- “是不是反编译器丢语义了？”

更好的问题顺序应当是：

### 第一步：先问“变的是语义，还是表达方式？”

如果 regenerated 侧仍能看到：

- `"air-buffer-no-alias"`
- `!alias.scope`
- `!noalias`

那就不能直接把“参数级 `noalias` 文本消失”当作语义完全消失。

### 第二步：再问“我们的内部模型有没有显式保留这类信息？”

如果内部参数模型根本不存 `noalias`，那 round-trip 文本漂移是预期内现象。

### 第三步：最后问“compare 是否把两种等价表达误报成差异？”

如果 compare 一边保留 `noalias`，另一边又剥掉 `"air-buffer-no-alias"`，那就很可能是 compare 口径问题。

## 六、推荐的后续处理顺序

对于这一类 case，更合理的修复优先级是：

### 1. 先修 compare 的 alias 归一化

优先考虑让 canonical compare：

- 要么把 `noalias` 也当作低价值参数修饰噪声处理
- 要么把 `"air-buffer-no-alias"` 归一化映射成等价的 alias 标记
- 要么把 alias 信息移到独立字段里做更可控的比较

这样可以先降低明显的 `L3` 误报。

### 2. 再决定要不要增强反编译器的 alias 建模

只有当后续证据表明：

- alias 信息缺失真的会系统性影响行为
- 或者它在多个样本中稳定关联真实 render / compile 回归

再投入把 alias 语义作为 first-class 信息纳入参数模型，才更划算。

## 最后结论

针对这个 shader 个案，我的最终判断是：

- **可以追溯到实现上的信息建模不足**
- **但这条 `L3` 更主要是 compare 口径问题**
- **当前证据不足以直接判定为“反编译器把 alias 语义搞坏了”**

换句话说：

**这是一个“实现层有限制、但告警层放大了限制”的案例。**

在工程上，优先修 compare，比优先把它当成 shader lowering 真 bug 更合理。
