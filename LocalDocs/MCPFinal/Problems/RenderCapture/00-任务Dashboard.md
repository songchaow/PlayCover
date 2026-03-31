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
- 真实 app（`QQ飞车`、`原神`）都可以启动并成功创建 `ready` session
- `get_capture_status` 已能在多个真实 app 上稳定返回完整诊断字段
- 真实 app 的 preflight 仍稳定返回：
  - `supports_gpu_trace=false`
  - `supports_developer_tools=false`
  - `failure_reason=gpu_trace_document_unsupported`
- 用户已在同一台机器、同一个 `QQ飞车` 包内，通过 app 自带调试按钮，走 **Apple `MTLCapture` 路线** 成功生成真实 `.gputrace`

因此，当前问题不再是：

> **“这台机器 / 这个 app 组合本身不支持 Apple `MTLCapture` 导出 `.gputrace`。”**

而是：

> **“为什么 app 内成功路径可以导出 `.gputrace`，而 PlayCover 当前实现仍被拦在错误的 capture object / 触发时机之前？”**

---

### 三、最终目标

最终目标只有一个：

> **用真实 app 成功执行 `capture_metal_frame`，生成可验证的 `.gputrace` 文件，并沉淀稳定 SOP。**

完成标准：

- `QQ飞车` 或其他真实 app 能成功 `launch_app`
- `create_session` 返回 `ready`
- `capture_metal_frame` 成功返回，并实际生成 `.gputrace`
- 结果与 app 内成功路径相互印证
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

### 五、构建 / 安装约束

Render Capture 相关联调如果涉及：

- 重建 `PlayTools`
- 重建 `PlayCover.app`
- 安装 / 重装 `PlayCover.app`
- 刷新 `PlayTools.xcframework`

则**必须使用 `BuildScripts/` 里的标准脚本执行**，不要手写 `xcodebuild`，也不要手工复制 `.app` 或手工拼装安装步骤。

当前应遵守的默认入口是：

- GUI 构建：`BuildScripts/build_gui.sh`
- GUI 构建并安装：`BuildScripts/build_and_install.sh`
- `PlayTools.xcframework` 同步：`BuildScripts/sync_playtools_xcframework.sh`
- Render Capture 专项验证：`BuildScripts/verify_render_capture.sh`

这条规则属于 **Render Capture 主文档级约束**，不能只写在子任务文档里。

---

### 六、当前总体判断

当前总体判断如下：

- `RC-001` 已完成：host / runtime / bridge 的观测增强已经就位，并已确认 `get_capture_status` 不再卡在超时
- `RC-003` 已完成：在第二个真实 app `原神` 上完成了非破坏性对照验证，确认 `gpu_trace_document_unsupported` **不是 `QQ飞车` 特有现象**
- `RC-005` 已完成：拿到了“PlayCover 路径下多个真实 app 以及普通 Swift 进程都返回 `supports_gpu_trace=false`”的历史证据
- `RC-006` 已完成：
  - 已先后验证 `device` 与 `scope(device)` 两条默认设备级最小路径
  - 两条路径都在真实 `QQ飞车` fresh session 上失败于同一个 Apple 拒绝点：
    - `startCapture failed: Capturing is not supported.`
  - `scope` 路径已经命中新 runtime 代码，因为错误文本明确回传了：
    - `target=scope`
    - `captureObject=scope(...)`
  - 因此当前可以排除：
    - 仅仅是 `supportsDestination(...)` 的 host/runtime 误门禁
    - 仅仅是“默认 `MTLDevice` 不对，只要换成默认设备绑定的 `MTLCaptureScope` 就会成功”
- 当前最可信的新判断是：
  - app 内成功按钮更可能依赖：
    - **真实渲染 `MTLCommandQueue`**
    - 或 **queue-bound `MTLCaptureScope`**
    - 或更贴近真实渲染提交点的 begin/end 语义
- 当前已知最新成功样本：
  - `QQ飞车` app 内调试按钮成功生成的 `.gputrace`：
    - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

因此，当前最重要的事已经从：

> **反复试默认设备级 capture 路径。**

切换为：

> **定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口，并围绕真实渲染提交点做下一轮最小实验。**

---

### 七、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | **P0** | `DONE` | 查清真实 app 上 `supports_gpu_trace=false / get_capture_status` 的直接现象；已确认当前 live 不再卡在超时，而是稳定返回 `gpu_trace_document_unsupported` | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-003` | **P0** | `DONE` | 用第二个真实 app `原神` 完成对照验证；已确认 `gpu_trace_document_unsupported` **不是 `QQ飞车` 特有现象** | `Tasks/RC-003-对照验证.md` |
| `RC-005` | **P1** | `DONE` | 完成旧假设定位；其“机器 / 环境全局不支持”的总判断已被 `QQ飞车` app 内成功 `.gputrace` 样本修正，但历史样本仍保留为对照证据 | `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md` |
| `RC-006` | **P0** | `DONE` | 已完成默认设备级最小实验闭环：移除 preflight 硬门禁后，又在真实 `QQ飞车` fresh session 上补做 `device` 与 `scope(device)` live 对照；两条路径都失败于 `startCapture failed: Capturing is not supported.` | `Tasks/RC-006-验证系统级-capture-前提与替代路径.md` |
| `RC-007` | **P0** | `TODO` | 定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口；下一轮不再重复默认设备级试验，而是转向真实渲染对象与注入点 | `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md` |
| `RC-002` | **P2** | `TODO` | 在实现路径校正后，再决定是否需要对 `QQ飞车` 做 fresh reinstall + 全链路复测，用于消除旧安装残留歧义 | `Tasks/RC-002-fresh-reinstall-复测.md` |
| `RC-004` | **P2** | `TODO` | 在截帧成功后，整理最终可重复 SOP、产物位置与关单验证标准 | `Tasks/RC-004-成功截帧与关单.md` |

### 八、当前最重要任务

当前最重要任务是：

> **`RC-007`：定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口。**

下一轮建议只做一件事：

1. 在 PlayTools 运行时里找到或新增**最小可插桩点**，用于发现真实渲染 `MTLCommandQueue`
2. 如果拿不到队列，优先补：
   - command queue 发现日志
   - `defaultCaptureScope` / queue 相关观测
   - 更贴近 frame 提交点的注入点说明
3. 只有在拿到真实 queue 或明确注入点后，再做下一轮 live
4. 不要再把时间花在：
   - `supportsDestination(...)` 猜测
   - 默认 `MTLDevice`
   - 默认设备绑定 `MTLCaptureScope`

---

### 九、参考信息

统一参考入口：

- `Refs/01-验证入口与代码锚点.md`
- `BuildScripts/probe_metal_capture_env.sh`

当前已记录的详细问题文档：

- `Tasks/RC-001-查清-supports_gpu_trace_false.md`
- `Tasks/RC-002-fresh-reinstall-复测.md`
- `Tasks/RC-003-对照验证.md`
- `Tasks/RC-004-成功截帧与关单.md`
- `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md`
- `Tasks/RC-006-验证系统级-capture-前提与替代路径.md`
- `Tasks/RC-007-定位真实渲染-command-queue-与-scope.md`
- `live/2026-03-31-qqfc-rc001c.md`
- `live/2026-03-31-yuanshen-rc003a.md`
- `live/2026-03-31-envprobe-rc005a.md`
- `live/2026-03-31-qqfc-rc006a.md`
- `live/2026-03-31-qqfc-rc006b.md`

已知最新成功样本：

- `QQ飞车` app 内调试按钮成功生成的 `.gputrace`：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`
