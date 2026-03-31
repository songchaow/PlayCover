## RC-002：fresh reinstall 复测

### 一、任务目标

在 `metalCaptureEnabled=true` 前提下，对真实 app 做一次 **fresh uninstall / reinstall / launch / session / capture** 全链路复测，用来消除“旧安装残留”歧义。

---

### 二、为什么它不是当前 P0

当前已有证据显示：

- `enabled=true`
- 已安装 app 的 `Info.plist` 中 `MetalCaptureEnabled=true`

因此它不像 `RC-001` 那样是当前最直接阻塞点。

但它仍有价值，因为文档中明确写过：

- 修改该设置后需要**重新安装**应用

所以需要一个**单独任务**来做这件事，而不是混在其它调查里。

---

### 三、本任务只做这些事

本任务完成范围应限制为：

1. 卸载目标 app
2. 确认 `metalCaptureEnabled=true`
3. 重新安装 / 重新拉起 app
4. 再做一次：
   - `launch_app`
   - `create_session`
   - `get_capture_status`
   - `capture_metal_frame`
5. 记录结果，并回写 Dashboard

不要在本任务里同时：

- 改 runtime 代码
- 改日志系统
- 做多个 app 对照验证

---

### 四、完成标准

输出一份明确结论：

- fresh reinstall **是否改变**了 `supports_gpu_trace` / `capture_metal_frame` 的结果
- 如果没有改变，应把该方向降级，不再作为主线阻塞
