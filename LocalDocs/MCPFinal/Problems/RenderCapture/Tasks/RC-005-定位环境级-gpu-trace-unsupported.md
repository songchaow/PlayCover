## RC-005：定位环境级 `gpu_trace_document_unsupported`

### 一、任务目标

回答新的核心问题：

> **为什么当前机器 / 当前 PlayCover 环境下，多个真实 app 都会返回 `supports_gpu_trace=false`，并落到 `failure_reason=gpu_trace_document_unsupported`？**

---

### 二、任务背景

截至当前，已经确认：

- `QQ飞车` 可以 `launch_app` / `create_session -> ready`
- `原神` 也可以 `launch_app` / `create_session -> ready`
- 两者都能稳定执行 `get_capture_status`
- 两者都返回：
  - `available=true`
  - `enabled=true`
  - `supports_gpu_trace=false`
  - `supports_developer_tools=false`
  - `has_default_device=true`
  - `default_device_name=Apple M4 Pro`
  - `failure_reason=gpu_trace_document_unsupported`
- 两者执行 `capture_metal_frame` 都失败且无 `.gputrace`

因此当前问题已经不再像是 app 特有问题，而更像：

- 机器级
- 系统 / 工具链级
- 或当前 PlayCover 运行环境级

---

### 三、本任务只聚焦环境级解释

本任务不再继续做“多 app 穷举”。

本轮优先回答：

1. `MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 受哪些条件影响
2. `supports_developer_tools=false` 是否意味着当前环境不支持 `.developerTools` / `.gpuTraceDocument`
3. 当前 macOS / Xcode / Developer Tools 组合是否存在全局限制
4. 当前 PlayCover runtime 上下文是否缺少 Apple 要求的某类前提

---

### 四、完成标准

完成本任务时，应至少给出以下之一：

- **明确的环境级根因**
- **强证据支持的根因假设**
- **已被排除的环境因素清单**

并能回答：

> **继续换 app 测是否还有意义，还是应该转向系统 / 工具链 / Apple API 限制分析。**
