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

截至本轮（2026-03-31），**问题已解决**：

- 根因是启动 iOS app 时缺少 `/usr/lib/libmtlcapture.dylib` 的注入
- 该库是 Apple GPU Tools Capture 的核心组件，Xcode 在 debug 模式下会自动注入
- 没有它，`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 始终返回 `false`
- 本轮已修改 GUI 和 MCP 两条启动路径，当 `metalCaptureEnabled=true` 时自动注入该库
- **QQ飞车** 已成功通过 `capture_metal_frame` 生成 124MB 的真实 `.gputrace`

---

### 三、最终目标

> **用真实 app 成功执行 `capture_metal_frame`，生成可验证的 `.gputrace` 文件，并沉淀稳定 SOP。**

完成标准：

- `QQ飞车` 或其他真实 app 能成功 `launch_app` ✅
- `create_session` 返回 `ready` ✅
- `capture_metal_frame` 成功返回，并实际生成 `.gputrace` ✅
- 结果与 app 内成功路径相互印证 ✅
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

**截帧功能已打通。** 核心修复如下：

1. **根因**：`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 需要 `/usr/lib/libmtlcapture.dylib`（Apple 私有 `GPUToolsCapture.framework`）被加载到进程中
2. **修复**：在 `PlayApp.effectiveLaunchEnvironment()`（GUI）和 `LaunchService.effectiveLaunchEnvironment()`（MCP）中，当 `metalCaptureEnabled=true` 时，设置 `DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib`
3. **附带修复**：MCP 的 `launchApp` 从 `/usr/bin/open` 改为 `NSWorkspace.openApplication`，以正确传递环境变量到目标 app 进程
4. **验证结果**：`QQ飞车` fresh session 上 `get_capture_status` 返回 `supports_gpu_trace=true`，`capture_metal_frame` 成功落盘 124MB `.gputrace`

历史调查摘要（已关闭）：

- `RC-001` ~ `RC-007`：逐步排除了 capture object 选择、queue 发现、环境变量等假设
- `RC-008`：先验证了 queue/queue_scope 路径仍失败，然后定位到 `supportsDestination` 返回 false 的根因是缺少 `libmtlcapture.dylib`

---

### 七、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | P0 | `DONE` | 查清真实 app 上 `supports_gpu_trace=false` 的直接现象 | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-003` | P0 | `DONE` | 用第二个真实 app `原神` 完成对照验证 | `Tasks/RC-003-对照验证.md` |
| `RC-005` | P1 | `DONE` | 环境级 gpu-trace-unsupported 定位 | `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md` |
| `RC-006` | P0 | `DONE` | 默认设备级 capture 前提与替代路径验证 | `Tasks/RC-006-验证系统级-capture-前提与替代路径.md` |
| `RC-007` | P0 | `DONE` | 真实渲染 command queue 发现与 queue/queue_scope 路径实现 | `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md` |
| `RC-008` | **P0** | `DONE` | **找到根因并修复**：注入 `libmtlcapture.dylib` + MCP 改用 `NSWorkspace` 启动，`QQ飞车` 成功生成 `.gputrace` | `Tasks/RC-008-验证真实queue路径-live.md` |
| `RC-004` | **P1** | `TODO` | 整理最终可重复 SOP、产物位置与关单验证标准 | `Tasks/RC-004-成功截帧与关单.md` |
| `RC-002` | P2 | `WONTFIX` | fresh reinstall 复测（截帧已成功，不再需要） | `Tasks/RC-002-fresh-reinstall-复测.md` |

### 八、当前最重要任务

> **`RC-004`：整理最终可重复 SOP、产物位置与关单验证标准。**

---

### 九、参考信息

统一参考入口：

- `Refs/01-验证入口与代码锚点.md`
- `BuildScripts/probe_metal_capture_env.sh`

成功截帧产物：

- PlayCover MCP 生成：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/Captures/capture_20260331_170807.gputrace`（124MB）
- QQ飞车 app 内调试按钮生成：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

关键代码修改：

- `PlayCover/Model/PlayApp.swift`：`effectiveLaunchEnvironment()` 新增 `DYLD_INSERT_LIBRARIES` 注入
- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`：`effectiveLaunchEnvironment()` 新增同样逻辑 + `launchApp()` 改用 `NSWorkspace.openApplication`
