## SIP、swizzle 与 Metal 截帧原理

### 一、文档目的

这篇教程用于回答三个经常被混在一起的问题：

1. **SIP 到底是什么**
2. **为什么 PlayCover 最终能成功截帧，但这不等于 SIP 失效**
3. **当前代码里到底是怎么做 swizzle / hook 的**

本文重点不是历史过程，而是基于**当前代码实现**给出可以稳定复述的解释口径。

---

### 二、先给结论

#### 1. 关于 SIP

**SIP（System Integrity Protection）是 macOS 的系统完整性保护机制。**

它的作用不是“禁止一切运行时 hook”，而是阻止应用或管理员权限轻易篡改系统关键文件、系统受保护进程和部分底层运行机制。

#### 2. 关于“截帧成功是否等于 SIP 没工作”

**不是。**

PlayCover 当前截帧成功，说明的是：

- `PlayTools` 已成功进入目标 app 进程
- 目标 app 进程内的 Metal 运行时链路可被当前方案观测和利用
- `MTLCaptureManager` / `libmtlcapture.dylib` 在当前场景下可用
- PlayCover 已经处理掉了若干兼容性问题（例如启动崩溃、空 trace、stopCapture 崩溃）

但这**不能推出 SIP 失效**。

#### 3. 关于当前 swizzle 的本质

当前与截帧直接相关的 swizzle，核心是：

- 在 **目标 app 进程内部**
- 对 `MTLDevice` 的 `newCommandQueue` 创建路径做运行时拦截
- 记录真实参与渲染的 `MTLCommandQueue`
- 再把这个 queue 或对应 scope 交给 `MTLCaptureManager` 去执行 GPU frame capture

这更接近**进程内运行时插桩**，不是“全局修改 macOS 暴露给所有进程的系统 API 行为”。

---

### 三、SIP 是什么

#### 1. 基本定义

SIP 是 Apple 在 macOS 上提供的系统级保护机制，也常被叫做 **Rootless**。

它的目标是：

> **即使拿到了管理员权限，也不能随意修改系统关键部分。**

#### 2. 它主要保护什么

可以粗略理解为：

- 保护系统关键目录和文件
- 保护部分系统进程不被注入、篡改或调试
- 限制一些会破坏系统完整性的底层行为
- 给代码签名、运行时装载和系统安全策略提供更稳固的系统边界

#### 3. 它和当前问题的关系

在 PlayCover 语境里，SIP 常常和下面几类问题一起出现：

- 签名
- Team ID
- AMFI
- 调试 / 注入
- 某些运行时能力的可用性

但必须注意：

- **SIP** 不是 **AMFI**
- **SIP / AMFI** 也不是 **游戏反作弊**
- **截帧成功** 也不是 **SIP 失效**

---

### 四、为什么“截帧成功”不等于“SIP 没工作”

#### 1. 当前方案做的是进程内运行时处理

PlayCover 当前做的事情是：

- 把 `PlayTools.framework` 注入目标 app
- 在目标 app 自己的进程里安装运行时 hook / swizzle
- 调用 Apple 已经提供的 `Metal` / `MTLCaptureManager` 能力进行截帧

这不是：

- 修改磁盘上的系统 `Metal.framework`
- 全局替换 macOS API
- 对所有进程统一改写 Metal 行为
- 篡改受 SIP 保护的系统组件本体

#### 2. 当前成功说明的是什么

当前成功更说明：

- **进程级链路通了**
- **运行时兼容性问题被逐步修复了**
- **Apple 自带的 capture 能力最终可被利用**

而不是说明：

- SIP 在整台机器上“不工作了”

#### 3. 真正影响当前截帧能否成功的因素

当前更关键的约束通常是：

- `PlayTools` 是否已正确注入
- `metalCaptureEnabled` 是否开启
- 启动模式是**延迟注入**还是**启动期注入**
- `libmtlcapture.dylib` 是否加载成功
- `MTLCaptureManager.supportsDestination(...)` 当前是否真的可用
- 游戏本身对 `GPUToolsCapture` 的兼容性
- 特定图形路径（例如 `MetalFX`）是否导致额外崩溃

这些都比“仅凭结果推断 SIP 没工作”更贴近真实原因。

---

### 五、当前实现里有哪几层 hook / swizzle

当前与截帧相关，可以分成三层理解：

#### 1. PlayTools 自己的 queue discovery swizzle

这是 **PlayCover 自己写的** swizzle。

目的：

- 发现 app 真实使用的 `MTLCommandQueue`
- 记录 queue 的类名、label、device 名称、发现来源
- 后续为 `capture_target=queue` / `queue_scope` 提供真实捕获对象

#### 2. GPUToolsCapture 的内部 hook

这是 **Apple 的 `libmtlcapture.dylib` / GPUToolsCapture** 自己做的 hook，不是 PlayCover 手写的 swizzle。

它会在不同模式下介入 Metal 对象：

