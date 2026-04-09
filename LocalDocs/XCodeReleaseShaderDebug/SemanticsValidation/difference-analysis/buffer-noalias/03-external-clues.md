## buffer-noalias：外部线索

## 目的

补充回答两个问题：

1. MSL / AIR 里是否存在公开且稳定的“只靠编译姿势就把 buffer alias 表达对齐”的标准路径
2. `__restrict` / alias metadata 这类现象，是否有外部资料支持它不仅仅是我们本地样本偶然观察到的行为

## 线索一：MSL 的公开主语义仍然是地址空间，而不是单独一套 buffer alias 关键字系统

参考资料：

- Apple Metal Shading Language Specification
- `https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf`

该文档的公开重点是：

- `device`
- `constant`
- `threadgroup`

这些地址空间如何约束 buffer / pointer 的内存语义。

当前没有找到同等级、同权威的公开资料，明确说明：

- 只通过某组 compile posture / flags，就可以把 `"air-buffer-no-alias"` 系统性变成参数级 `noalias`

这意味着：

- 单靠“调姿势”去追这条差异，证据基础不强

## 线索二：LLVM / GPU 后端里，alias 信息确实经常通过 metadata 或参数属性表达

参考资料：

- LLVM PR: `https://github.com/llvm/llvm-project/pull/102461`
- LLVM test: `https://github.com/llvm/llvm-project/blob/main/llvm/test/CodeGen/AMDGPU/attributor-noalias-addrspace.ll`
- LLVM test: `https://github.com/llvm/llvm-project/blob/main/llvm/test/CodeGen/AMDGPU/expand-atomicrmw-flat-noalias-addrspace.ll`

这组资料的价值不在于它们直接证明 Apple AIR 的细节，而在于它们说明：

- alias / noalias 在 GPU 相关 IR 里，本来就可能以不同层次表达
- 有时挂在参数属性上
- 有时挂在 metadata 上

这和我们本地观察到的现象是一致的：

- original 更像参数级 `noalias`
- regenerated 更像 `"air-buffer-no-alias"` + metadata 路线

## 线索三：外部资料没有推翻本地实验结论

当前外部线索没有提供一个更强的替代解释，例如：

- “只要切到某个 target，编译器就会自动稳定产出参数级 `noalias`”

相反，它们更支持一个较稳的结论：

- alias 信息的**承载层级**本来就可能变化
- 如果想要指定某一种表达形式，最可控的入口仍然是**源码写法本身**

结合本地实验，这就把结论收敛得更清楚了：

- 对这个 case 来说，真正可控的杠杆是 `__restrict`
- 而不是单纯指望 compile posture 自己把表达切过去

## 当前对外部线索的使用方式

这些资料更适合支持下面这条工程判断：

- **不要优先把时间投在 posture 调参上**
- **优先在 compare 和 emitted MSL 两层做可控实验**

也就是说，外部资料不是直接给出了“现成答案”，而是帮助排除了一个不太值得优先投入的方向。

## 一句话总结

外部线索的作用，主要是帮我们确认：

- **alias 表达层级漂移是合理现象**
- **但如果想强行把它拉回参数级 `noalias`，当前最有效的手段还是改 MSL 写法，而不是改 compile posture**
