## RC-005：定位环境级 `gpu_trace_document_unsupported`

### 一、任务目标

回答新的核心问题：

> **为什么当前机器 / 当前 PlayCover 环境下，多个真实 app 都会返回 `supports_gpu_trace=false`，并落到 `failure_reason=gpu_trace_document_unsupported`？**

---

### 二、本轮执行范围

本轮不再继续做“多 app 穷举”。

只做两类最小验证：

1. **最新 `PlayCover.app` + 真实 app live 复测**
2. **脱离 PlayCover 的普通 Swift 进程环境探针**

目的不是直接让 `.gputrace` 成功，而是先回答：

> **当前阻塞点更像 session / bridge 问题，还是当前机器 / Xcode-Metal 运行环境级限制。**

---

### 三、本轮关键事实

#### 1. 最新 GUI 与真实 app 链路正常

本轮先完成：

- 重新构建并安装最新 `PlayCover.app`
- 启动最新 GUI
- 确认 GUI MCP HTTP 端口 `19820` 正常监听
- 确认 runtime 注册端口 `52741` 正常监听

随后对两款真实 app 做最小 live 复测：

- `QQ飞车`（`com.tencent.tmgp.speedmobile`）
- `原神`（`com.miHoYo.Yuanshen`）

两者当前都满足：

- `check_playtools_installed == true`
- `get_app_settings.metalCaptureEnabled == true`
- `launch_app` 成功
- `create_session(timeout=20)` 成功，session 都为 `ready`

#### 2. 两个真实 app 的 capture 诊断完全一致

两者 `get_capture_status` 都稳定返回：

- `available=true`
- `enabled=true`
- `supports_gpu_trace=false`
- `supports_developer_tools=false`
- `has_default_device=true`
- `default_device_name=Apple M4 Pro`
- `failure_reason=gpu_trace_document_unsupported`

两者补做一次最小 `capture_metal_frame(duration_ms=100)` 后，也都直接失败在同一条 runtime 文本上：

```text
GPU trace document not supported. enabled=true, captureManagerAvailable=true, supportsGPUTrace=false, supportsDeveloperTools=false, hasDefaultDevice=true, defaultDeviceName=Apple M4 Pro, failureReason=gpu_trace_document_unsupported
```

而且失败后：

- `list_sessions` 中两个 session 仍保持 `ready`
- 当前 crash 目录没有新增本轮 `QQ飞车` / `原神` crash 报告

这说明当前失败表现为：

> **能力不支持，但 session 链路仍健康。**

#### 3. 普通 Swift 进程里的环境探针也得到同样结果

为区分“只有 PlayCover runtime 不支持”还是“当前机器级不支持”，本轮额外在普通 Swift 进程中直接探测：

- `MTLCaptureManager.supportsDestination(.gpuTraceDocument)`
- `MTLCaptureManager.supportsDestination(.developerTools)`
- `MTLCreateSystemDefaultDevice()`

结果是：

```text
supports_gpu_trace=false
supports_developer_tools=false
default_device=Apple M4 Pro
```

即使带上社区案例里常见的：

- `METAL_DEVICE_WRAPPER_TYPE=1`

再测一轮，结果仍然不变：

```text
supports_gpu_trace=false
supports_developer_tools=false
default_device=Apple M4 Pro
```

这一步是本轮最关键的新证据。

因为它表明：

- 即使完全脱离 PlayCover MCP / runtime session / bridge
- 当前机器上的普通进程仍然看不到 `.gpuTraceDocument` 与 `.developerTools` 支持
- 但默认 Metal device 又是可见的

因此当前更可信的方向是：

> **当前机器 / 当前 Xcode-Metal 运行环境对 capture destination 的支持策略本身受限。**

#### 4. 安装态差异不足以解释当前主症状

本轮额外读取两款已安装 app 的 `Info.plist`：

- `QQ飞车`：`MetalCaptureEnabled == true`
- `原神`：**缺少** `MetalCaptureEnabled`

但两者 live 诊断仍然完全一致。

因此至少可以得出：

> **安装包里是否存在 `MetalCaptureEnabled` key，不足以解释当前 `supports_gpu_trace=false` 的主症状。**

---

### 四、本轮结论

`RC-005` 到本轮为止，可以视为 **完成**。

因为它已经达到了“强证据支持的根因假设”完成标准：

1. 最新 `PlayCover.app`、最新 GUI MCP、最新真实 session 链路都正常
2. 两个真实 app 都稳定返回相同的 `gpu_trace_document_unsupported`
3. capture 失败后 session 仍保持 `ready`
4. **普通 Swift 进程中也同样得到 `supports_gpu_trace=false / supports_developer_tools=false`**
5. 社区经验里常见的 `METAL_DEVICE_WRAPPER_TYPE=1` 在本机上没有改变结果

因此当前最可信的判断是：

> **阻塞点主要位于当前机器 / 当前 Xcode-Metal 运行环境对 `.gpuTraceDocument` / `.developerTools` destination 的支持限制，而不是 PlayCover MCP session 自身。**

---

### 五、已经回答的问题

本任务当前已经能明确回答：

#### 1. 继续换更多真实 app 是否还有意义？

**意义已经很低。**

因为：

- 两个真实 app 已经给出完全一致的 live 样本
- 普通 Swift 进程里也同样不支持目标 destination

所以继续换 app，大概率不会改变主结论。

#### 2. 后续主线是否应切向系统 / 工具链 / Apple API 限制分析？

**是。**

更合理的下一步应该围绕：

- 是否存在任何系统级可行路径让 `supportsDestination == true`
- Apple 文档对 `.gpuTraceDocument` / `.developerTools` 的明确限制说明
- 是否需要改走 Xcode attach / Developer Tools 驱动路径

---

### 六、后续建议

建议把下一步任务收敛为：

> **验证当前机器是否存在任何系统级可行路径，让 `.gpuTraceDocument` 或 `.developerTools` destination 变为可用。**

可直接复跑的入口：

- `BuildScripts/probe_metal_capture_env.sh`

详细 live 与环境探针样本见：

- `live/2026-03-31-envprobe-rc005a.md`
- `live/2026-03-31-qqfc-rc001c.md`
- `live/2026-03-31-yuanshen-rc003a.md`
