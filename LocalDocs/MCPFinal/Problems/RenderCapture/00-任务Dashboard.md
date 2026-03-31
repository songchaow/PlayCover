## Render Capture：任务 Dashboard

### 一、文档目的

这份文档是 **每个 agent 的统一入口**。

要求：

- **先读它，再开始工作**
- **主文档保持简洁**，只保留背景、目标、流程、当前优先级与任务状态
- **详细过程、日志、假设、实验结果** 统一下沉到子文档
- agent 结束时要**整理并重写**本页，而不是只在末尾追加

---

### 二、问题背景

PlayCover MCP 需要对真实 app 成功执行 `capture_metal_frame`，生成 `.gputrace` 文件。

截至 2026-03-31 晚，**截帧功能已基本打通，但存在已知兼容性问题**：

- 根因是启动 iOS app 时缺少 `/usr/lib/libmtlcapture.dylib` 的注入
- 该库是 Apple GPU Tools Capture 的核心组件（`GPUToolsCapture.framework`），Xcode 在 debug 模式下会自动注入
- 没有它，`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 始终返回 `false`
- 已修改 GUI 和 MCP 两条启动路径，当 `metalCaptureEnabled=true` 时通过 `DYLD_INSERT_LIBRARIES` 自动注入该库
- **QQ飞车** 已成功通过 `capture_metal_frame` 生成 124MB 的真实 `.gputrace`
- **⚠️ 新发现**：**原神** 在 `metalCaptureEnabled=true` 时启动崩溃（`SIGABRT`），根因是 `GPUToolsCapture` 的启动期 hook 与原神的 `CAMetalLayer` 初始化不兼容（详见第六节）

---

### 三、最终目标

> **用真实 app 成功执行 `capture_metal_frame`，生成可验证的 `.gputrace` 文件，并沉淀稳定 SOP。截帧功能不应导致不需要截帧的 app 崩溃。**

完成标准：

- `QQ飞车` 或其他真实 app 能成功 `launch_app` ✅
- `create_session` 返回 `ready` ✅
- `capture_metal_frame` 成功返回，并实际生成 `.gputrace` ✅
- 结果与 app 内成功路径相互印证 ✅
- 开启 `metalCaptureEnabled` 不会导致不兼容 app 启动崩溃 → `RC-009` 待解决
- 输出一份可重复执行的验证步骤 → `RC-004` 待完成

---

### 四、Agent 工作流（强约束）

每个 agent **只做一个任务**。

标准流程：

1. **先读取本 Dashboard**
2. **只领取一个当前最重要的任务**，不要同时做多个
3. 如果发现该任务过大：
   - 先把它拆成更小的子任务写回 Dashboard
   - **本轮只完成其中一个子任务**
4. 详细调查过程写入对应子文档，不把长日志堆到主文档
5. 收尾时必须更新：
   - 本 Dashboard 的任务状态 / 优先级 / 当前最重要任务
   - 对应子文档的结论、证据、下一步建议
6. 更新时要**整理已有内容**：
   - 删掉过时事项
   - 合并重复项
   - 把不再重要的信息移出主文档

禁止事项：

- **禁止一个 agent 长时间死磕最终目标**
- **禁止把"连续多次尝试 capture"当成一个单独任务无限延长**
- **禁止只追加、不整理主文档**

---

### 五、构建 / 安装约束

Render Capture 相关联调如果涉及：

- 重建 `PlayTools`
- 重建 `PlayCover.app`
- 安装 / 重装 `PlayCover.app`
- 刷新 `PlayTools.xcframework`

则**必须使用 `BuildScripts/` 里的标准脚本执行**，不要手写 `xcodebuild`，也不要手工复制 `.app` 或手工拼装安装步骤。

当前应遵守的默认入口是：

- GUI 构建：`BuildScripts/build_gui.sh`
- GUI 构建并安装：`BuildScripts/build_and_install.sh`
- `PlayTools.xcframework` 同步：`BuildScripts/sync_playtools_xcframework.sh`
- Render Capture 专项验证：`BuildScripts/verify_render_capture.sh`

这条规则属于 **Render Capture 主文档级约束**，不能只写在子任务文档里。

---

### 六、当前总体判断

#### 6.1 已打通的能力

截帧核心链路已验证成功（QQ飞车）：

1. **根因**：`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 需要 `/usr/lib/libmtlcapture.dylib`（Apple 私有 `GPUToolsCapture.framework`）被加载到进程中
2. **修复**：在 `PlayApp.effectiveLaunchEnvironment()`（GUI）和 `LaunchService.effectiveLaunchEnvironment()`（MCP）中，当 `metalCaptureEnabled=true` 时，设置 `DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib`
3. **附带修复**：MCP 的 `launchApp` 从 `/usr/bin/open` 改为 `NSWorkspace.openApplication`，以正确传递环境变量到目标 app 进程
4. **验证结果**：`QQ飞车` fresh session 上 `get_capture_status` 返回 `supports_gpu_trace=true`，`capture_metal_frame` 成功落盘 124MB `.gputrace`

