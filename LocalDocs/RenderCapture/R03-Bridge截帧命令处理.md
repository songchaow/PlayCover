### 任务编号与标题

- **ID**：`R03`
- **标题**：PlayTools Bridge 截帧命令处理

### Dashboard

- **状态**：`DONE`
- **优先级**：`P1`
- **预计工作量**：`S`（小型）
- **依赖任务**：`R02`
- **阻塞任务**：`R04`
- **建议执行顺序**：第 3 个
- **预期提交数**：`1`

### 开工前必读

- `00-主文档.md`
- `R02-PlayTools-MetalCaptureService.md`（确认已完成）
- 本文档
- 了解 Bridge 通信机制：
  - `PlayCoverMCP/Session/BridgeProtocol.swift` — Bridge 协议定义
  - `PlayCoverMCP/Session/BridgeClient.swift` — Host 侧 Bridge 客户端
  - `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift` — PlayTools 侧 Bridge 监听器

### 任务目标

在 PlayTools 的 Bridge 层新增 `capture_frame` 和 `get_capture_status` 命令处理，使 PlayCover Host（通过 MCP 或直接）能够远程触发截帧。

### 范围内

1. **修改 PlayTools BridgeListener**
   - 在 `handleCommand()` 中新增 `capture_frame` 命令
   - 在 `handleCommand()` 中新增 `get_capture_status` 命令
2. **修改 PlayCoverMCP BridgeProtocol**
   - 在协议定义中新增截帧相关的命令类型
3. 文档更新

### 范围外

- 不修改 MCP 工具定义（R04）
- 不修改 GUI（R05）

### 预期改动文件

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`
- `PlayCoverMCP/Session/BridgeProtocol.swift`
- `LocalDocs/RenderCapture/` 相关文档

### 实施细节

#### 1. Bridge 协议扩展

**文件**：`PlayCoverMCP/Session/BridgeProtocol.swift`

在现有的 Bridge 命令类型中新增：

```swift
// 在 BridgeCommand 或类似的命令枚举/类型中新增
case captureFrame      // "capture_frame"
case getCaptureStatus  // "get_capture_status"
```

命令参数格式（JSON）：

```json
// capture_frame 命令
{
    "type": "command",
    "command": "capture_frame",
    "params": {
        "output_path": "/optional/custom/path.gputrace",
        "duration_ms": 100
    }
}

// get_capture_status 命令
{
    "type": "command", 
    "command": "get_capture_status",
    "params": {}
}
```

响应格式：

```json
// capture_frame 响应
{
    "type": "commandResponse",
    "success": true,
    "data": {
        "output_path": "/Users/.../Documents/Captures/com.example.app_20260325_143000.gputrace",
        "message": "Capture completed successfully"
    }
}

// get_capture_status 响应
{
    "type": "commandResponse",
    "success": true,
    "data": {
        "available": true,
        "supports_gpu_trace": true,
        "is_capturing": false,
        "enabled": true
    }
}
```

#### 2. BridgeListener 命令处理

**文件**：`Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`

在 `handleCommand()` 的 switch/if-else 链中新增：

```swift
case "capture_frame":
    let outputPath = params?["output_path"] as? String
    let durationMs = params?["duration_ms"] as? Int ?? 100
    let outputURL = outputPath.map { URL(fileURLWithPath: $0) }
    
    // 异步执行截帧（start → wait → stop）
    DispatchQueue.global(qos: .userInitiated).async {
        let startResult = MetalCaptureService.shared.captureFrame(outputURL: outputURL)
        guard startResult.success else {
            self.sendResponse(success: false, data: ["message": startResult.message])
            return
        }
        
        // 等待指定时间后停止截帧
        Thread.sleep(forTimeInterval: Double(durationMs) / 1000.0)
        
        let stopResult = MetalCaptureService.shared.stopCapture()
        self.sendResponse(success: true, data: [
            "output_path": startResult.outputPath ?? "",
            "message": "Capture completed"
        ])
    }

case "get_capture_status":
    let status = MetalCaptureService.shared.getStatus()
    sendResponse(success: true, data: [
        "available": status.available,
        "supports_gpu_trace": status.supportsGPUTrace,
        "is_capturing": status.isCapturing,
        "enabled": status.enabled
    ])
```

#### 3. 注意事项

- **BridgeListener 的现状**：当前 BridgeListener 中很多命令处理标记为 TODO，已支持的命令包括 `tap`、`long_press`、`swipe`、`drag`、`press_key`、`type_text`、`toggle_debug_overlay`
- **响应机制**：需要确认 BridgeListener 中发送响应的具体方法名和格式，参考已有命令的响应模式
- **线程模型**：截帧操作可能需要在特定线程执行（Metal 命令需要在 Metal 线程或主线程），需要测试确认

### 验收标准

1. BridgeProtocol 中定义了 `capture_frame` 和 `get_capture_status` 命令
2. BridgeListener 能够正确处理这两个新命令
3. 通过 Bridge TCP 发送命令能够触发截帧并返回响应
4. PlayTools 和 PlayCoverMCP 都能正常编译

### 测试（参照统一测试策略）

**本 task 新增检查项**：C12 ~ C14

| # | 检查项 | 层级 |
|---|--------|------|
| C12 | `BridgeProtocol` 含 `capture_frame` 命令 | L3 |
| C13 | `BridgeListener` 处理 `capture_frame` 命令 | L3 |
| C14 | `BridgeListener` 处理 `get_capture_status` 命令 | L3 |

**完成后验证范围**：C01 ~ C14（含 R01 的 C01~C07、R02 的 C08~C11 回归）

**执行方式**：`./Scripts/verify_render_capture.sh`

**人工验证**（如可行）：通过 TCP 发送 `capture_frame` 命令，验证响应格式正确

### 实施结果

- **实际改动文件**：
  - `PlayCoverMCP/Session/BridgeProtocol.swift` — 新增 `BridgeCommandName` 枚举，定义所有命令字符串常量（含 `captureFrame` 和 `getCaptureStatus`）
  - `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift` — 在 `handleCommand()` 中新增 `capture_frame` 和 `get_capture_status` case
  - `.gitignore` — 为 `BridgeListener.swift` 添加逐级打洞例外规则，纳入 git 管理
  - `LocalDocs/RenderCapture/00-主文档.md` — 更新任务看板状态
- **关键决策**：
  - Bridge 协议层不需要新增 `BridgeMessageType` case：现有的 `command` / `commandResponse` 消息类型足够，命令区分靠 `CommandPayload.command` 字符串字段
  - 新增 `BridgeCommandName` 枚举统一管理命令字符串常量，便于 R04 MCP 工具引用，也为已有命令补全了常量定义
  - `capture_frame` 命令同步调用 `MetalCaptureService.shared.captureFrame()`，截帧的定时停止由 service 内部的 `asyncAfter` 处理，BridgeListener 不做额外线程等待
  - `BridgeListener.swift` 通过 `.gitignore` 逐级打洞纳入 git 管理（同 `PlaySettings.swift`、`MetalCaptureService.swift`、`PlayCover.swift`）
- **已知问题**：无
- **Commit Hash**：`f47897e9`