- 启动期注入：通过 `DYLD_INSERT_LIBRARIES`
- 延迟注入：通过运行时 `dlopen`

它会影响的对象包括：

- `CAMetalLayer`
- `MTLDevice`
- `MTLCommandQueue`
- 其他被其代理成 `CaptureMTL*` 的对象

#### 3. 兼容性补丁（不是 swizzle，但经常一起讨论）

为了解决 `GPUToolsCapture` 在某些 app 上的兼容性问题，当前实现还增加了：

- `traceStream` / `streamReference` 的 fallback stubs
- `stopCapture` 的 `SIGSEGV` guard

这些不是经典的 `method_exchangeImplementations`，但属于当前 capture runtime 方案的重要组成部分。

---

### 六、当前 capture swizzle 是怎么装上的

#### 1. 初始化入口

`PlayTools` runtime 启动时，`PlayCover.launch()` 会先初始化 `MetalCaptureService`：

- `MetalCaptureService.shared.initialize()`
- 如有需要再 `prepareForLibrarySourceAttributionIfNeeded()`
- 然后才安装 `makeLibrary(...)` 那套 swizzle

这说明：

- **capture 相关发现逻辑优先安装**
- 之后才进入 shader replacement 相关 hook

#### 2. `initialize()` 里做什么

`MetalCaptureService.initialize()` 当前不会立刻抓 `MTLCaptureManager.shared()`，而是先执行：

- `installQueueDiscoveryIfNeeded()`

这样做的原因是：

- 避免在 `libmtlcapture.dylib` 尚未加载前就过早缓存一个“不支持 capture destination”的 `MTLCaptureManager`

也就是说，**queue discovery swizzle 会比 capture manager 真正使用更早装上。**

---

### 七、当前到底 swizzle 了哪两个方法

`installQueueDiscoveryIfNeeded()` 当前 hook 的是运行时 `MTLDevice` 上的两个实例方法：

1. `newCommandQueue`
2. `newCommandQueueWithMaxCommandBufferCount:`

这两个方法是 queue 创建的关键入口。

只要目标 app 通过默认 `MTLDevice` 创建 command queue，我们就能在这里拿到返回值并记录下来。

---

### 八、当前 swizzle 的实现方式

当前使用的是标准 Objective-C runtime 交换实现：

- `class_getInstanceMethod`
- `class_addMethod`
- `method_exchangeImplementations`

整体逻辑是：

1. 找到目标类上的原始方法
2. 找到 `CommandQueueDiscoverySwizzles` 里的替代实现
3. 交换二者实现地址
4. 外部继续调用原始 selector
5. 实际先进我们的 `pc_*` 方法
6. 在 `pc_*` 方法内部再回调“交换后的原始实现”

这样就达成了：

- **不改变调用点**
- **先执行自定义逻辑，再执行原始逻辑**
- **最后把原始返回值照常返回**

---

### 九、当前 swizzle 回调里具体做了什么

#### 1. 先调用原始实现

`pc_newCommandQueue()` 和 `pc_newCommandQueueWithMaxCommandBufferCount(...)` 的第一步，都是先调用原始实现，拿到真正创建出来的 queue。

#### 2. 再做诊断和记录

拿到 queue 之后，会记录：

- `isa` class
- `type(of:)`
- 是否响应 `traceStream`
- class hierarchy
- 发现来源（`newCommandQueue` 或 `newCommandQueueWithMaxCommandBufferCount(...)`）

这样做的一个关键目的，是判断：

> 当前拿到的 queue 是不是已经被 `GPUToolsCapture` 代理成 `CaptureMTLCommandQueue`

#### 3. 最后原样返回 queue

也就是说，当前 queue discovery swizzle **不直接篡改 queue 行为本身**。

它主要承担的是：

- **观测**
- **缓存**
- **为后续 capture 选择真实对象**

而不是“把渲染逻辑替换成别的东西”。

---

### 十、为什么当前一定要记录真实 queue

因为当前 capture 不是只有一种模式。

除了以 default Metal device 为捕获对象，还支持：

- `queue`
- `queue_scope`

这两种模式都要求我们能拿到一个真实、近期仍在使用的 `MTLCommandQueue`。

所以当前 swizzle 的结果会进入内部 `trackedCommandQueues` 缓存，供后续：

- `latestTrackedCommandQueue()`
- `makeCaptureScope(commandQueue:)`
- `capture_target=queue` / `queue_scope`

使用。

换句话说：

> **当前 swizzle 的直接价值，不是替换渲染，而是“找出真正值得截帧的 queue”。**

---

### 十一、GPUToolsCapture 与当前 swizzle 的关系

#### 1. 两者不是同一层

当前必须区分：

- **PlayTools 自己的 swizzle**：拦 `newCommandQueue`
- **GPUToolsCapture 的内部 hook**：拦 `CAMetalLayer`、包装 `MTLDevice` / `MTLCommandQueue` 等对象