#### 6.2 新发现：`DYLD_INSERT_LIBRARIES` 注入导致部分 app 崩溃

**2026-03-31 22:23 发现**：`原神`（`com.miHoYo.Yuanshen`）在 `metalCaptureEnabled=true` 时启动即崩溃。

**崩溃日志关键栈帧**：

```
12  CoreFoundation  -[NSObject(NSObject) doesNotRecognizeSelector:]
13  CoreFoundation  ___forwarding___
15  GPUToolsCapture MakeLayerInfos + 248
16  GPUToolsCapture OpenLayerStream + 168
17  GPUToolsCapture CAMetalLayer_init + 44
18  UIKitCore       -[UIView _createLayerWithFrame:]
19  UIKitCore       UIViewCommonInitWithFrame
```

**崩溃因果链**：

1. `metalCaptureEnabled=true` → PlayCover 注入 `DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib`
2. `libmtlcapture.dylib`（`GPUToolsCapture`）在进程加载时 **全局 hook `CAMetalLayer` 的初始化路径**
3. app 启动 → 创建第一个 `UIView`（含 `CAMetalLayer`）→ `GPUToolsCapture.CAMetalLayer_init` → `MakeLayerInfos`
4. `MakeLayerInfos` 对 layer 对象调用了某个 selector，原神的 layer 子类 / 代理不响应 → `doesNotRecognizeSelector:` → `objc_exception_throw` → `abort()`

**关键结论**：

- `DYLD_INSERT_LIBRARIES` 注入发生在 **进程最早期**（dyld 阶段），`GPUToolsCapture` 的 hook 在第一个 `CAMetalLayer` 创建时就触发
- 这是一个 **启动期同步崩溃**，app 代码无法捕获或绕过
- QQ飞车不崩溃是因为它的 `CAMetalLayer` 使用方式恰好兼容 `GPUToolsCapture` 的 hook
- 不同 app 对 `CAMetalLayer` 的子类化 / 包装方式不同，所以兼容性因 app 而异

**临时修复**：已将原神的 `metalCaptureEnabled` 关闭为 `false`。

#### 6.3 当前方案的限制

| 限制 | 说明 |
|---|---|
| **app 兼容性不可预知** | 无法提前判断哪些 app 会因 `GPUToolsCapture` hook 崩溃，只能逐 app 实测 |
| **全有或全无** | 当前 `DYLD_INSERT_LIBRARIES` 注入发生在进程启动前，无法按需开关 |
| **崩溃不可恢复** | 不兼容 app 开启 `metalCaptureEnabled` 后直接无法启动，用户体验极差 |
| **`GPUToolsCapture` 是 Apple 私有框架** | 其内部行为（`MakeLayerInfos` 期望的 selector）随 macOS 版本变化，不可控 |

---

### 七、延迟注入方案（RC-009 核心技术方向）

