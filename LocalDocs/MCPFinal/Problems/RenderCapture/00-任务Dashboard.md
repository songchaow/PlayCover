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

截至 2026-03-31 深夜，**截帧功能已全面打通，兼容性问题已解决**：

- 根因是 iOS app 需要 `/usr/lib/libmtlcapture.dylib`（`GPUToolsCapture.framework`）才能使 `MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 返回 `true`
- 早期方案通过 `DYLD_INSERT_LIBRARIES` 启动期注入，但部分 app（如原神）因 `GPUToolsCapture` 全局 hook `CAMetalLayer` 导致启动崩溃
- **最终方案**（RC-009）：改为 runtime `dlopen` 延迟注入，仅在首次调用 `capture_metal_frame` 或 `get_capture_status` 时加载
- **RC-011 端到端验证通过**（2026-03-31 23:16）：QQ飞车成功截帧 413MB `.gputrace`，原神 `metalCaptureEnabled=true` 正常启动无崩溃

---

### 三、最终目标

> **用真实 app 成功执行 `capture_metal_frame`，生成可验证的 `.gputrace` 文件，并沉淀稳定 SOP。截帧功能不应导致不需要截帧的 app 崩溃。**

完成标准：

- `QQ飞车` 或其他真实 app 能成功 `launch_app` ✅
- `create_session` 返回 `ready` ✅
- `capture_metal_frame` 成功返回，并实际生成 `.gputrace` ✅
- 结果与 app 内成功路径相互印证 ✅
- 开启 `metalCaptureEnabled` 不会导致不兼容 app 启动崩溃 ✅（RC-009 + RC-011 已验证）
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

截帧核心链路已验证成功（QQ飞车 + 延迟注入方案）：

1. **根因**：`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 需要 `/usr/lib/libmtlcapture.dylib`（Apple 私有 `GPUToolsCapture.framework`）被加载到进程中
2. **最终修复**（RC-009）：在 `MetalCaptureService.ensureGPUToolsCaptureLoaded()` 中通过 runtime `dlopen` 按需加载，替代早期的 `DYLD_INSERT_LIBRARIES` 启动期注入
3. **附带修复**：MCP 的 `launchApp` 从 `/usr/bin/open` 改为 `NSWorkspace.openApplication`，以正确传递环境变量到目标 app 进程
4. **RC-011 验证结果**（2026-03-31 23:16）：
   - QQ飞车 `get_capture_status` 返回 `supports_gpu_trace=true`，`capture_metal_frame` 成功落盘 **413MB** `.gputrace`
   - 原神 `metalCaptureEnabled=true` 正常启动、`create_session` 返回 `ready`，无崩溃

#### 6.2 已解决：延迟 dlopen 后 `doesNotRecognizeSelector` 崩溃（RC-012）

**问题**：延迟 `dlopen` 加载 `GPUToolsCapture` 后，原神渲染线程调用 `nextDrawable` 时崩溃。

**根因**（反汇编确认）：`GPUToolsCapture` hook 了 `nextDrawable` → `CAMetalLayer_shimDrawable` → `OpenLayerStream` → `MakeLayerInfos`。`MakeLayerInfos` 对所有 tracked layer 及其 `device` 调用 `traceStream`、`streamReference` 等私有 selector。延迟 dlopen 时，预创建的 Metal 对象不是 `Capture*` 代理类，缺少这些方法。

**修复**：在 `dlopen` 前给 `NSObject` 添加 `traceStream` 和 `streamReference` 的 nil-returning fallback stub。所有 `Capture*` 代理类的真实实现会覆盖这些 stub。

**结果**：原神可正常运行、`get_capture_status` 成功返回 `supportsGPUTrace=true`，不再崩溃。

#### 6.3 已知限制：延迟注入模式下截帧产物为空（原神）

**问题**：`capture_metal_frame` → `startCapture` 成功 → `stopCapture` 时 `GPUToolsCapture` 内部 `GTTraceContextDumpEmptyCapture` 发生 SIGSEGV。

