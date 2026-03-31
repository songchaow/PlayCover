## RC-008：验证真实 `queue` / `queue_scope` 路径 live

### 一、任务目标

用真实 app（优先 `QQ飞车`）回答下面这个问题：

> **本轮新加的 `queue` / `queue_scope` 路径，是否已经真正命中真实渲染 `MTLCommandQueue`，并能否比默认设备级路径更接近成功导出 `.gputrace`？**

---

### 二、任务背景

`RC-007` 已经完成了第一版实现：

- runtime 新增真实 command queue 发现钩子
- `capture_metal_frame` 新增：
  - `capture_target=queue`
  - `capture_target=queue_scope`
- `get_capture_status` 新增 queue 发现相关诊断字段

因此，当前最重要的不是继续写新代码，而是先回答：

1. runtime 是否真的看到了真实 queue
2. `queue` / `queue_scope` 是否比 `device` / `scope(device)` 更接近成功路径

---

### 三、执行前提

1. 使用最新构建启动 `PlayCover.app`
2. 如确认被测 app 仍携带旧版 `PlayTools`，按主文档约束使用标准脚本 / 标准安装路径处理，不要手工拼装
3. 真实 app 必须是 fresh launch
4. `create_session` 必须到 `ready`

---

### 四、推荐执行顺序

#### 1. 先看状态，不要先盲试 capture

先执行 `get_capture_status`，重点看：

- `queue_discovery_installed`
- `tracked_command_queue_count`
- `latest_command_queue_label`
- `latest_command_queue_device_name`
- `latest_command_queue_class_name`
- `default_capture_scope_label`

如果这些字段里：

- `queue_discovery_installed != true`
- 或 `tracked_command_queue_count == 0`

则本轮不要急着继续 `capture_metal_frame`，而应先判断：

- 新 runtime 代码是否真正进入被测 app
- app 是否已经开始 Metal 渲染

#### 2. 再做两条 live 对照

仅在 queue 诊断字段已经命中后，再做：

1. `capture_target=queue`
2. `capture_target=queue_scope`

每次都记录：

- 返回消息
- 是否实际落盘 `.gputrace`
- 产物位置
- 若失败，完整 `startCapture failed ...` 文本

---

### 五、完成标准

本任务完成时，至少应得到以下之一：

- **确认 `queue` / `queue_scope` 其中一条能成功落盘 `.gputrace`**
- 或 **确认 runtime 已命中真实 queue，但 `startCapture` 仍失败，并拿到新的高价值错误文本**
- 或 **确认 queue 诊断字段仍为空，从而把阻塞点明确收敛为“新 runtime 代码尚未真正进入被测 app / app 尚未创建 Metal queue”**

---

### 六、记录重点

本轮记录不要再停留在“支持/不支持”的抽象层，而要优先记录：

1. queue 诊断字段是否有值
2. 命中的 queue 摘要是否稳定
3. `queue` 与 `queue_scope` 谁更接近成功路径
4. 若仍失败，失败点是否已经从“错误 capture object”进一步缩小到“错误 begin/end 时机”
