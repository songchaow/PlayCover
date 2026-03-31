## RC-001：查清 `supports_gpu_trace=false`

### 一、任务目标

回答一个关键问题：

> **为什么当前真实 app 已能创建 `ready` session，但 Render Capture 相关状态与真实行为仍不符合预期？**

这个问题仍是当前 `Render Capture` 的主阻塞点。

---

### 二、本轮前的已知事实

#### 1. 基础链路已打通

已经确认：

- `PlayCover.app` 已通过安装脚本重装并启动
- GUI MCP HTTP 端口 `19820` 正常监听
- runtime 注册端口 `52741` 正常监听
- 真实 app `QQ飞车` 可以正常 `launch_app`
- `create_session` 能成功返回 `ready`

这说明：

- GUI 内嵌 MCP 正常
- runtime 注册链路正常
- 当前问题不在 `create_session` 本身

#### 2. 历史 live 症状

此前记录的真实对象：

- **app**：`QQ飞车`
- **bundleId**：`com.tencent.tmgp.speedmobile`

此前已经确认：

- `check_playtools_installed == true`
- app 设置里的 `metalCaptureEnabled == true`
- 已安装 app 的 `Info.plist` 中 `MetalCaptureEnabled == true`
- `get_capture_status` 历史结果为：

```json
{
  "available": true,
  "enabled": true,
  "is_capturing": false,
  "supports_gpu_trace": false
}
```

随后执行真实截帧：

- 调用 `capture_metal_frame`
- 返回失败：`Invalid bridge message: Command failed: error`
- 目标输出路径下**没有生成** `.gputrace`

---

### 三、`RC-001-A`：观测增强已完成

本轮之前已经完成的更小子任务是：

> **把 `supports_gpu_trace=false` 和 capture 失败从黑盒布尔值 / 黑盒错误，改造成可判因的诊断输出。**

#### 1. 代码改动

已修改：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Session/BridgeClient.swift`

#### 2. 新增诊断字段

`get_capture_status` 现在除原有字段外，还会返回：

- `supports_developer_tools`
- `has_default_device`
- `default_device_name`
- `failure_reason`
- `diagnostic_summary`

#### 3. capture 失败信息补强

`BridgeClient` 现在会优先透传 runtime 的 `result.message`，因此真实失败应能直接看到类似：

- `GPU trace document not supported`
- 或其他 runtime 侧原始错误描述

---

### 四、`RC-001-B`：本轮真实复测的关键发现

本轮原定任务是：

> **重建并安装带新诊断的 PlayCover / app，执行一次 `get_capture_status` 与一次最小 `capture_metal_frame`，把 live 输出归档后再判定问题归类。**

#### 1. 第一份 live 样本：仍是旧 4 字段

本轮一开始在 `QQ飞车` 上得到的 live 结果是：

- `launch_app`：成功
- `create_session`：`ready`
- `get_capture_status`：**仍只返回 4 个旧字段**
- `capture_metal_frame`：失败，错误为 `GPU trace document not supported`

这说明：

- host 侧 bridge 错误补强已经生效
- 但 runtime 侧新增诊断字段**并没有真正进入 live app**

#### 2. 不是逻辑没生效，而是打包产物陈旧

本轮随后确认：

- `QQ飞车` 实际加载的是：
  - `~/Library/Frameworks/PlayTools.framework/PlayTools`
- `PlayCover.xcodeproj` 在打包时复制的是：
  - `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
- 也就是说，**GUI 打包时并不会直接编译 `Carthage/Checkouts/PlayTools` 的源码，而是吃预构建 framework**

因此，之前的关键矛盾实际上是：

> **源码中的新诊断逻辑已经写好了，但 GUI / 真实 app 仍在加载旧的 `PlayTools.xcframework` 产物。**

#### 3. 为什么这个问题之前一直没暴露得这么明确

因为此前 `RC-001-A` 只完成了源码层面的观测增强，但没有把 `PlayTools` 预构建产物从源码重建出来。

而本轮在尝试源码重建 `PlayTools.framework` 时，又发现了一个会直接阻塞重建的编译问题：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `diagnosticSummary` 字符串插值里的 `"nil"` / `"none"` 转义写法会导致 Swift 编译失败

该问题已在本轮修复。

#### 4. 本轮新增的构建收口

为了避免后续再出现“源码改了但 GUI 仍吃旧 runtime”的情况，本轮新增：

- `BuildScripts/sync_playtools_xcframework.sh`

并把它接入到：

- `BuildScripts/build_gui.sh`
- `BuildScripts/build_and_install.sh`
- `BuildScripts/build_all.sh`

