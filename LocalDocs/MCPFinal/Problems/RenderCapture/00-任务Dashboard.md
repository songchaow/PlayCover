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
- PlayCover 当前实现里，真实 app 仍稳定返回：
  - `supports_gpu_trace=false`
  - `supports_developer_tools=false`
  - `failure_reason=gpu_trace_document_unsupported`
- **但现在出现了新的强证据**：用户已在同一台机器、同一个 `QQ飞车` 包内，通过 app 自带调试按钮，走 **Apple `MTLCapture` 路线** 成功生成真实 `.gputrace`

这说明当前主问题已经不应再表述为：

> **“这台机器 / 这个 app 组合本身不支持 Apple `MTLCapture` 导出 `.gputrace`。”**

而应切换为：

> **“为什么 app 内成功路径可以导出 `.gputrace`，而 PlayCover 当前实现却把自己拦在 `supportsDestination(...)` / 当前触发方式之前？”**

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
- **但 `RC-005` 的旧总判断已被新证据修正**：
  - 同一台机器、同一个 `QQ飞车`、同样是 Apple `MTLCapture` 路线，app 内调试按钮已经成功生成 `.gputrace`
  - 因此，**“当前机器 / 当前 app 全局不支持 `.gpuTraceDocument`”不再是当前最可信结论**
  - 现在更应优先怀疑的是：
    - PlayCover 当前把 `supportsDestination(.gpuTraceDocument)` 当成了过早的硬门禁
    - 当前 `captureObject` 选择（默认 `MTLDevice`）与 app 内成功路径不一致
    - 当前外部触发时机 / start-stop 语义与 app 内成功路径不一致
    - 当前实现缺少对 app 内成功行为的直接对照观察
- 已知最新强证据：
  - 用户已在 `QQ飞车` 中通过 app 内调试按钮成功保存一份真实 `.gputrace`
  - 成功产物位于：
    - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

因此，当前最重要的事已经从：

> **验证当前机器是否存在任何系统级可行路径，让 `.gpuTraceDocument` 或 `.developerTools` destination 变为可用。**

切换为：

> **以 `QQ飞车` app 内成功截帧路径为金标准，对照 PlayCover 当前实现，找出差异并做最小修正实验。**

---

### 七、任务 TODO 状态

| ID | 优先级 | 状态 | 任务 | 详细文档 |
|---|---|---|---|---|
| `RC-001` | **P0** | `DONE` | 查清真实 app 上 `supports_gpu_trace=false / get_capture_status` 的直接现象；已确认当前 live 不再卡在超时，而是稳定返回 `gpu_trace_document_unsupported` | `Tasks/RC-001-查清-supports_gpu_trace_false.md` |
| `RC-003` | **P0** | `DONE` | 用第二个真实 app `原神` 完成对照验证；已确认 `gpu_trace_document_unsupported` **不是 `QQ飞车` 特有现象** | `Tasks/RC-003-对照验证.md` |
| `RC-005` | **P1** | `DONE` | 完成旧假设定位；其“机器 / 环境全局不支持”的总判断已被 `QQ飞车` app 内成功 `.gputrace` 样本修正，但历史样本仍保留为对照证据 | `Tasks/RC-005-定位环境级-gpu-trace-unsupported.md` |
| `RC-006` | **P0** | `TODO` | 以 `QQ飞车` app 内成功按钮为金标准，观察并对照 PlayCover 当前实现，重点比较 `supportsDestination(...)` 门禁、`captureObject`、触发时机与 start/stop 语义，形成最小实验方案 | `Tasks/RC-006-验证系统级-capture-前提与替代路径.md` |
| `RC-002` | **P2** | `TODO` | 在实现路径校正后，再决定是否需要对 `QQ飞车` 做 fresh reinstall + 全链路复测，用于消除旧安装残留歧义 | `Tasks/RC-002-fresh-reinstall-复测.md` |
| `RC-004` | **P2** | `TODO` | 在截帧成功后，整理最终可重复 SOP、产物位置与关单验证标准 | `Tasks/RC-004-成功截帧与关单.md` |

### 八、当前最重要任务

当前最重要任务是：

> **`RC-006`：以 `QQ飞车` app 内成功截帧路径为金标准，对照并修正 PlayCover 当前实现。**

下一轮建议只做一件事：

1. 获取并记录 app 内调试按钮的**最短复现步骤**
2. 观察该成功路径的行为特征：
   - 一次点击还是开始/结束两步
   - 触发后多久落盘
   - 是否出现明显卡顿 / 暂停 / UI 提示
3. 对照当前 `MetalCaptureService.captureFrame(...)`，优先审视：
   - 是否不该把 `supportsDestination(.gpuTraceDocument)` 当成硬前置条件
   - 是否不该只抓默认 `MTLDevice`
   - 是否需要改成更贴近 app 渲染时机的触发方式
4. 只做**最小修正实验**，避免再次回到泛化的环境猜测

本轮结果表明：

- 继续单纯围绕“机器是否全局不支持”做推断，价值已经很低
- 后续主线应切到：**参考 app 内成功路径，修正我们自己的实现假设**

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
- `live/2026-03-31-qqfc-rc001c.md`
- `live/2026-03-31-yuanshen-rc003a.md`
- `live/2026-03-31-envprobe-rc005a.md`

已知最新成功样本：

- `QQ飞车` app 内调试按钮成功生成的 `.gputrace`：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`
