## RC-007：定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口

### 一、任务目标

回答新的核心问题：

> **既然 `device` 与 `scope(device)` 两条最小路径都在 `startCapture` 阶段被 Apple API 直接拒绝，那么 app 内成功按钮依赖的真实 capture target / 时机到底是什么？**

---

### 二、任务背景

`RC-006` 已经完成两轮关键实验：

1. 移除了 `supportsDestination(.gpuTraceDocument)` 的 host/runtime 硬门禁
2. 新增了 `capture_target=device|scope` 实验入口，并在真实 `QQ飞车` fresh session 上完成 live 对照

当前已知 live 结论：

- `capture_target=device`：
  - `startCapture failed: Capturing is not supported.`
- `capture_target=scope`（绑定默认 `MTLDevice` 的 `MTLCaptureScope`）：
  - `startCapture failed: Capturing is not supported.`
- 两条路径都没有落盘 `.gputrace`
- 失败后 session 仍保持 `ready`

因此当前已经不宜继续围绕“默认设备级 capture object”反复试验。

---

### 三、本任务只聚焦“真实渲染入口”

本轮优先回答：

1. PlayCover / PlayTools 运行时里是否存在可以拿到**真实渲染 `MTLCommandQueue`** 的入口
2. 如果没有直接入口，最小可行的**观测点 / 注入点**应该插在哪个文件 / 函数
3. app 内成功按钮更可能对应哪种语义：
   - queue capture
   - queue-bound scope
   - app 内部 begin/end 包裹真实 frame render 提交
4. 下一轮最值得做的最小代码实验是什么：
   - queue capture
   - queue-bound scope
   - runtime 观测 `defaultCaptureScope` / command queue 发现逻辑

---

### 四、完成标准

完成本任务时，应至少给出以下之一：

- **一个可实现的真实渲染 command queue 获取点**
- **一份高可信的 queue / scope 注入方案**
- **一轮新的最小实现实验设计，明确不再停留在默认 `MTLDevice` 级别**

更理想的完成结果是：

- 直接产出第一版 queue-bound capture 实验代码，并完成一次真实 live

---

### 五、当前已知关键事实

1. `QQ飞车` app 内调试按钮可以成功生成真实 `.gputrace`
2. PlayCover 路径里：
   - `supports_gpu_trace=false`
   - `supports_developer_tools=false`
   - `failure_reason=gpu_trace_document_unsupported`
3. `RC-006-B` 已确认：
   - `capture_target=device` 与 `capture_target=scope(device)` 都失败在 `startCapture`
   - scope 实验已经命中新 runtime 代码路径，不存在“代码未生效”的歧义
4. 仓内当前没有现成的：
   - `MTLCommandQueue`
   - `CAMetalLayer`
   - `MTKView`
   - queue-bound `MTLCaptureScope`
   高层 Swift 入口暴露点

---

### 六、下一步建议

下一轮优先只做一件事即可：

1. 在 PlayTools 运行时里找一个**最小可插桩点**，用于发现或记录真实渲染队列
2. 若无法直接拿到队列，则优先补：
   - command queue 发现日志
   - `defaultCaptureScope` / queue 相关观测
   - 更贴近渲染提交点的注入点说明
3. 拿到真实 queue 或明确注入点后，再做下一轮 live，而不是继续重复 `device` / `scope(device)`