为了解决 6.2 中的兼容性问题，拟将注入时机从 **启动期 `DYLD_INSERT_LIBRARIES`** 改为 **运行时按需 `dlopen`**。

#### 7.1 方案概述

| 项 | 当前（DYLD_INSERT_LIBRARIES） | 目标（dlopen 延迟注入） |
|---|---|---|
| 注入时机 | 进程启动前（dyld 阶段） | 首次执行 `capture_metal_frame` 或 `get_capture_status` 时 |
| 注入位置 | Host 侧 `effectiveLaunchEnvironment()` | Runtime 侧 `MetalCaptureService` |
| CAMetalLayer hook | 影响 **所有** layer 创建（包括启动阶段） | 仅影响 dlopen **之后** 创建的 layer |
| 不兼容 app | 启动即崩溃 | 正常启动；截帧时可能成功（如果不兼容的 layer 只在启动阶段创建） |

#### 7.2 代码改动方向

涉及 3 个文件：

**A. `PlayCover/Model/PlayApp.swift` + `PlayCoverMCP/HostServices/Launch/LaunchService.swift`**

- 当 `metalCaptureEnabled=true` 时，**不再设置 `DYLD_INSERT_LIBRARIES`**
- 其余环境变量逻辑不变

**B. `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`**

- 新增延迟加载逻辑：

```swift
private static var gpuToolsCaptureLoaded = false

private func ensureGPUToolsCaptureLoaded() -> Bool {
    guard !Self.gpuToolsCaptureLoaded else { return true }
    let handle = dlopen("/usr/lib/libmtlcapture.dylib", RTLD_NOW)
    Self.gpuToolsCaptureLoaded = (handle != nil)
    if Self.gpuToolsCaptureLoaded {
        // 重新获取 captureManager 以反映新加载的库能力
        captureManager = MTLCaptureManager.shared()
    }
    return Self.gpuToolsCaptureLoaded
}
```

- 在 `captureFrame()` 和 `getStatus()` 中调用 `ensureGPUToolsCaptureLoaded()`

#### 7.3 方案风险与待验证问题

这是 RC-009 的核心探索方向，以下是必须在实施前/中验证的关键问题：

| # | 待验证问题 | 为什么重要 | 验证方法 |
|---|---|---|---|
| **Q1** | `dlopen` 后 `supportsDestination(.gpuTraceDocument)` 能否变为 `true`？ | `MTLCaptureManager` 是单例，可能在首次查询时缓存了 `false`。如果缓存不可刷新，整个方案不成立 | 写一个 Swift CLI：先查询 → `dlopen` → 再查询，观察前后变化 |
| **Q2** | `dlopen` 后新创建的 `CAMetalLayer` 是否仍会崩溃（对原神）？ | 如果原神在渲染循环中持续创建新 `CAMetalLayer`（且使用不兼容模式），截帧期间仍可能崩溃 | 延迟注入后在原神上执行 `capture_metal_frame`，观察是否崩溃 |
| **Q3** | `dlopen` 后 `startCapture` 能否成功？ | 即使 `supportsDestination` 返回 `true`，`startCapture` 也可能对延迟加载场景有额外检查 | QQ飞车上验证：改为延迟注入后重跑完整截帧流程 |
| **Q4** | 延迟注入是否需要重建 xcframework + 重装 app？ | 改动在 PlayTools runtime 侧（`MetalCaptureService.swift`），需要 `sync_playtools_xcframework.sh` + 重装 app | 标准构建流程 |

**如果 Q1 验证失败**（`dlopen` 后 `supportsDestination` 仍为 `false`），则需要考虑：

- 是否有 API 可以重置 `MTLCaptureManager` 的内部缓存
- 是否需要在 `dlopen` 后才首次访问 `MTLCaptureManager.shared()`（推迟 `initialize()` 时机）
- 最坏情况：延迟注入方案不可行，需要改用其他策略（如 LLDB attach 注入）

---

