## buffer-noalias：可行对齐方案与成本判断

## 问题重述

当前真实 case 的差异是：

- original IR：第一个 constant buffer 参数写成参数级 `noalias`
- regenerated IR：默认写成 `"air-buffer-no-alias"`

最小实验和真实 shader 副本实验已经证明：

- 只要在 MSL 中把对应参数写成 `__restrict`，就能把 regenerated IR 拉回参数级 `noalias`

所以现在的问题已经从：

- “能不能对齐？”

转变为：

- “应该通过哪一层对齐，成本和风险各是什么？”

## 方案一：只改 canonical compare

### 做法

在 `Scripts/ir_canonical_compare.py` 中，把下列两种表达做等价归一：

- `noalias`
- `"air-buffer-no-alias"`

必要时再把相关 alias metadata 也收敛到统一 canonical token。

### 优点

- 成本最低
- 风险最小
- 可以立刻降低当前这类 `L3` 误报
- 不会改变真正的 shader 编译结果

### 缺点

- 只能修报告口径
- 不能让 regenerated IR 文本真的更接近 original IR

### 适用场景

- 当前目标是先把语义判断做准
- 当前还没有证据表明 alias 表达差异已经影响最终行为

### 当前判断

这是**最值得先做**的方案。

## 方案二：改 emitted MSL，定向给参数加 `__restrict`

### 做法

在 `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` 中，对特定 buffer 参数发射：

- `const constant StructType& __restrict arg [[buffer(N)]]`

或者对应的 pointer 形式。

### 优点

- 已被最小实验和真实 case 副本实验验证为可行
- 能直接把 regenerated IR 的参数表达拉近 original IR
- 对想做“文本级 round-trip 对齐”的场景很有吸引力

### 缺点

- `__restrict` 不是纯 cosmetic 变化，而是更强的 alias 约束
- 这会改变编译器的分析与优化前提
- 虽然它可能更接近 original IR，但如果某些参数原本不该被视为 `noalias`，就可能引入新的行为风险

### 关键风险

实验表明：

- 默认写法会生成 `"air-buffer-no-alias"`
- 加 `__restrict` 会变成参数级 `noalias`

这意味着它不是“只换一种文字写法”，而是真的在改变编译器对参数别名关系的建模方式。

### 更稳妥的使用方式

如果要走这条路，更建议：

- 只对有强证据的参数定向使用
- 例如仅在 metadata / 原始 IR 已经明确给出 `noalias` 的情况下，才尝试回放 `__restrict`

而不建议：

- 对所有 constant buffer 统一一刀切加 `__restrict`

### 当前判断

这是**技术上可行，但工程上要非常克制**的方案。

## 方案三：尝试只改重编译 posture / flags

### 做法

不改 emitted MSL，只改：

- target
- 平台姿势
- compile flags
- 其它编译 driver 选项

希望编译器自己把 `"air-buffer-no-alias"` 变成参数级 `noalias`。

### 优点

- 理论上最“干净”，不碰语义源码

### 缺点

- 当前实验没有支持这条路是主导因子
- 同一组样本里，真正决定差异的是 `__restrict`，不是 target
- 就算 posture 影响周边 metadata，也没有证据表明它能稳定把这条关键差异自动切换到 `noalias`

### 当前判断

这是**优先级最低**的方案。

除非后续外部资料或更深实验表明 Apple 的某条编译链能系统性改变 alias 参数表达，否则不建议把时间先投在这里。

## 方案四：增强参数语义建模，但不立刻改变 emitted MSL

### 做法

在 `IRToMSLConverter` 的内部参数模型里显式加入 alias 语义，例如：

- `hasNoAlias`
- `aliasHint`

先把信息保留下来，再决定：

- compare 是否使用
- MSL 发射是否使用

### 优点

- 这是中长期最干净的工程化方案
- 能把“原始 IR 观察到的 alias 约束”沉淀成 first-class 信息
- 后续无论是做 compare 还是做 MSL emission，都会更可控

### 缺点

- 成本比单改 compare 高
- 仅建模本身不能自动带来文本对齐
- 真正把它回放到 emitted MSL 时，仍然要回到方案二的风险判断

### 当前判断

这是**值得做的中期能力建设**，但不是当前小任务里最该优先动手的第一刀。

## 综合结论

如果把“收益 / 风险 / 成本”放在一起排序，当前最合理的顺序是：

1. **先改 compare 归一化**
2. **再决定是否做 alias 语义建模**
3. **最后才考虑定向回放 `__restrict`**
4. **不要优先押注纯 compile posture 调参**

原因很简单：

- `compare` 方案能先消掉误报
- `建模` 方案能为后续能力打基础
- `__restrict` 方案虽然能对齐文本，但本质上是在主动改变 alias 约束
- posture 方案当前证据最弱

## 对这个真实 case 的具体建议

针对 `91c46448ca24983b29716a9fe2c28a7930c10b81802758ded6977907bf01ae9b` 这个 case，最保守也最合理的建议是：

### 第一阶段

- 先在 `ir_canonical_compare.py` 中把 `noalias` / `"air-buffer-no-alias"` 做等价归一

### 第二阶段

- 如果未来确实需要把 round-trip IR 文本尽量贴近 original IR，再考虑给这类参数定向回放 `__restrict`

### 第三阶段

- 若要规模化推进，再把 alias 约束纳入 `IRToMSLConverter` 的参数语义建模

## 一句话总结

**这个点现在已经不是“做不到”，而是“做得到，但直接用 `__restrict` 去追文本对齐，风险比改 compare 更高”。**

所以工程上最好的第一刀，不是先改 emitted MSL，而是先改 compare。
