## RC-001：查清 `supports_gpu_trace=false`

### 一、任务目标

回答一个关键问题：

> **为什么当前真实 app 已能创建 `ready` session，且 `available=true`、`enabled=true`，但 `get_capture_status` 仍返回 `supports_gpu_trace=false`？**

这个问题仍是当前 `Render Capture` 的主阻塞点。

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

#### 2. 真实 app 当前历史状态

此前记录的真实对象：

- **app**：`QQ飞车`
- **bundleId**：`com.tencent.tmgp.speedmobile`

此前已经确认：

- `check_playtools_installed == true`
- app 设置里的 `metalCaptureEnabled == true`
- 已安装 app 的 `Info.plist` 中 `MetalCaptureEnabled == true`
- `get_capture_status` 历史结果为：

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

#### 3. 这说明什么

以上历史现象说明：

- 截帧服务对象存在（`available=true`）
- 设置层已经打开（`enabled=true`）
- 但 **GPU trace document 导出能力当前不可用**

因此，真正需要查清的不是“这次命令为什么抽象失败”，而是：

> **为什么 runtime 侧判断 `supportsDestination(.gpuTraceDocument)` 为 `false`。**

---

### 三、本轮完成的子任务（`RC-001-A`）

本轮没有继续盲目重试真实 capture，而是完成了一个更小的观测增强子任务：

> **把 `supports_gpu_trace=false` 和 capture 失败从黑盒布尔值 / 黑盒错误，改造成可判因的诊断输出。**

#### 1. 代码改动

本轮已修改：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Session/BridgeClient.swift`

#### 2. 新增诊断字段

`get_capture_status` 现在除原有字段外，还会返回：

- `supports_developer_tools`
- `has_default_device`
- `default_device_name`
- `failure_reason`
- `diagnostic_summary`

#### 3. capture 失败信息也被补强

此前 `capture_metal_frame` 在 runtime 返回 `status=error` 时，host 常只看到：

- `Invalid bridge message: Command failed: error`

本轮后，`BridgeClient` 会优先透传 runtime 的 `result.message`，因此后续真实失败应能直接看到更具体的原因，例如：

- `GPU trace document not supported. ...`
- 或其他 runtime 侧原始错误描述

---

### 四、本轮产出的判因边界

本轮**还没有**用真实 app 得到新的 live 样本，因此还不能最终下结论它是环境级还是 app 级。

但本轮已经把后续判因边界明确为下面几类：

#### 1. `failure_reason=disabled_by_settings`

说明问题仍在设置链路，优先检查：

- host 设置值
- 是否重装后生效
- runtime 侧读取到的 `PlaySettings`

#### 2. `failure_reason=capture_manager_unavailable`

说明问题更偏向：

- runtime 初始化异常
- `MTLCaptureManager` 在该进程里不可用
- 或能力初始化时机不对

#### 3. `failure_reason=gpu_trace_document_unsupported`

说明：

- `MTLCaptureManager` 已可访问
- 但 `.gpuTraceDocument` 导出目的地不被当前 runtime 进程支持

此时需要再结合以下字段继续判因：

- `supports_developer_tools`
- `has_default_device`
- `default_device_name`

若出现：

- `supports_developer_tools=true`
- 但 `supports_gpu_trace=false`

则更像是：

- **capture service 存在，但导出 `.gputrace` 的 destination 能力受限**
- 更偏环境级 / destination 级问题，而不是 session 链路问题

#### 4. `has_default_device=false`

说明 runtime 进程连默认 Metal device 都没看到，问题更偏：

- 当前 app / 当前环境下的 Metal device 可见性问题
- 需要优先检查运行环境，而不是继续追 MCP 链路

---

### 五、验证结果

本轮已完成的验证：

- `PlayCover` Release 构建成功
- 定向测试通过：
  - `CaptureResultTests`
  - `CaptureToolsRegistrationTests`
  - `SessionHandshakeTests`
- 新增测试覆盖了：
  - `get_capture_status` 新诊断字段输出
  - bridge 对 runtime 错误 message 的保留

额外说明：

- 全量 `PlayCoverMCP` 测试仍存在一个看起来与本轮无关的既有失败：
  - `InstallerServiceTests.testInstallFatArm64BinaryDoesNotFailSliceExtraction()`

当前没有证据表明该失败由本轮 `Render Capture` 诊断改动引入。

---

### 六、下一步最小任务（`RC-001-B`）

下一步不要扩散范围，**只做一件事**：

> **用带新诊断的构建，对真实 app 重新做一轮最小复测，并把 live 输出存档。**

建议步骤：

1. 构建并安装最新 `PlayCover.app`
2. 确保目标 app 为新安装态（避免旧安装残留）
3. `launch_app`
4. `create_session`
5. 执行一次 `get_capture_status`
6. 只补一次 `capture_metal_frame`
7. 记录返回的：
   - `supports_gpu_trace`
   - `supports_developer_tools`
   - `has_default_device`
   - `default_device_name`
   - `failure_reason`
   - `diagnostic_summary`
   - `capture_metal_frame` 的完整错误文本

拿到这组 live 证据后，再决定它应该归到：

- 环境级问题
- runtime 级问题
- app 级问题
- 或 reinstall / 生效时机问题

---

### 七、完成标准

本任务整体完成的标准仍然不是“截帧成功”，而是：

> **把 `supports_gpu_trace=false` 的原因边界查清，并能明确下一步应该由哪个更小任务继续。**

就本轮子任务而言，完成标准已经达到：

- `supports_gpu_trace=false` 不再只是黑盒布尔值
- `capture_metal_frame` 失败不再只是黑盒 `error`
- 后续 agent 已有足够的诊断字段去收集一份可判因的真实样本
