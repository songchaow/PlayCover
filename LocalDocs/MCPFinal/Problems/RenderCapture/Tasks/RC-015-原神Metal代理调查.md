## RC-015：原神 Metal 对象未被 GPUToolsCapture 代理的调查

### 一、任务目标

调查启动期注入模式下，为什么原神的 `tracked queue class` 是 `AGXG16XFamilyCommandQueue` 而非 `CaptureMTLCommandQueue`，导致 trace 产物为空。

### 二、状态

**DONE** — **原神截帧成功！357MB `.gputrace` 产物。**

### 三、关键发现

#### 3.1 根因：之前测试时 PlayTools 未正确更新到 app 中

RC-014 报告 tracked queue class 为 `AGXG16XFamilyCommandQueue` 的结论**有误**。实际原因是：
- 修改 PlayTools 代码后，需要完整执行 `sync_playtools_xcframework.sh` → `build_and_install.sh` → **重启 PlayCover** → 重新启动 app
- 如果 PlayCover 没有重启，旧的 PlayTools.framework 可能仍被使用
- RC-014 测试时可能因为 PlayCover 未重启，导致 app 内运行的 PlayTools 版本与预期不一致

#### 3.2 启动期注入确实有效

在正确重建+安装+重启后，启动期注入模式下：

| 指标 | 结果 |
|---|---|
| tracked queue class | `CaptureMTLCommandQueue` ✅ |
| tracked queue count | 2 |
| `supportsGPUTrace` | true |
| `lastCaptureWasEmptyTrace` | false ✅ |
| `stopCapture` | 正常完成（无 SIGSEGV）✅ |
| trace 产物 | **357MB**（922 files）✅ |
| 原神进程 | 截帧后仍存活 ✅ |

#### 3.3 GPUToolsCapture 确实代理了原神的 Metal 管线

`get_capture_status` 返回：
```
latestTrackedQueue=class=CaptureMTLCommandQueue, label=nil, device=Apple M4 Pro, source=newCommandQueue
```

这证明：
1. `GPUToolsCapture`（通过 `DYLD_INSERT_LIBRARIES` 启动期注入）成功 hook 了 `MTLDevice.newCommandQueue`
2. 原神创建的 command queue 被正确包裹为 `CaptureMTLCommandQueue` 代理
3. PlayTools 的 queue discovery swizzle 记录到的是代理后的 queue

### 四、RC-015 诊断代码

为了调查此问题，在 `MetalCaptureService.swift` 中添加了以下诊断功能：

1. **`logRC015PreSwizzleDiagnostics()`**：swizzle 前检查 IMP 地址、`CaptureMTLCommandQueue` 类是否存在、device 类型、probe queue 类型
2. **`logRC015PostSwizzleDiagnostics()`**：swizzle 后验证 IMP 已交换
3. **`logRC015CaptureClasses()`**：枚举所有 `Capture*`/`GTTrace*`/`GPUTools*` ObjC 类（C 层实现，避免 Swift runtime 崩溃）
4. **`logRC015CaptureFrameDiagnostics()`**：captureFrame 时一次性输出所有 tracked queue 的深度信息
5. **`classHierarchyString()`**：辅助方法，输出对象的完整类继承链

`CommandQueueDiscoverySwizzles` 的回调中也添加了深度日志，记录每个 queue 的 isa、type、traceStream 响应情况和类继承链。

在 `GuardedCapture.m` 中新增了 `PlayTools_logGPUToolsCaptureClasses()` C 函数，用纯 ObjC runtime 枚举类，避免 Swift `objc_copyClassList` → `swift_dynamicCast` 在 GPUToolsCapture 未完全初始化的类上崩溃。

### 五、遇到的问题

#### 5.1 Swift 类枚举崩溃

初始版本在 Swift 中用 `objc_copyClassList` + `NSStringFromClass` 遍历所有 ObjC 类时，触发了 `swift_dynamicCast` → `___forwarding___.cold.4` → `EXC_BREAKPOINT` 崩溃。原因是 GPUToolsCapture 注册的某些类未完全初始化，Swift runtime 在尝试动态类型检查时失败。

**解决方案**：将类枚举移到 `GuardedCapture.m` 中用纯 C/ObjC 实现（`class_getName` + `strncmp`）。

### 六、兼容性矩阵（最终）

| App | 延迟注入启动 | 延迟注入截帧 | 启动期注入启动 | 启动期注入截帧 |
|---|---|---|---|---|
| QQ飞车 | ✅ | ✅ 413MB | ✅ | ✅ 124MB |
| 原神 | ✅ | 空 trace | ✅ (需关闭MetalFX) | **✅ 357MB** |

### 七、结论

1. 原神截帧**已成功**，启动期注入 + 关闭 MetalFX 是有效的截帧方案
2. RC-014 关于"原神与 GPUToolsCapture 根本不兼容"的结论**需要修正** — 实际上是兼容的，之前结论有误
3. 延迟注入模式下 trace 为空是预期行为（queue 在 GPUToolsCapture 加载前已创建，不会被代理）
4. 最终目标**已达成**：原神成功执行 `capture_metal_frame`，生成非空 `.gputrace` 文件
