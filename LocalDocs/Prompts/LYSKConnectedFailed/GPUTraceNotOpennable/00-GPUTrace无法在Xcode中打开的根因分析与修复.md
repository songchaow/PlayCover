# GPUTrace 无法在 Xcode 中打开的根因分析与修复

## 一、问题现象

恋与深空（LYSK）通过 PlayCover MCP 的 `capture_metal_frame` 截帧后，产出的 `.gputrace` 文件在 Xcode 中打开时：

- 弹窗报错："GPU Capture is empty — No GPU commands have been captured. At least one command buffer must be created and committed within the boundaries of a GPU Capture."
- Overview 面板能显示统计信息（如 369 Draw Calls、84 Render Encoders），但左侧 "Group by API Call" 无法展开，无法逐 draw call 调试。
- Memory 面板正常显示纹理/Buffer 资源。

## 二、调查过程

### 2.1 排除沙盒权限问题

`.gputrace` 文件位于 `~/Library/Containers/com.papegames.lysk/` 沙盒内，所有文件都带有 `com.apple.quarantine` 扩展属性。通过 `xattr -rd com.apple.quarantine` 递归清除后，Xcode 仍报同样错误 → **权限不是根因，但每次新截帧都需要清除。**

### 2.2 排除 capture scope boundary 问题

对比 QQ飞车成功 trace 的 metadata，发现 `boundaryLess=false` 在两者中相同。尝试在 `device` / `queue_scope` / `scope` 多种 target 之间切换，均无效 → **不是 scope boundary 标记导致的。**

### 2.3 定位 `libmtlcapture.dylib` 路径失效（第一个根因）

启用 `injectMetalCaptureEnvironment=true` 后 LYSK 直接闪退。通过命令行复现发现：

```
dyld: terminating because inserted dylib '/usr/lib/libmtlcapture.dylib' could not be loaded
```

**在当前 macOS 26.4.1 上，`/usr/lib/libmtlcapture.dylib` 已不存在。** GPU capture 库已迁移到 `/System/Library/PrivateFrameworks/GPUToolsCapture.framework/GPUToolsCapture`。

### 2.4 定位延迟注入模式下 Capture 代理缺失（第二个根因）

修复路径后，对比延迟 dlopen 和启动期注入两种模式的 trace：

| 模式 | device-resources 中的 queue 类型 | trace 中有 presentDrawable 记录 | Xcode 能打开 |
|------|------|------|------|
| 延迟 dlopen | `command-queue`（原始类） | ❌ | ❌ |
| 启动期注入 | `CaptureMTLCommandQueue`（代理类） | ✅ | 取决于下一步 |

**延迟 dlopen 模式下，Metal 对象在 GPUToolsCapture 加载前已创建，不会被 `Capture*` 代理包装。** 因此 `presentDrawable`、command buffer commit 等事件不会被 trace 引擎记录。Xcode 虽能解析资源数据，但缺少命令流 → 报 "empty"。

### 2.5 定位 PlayTools swizzle 破坏代理链（第三个根因）

启用启动期注入后，Capture* 代理存在，但 Xcode 仍报 empty。通过编写 4 个递进的最小复现测试：

1. ✅ 同步 blit encoder → Xcode 正常
2. ✅ 异步多帧 render pass → Xcode 正常
3. ✅ CAMetalLayer + presentDrawable → Xcode 正常
4. ✅ 渲染已在进行中时启动 capture → Xcode 正常

所有测试都成功，说明 Xcode 和 `MTLCaptureManager` 本身没有问题。

最终定位到：**PlayTools 的 `MetalCaptureService` 在初始化时对 `CaptureMTLDevice` 的 `newCommandQueue` 和 `CaptureMTLCommandQueue` 的 `commandBuffer`/`commit` 做了 `method_exchangeImplementations` swizzle。这些 swizzle 破坏了 GPUToolsCapture 代理类的内部 dispatch 链，导致 command buffer 的 commit 事件没有被 trace 引擎记录。**

具体机制：GPUToolsCapture 的 `CaptureMTLCommandQueue` 在 `commandBuffer` 方法内部会进行 tracing 注册，在 `commit` 方法内部会写入 trace 数据。PlayTools 的 swizzle 将这些方法的 IMP 替换为 `pc_commandBuffer` / `pc_commit`，虽然 swizzle 方法内部会回调原始实现（通过 `self.pc_xxx()` 的 IMP 交换技巧），但 GPUToolsCapture 代理的内部状态机可能依赖于方法调用者的 IMP 地址或调用栈上下文来判断是否处于 "capturing" 状态，swizzle 后这些条件不再满足。

## 三、修复方案（RC-017）

