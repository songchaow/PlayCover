## RC-010：dlopen 可行性验证

### 一、任务目标

用独立 Swift CLI 验证：**在不预设 `DYLD_INSERT_LIBRARIES` 的环境下，运行时 `dlopen("/usr/lib/libmtlcapture.dylib")` 后 `MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 能否从 `false` 变为 `true`。**

这是 RC-009 延迟注入方案的前置门槛。

---

### 二、验证结果（2026-03-31 22:46）

运行环境：Apple M4 Pro, macOS

#### 场景 A：先查询 → dlopen → 再查询

```
[A] BEFORE dlopen: supportsGPUTrace = false
[A] BEFORE dlopen: supportsDeveloperTools = false
[A] dlopen: SUCCESS (handle=0x000000007e3c7f70)
[A] AFTER dlopen: supportsGPUTrace = false          ← 缓存！原始实例不刷新
[A] AFTER dlopen: supportsDeveloperTools = false
```

**场景 A2**（dlopen 后重新获取 `shared()`）：

```
[A2] Re-acquired manager supportsGPUTrace = true    ← 新实例返回 true！
[A2] Same instance as A? false                       ← 确认是新实例
```

#### 场景 B：先 dlopen → 后查询

```
[B] dlopen: SUCCESS (handle=0x000000007e3c7f70)
[B] supportsGPUTrace = true                          ← 直接成功
[B] supportsDeveloperTools = false
```

---

### 三、结论

| 场景 | 结果 | 含义 |
|---|---|---|
| A：先查后加载（原实例） | `false` → `false` | `MTLCaptureManager` 单例缓存了首次查询结果 |
| A2：先查后加载（重新 `shared()`） | → `true` | **dlopen 后重新获取 `shared()` 可以刷新状态** |
| B：先加载后查 | → `true` | **dlopen-first 方案完全可行** |

**关键发现**：

1. **`dlopen` 方案可行** ✅ — `supportsDestination(.gpuTraceDocument)` 在 `dlopen` 后能返回 `true`
2. **必须在 `dlopen` 后重新获取 `MTLCaptureManager.shared()`** — 已缓存的实例不会刷新
3. **最佳策略**：不在 `initialize()` 中获取 `captureManager`，而是在首次 `captureFrame()` / `getStatus()` 时先 `dlopen` 再获取

---

### 四、实施（RC-009）

基于验证结果，已直接实施 RC-009 延迟注入方案：

**代码改动**：

1. **`PlayCover/Model/PlayApp.swift`**：移除 `effectiveLaunchEnvironment()` 中的 `DYLD_INSERT_LIBRARIES` 注入
2. **`PlayCoverMCP/HostServices/Launch/LaunchService.swift`**：同上
3. **`Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`**：
   - 新增 `ensureGPUToolsCaptureLoaded()` 方法：`dlopen` + 重新获取 `captureManager`
   - `initialize()` 不再获取 `captureManager`（避免缓存 `false`）
   - `captureFrame()` 和 `getStatus()` 中在使用前调用 `ensureGPUToolsCaptureLoaded()`

---

### 五、状态

`DONE` — 验证通过，RC-009 已实施。

验证脚本保留在 `/tmp/dlopen_probe.swift` 和 `/tmp/dlopen_probe_b.swift`。
