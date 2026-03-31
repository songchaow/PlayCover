## RC-006：验证系统级 capture 前提与替代路径

### 一、任务目标

回答新的核心问题：

> **当前机器上，是否存在任何受支持的路径让 `MTLCaptureManager.supportsDestination(.gpuTraceDocument / .developerTools)` 变为 `true`？**

---

### 二、任务背景

`RC-005` 已经拿到强证据表明：

- 两个真实 app 在最新 `PlayCover.app` 上都稳定返回：
  - `supports_gpu_trace=false`
  - `supports_developer_tools=false`
  - `failure_reason=gpu_trace_document_unsupported`
- 失败后 session 仍保持 `ready`
- 普通 Swift 进程中，`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 也返回 `false`
- 带 `METAL_DEVICE_WRAPPER_TYPE=1` 再测，结果仍未改变

这说明当前主线已经不该继续停留在“再换一个 app 试试”。

---

### 三、本任务只聚焦系统级可行路径

本轮优先回答：

1. 普通带 bundle / `Info.plist` 的最小原生样本，是否会返回不同结果
2. 通过 Xcode / Developer Tools attach 的路径，是否会改变 `supportsDestination` 结果
3. Apple 文档是否明确限制了 `.gpuTraceDocument` / `.developerTools` 的使用上下文
4. 如果当前机器确实不存在可行路径，是否应把目标从“当前机型直接产出 `.gputrace`”改成“给出明确不支持结论与替代 SOP”

---

### 四、完成标准

完成本任务时，应至少给出以下之一：

- **一个可行的系统级成功路径**
- **Apple 文档或强实验证据支撑的“不支持”结论**
- **一份替代验证 SOP**（例如改走 Xcode attach / 切换环境 / 降级目标）

---

### 五、本轮新增结论（2026-03-31）

本轮围绕“是否可以通过修改目标 app 属性或启动配置，让 `supports_gpu_trace` / `supports_developer_tools` 发生变化”做了两件事：

1. **补充外部证据**
   - 社区案例表明：对 macOS 程序做编程式 Metal capture 时，`Info.plist` 中的 `MetalCaptureEnabled=true` 与 `METAL_DEVICE_WRAPPER_TYPE=1` 可能是必要条件之一
   - 这并不能直接证明当前机器一定可行，但至少说明“启动环境”本身值得单独验证

2. **回看 PlayCover 当前实现后发现一个关键事实**
   - 无论是 GUI 正常启动、GUI 的 LLDB 启动，还是 MCP 的 `launch_app` / `launch_app_with_lldb`，启动前都会清掉 Metal capture 相关环境变量
   - 这意味着即使外部 shell 已经准备好了 `METAL_DEVICE_WRAPPER_TYPE=1` 一类变量，当前 PlayCover 也会把它们抹掉，导致这条假设路径在现状下**根本没有被真正验证过**

因此，本轮没有直接把 `RC-006` 关单，而是先落了一个**新的实验入口**：

- 新增每 app 设置字段：`injectMetalCaptureEnvironment`
- 当它为 `true` 时，GUI 与 MCP 启动链路会为目标 app 注入：
  - `METAL_DEVICE_WRAPPER_TYPE=1`
  - `METAL_CAPTURE_ENABLED=1`
  - `METAL_FRAME_CAPTURE_ENABLED=1`
  - `MTLCaptureEnabled=1`

这让后续可以在**不手改目标 app 包**的前提下，直接验证：

> **“特殊启动环境”是否足以让当前机器上的 `supportsDestination(...)` 结果发生变化。**

### 六、下一步建议

下一轮优先做一件事即可：

1. 选一个真实 app（优先 `QQ飞车`）
2. 用 `update_app_settings` 同时打开：
   - `metalCaptureEnabled=true`
   - `injectMetalCaptureEnvironment=true`
3. 分别走：
   - `launch_app`
   - `launch_app_with_lldb`
4. 复测：
   - `create_session`
   - `get_capture_status`
   - `capture_metal_frame`
5. 记录 `supports_gpu_trace` / `supports_developer_tools` 是否有任何变化

如果仍然完全不变，则可以把“不支持结论”的证据链再向前推进一大步。 