**根因**：延迟 dlopen 后，原神的 Metal 对象（device、commandQueue、texture 等）不是 `Capture*` 代理，`GPUToolsCapture` 无法拦截 GPU 命令流，trace context 始终为空。`stopCapture` 访问空 trace context 导致段错误。

**结论**：原神与 `GPUToolsCapture` 根本不兼容（启动期注入崩溃 SIGABRT，延迟注入截帧 SIGSEGV）。当前截帧功能对原神不可用，但不影响兼容 app（如 QQ飞车）。

#### 6.4 双模式注入方案

| 模式 | 设置 | 机制 | 适用场景 |
|---|---|---|---|
| **延迟注入**（默认） | `metalCaptureEnabled=true` | runtime `dlopen` + NSObject compat stubs | 所有 app 安全启动；兼容 app 可截帧 |
| **启动期注入** | `metalCaptureEnabled=true` + `injectMetalCaptureEnvironment=true` | `DYLD_INSERT_LIBRARIES` 注入 | 兼容 app 获得完整 trace context |

#### 6.5 app 兼容性矩阵

| App | 延迟注入启动 | 延迟注入截帧 | 启动期注入启动 | 启动期注入截帧 |
|---|---|---|---|---|
| QQ飞车 | ✅ | ✅ 413MB .gputrace | ✅ | ✅ 124MB .gputrace |
| 原神 | ✅ | ❌ SIGSEGV (空 trace) | ❌ SIGABRT (CAMetalLayer hook) | N/A |

---

### 七、延迟注入方案（RC-009 — 已实施 ✅）

已将注入时机从 **启动期 `DYLD_INSERT_LIBRARIES`** 改为 **运行时按需 `dlopen`**。

#### 7.1 方案概述

| 项 | 旧（DYLD_INSERT_LIBRARIES） | 新（dlopen 延迟注入） |
|---|---|---|
| 注入时机 | 进程启动前（dyld 阶段） | 首次执行 `capture_metal_frame` 或 `get_capture_status` 时 |
| 注入位置 | Host 侧 `effectiveLaunchEnvironment()` | Runtime 侧 `MetalCaptureService.ensureGPUToolsCaptureLoaded()` |
| CAMetalLayer hook | 影响 **所有** layer 创建（包括启动阶段） | 仅影响 dlopen **之后** 创建的 layer |
| 不兼容 app | 启动即崩溃 | 正常启动；截帧时可能成功 |

#### 7.2 代码改动（已完成）

**A. `PlayCover/Model/PlayApp.swift` + `PlayCoverMCP/HostServices/Launch/LaunchService.swift`**

- 移除 `DYLD_INSERT_LIBRARIES` 注入逻辑
- 其余环境变量逻辑不变

**B. `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`**

- 新增 `ensureGPUToolsCaptureLoaded()` 方法：`dlopen` + 重新获取 `captureManager`
- `initialize()` 不再获取 `captureManager`（避免单例缓存 `false`）
- `captureFrame()` 和 `getStatus()` 调用时自动延迟加载

#### 7.3 Q1 验证结果（RC-010 已完成）

| 场景 | 结果 | 含义 |
|---|---|---|
| 先查后 dlopen（原实例） | `false` → `false` | 单例缓存了首次查询 |
| 先查后 dlopen（重新 `shared()`） | → `true` | **dlopen 后重新获取 `shared()` 可刷新** |
| 先 dlopen 后查 | → `true` | **dlopen-first 完全可行** |

#### 7.4 待实测验证

| # | 问题 | 状态 |
|---|---|---|
| **Q1** | `dlopen` 后 `supportsDestination` 能否变 `true`？ | ✅ 已验证通过 |
| **Q2** | 原神延迟注入后能否正常启动？ | ✅ 已验证通过（2026-03-31 23:18，PID 98638，session ready） |
| **Q3** | QQ飞车延迟注入后能否成功截帧？ | ✅ 已验证通过（2026-03-31 23:16，413MB `.gputrace`） |
| **Q4** | 是否需要重建 xcframework + 重装 app？ | ✅ 是 — 已通过标准脚本完成重建 + 重新注入 |

---