这样 GUI 相关构建入口现在会在构建前自动同步 `PlayTools.xcframework` 预构建 slice。

---

### 五、真正切到最新 PlayTools runtime 后的 live 结果

在完成以下动作后：

1. 修复 `PlayTools` 源码重建阻塞
2. 从源码重建 `PlayTools.framework`
3. 回写 `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
4. 重装 `PlayCover.app`
5. 对 `QQ飞车` 执行 remove / inject PlayTools，使 app 内 `AKInterface.bundle` 与 GUI 内置版本一致
6. 手动 kill 旧 PID，确保是真正的 fresh launch

最新 live 结果变成：

- `launch_app`：成功
- `create_session`：`ready`
- 第一次 `get_capture_status`：**超时**
  - `Bridge operation timed out: Receive timed out`
- 之后 `list_sessions` 显示该 session 进入：`disconnected`
- 最新 crash 报告：`speedmobile-2026-03-31-114113.ips`

日志中可确认：

- 新 runtime 的 `BridgeListener` 已成功启动并完成 register / registerAck
- 也就是：**新的 runtime 确实已经进入真实 app 进程了**
- 当前新主问题不再是“旧 runtime 没切上”，而是：
  - **`get_capture_status` 在真实 app 上执行时未正常返回，随后 session 断开 / app 崩溃**

---

### 六、本轮得到的判因边界

本轮后，`RC-001` 的边界已经明显收敛：

#### 1. 旧 4 字段 live 样本不应再被当作“最新诊断逻辑的真实结果”

因为它来自：

- **陈旧的 `PlayTools.xcframework` 预构建产物**
- 而不是当前 checkout 源码对应的 runtime

#### 2. 真正加载最新 runtime 后，主阻塞点前移了

当前最应该调查的不是：

- `supports_gpu_trace=false` 这个旧布尔值本身

而是：

- **为什么 `get_capture_status` 在真实 app 上会超时**
- **为什么超时后 session 会进入 `disconnected`**
- **为什么随后 app 会 crash**

这更像是：

- runtime 命令派发问题
- `MetalCaptureService.getStatus()` 执行阶段问题
- 主线程同步调用卡住
- 或 runtime 在命令处理过程中触发崩溃

而不再只是“destination 是否支持 `.gpuTraceDocument`”这一层问题。

---

### 七、验证结果

本轮已完成的验证：

- `PlayCover` Release 构建成功
- `PlayTools.framework` 现已可从源码成功重建
- `PlayTools` 新构建产物已成功进入：
  - `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
  - `~/Applications/PlayCover.app/Contents/Frameworks/PlayTools.framework`
  - `~/Library/Frameworks/PlayTools.framework`
- `QQ飞车` 的 `AKInterface.bundle` 已确认与当前 GUI 内置版本哈希一致
- 真正 fresh launch 后，`create_session` 在最新 runtime 下仍可回到 `ready`

额外说明：

- 详细 live 输出已归档到：
  - `live/2026-03-31-qqfc-rc001b.md`

---

### 八、下一步最小任务（`RC-001-C`）

下一步不要扩散范围，**只做一件事**：

> **在真正加载最新 PlayTools runtime 的前提下，定位 `get_capture_status` 为什么会超时并把 session 打到 `disconnected`。**

建议步骤：

1. 保持 `QQ飞车` fresh launch
2. 创建 `ready` session
3. 只执行一次 `get_capture_status`
4. 同步抓：
   - runtime / bridge 日志
   - session 状态变化
   - 最新 crash 报告
5. 若需要新增日志，只在：
   - `BridgeListener` 的 `get_capture_status` 命令处理入口 / 出口
   - `MetalCaptureService.getStatus()`
   - 相关主线程同步调用点
   做最小观测增强

目标不是继续盲试 capture，而是先回答：

- 命令有没有进入 runtime handler
- handler 有没有开始执行
- 是卡住、超时，还是崩溃中断

---

### 九、完成标准

`RC-001` 的阶段性完成标准现在变为：

> **把“旧产物导致的假样本”和“真正新 runtime 下的真实阻塞点”明确区分开，并给出下一个更小调查任务。**

就本轮 `RC-001-B` 而言，完成标准已经达到：

- 证明确实存在“源码更新但 GUI 仍吃旧 `PlayTools.xcframework`”的问题
- 修复了会阻塞 `PlayTools` 源码重建的编译错误
- 把 live 样本推进到了“新 runtime ready，但 `get_capture_status` 超时”的新阶段
- 已经可以明确把后续主线切换到 `RC-001-C`
