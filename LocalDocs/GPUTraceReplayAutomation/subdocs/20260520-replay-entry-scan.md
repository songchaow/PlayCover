## 目标

记录 2026-05-20 这一轮静态与动态扫描中，已经确认的 replay 自动化入口、关键进程、符号锚点与缓存路径。此文档偏细节，供后续 `R1` 主线任务引用。

## 已确认模块

- `GPUDebugger.ideplugin`
- `GPUTools.framework`
- `GPUToolsServices.framework`
- `GPUToolsShaderProfiler.framework`
- `GPUToolsPlatform.framework`
- `GPUToolsDesktopFoundation.framework`
- `DVTInstrumentsFoundation.framework`
- `DVTInstrumentsUtilities.framework`
- `GPU.instrdst` (`com.apple.gpu-tracing`)
- `GPUCounters.instrdst` (`com.apple.gpu-counters`)

## 已确认进程

在当前 Xcode 正在 replay 时，观察到以下关键进程：

- `Xcode`
- `GPUToolsCompatService`
- `GPUToolsAgentService`
- `GPUToolsReplayService.xpc`
- `GTLLVMHelper`

其中最关键的新发现是：**`GPUToolsReplayService.xpc` 明确存在且处于运行态**。

## 已确认的高价值符号 / 字符串

### `GPUDebugger`

- `com.apple.gputools.MTLReplayer`
- `com.apple.gputools.replay`
- `GTErrorKeyGputracePath`
- `GTErrorKeyReplayerContext`
- `GTErrorKeyReplayerBreadcrumbs`
- `GTErrorKeyReplayerActivityLog`
- 多组 `GPUTraceShaderProfiler*` / `GPUTrace*` 相关符号

### `GPUToolsServices`

- `ReplayerLaunch`
- `-[DYCaptureSession _activateWithSession:serial:invalidationCompletion:initiatedByInferior:replayerLaunchDictionary:]`
- `+[DYDevice replayerAppIdentifier]`
- `-[DYDevice needsGPUToolsServiceBeforePlayback]`
- `-[DYGuestApp shouldLoadReplayer]`
- `-[DYGuestApp setShouldLoadReplayer:]`
- `-[DYGuestAppSession hardwareCountersConfiguration]`
- `_OBJC_IVAR_$_DYCaptureSession._replayerLaunchDictionary`
- `_OBJC_IVAR_$_DYGuestAppSession._hardwareCountersConfiguration`

### `GPUToolsShaderProfiler`

- `derivedCountersData`
- `exportDerivedCounterDataAtPath:renameWhenConflict:`
- `DerivedCounters`
- `RawCounterData`
- `DYShaderProfilerProgramInfo` 相关对象

### `GPUToolsReplayService`

- 可执行字符串直接包含：`com.apple.gputools.replay`
- 当前 `nm -m` 没有快速扫出明显公开符号，后续应优先从 ObjC runtime、class-dump 等方向继续挖。

## 已确认的文件访问关系

### `GPUToolsCompatService`

已观察到它直接打开：

- `.gputrace/startup-0-platform`
- `.gputrace/store0`
- `.gputrace/device-resources-*`

结论：它与 **bundle 兼容读取 / 预处理** 高度相关。

### `GPUToolsReplayService`

已观察到它直接打开：

- `.gputrace/store0`
- `AGXMetalG16X` 相关驱动与资源
- `GPUToolsReplay.framework/Resources/default.metallib`
- `/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/.../functions.list`
- `/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/.../functions.data`
- `/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/.../libraries.list`
- `/private/var/folders/.../C/com.apple.gputools.GPUToolsReplayService/com.apple.metal/.../libraries.data`

结论：它不只是“挂名存在”，而是在**直接消费 replay 所需的 capture 数据和 shader/library 缓存**。

## Instruments package 侧信息

### `GPU.instrdst`

- package id：`com.apple.gpu-tracing`
- 文档写明：包含 `Metal System Trace` 与其他 system level graphics libraries 的 instrument 与 modeling logic
- 模板包括：
  - `Metal System Trace`
  - `Game Performance`
  - `Game Memory`
  - `Game Performance Overview`

### `GPUCounters.instrdst`

- package id：`com.apple.gpu-counters`
- 文档写明：包含 GPU Counters 的 instrument 与 modeling logic
- 已见 schema：
  - `metal-gpu-counter-intervals`
  - `metal-gpu-counter-profile`

## 当前判断

- 当前 replay 自动化通路更接近：
  - **Xcode / GPUDebugger 前端**
  - **`GPUToolsServices` 中的 `DY*` 对象模型**
  - **`GPUToolsCompatService` / `GPUToolsAgentService` / `GPUToolsReplayService` 的分工协作**
  - **`GPU.instrdst` / `GPUCounters.instrdst` 提供的 modeler 与 schema**
- 目前还不能把它简化成“单个私有 ABI”。
- 当前最值得继续深挖的是：
  - `replayerLaunchDictionary`
  - `hardwareCountersConfiguration`
  - `GPUToolsReplayService` 的运行时类与入参面

## 建议的下一步

- 最高优先级继续执行 `R1.1`：
  - 导出 `GPUToolsServices` / `GPUToolsReplayService` 的类、selector、property、ivar。
  - 目标是画出最小对象图，而不是立即尝试注入或手工构造 replay。