### 八、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | — | `DONE` | 查清真实 app 上 `supports_gpu_trace=false` 的直接现象 | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-003` | — | `DONE` | 用第二个真实 app `原神` 完成对照验证 | `Tasks/RC-003-对照验证.md` |
| `RC-005` | — | `DONE` | 环境级 gpu-trace-unsupported 定位 | `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md` |
| `RC-006` | — | `DONE` | 默认设备级 capture 前提与替代路径验证 | `Tasks/RC-006-验证系统级-capture-前提与替代路径.md` |
| `RC-007` | — | `DONE` | 真实渲染 command queue 发现与 queue/queue_scope 路径实现 | `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md` |
| `RC-008` | — | `DONE` | 找到根因并修复：注入 `libmtlcapture.dylib` + MCP 改用 `NSWorkspace` 启动，QQ飞车成功生成 `.gputrace` | `Tasks/RC-008-验证真实queue路径-live.md` |
| `RC-009` | — | `DONE` | **延迟注入方案**：移除 `DYLD_INSERT_LIBRARIES`，改为 runtime `dlopen`，解决部分 app 启动崩溃 | `Tasks/RC-009-延迟注入方案.md` |
| `RC-010` | — | `DONE` | **验证 Q1**：独立 Swift CLI 确认 `dlopen` 后 `supportsDestination(.gpuTraceDocument)` 可变为 `true` | `Tasks/RC-010-dlopen可行性验证.md` |
| `RC-002` | — | `WONTFIX` | fresh reinstall 复测（截帧已成功，不再需要） | `Tasks/RC-002-fresh-reinstall-复测.md` |
| **`RC-011`** | — | **DONE** | **端到端验证**：重建 PlayTools xcframework + PlayCover.app，实测 QQ飞车延迟注入截帧（Q3 ✅ 413MB）和原神正常启动（Q2 ✅ session ready） | `Tasks/RC-011-端到端验证.md` |
| **`RC-012`** | — | **DONE** | **原神截帧兼容性攻关**：反汇编 `GPUToolsCapture`，定位 `traceStream`/`streamReference` 崩溃根因，实现 NSObject fallback stubs，恢复双模式注入 | `Tasks/RC-012-原神截帧兼容性.md` |
| `RC-004` | **P0** | `TODO` | 整理最终可重复 SOP、产物位置与关单验证标准 | `Tasks/RC-004-成功截帧与关单.md` |

### 九、当前最重要任务

> **`RC-004`：整理最终可重复 SOP、产物位置与关单验证标准。**
>
> 截帧功能对兼容 app（QQ飞车）已完全可用。原神因与 `GPUToolsCapture` 根本不兼容，截帧暂不可用（已记录到兼容性矩阵）。双模式注入已实现，用户可按需选择。

---

### 十、参考信息

统一参考入口：

- `Refs/01-验证入口与代码锚点.md`
- `BuildScripts/probe_metal_capture_env.sh`

成功截帧产物：

- RC-011 延迟注入验证（2026-03-31 23:16）：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_231639.gputrace`（413MB）
- 早期 DYLD_INSERT_LIBRARIES 方案验证（2026-03-31 17:08）：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_170807.gputrace`（124MB）
- QQ飞车 app 内调试按钮生成：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

关键代码锚点：

- `PlayCover/Model/PlayApp.swift`：`effectiveLaunchEnvironment()` — 已移除 `DYLD_INSERT_LIBRARIES` 注入
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：`effectiveLaunchEnvironment()` — 已移除 `DYLD_INSERT_LIBRARIES` 注入
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`：runtime 截帧核心实现，`ensureGPUToolsCaptureLoaded()` 实现延迟 dlopen

崩溃样本（已解决）：

- 原神崩溃（2026-03-31 22:23，`DYLD_INSERT_LIBRARIES` 方案下）：`GPUToolsCapture.MakeLayerInfos` → `doesNotRecognizeSelector` → `SIGABRT`，发生在 `UIView _createLayerWithFrame:` 启动路径上
- **已通过 RC-009 延迟注入方案解决**，RC-011 验证原神 `metalCaptureEnabled=true` 正常启动
