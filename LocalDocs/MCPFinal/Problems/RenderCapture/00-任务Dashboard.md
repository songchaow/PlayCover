## Render Capture：任务 Dashboard

### 一、文档目的

这份文档是 **每个 agent 的统一入口**。

要求：

- **先读它，再开始工作**
- **主文档保持简洁**，只保留背景、目标、流程、当前优先级与任务状态
- **详细过程、日志、假设、实验结果** 统一下沉到子文档
- agent 结束时要**整理并重写**本页，而不是只在末尾追加

---

### 二、问题背景

当前要解决的是 `Render Capture` 的真实联调问题，目标是让 PlayCover MCP 能对真实 app 成功执行：

- `get_capture_status`
- `capture_metal_frame`

截至当前，已经确认：

- `PlayCover.app` 已能正常启动，GUI 内嵌 MCP 可用
- 真实 app（优先 `QQ飞车`）可以启动并成功创建 `ready` session
- 当前真正的阻塞点不是 session 链路，而是：**截帧链路仍未成功落盘 `.gputrace`**

详细现状见：

- `Tasks/RC-001-查清-supports_gpu_trace_false.md`

---

### 三、最终目标

最终目标只有一个：

> **用真实 app 成功执行 `capture_metal_frame`，生成可验证的 `.gputrace` 文件，并沉淀稳定 SOP。**

完成标准：

- `QQ飞车` 或其他真实 app 能成功 `launch_app`
- `create_session` 返回 `ready`
- `get_capture_status` 显示截帧能力可用
- `capture_metal_frame` 成功返回，并实际生成 `.gputrace`
- 输出一份可重复执行的验证步骤

---

### 四、Agent 工作流（强约束）

每个 agent **只做一个任务**。

标准流程：

1. **先读取本 Dashboard**
2. **只领取一个当前最重要的任务**，不要同时做多个
3. 如果发现该任务过大：
   - 先把它拆成更小的子任务写回 Dashboard
   - **本轮只完成其中一个子任务**
4. 详细调查过程写入对应子文档，不把长日志堆到主文档
5. 收尾时必须更新：
   - 本 Dashboard 的任务状态 / 优先级 / 当前最重要任务
   - 对应子文档的结论、证据、下一步建议
6. 更新时要**整理已有内容**：
   - 删掉过时事项
   - 合并重复项
   - 把不再重要的信息移出主文档

禁止事项：

- **禁止一个 agent 长时间死磕最终目标**
- **禁止把“连续多次尝试 capture”当成一个单独任务无限延长**
- **禁止只追加、不整理主文档**

---

### 五、当前总体判断

当前总体判断如下：

- `session` 链路已经不是主阻塞点
- `supports_gpu_trace=false` 仍是当前最关键的真实阻塞点
- **本轮已完成 `RC-001` 的观测增强子任务**：
  - runtime `get_capture_status` 不再只返回 4 个布尔字段
  - 现在会额外透出：
    - `supports_developer_tools`
    - `has_default_device`
    - `default_device_name`
    - `failure_reason`
    - `diagnostic_summary`
  - `capture_metal_frame` 失败时，bridge 也会保留 runtime 原始错误信息，不再只剩 `Command failed: error`

因此，当前最重要的事已经从“盲重试 capture”切换为：

> **基于新增诊断字段，对真实 app 再做一轮最小复测，收集一份可判因的 live 样本。**

---

### 六、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | **P0** | `DOING` | 查清 `supports_gpu_trace=false` 的直接原因；本轮已完成观测增强，下一步用真实 app 样本判定它是环境级、runtime 级还是 app 级问题 | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-002` | **P1** | `TODO` | 在 `metalCaptureEnabled=true` 前提下，对 `QQ飞车` 做 fresh reinstall + 全链路复测，消除“旧安装残留”歧义 | `Tasks/RC-002-fresh-reinstall-复测.md` |
| `RC-003` | **P1** | `TODO` | 做对照验证，区分问题是 `QQ飞车` 特有，还是当前机器 / 当前 PlayCover 环境的普遍问题 | `Tasks/RC-003-对照验证.md` |
| `RC-004` | **P2** | `TODO` | 在截帧成功后，整理最终可重复 SOP、产物位置与关单验证标准 | `Tasks/RC-004-成功截帧与关单.md` |

### 七、当前最重要任务

当前最重要任务是：

> **`RC-001-B`：重建并安装带新诊断的 PlayCover / app，执行一次 `get_capture_status` 与一次最小 `capture_metal_frame`，把 live 输出归档后再判定问题归类。**

本轮已经完成的是 `RC-001-A`：**把 opaque false / opaque error 改造成可观测的诊断输出。**

---

### 八、参考信息

统一参考入口：

- `Refs/01-验证入口与代码锚点.md`

当前已记录的详细问题文档：

- `Tasks/RC-001-查清-supports_gpu_trace_false.md`
- `Tasks/RC-002-fresh-reinstall-复测.md`
- `Tasks/RC-003-对照验证.md`
- `Tasks/RC-004-成功截帧与关单.md`