### 3.1 修复 GPUToolsCapture 库路径（3 处）

| 文件 | 修改 |
|------|------|
| `PlayCover/Model/PlayApp.swift` | `gpuToolsCaptureLibrary` 改为运行时自动检测 |
| `PlayCoverMCP/HostServices/Launch/LaunchService.swift` | 同上 |
| `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` | dlopen 路径改为候选列表 |

候选路径（按优先级）：
1. `/usr/lib/libmtlcapture.dylib`（旧版 macOS）
2. `/System/Library/PrivateFrameworks/GPUToolsCapture.framework/GPUToolsCapture`（新版 macOS）

### 3.2 启动期注入时跳过 swizzle 安装

在 `installQueueDiscoveryIfNeeded()` 入口检测 `CaptureMTLDevice` 类是否存在：

```swift
if NSClassFromString("CaptureMTLDevice") != nil {
    // 启动期注入已激活，Capture* 代理已全覆盖
    // 跳过 swizzle 以避免破坏代理内部 dispatch 链
    return
}
```

这会同时跳过：
- `newCommandQueue` / `newCommandQueueWithMaxCommandBufferCount:` 的 discovery swizzle
- 后续触发的 `commandBuffer` / `commit` 的 activity swizzle

### 3.3 根据注入模式自动选择 capture target

| 模式 | 自动选择的 target | 原因 |
|------|------|------|
| 启动期注入（`CaptureMTLDevice` 存在） | `.device` | 无 swizzle → 无 tracked queue → 不能用 `queue_scope` |
| 延迟 dlopen | `.queueScope` | 有 swizzle → 有 tracked queue → scope boundary 需要 queue |

### 3.4 MCP 侧不再硬编码默认 target

`CaptureFrameParams.captureTarget` 从 `CaptureTarget` 改为 `CaptureTarget?`，默认为 `nil`。当 MCP 不传 `capture_target` 时，runtime 侧的 `MetalCaptureService.captureFrame()` 会根据当前注入模式自动选择。

### 3.5 提高 capture 时间窗口参数

- `minimumVsyncStopThreshold`：2 → 4（确保覆盖低帧率场景下的完整帧）
- `minimumCaptureDurationMs` / `durationMs` 默认值：100ms → 200ms

## 四、修复的适用范围与局限性

### 4.1 启动期注入模式（`injectMetalCaptureEnvironment=true`）

**✅ 完全有效。** 这是 LYSK 及所有 Unity 系 app 截帧的推荐模式。

- GPUToolsCapture 在 dyld 阶段加载，所有 Metal 对象从创建时就被代理
- PlayTools 不做 swizzle，不干扰代理链
- `device` target capture 正常工作
- Xcode 能完整展示 draw call 列表

### 4.2 延迟 dlopen 模式（默认模式，`injectMetalCaptureEnvironment=false`）

**⚠️ 部分有效，但存在固有局限。**

- 对于 Metal 对象在 GPUToolsCapture 加载**之后**创建的 app（如 QQ飞车），截帧正常
- 对于 Metal 对象在加载**之前**已创建的 app（如原神、LYSK），trace 中会缺少命令流数据
- PlayTools 的 swizzle 在此模式下仍然工作（因为不存在 Capture* 代理类）
- 这不是 RC-017 引入的退化 — 这是延迟 dlopen 模式的固有约束，与修复前一样

### 4.3 是否"只能用启动期注入模式了"？

**不是。** 两种模式仍然并存：

- **延迟 dlopen（默认）**：所有 app 安全启动，兼容 app 可截帧。这是保守的安全默认值。
- **启动期注入**：需要手动开启 `injectMetalCaptureEnvironment=true`。对 LYSK、原神等 Unity app 是截帧的**必要条件**。对某些 app 可能导致启动崩溃（如原神需要先关闭 MetalFX）。

RC-017 的修复只是确保：当用户选择启动期注入模式时，PlayTools 不再干扰 GPUToolsCapture 的工作。

## 五、修改文件清单

| 文件 | 修改内容 |
|------|------|
| `PlayCover/Model/PlayApp.swift` | `gpuToolsCaptureLibrary` 路径自动检测 |
| `PlayCoverMCP/HostServices/Launch/LaunchService.swift` | 同上 |
| `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift` | dlopen 路径候选列表 + 启动期注入时跳过 swizzle + 自动选择 capture target + 提高时间窗口 |
| `PlayCoverMCP/Session/CaptureService.swift` | `CaptureFrameParams.captureTarget` 改为 Optional |
| `PlayCoverMCP/Tools/Session/CaptureTools.swift` | 默认 target 改为 nil（让 runtime 自动选择） |
