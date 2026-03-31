## RC-006：以 app 内成功路径为金标准，对照修正 PlayCover 截帧实现

### 一、任务目标

回答新的核心问题：

> **同一台机器、同一个 `QQ飞车`、同样是 Apple `MTLCapture` 路线，为什么 app 内调试按钮可以成功生成 `.gputrace`，而 PlayCover 当前实现仍失败在 `supportsDestination(...)` / 当前触发方式之前？**

---

### 二、任务背景

此前 `RC-005` 曾得到一条强历史证据链：

- PlayCover 路径下，多个真实 app 稳定返回：
  - `supports_gpu_trace=false`
  - `supports_developer_tools=false`
  - `failure_reason=gpu_trace_document_unsupported`
- 普通 Swift 进程里，`MTLCaptureManager.supportsDestination(.gpuTraceDocument)` 也返回 `false`

但 2026-03-31 出现新的更强证据：

- 用户已在同一台机器、同一个 `QQ飞车` 包内，通过 app 自带调试按钮，走 **Apple `MTLCapture` 路线** 成功生成真实 `.gputrace`
- 成功产物位于：
  - `/Users/songdogwang/Library/Containers/com.tencent.tmgp.speedmobile/Data/Documents/FrameCapture/CapturedFrame20260331135148.gputrace`

因此当前已经不能再把主问题表述为：

> **“当前机器 / 当前 app 组合根本不支持 `.gpuTraceDocument`。”**

更合理的新方向是：

> **把 app 内成功路径当成金标准，直接对照 PlayCover 当前实现，找出调用门禁、`captureObject`、触发时机或 start/stop 语义上的关键差异。**

---

### 三、本任务只聚焦“成功路径对照”

本轮优先回答：

1. app 内调试按钮的**最短复现步骤**是什么
2. 它是一次点击完成，还是开始 / 结束两步
3. 触发后大概多久落盘，是否伴随明显卡顿 / 暂停 / UI 提示
4. 它与 `MetalCaptureService.captureFrame(...)` 的关键差异是什么：
   - `supportsDestination(.gpuTraceDocument)` 是否只是一个误导性的硬门禁
   - 当前是否不该只抓默认 `MTLDevice`
   - 当前外部触发时机是否偏离 app 的真实渲染时机
   - 当前自动 stop 的方式是否与 app 内成功路径不一致

---

### 四、完成标准

完成本任务时，应至少给出以下之一：

- **一份基于成功路径对照得出的最小修正方案**
- **一组最值得优先尝试的代码实验点**
- **一条可以解释“为什么 app 内成功、PlayCover 当前失败”的高可信差异链**

更理想的完成结果是：

- 直接产出一个新的最小实现实验，使 PlayCover 路径也能成功生成 `.gputrace`

---

### 五、本轮已知关键事实（2026-03-31）

1. `QQ飞车` app 内成功按钮已经生成真实 `.gputrace`
2. 该成功样本不是空壳路径，而是完整 trace 包
3. app 内实现使用的也是 **Apple `MTLCapture` 路线**，不是自研替代格式
4. 因此：
   - `supports_gpu_trace=false` / `supports_developer_tools=false` 在 PlayCover 当前路径下仍然是**真实现象**
   - 但它们**不能再被直接解释为“当前机器或当前 app 全局不支持 Apple `MTLCapture`”**
5. 当前更值得怀疑的，是 PlayCover 自己的实现假设：
   - 过早依赖 `supportsDestination(...)`
   - `captureObject` 选择过粗
   - 触发时机不对
   - 自动 stop 语义与 app 内成功路径不一致

---

### 六、下一步建议

下一轮优先做一件事即可：

1. 获取用户提供的 app 内调试按钮复现步骤
2. 按该步骤观察成功路径的外部行为
3. 直接对照：
   - `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
   - app 内成功路径的行为特征
4. 形成一个**最小实验方案**，优先尝试修正：
   - 去掉或放宽 `supportsDestination(.gpuTraceDocument)` 的硬门禁
   - 调整 `captureObject`
   - 调整 start/stop 触发时机

如果该最小实验能成功落盘 `.gputrace`，则当前主线即可从“解释差异”切换为“整理稳定 SOP”。
