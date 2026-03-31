## RC-001：查清 `supports_gpu_trace=false`

### 一、任务目标

回答一个关键问题：

> **为什么当前真实 app 已能创建 `ready` session，但 Render Capture 相关状态与真实行为仍不符合预期？**

这个问题曾经是 `Render Capture` 的主阻塞点。

---

### 二、历史脉络

#### 1. 基础链路已打通

已经确认：

- `PlayCover.app` 可以正常启动
- GUI MCP HTTP 端口 `19820` 正常监听
- runtime 注册端口 `52741` 正常监听
- 真实 app `QQ飞车` 可以正常 `launch_app`
- `create_session` 能成功返回 `ready`

这说明：

- GUI 内嵌 MCP 正常
- runtime 注册链路正常
- 当前问题不在 `create_session` 本身

#### 2. 历史症状分为两个阶段

第一阶段的 live 症状是：

- `get_capture_status` 只有旧 4 字段
- `capture_metal_frame` 失败，且无 `.gputrace` 落盘

第二阶段在真正切到最新 runtime 后，一度出现：

- `get_capture_status` 超时
- session 进入 `disconnected`
- `QQ飞车` crash

---

### 三、已完成子任务

#### `RC-001-A`：观测增强

已完成：

- 为 `get_capture_status` 新增诊断字段：
  - `supports_developer_tools`
  - `has_default_device`
  - `default_device_name`
  - `failure_reason`
  - `diagnostic_summary`
- 为 capture 失败补强 runtime 原始错误透传

涉及文件：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Session/BridgeClient.swift`

#### `RC-001-B`：确认旧样本来自陈旧预构建 runtime

已完成：

- 证实 GUI 打包实际吃的是 `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
- 不是直接吃 `Carthage/Checkouts/PlayTools` 源码
- 修复了一个会阻塞 `PlayTools.framework` 源码重建的编译问题
- 将 `sync_playtools_xcframework.sh` 接入 GUI 构建 / 安装入口

这一步把问题从“源码更新但 live 仍是旧字段”推进到了“最新 runtime 下的真实 live 行为”。

---

### 四、`RC-001-C`：本轮最小 fresh-launch 复测

本轮只做一件事：

> **在真正加载最新 PlayTools runtime 的前提下，对 `QQ飞车` 执行一次最小 `get_capture_status` 复测，判断它是否还会超时、断链或崩溃。**

#### 1. 本轮补充的最小观测增强

本轮新增了更细的 runtime 观测日志，位置包括：

- `BridgeListener` 的命令入口 / `get_capture_status` 入口 / 主线程执行点 / 返回点
- `MetalCaptureService.getStatus()` 的状态探针入口与出口

然后：

- 重建并安装最新 `PlayCover.app`
- 启动最新 GUI
- 通过 GUI 内嵌 MCP 执行真实复测

#### 2. 复测前确认

在 `QQ飞车` 上确认到：

- `metalCaptureEnabled == true`
- `check_playtools_installed == true`
- 当前没有残留 session
- 当前没有残留 `speedmobile` 进程

#### 3. 最小复测链路

执行顺序：

1. `launch_app(com.tencent.tmgp.speedmobile)`
2. `create_session(timeout=20)`
3. **只执行一次** `get_capture_status(sessionId=...)`
4. 立即检查：
   - `list_sessions`
   - runtime 日志
   - crash 报告目录

#### 4. live 结果

本轮结果是：

- `launch_app`：成功
- `create_session`：`ready`
- `get_capture_status`：**成功返回，不再超时**
- `list_sessions`：同一 session 仍为 `ready`
- `DiagnosticReports`：**没有新的** `speedmobile-*.ips`

本轮真实返回结果为：

```json
{
  "available": true,
  "default_device_name": "Apple M4 Pro",
  "diagnostic_summary": "enabled=true, captureManagerAvailable=true, supportsGPUTrace=false, supportsDeveloperTools=false, hasDefaultDevice=true, defaultDeviceName=Apple M4 Pro, failureReason=gpu_trace_document_unsupported",
  "enabled": true,
  "failure_reason": "gpu_trace_document_unsupported",
  "has_default_device": true,
  "is_capturing": false,
  "supports_developer_tools": false,
  "supports_gpu_trace": false
}
```

#### 5. runtime / bridge 证据

本轮日志可确认：

- `BridgeListener get_capture_status begin; entering valueOnMainSync`
- `BridgeListener get_capture_status executing on main; onMain=true`
- `BridgeListener get_capture_status returned from main. ... failureReason=gpu_trace_document_unsupported`

这说明：

- 命令已经进入 runtime handler
- 主线程执行点已经真正跑到
- `MetalCaptureService.getStatus()` 已经返回
- host 侧成功收到了 response

---

### 五、本轮结论

本轮后，`RC-001` 的边界进一步收敛：

#### 1. 旧 4 字段 live 样本不能代表当前真实状态

因为它来自：

- **陈旧的 `PlayTools.xcframework` 预构建产物**
- 而不是当前 checkout 源码对应的 runtime

#### 2. “超时 + disconnected + crash” 当前不能再被当作主阻塞点

至少在本轮：

- 最新 GUI
- 最新 runtime
- `QQ飞车` fresh launch
- 只执行一次 `get_capture_status`

的最小路径下，这组症状**没有复现**。

#### 3. 当前最新稳定 live 现象已经明确

当前更应该围绕的是：

- `supports_gpu_trace == false`
- `supports_developer_tools == false`
- `has_default_device == true`
- `default_device_name == Apple M4 Pro`
- `failure_reason == gpu_trace_document_unsupported`

也就是说，当前问题已经从：

> “为什么 `get_capture_status` 会超时？”

收敛为：

> **“为什么状态可以稳定返回，但真实 app 仍然不支持 `.gpuTraceDocument` 输出？”**

---

### 六、对后续任务的影响

`RC-001-C` 完成后，后续主线不应继续围绕“先证明超时/断链是否存在”。

更合理的下一步是：

> **做对照验证（`RC-003`），在另一款真实 app 上执行同样的最小链路，区分 `gpu_trace_document_unsupported` 是 `QQ飞车` 特有，还是当前机器 / 当前 PlayCover 环境的普遍问题。**

因为现在已经知道：

- session 链路是通的
- `get_capture_status` 返回链路是通的
- 默认 Metal device 是可见的

最缺的，是**对照样本**。

---

### 七、验证结果

到本轮结束时，已确认：

- `PlayCover` Release 构建成功
- 最新 `PlayCover.app` 已安装并启动
- `QQ飞车` 在本轮最小 fresh-launch 复测中：
  - 能成功 `create_session -> ready`
  - 能成功执行 `get_capture_status`
  - session 不会立即进入 `disconnected`
  - 没有新增 crash 报告
- 当前 live 诊断字段已能稳定进样本

详细 live 输出见：

- `live/2026-03-31-qqfc-rc001b.md`
- `live/2026-03-31-qqfc-rc001c.md`

---

### 八、阶段完成标准

`RC-001` 到本轮为止，可以认为阶段性目标已达到：

- 区分了“旧产物导致的假样本”和“最新 runtime 下的真实 live 样本”
- 确认 `get_capture_status` 当前已能稳定返回完整诊断
- 把主问题收敛到了 `gpu_trace_document_unsupported`
- 明确把下一步主线切换到 `RC-003` 对照验证
