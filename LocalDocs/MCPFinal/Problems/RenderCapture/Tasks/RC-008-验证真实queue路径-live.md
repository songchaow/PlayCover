## RC-008：验证真实 queue 路径 + 定位根因 + 修复

### 一、状态：`DONE`

### 二、任务目标（原始）

验证 `queue` / `queue_scope` 路径是否命中真实渲染 queue 并能成功导出 `.gputrace`。

### 三、执行过程与结论

#### 阶段 1：queue / queue_scope live 验证（16:24–16:30）

- runtime 成功发现 4 个真实 `MTLCommandQueue`（类名 `CaptureMTLCommandQueue`）
- `queue` 和 `queue_scope` 两条路径都失败于 `startCapture failed: Capturing is not supported.`
- 错误文本与 `device` / `scope(device)` 完全一致
- **结论**：阻塞点不在 capture object 选择，而在 `supportsDestination(.gpuTraceDocument) == false`

#### 阶段 2：根因定位（16:47–17:00）

- Apple 文档明确说编程式截帧是标准功能，需要 `Info.plist` 中 `MetalCaptureEnabled=true`（已有）
- 社区经验指出需要 `/usr/lib/libmtlcapture.dylib`（系统中存在，是 `GPUToolsCapture.framework` 的符号链接）
- 实验验证：**`DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib` 使 `supportsDestination(.gpuTraceDocument)` 变为 `true`**
- 发现 MCP 的 `launchApp` 使用 `/usr/bin/open`，**不会传递环境变量到目标 app**

#### 阶段 3：修复（17:00–17:08）

代码修改：

1. **`PlayCover/Model/PlayApp.swift`**：`effectiveLaunchEnvironment()` 当 `metalCaptureEnabled=true` 时注入 `DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib`
2. **`PlayCoverMCP/HostServices/Launch/LaunchService.swift`**：
   - 同样注入 `DYLD_INSERT_LIBRARIES`
   - `launchApp()` 从 `/usr/bin/open` 改为 `NSWorkspace.openApplication`，以正确传递环境变量

#### 阶段 4：验证成功（17:07–17:08）

- `get_capture_status`：`supports_gpu_trace=true`，`failure_reason=none`
- `capture_metal_frame`：成功，产物 124MB
- 产物路径：`/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_170807.gputrace`

### 四、根因总结

Apple 的 `MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 依赖 `/usr/lib/libmtlcapture.dylib`（`GPUToolsCapture.framework`）被加载到进程中。Xcode 在 GPU Frame Capture debug 模式下会自动注入这个库。PlayCover 此前的启动路径没有注入该库，导致所有 `startCapture` 调用都被 Apple 拒绝。
