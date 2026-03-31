## RC-010：dlopen 可行性验证

### 一、任务目标

用独立 Swift CLI 验证：**在不预设 `DYLD_INSERT_LIBRARIES` 的环境下，运行时 `dlopen("/usr/lib/libmtlcapture.dylib")` 后 `MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 能否从 `false` 变为 `true`。**

这是 RC-009 延迟注入方案的前置门槛。

---

### 二、为什么这个验证很关键

`MTLCaptureManager` 是系统单例。存在以下可能性：

- 首次调用 `supportsDestination(.gpuTraceDocument)` 时，Metal 运行时检查当前进程中是否加载了 `GPUToolsCapture`，**并缓存结果**
- 如果是缓存式查询，则在 `dlopen` 之前查询过一次 `false` 后，即使后来加载了库，也永远返回 `false`
- 如果是实时查询，则 `dlopen` 后立即可用

---

### 三、验证方案

编写一个独立 Swift 脚本（不依赖 PlayCover / PlayTools），测试 3 个场景：

#### 场景 A：先查询 → 后 dlopen → 再查询

```swift
import Metal
import Darwin

let manager = MTLCaptureManager.shared()
let before = manager.supportsDestination(.gpuTraceDocument)
print("BEFORE dlopen: supportsGPUTrace = \(before)")

let handle = dlopen("/usr/lib/libmtlcapture.dylib", RTLD_NOW)
print("dlopen result: \(handle != nil ? "success" : "failed: \(String(cString: dlerror()))")")

let after = manager.supportsDestination(.gpuTraceDocument)
print("AFTER dlopen: supportsGPUTrace = \(after)")
```

#### 场景 B：先 dlopen → 后查询（不缓存 false）

```swift
import Metal
import Darwin

let handle = dlopen("/usr/lib/libmtlcapture.dylib", RTLD_NOW)
print("dlopen result: \(handle != nil ? "success" : "failed: \(String(cString: dlerror()))")")

let manager = MTLCaptureManager.shared()
let result = manager.supportsDestination(.gpuTraceDocument)
print("supportsGPUTrace = \(result)")
```

#### 场景 C：先 dlopen → 后获取 MTLCaptureManager（推迟单例初始化）

```swift
import Metal
import Darwin

let handle = dlopen("/usr/lib/libmtlcapture.dylib", RTLD_NOW)
print("dlopen result: \(handle != nil ? "success" : "failed")")

// 延迟获取 — 确保 MTLCaptureManager 单例在库加载后才初始化
let manager = MTLCaptureManager.shared()
let gpuTrace = manager.supportsDestination(.gpuTraceDocument)
let devTools = manager.supportsDestination(.developerTools)
print("supportsGPUTrace = \(gpuTrace)")
print("supportsDeveloperTools = \(devTools)")
```

运行方式：

```bash
# 确保不设 DYLD_INSERT_LIBRARIES
env -i HOME=$HOME PATH=$PATH xcrun swift /tmp/dlopen_probe.swift
```

---

### 四、期望结果矩阵

| 场景 | before dlopen | after dlopen | 含义 |
|---|---|---|---|
| A：先查后加载 | `false` | `true` | **最佳**：实时查询，延迟注入完全可行 |
| A：先查后加载 | `false` | `false` | **缓存问题**：需要在 dlopen 之前避免查询 `supportsDestination` |
| B：先加载后查 | — | `true` | **可行**：只要 dlopen 在首次查询前完成即可 |
| B：先加载后查 | — | `false` | **不可行**：`dlopen` 方式无法激活 `GPUToolsCapture`，需要 `DYLD_INSERT_LIBRARIES` |

---

### 五、如果验证失败的后备思路

如果所有场景都返回 `false`：

1. **检查 `dlopen` 是否真的成功加载了库**：确认 `handle != nil`，且 `GPUToolsCapture` 的符号可解析（如 `dlsym(handle, "MakeLayerInfos")`）
2. **检查是否需要 `METAL_DEVICE_WRAPPER_TYPE=1` 等环境变量配合**：当前 `injectMetalCaptureEnvironment` 开关正好可以测试
3. **检查是否需要 `Info.plist` 中有 `MetalCaptureEnabled=true`**：独立 CLI 没有 `Info.plist`，可能需要用一个真实 app bundle 来测试
4. **最后手段**：如果 `dlopen` 方案不可行，考虑改为只有在用户显式执行 `capture_metal_frame` 前才重启 app（带 `DYLD_INSERT_LIBRARIES`），即"按需重启"策略

---

### 六、状态

`TODO` — 当前最高优先级任务。
