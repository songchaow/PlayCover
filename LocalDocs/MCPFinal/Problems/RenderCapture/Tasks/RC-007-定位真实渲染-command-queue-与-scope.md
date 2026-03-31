## RC-007：定位真实渲染 `MTLCommandQueue` / queue-bound scope 入口

### 一、任务结论

本任务已完成。

本轮已经给出并落地了 **第一版真实渲染入口实现**：

1. 在 `PlayTools` 运行时的 `MetalCaptureService.initialize()` 中，新增了对默认 `MTLDevice` 的 `newCommandQueue` / `newCommandQueueWithMaxCommandBufferCount:` 发现钩子
2. runtime 会记录最近发现的真实 `MTLCommandQueue`，并将其摘要暴露到 `get_capture_status`
3. `capture_metal_frame` 新增了两条不再停留在默认设备级的实验路径：
   - `capture_target=queue`
   - `capture_target=queue_scope`
4. `queue_scope` 使用 `MTLCaptureManager.makeCaptureScope(commandQueue:)` 创建 queue-bound scope
5. host / bridge / MCP tool / tests 已全部同步到新路径与新状态字段

这意味着：

> **仓内已经不再只有“默认 `MTLDevice`”这一种实验入口，而是有了可直接围绕真实 runtime command queue 做 live 的第一版代码路径。**

---

### 二、为什么这样做

`RC-006` 已经证明：

- `capture_target=device`
- `capture_target=scope(device)`

两条默认设备级路径都在 `startCapture` 阶段被 Apple API 直接拒绝：

- `startCapture failed: Capturing is not supported.`

因此，继续围绕默认 `MTLDevice` 或默认设备绑定 `MTLCaptureScope` 试验，信息增益已经非常低。

结合用户提供的外部事实：

- 同一台机器
- 同一个 `QQ飞车` 包
- app 内调试按钮可以成功导出真实 `.gputrace`

本轮最合理的收敛方向就是：

- **先拿到真实渲染 `MTLCommandQueue`**
- 再围绕真实 queue 或 queue-bound scope 做下一轮 live

---

### 三、本轮实际落地项

#### 1. runtime / PlayTools

本轮主要改动落在：

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`

新增内容包括：

- command queue 发现钩子
- tracked queue 缓存与摘要输出
- `queue` / `queue_scope` 两种新 capture target
- `defaultCaptureScope` 与 queue 发现状态的诊断输出

当前 `get_capture_status` 新增诊断字段：

- `queue_discovery_installed`
- `tracked_command_queue_count`
- `latest_command_queue_label`
- `latest_command_queue_device_name`
- `latest_command_queue_class_name`
- `default_capture_scope_label`

#### 2. host / MCP bridge / tool

同步修改：

- `PlayCoverMCP/Session/CaptureService.swift`
- `PlayCoverMCP/Session/BridgeProtocol.swift`
- `PlayCoverMCP/Tools/Session/CaptureTools.swift`

完成内容：

- host 侧枚举新增 `queue` / `queue_scope`
- bridge 注释同步新参数与新状态字段
- tool schema / 参数校验 /状态解析同步到新字段

#### 3. tests

同步更新：

- `PlayCoverMCPTests/CaptureToolsTests.swift`

已覆盖：

- `queue_scope` 新参数编码
- tool 参数校验
- `get_capture_status` 中新增 queue 诊断字段的 JSON 透传

---

### 四、本轮验证结果

#### 1. 构建验证

已执行：

- `BuildScripts/build_gui.sh`

结果：

- **通过**

说明：

- `PlayTools` 运行时代码
- `BridgeListener`
- GUI 打包链路

都已经能通过仓库标准脚本构建。

#### 2. 定向 MCP 测试

已执行：

- `BuildScripts/test_mcp.sh CaptureParamsTests CaptureResultTests CaptureErrorTests CaptureErrorMCPMappingTests FakeCaptureServiceTests CaptureServiceValidationTests CaptureCommandEncodingTests CaptureToolsRegistrationTests`

结果：

- **47 tests passed, 0 failures**

#### 3. 全量 MCP 测试

已执行：

- `BuildScripts/test_mcp.sh`

结果：

- 存在 **1 个失败**：
  - `InstallerServiceTests.testInstallFatArm64BinaryDoesNotFailSliceExtraction()`

判断：

- 该失败不在本轮 capture / queue 改动范围内
- 本轮新增 capture 路径相关测试与构建验证均已通过

---

### 五、本轮回答了什么，仍没回答什么

#### 已回答

本轮已经回答了：

1. **真实渲染 `MTLCommandQueue`` 的最小可实现获取点在哪里？**
   - 在 runtime 的 `MetalCaptureService.initialize()` 中，对默认 `MTLDevice` 的 `newCommandQueue` 创建路径做钩取
2. **如果没有现成高层 Swift 暴露点，最小可插桩点应该放哪里？**
   - 放在 PlayTools runtime 自己的 Metal capture service，而不是继续去猜上层 app 的 `CAMetalLayer` / `MTKView`
3. **下一轮最值得做的最小代码实验是什么？**
   - 不是继续 `device` / `scope(device)`
   - 而是直接对：
     - `queue`
     - `queue_scope`
     做真实 live

#### 仍未回答

本轮还没有回答的是：

1. runtime 当前发现到的 queue，是否就是**真实渲染主 queue**
2. 即便拿到真实 queue，`startCapture` 是否还会被 Apple API 拒绝
3. 如果 queue 路径仍失败，问题是否已经进一步收敛到：
   - begin/end 时机
   - 更贴近 command buffer commit 的包裹语义
   - 或 app 内部特定 capture 入口

---

### 六、下一步建议

下一轮只做一件事：

> **在真实 `QQ飞车` fresh session 上验证 `queue` / `queue_scope` 新路径。**

建议顺序：

1. 用最新构建启动 `PlayCover.app`
2. 先看 `get_capture_status`：
   - `queue_discovery_installed`
   - `tracked_command_queue_count`
   - `latest_command_queue_*`
   - `default_capture_scope_label`
3. 若 queue 诊断字段仍为空：
   - 先不要做 capture live
   - 说明新 runtime 代码还没真正进入被测 app，或 app 尚未走到 Metal queue 创建阶段
4. 若 queue 诊断字段已命中：
   - 对 `capture_target=queue`
   - 与 `capture_target=queue_scope`
   做 live 对照
5. 重点记录：
   - 是否落盘 `.gputrace`
   - 若失败，完整 runtime 错误文本
   - queue 摘要是否稳定

对应下一任务：

- `RC-008-验证真实queue路径-live.md`