### 八、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | — | `DONE` | 查清真实 app 上 `supports_gpu_trace=false` 的直接现象 | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-003` | — | `DONE` | 用第二个真实 app `原神` 完成对照验证 | `Tasks/RC-003-对照验证.md` |
| `RC-005` | — | `DONE` | 环境级 gpu-trace-unsupported 定位 | `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md` |
| `RC-006` | — | `DONE` | 默认设备级 capture 前提与替代路径验证 | `Tasks/RC-006-验证系统级-capture-前提与替代路径.md` |
| `RC-007` | — | `DONE` | 真实渲染 command queue 发现与 queue/queue_scope 路径实现 | `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md` |
| `RC-008` | — | `DONE` | **找到根因并修复**：注入 `libmtlcapture.dylib` + MCP 改用 `NSWorkspace` 启动，`QQ飞车` 成功生成 `.gputrace` | `Tasks/RC-008-验证真实queue路径-live.md` |
| `RC-002` | — | `WONTFIX` | fresh reinstall 复测（截帧已成功，不再需要） | `Tasks/RC-002-fresh-reinstall-复测.md` |
| **`RC-009`** | **P0** | **TODO** | **延迟注入方案：验证 `dlopen` 可行性并实施**，解决 `DYLD_INSERT_LIBRARIES` 导致部分 app 崩溃的兼容性问题 | `Tasks/RC-009-延迟注入方案.md` |
| **`RC-010`** | **P0** | **TODO** | **验证 Q1**：独立 Swift CLI 验证 `dlopen("/usr/lib/libmtlcapture.dylib")` 后 `supportsDestination(.gpuTraceDocument)` 能否从 `false` 变为 `true`。这是 RC-009 的前置门槛 | `Tasks/RC-010-dlopen可行性验证.md` |
| `RC-004` | P1 | `TODO` | 整理最终可重复 SOP、产物位置与关单验证标准（需等 RC-009 确定最终注入策略后再关单） | `Tasks/RC-004-成功截帧与关单.md` |

### 九、当前最重要任务

> **`RC-010`：验证 `dlopen` 可行性。**
>
> 这是 RC-009 延迟注入方案的前置门槛。如果 Q1 验证通过，立即推进 RC-009 实施；如果失败，需要重新评估技术方向。

RC-010 的具体步骤：

1. 编写一个独立 Swift CLI（不依赖 PlayCover / PlayTools），在 **不设 `DYLD_INSERT_LIBRARIES`** 的环境下：
   - 查询 `MTLCaptureManager.shared().supportsDestination(.gpuTraceDocument)` → 预期 `false`
   - 执行 `dlopen("/usr/lib/libmtlcapture.dylib", RTLD_NOW)`
   - 再次查询 `supportsDestination(.gpuTraceDocument)` → 观察是否变为 `true`
2. 如果首次查询前就 dlopen，是否能得到 `true`？（验证 `MTLCaptureManager` 的初始化时序要求）
3. 将结果记录到 `Tasks/RC-010-dlopen可行性验证.md`

---

### 十、参考信息

统一参考入口：

- `Refs/01-验证入口与代码锚点.md`
- `BuildScripts/probe_metal_capture_env.sh`

成功截帧产物：

- PlayCover MCP 生成：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_170807.gputrace`（124MB）
- QQ飞车 app 内调试按钮生成：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

关键代码锚点：

- `PlayCover/Model/PlayApp.swift`：`effectiveLaunchEnvironment()` — `DYLD_INSERT_LIBRARIES` 注入逻辑
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：`effectiveLaunchEnvironment()` — 同上 + `launchApp()` 使用 `NSWorkspace.openApplication`
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`：runtime 截帧核心实现，RC-009 改动的主要目标

崩溃样本：

- 原神崩溃（2026-03-31 22:23）：`GPUToolsCapture.MakeLayerInfos` → `doesNotRecognizeSelector` → `SIGABRT`，发生在 `UIView _createLayerWithFrame:` 启动路径上
