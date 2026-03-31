## RC-006：以 app 内成功路径为金标准，对照修正 PlayCover 截帧实现

### 一、任务目标

回答新的核心问题：

> **同一台机器、同一个 `QQ飞车`、同样是 Apple `MTLCapture` 路线，为什么 app 内调试按钮可以成功生成 `.gputrace`，而 PlayCover 当前实现仍失败在 `supportsDestination(...)` / 当前触发方式之前？**

---

### 二、任务结论

`RC-006` 到本轮已经完成，并收敛出一条高可信差异链：

1. **移除 `supportsDestination(.gpuTraceDocument)` 的硬门禁**后，真实失败点已经推进到 Apple API 本身：
   - `startCapture failed: Capturing is not supported.`
2. 本轮新增 `capture_target=device|scope` 最小实验后，又完成了同一 fresh `QQ飞车` session 上的直接对照：
   - `device`：失败于 `startCapture`
   - `scope(device)`：仍失败于 `startCapture`
3. `scope` 路径已经明确命中新 runtime 新代码，因为错误文本里回传了：
   - `target=scope`
   - `captureObject=scope(...)`
4. 因此当前已经可以排除两个方向：
   - **不是**只有 host / runtime 的 preflight 门禁误伤
   - **也不是**只要把 capture object 从默认 `MTLDevice` 换成默认设备绑定的 `MTLCaptureScope` 就能逼近 app 内成功路径

当前最可信的新判断是：

> **app 内成功按钮更可能依赖真实渲染 `MTLCommandQueue`、queue-bound scope，或更贴近真实 frame 提交点的 begin/end 语义，而不是当前 PlayCover 这条默认设备级路径。**

---

### 三、本任务产出

本任务已经给出了完成标准要求中的两类结果：

- **一份最值得优先尝试的代码实验点**
- **一条可以解释“为什么 app 内成功、PlayCover 当前失败”的高可信差异链**

本轮新增的最小实现实验包括：

1. `capture_metal_frame` 支持 `capture_target=device|scope`
2. runtime `scope` 路径使用临时 `MTLCaptureScope`
3. `scope` 模式改为：
   - 在首个 vsync 时 `begin()`
   - 在满足 `duration_ms` 且至少经过 2 个 vsync 后 `end()` + `stopCapture()`
4. runtime 错误文本显式回传：
   - `target=...`
   - `captureObject=...`

详细 live 样本见：

- `live/2026-03-31-qqfc-rc006a.md`
- `live/2026-03-31-qqfc-rc006b.md`

---

### 四、关键 live 事实（截至 2026-03-31）

1. `QQ飞车` app 内调试按钮已经成功生成真实 `.gputrace`
2. fresh `QQ飞车` session 上，`get_capture_status` 仍稳定返回：
   - `supports_gpu_trace=false`
   - `supports_developer_tools=false`
   - `failure_reason=gpu_trace_document_unsupported`
3. `capture_target=scope` 的真实失败文本为：
   - `startCapture failed: Capturing is not supported.. target=scope, captureObject=scope(...)`
4. 同 session 的 `capture_target=device` 对照为：
   - `startCapture failed: Capturing is not supported.. target=device, captureObject=device(...)`
5. 两条路径都没有落盘 `.gputrace`
6. 两条路径失败后 session 都仍保持 `ready`

---

### 五、对后续任务的直接影响

`RC-006` 到此应视为**已完成并收口**，因为默认设备级路径已经被充分验证：

- preflight 门禁分支：已验证
- `device` 分支：已验证
- `scope(device)` 分支：已验证

下一步主线不应继续停留在这三类路径上，而应正式切到：

> **定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口。**

后续请转到：

- `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md`