前者是我们写的。后者是 Apple 私有 capture 框架干的。

#### 2. 当前代码会显式检测 GPUToolsCapture 是否已加载

当前实现会用类似下面的方式判断：

- 是否存在 `CaptureMTLDevice` 类

如果已经存在，说明：

- `libmtlcapture.dylib` 已经通过启动期注入提前生效
- 当前拿到的 device / queue 可能已经是 `CaptureMTL*` 代理对象

这正是为什么当前 swizzle 里会打印 queue class hierarchy 和 `traceStream` 能力。

#### 3. 当前两层是叠加工作的

真实运行时，经常是下面这种叠层关系：

1. app 启动
2. PlayTools 装 queue discovery swizzle
3. 视模式不同，`libmtlcapture.dylib` 通过 `DYLD_INSERT_LIBRARIES` 或 `dlopen` 加入
4. GPUToolsCapture 开始代理部分 Metal 对象
5. 我们的 swizzle 继续记录这些对象，判断它们是否已经变成 `CaptureMTL*`
6. `capture_metal_frame` 再根据当前状态选择 `device` / `scope` / `queue` / `queue_scope`

所以当前并不是“只有一层 hook”。

---

### 十二、为什么还需要 compat stubs

这是当前实现里很关键的一点。

#### 1. 问题来源

`GPUToolsCapture` 会在某些路径里调用私有 selector，例如：

- `traceStream`
- `streamReference`

但某些对象如果是在 capture 框架加载之前就创建出来的，它们不一定已经被代理或补齐这些方法。

结果就是：

- `doesNotRecognizeSelector`
- `SIGABRT`
- 启动期或延迟注入阶段崩溃

#### 2. 当前方案

当前通过 `GuardedCapture.m` 在 `NSObject` 上注入 nil-returning fallback stubs。

并且这件事是通过：

- `__attribute__((constructor))`

在 PlayTools 被 dyld 加载时尽早完成。

#### 3. 这不是 swizzle

这里没有交换实现，而是：

- 如果 `NSObject` 还没有这个 selector
- 就用 `class_addMethod` 动态补一个实现
- 让对象至少不会因为缺 selector 而崩溃

因此它更准确叫：

- **compat stub**
- **runtime method injection**

不是经典意义上的 swizzle。

---

### 十三、为什么还需要 `SIGSEGV` guard

即使前面都不崩，延迟注入模式下仍可能出现另一类问题：

- Metal 对象创建太早
- `GPUToolsCapture` 没能完整代理命令流
- `stopCapture()` 时内部落到空 trace context
- 触发 `SIGSEGV`

当前通过 `GuardedCapture.m` 把 `manager.stopCapture()` 包进：

- `sigsetjmp`
- `siglongjmp`
- 自定义 `SIGSEGV` handler

这样即使遇到 empty trace 导致的崩溃，也能：

- 恢复执行
- 把结果标记成 `lastCaptureWasEmptyTrace=true`
- 继续给外部返回“当前 capture 失败/为空”的诊断信息

---

### 十四、项目里还有另一套 swizzle：`makeLibrary(...)`

这一套不直接负责 `capture_metal_frame`，但和当前 Metal 相关文档经常一起被提到。

它的作用是：

- hook `MTLDevice.makeLibrary(...)` / `newLibraryWithData(...)` 等路径
- 观测 metallib 或源码编译链路
- 支持 shader source extraction / replacement

它和当前 capture swizzle 的关系是：

- **实现模式相同**：也使用 `method_exchangeImplementations`
- **初始化顺序相邻**：在 `PlayCover.launch()` 里先处理 capture，再装这套 library hook
- **目标不同**：它关心的是 shader library 创建，不是 command queue 发现

因此在讲“当前 swizzle 原理”时，最好把这两套分开，不要混成一个概念。

---

### 十五、当前可以怎么对外解释

如果别人问：

> 你们是不是通过修改 macOS API 行为、让 SIP 失效，才把截帧做成的？

更准确的回答应该是：

> 不是。当前方案是在目标 app 进程内部安装运行时 swizzle / hook，观测并记录 Metal queue，再调用 Apple 自带的 capture 能力导出 `.gputrace`。PlayCover 还额外处理了 `GPUToolsCapture` 的兼容性问题，但这不等于系统级的 SIP 失效。

如果要再压缩一点，可以说：

> 当前成功的关键不是“让 SIP 不工作”，而是“让目标进程内的 Metal capture 链路工作起来”。

---

### 十六、最终总结

只记住三句话即可：

1. **SIP 是 macOS 系统完整性保护，不等于一切 hook 都会被禁止。**
2. **PlayCover 当前截帧成功，说明的是目标 app 进程内的 runtime capture 链路跑通了，不等于 SIP 失效。**
3. **当前与截帧直接相关的 swizzle，核心是 hook `MTLDevice.newCommandQueue(...)` 创建路径，记录真实 queue，再把它交给 `MTLCaptureManager` 使用。**
