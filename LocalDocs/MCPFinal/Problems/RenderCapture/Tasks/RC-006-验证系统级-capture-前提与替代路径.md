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
