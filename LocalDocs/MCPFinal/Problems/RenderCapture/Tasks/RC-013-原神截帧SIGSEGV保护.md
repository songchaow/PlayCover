## RC-013：原神截帧兼容性（续）— SIGSEGV 安全保护

### 一、任务目标

在 RC-012 的基础上继续攻坚，让原神执行 `capture_metal_frame` 时不再崩溃。

### 二、状态

**DONE** — 实现了 SIGSEGV 安全保护。原神可以安全执行 `capture_metal_frame` 而不崩溃，但产物为空 trace（延迟 dlopen 模式的根本限制）。

### 三、问题回顾

RC-012 发现：延迟 dlopen 后调用 `stopCapture` 时，`GPUToolsCapture` 内部的 `GTTraceContextDumpEmptyCapture` 会 SIGSEGV，导致原神崩溃。此前的临时方案是检查 `manager.isCapturing` 来跳过 `stopCapture`，但如果 `isCapturing` 为 `true`（capture 确实在进行中），仍然会崩溃。

### 四、解决方案：SIGSEGV 信号保护

#### 4.1 反汇编分析

通过反汇编 `GPUToolsCapture.framework`，确认了崩溃路径：

```
-[CaptureMTLCaptureManager stopCapture]
  → GTTraceContext_pushEncoderWithStream
  → GTCaptureBoundaryTracker_handleTrigger
    → dispatch_sync block
      → GTTraceContextDumpEmptyCapture  ← SIGSEGV
      → GTTraceContextDumpEnd
```

`stopCapture` 本身是一个简短方法（~30 条指令），最终调用 `GTCaptureBoundaryTracker_handleTrigger`，后者在 dispatch block 中走到 dump 路径触发崩溃。

#### 4.2 方案设计

在调用 `manager.stopCapture()` 前安装 POSIX `SIGSEGV` 信号处理器，使用 `sigsetjmp`/`siglongjmp` 在崩溃时恢复执行。

**为什么用 C 而不是 Swift**：Swift 编译器禁止调用标记了 `returns_twice` 属性的函数（`sigsetjmp`/`setjmp`），因此信号处理核心逻辑必须用 C/ObjC 实现。

#### 4.3 代码改动

1. **新增 `GuardedCapture.h` / `GuardedCapture.m`**：
   - C 模块实现 `PlayTools_guardedStopCapture(block)` 函数
   - 使用 `__thread` 线程局部变量避免多线程冲突
   - 安装 `SA_SIGINFO` 信号处理器，支持获取崩溃地址
   - `sigsetjmp`/`siglongjmp` 实现崩溃恢复
   - 正确保存/恢复前一个信号处理器

2. **修改 `MetalCaptureService.swift`**：
   - `stopActiveCapture()` 使用 `PlayTools_guardedStopCapture` 包裹 `manager.stopCapture()`
   - 新增 `lastCaptureWasEmptyTrace` 标记，记录 SIGSEGV 恢复状态
   - `diagnosticSummary` 中输出 `lastCaptureWasEmptyTrace` 供诊断

3. **修改 `PlayTools.h`**：添加 `#import "GuardedCapture.h"`

4. **修改 `PlayTools.xcodeproj/project.pbxproj`**：添加新文件到构建目标

### 五、验证结果（2026-04-01 00:25）

| 测试项 | 结果 |
|---|---|
| 原神启动（延迟注入模式） | ✅ 正常启动，PID 93583 |
| `create_session` | ✅ `status=ready` |
| `get_capture_status` | ✅ `supportsGPUTrace=true` |
| `capture_metal_frame` | ✅ **不再崩溃！** `startCapture` 成功 |
| `stopCapture` | ✅ SIGSEGV 被捕获并恢复，app 继续运行 |
| 产物 | 空 trace（`store0` 0 bytes），`lastCaptureWasEmptyTrace=true` |
| 原神进程存活 | ✅ 截帧后仍在运行 |

#### 日志确认

```
diagnostic_summary: ...lastCaptureWasEmptyTrace=true...
[PlayTools] RC-013: SIGSEGV at addr 0x... caught inside stopCapture (GTTraceContextDumpEmptyCapture), recovering via siglongjmp
```

### 六、已知限制

产物仍然是空 trace（0 bytes），因为延迟 dlopen 模式下原神的 Metal 对象不被 `GPUToolsCapture` 的 `Capture*` 代理包裹，`GPUToolsCapture` 无法拦截 GPU 命令流。这是 Apple 私有框架的根本架构限制。

**要获得非空 trace**，需要一种方式让 `GPUToolsCapture` 能正确包裹原神的 Metal 对象。可能的方向：
- 启动期注入 + 修复原神的 `CAMetalLayer` 兼容性（目前启动即 SIGABRT）
- 在 `dlopen` 后强制将现有 Metal 对象的 isa 指针切换到 `Capture*` 代理类（极端危险）
- 等待 Apple 修复 `GPUToolsCapture` 对第三方 app 的兼容性

### 七、兼容性矩阵更新

| App | 延迟注入启动 | 延迟注入截帧 | 启动期注入启动 | 启动期注入截帧 |
|---|---|---|---|---|
| QQ飞车 | ✅ | ✅ 413MB .gputrace | ✅ | ✅ 124MB .gputrace |
| 原神 | ✅ | ✅ 不崩溃，但空 trace (RC-013) | ❌ SIGABRT | N/A |
