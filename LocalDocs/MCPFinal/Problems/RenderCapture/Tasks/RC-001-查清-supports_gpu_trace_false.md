## RC-001：查清 `supports_gpu_trace=false`

### 一、任务目标

回答一个关键问题：

> **为什么当前真实 app 已能创建 `ready` session，且 `available=true`、`enabled=true`，但 `get_capture_status` 仍返回 `supports_gpu_trace=false`？**

这个问题是当前 `Render Capture` 的主阻塞点。

---

### 二、当前已确认事实

#### 1. 基础链路已打通

已经确认：

- `PlayCover.app` 已通过安装脚本重装并启动
- GUI MCP HTTP 端口 `19820` 正常监听
- runtime 注册端口 `52741` 正常监听
- 真实 app `QQ飞车` 可以正常 `launch_app`
- `create_session` 能成功返回 `ready`

这说明：

- GUI 内嵌 MCP 正常
- runtime 注册链路正常
- 当前问题不在 `create_session` 本身

#### 2. 真实 app 当前状态

本轮测试对象：

- **app**：`QQ飞车`
- **bundleId**：`com.tencent.tmgp.speedmobile`

已经确认：

- `check_playtools_installed == true`
- app 设置里的 `metalCaptureEnabled == true`
- 已安装 app 的 `Info.plist` 中 `MetalCaptureEnabled == true`

#### 3. 关键返回结果

`get_capture_status` 返回：

```json
{
  "available": true,
  "enabled": true,
  "is_capturing": false,
  "supports_gpu_trace": false
}
```

随后执行真实截帧：

- 调用 `capture_metal_frame`
- 返回失败：`Invalid bridge message: Command failed: error`
- 目标输出路径下**没有生成** `.gputrace`

#### 4. 当前判断

这说明当前状态更接近：

- 截帧服务对象存在（`available=true`）
- 设置层已经打开（`enabled=true`）
- 但 **GPU trace document 导出能力当前不可用**

因此，最优先要回答的不是“为什么这次命令失败”，而是：

> **为什么 runtime 侧判断 `supportsDestination(.gpuTraceDocument)` 为 `false`。**

---

### 三、相关代码锚点

优先关注：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Tools/Session/CaptureTools.swift`
- `PlayCover/AppInstaller/Installer.swift`
- `LocalDocs/MCPFinal/03-能力清单.md`
- `LocalDocs/MCPFinal/01-架构与设计.md`

关键点：

- `MetalCaptureService.initialize()` 会初始化 `MTLCaptureManager`
- `getStatus()` 中：
  - `available = captureManager != nil`
  - `supportsGPUTrace = captureManager?.supportsDestination(.gpuTraceDocument) ?? false`
- `captureFrame()` 会在 `supportsDestination(.gpuTraceDocument)` 为 `false` 时直接失败

---

### 四、建议调查方向

后续 agent 不要整包推进，**一次只选一个方向**：

#### 方向 A：确认这是环境级限制还是 app 级限制

例如：

- 同机同版本 PlayCover 下，换另一个真实 app 测一次
- 如有可控的最小 Metal 样本，再做最小对照

#### 方向 B：确认 runtime 初始化阶段到底拿到了什么能力

例如：

- 给 `MetalCaptureService.initialize()` / `getStatus()` 增加更明确日志
- 补充返回信息，区分：
  - `MTLCaptureManager` 存在
  - 但 `.gpuTraceDocument` 不支持
  - 还是 runtime 初始化顺序异常

#### 方向 C：确认是否还存在“必须 fresh reinstall 才真正生效”的残余歧义

虽然当前证据表明设置已生效，但这项仍值得单独验证，不应混在其它任务里。

---

### 五、当前不建议做的事

当前不建议：

- 不带新证据地反复调用 `capture_metal_frame`
- 一轮里同时做“重装 + 改代码 + 换 app + 打日志”四件事
- 让一个 agent 同时承担“查明原因 + 修复 + 回归 + 写 SOP”

---

### 六、完成标准

本任务完成的标准不是“截帧成功”，而是：

> **把 `supports_gpu_trace=false` 的原因边界查清，并能明确下一步应该由哪个更小任务继续。**

可接受的完成形态包括：

- 明确它是**环境级限制**
- 明确它是**某类 app 特有**
- 明确它是**runtime 初始化 / 能力暴露逻辑缺陷**
- 明确它仍受**重装时机**影响，并给出独立后续任务
