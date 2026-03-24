### 任务编号与标题

- **ID**：`R04`
- **标题**：MCP 截帧工具暴露

### Dashboard

- **状态**：`TODO`
- **优先级**：`P1`
- **预计工作量**：`S`（小型）
- **依赖任务**：`R03`
- **阻塞任务**：`R06`
- **建议执行顺序**：第 4 个
- **预期提交数**：`1`

### 开工前必读

- `00-主文档.md`
- `R03-Bridge截帧命令处理.md`（确认已完成）
- 本文档
- 了解 MCP 工具注册模式：
  - `PlayCoverMCP/Tools/` — 工具定义目录
  - `PlayCoverMCP/main.swift` — 服务注册入口
  - `PlayCoverMCP/Server/MCPServer.swift` — MCP 服务器核心

### 任务目标

在 PlayCoverMCP 中暴露两个 MCP tool，供外部 AI agent 或 MCP client 调用：

1. `capture_metal_frame` — 触发一次 Metal 帧截取
2. `get_capture_status` — 查询截帧服务状态

### 范围内

1. **新增 `PlayCoverMCP/Tools/Host/CaptureTools.swift`**（或 `Session/CaptureTools.swift`）
   - 定义 `capture_metal_frame` tool
   - 定义 `get_capture_status` tool
2. **修改 `PlayCoverMCP/main.swift`** — 注册新工具
3. **如有 GUI 内嵌 MCP 版本，同步修改 `PlayCover/Services/MCPManager.swift`**
4. 单元测试
5. 文档更新

### 范围外

- 不修改 PlayTools 截帧实现（R02）
- 不修改 Bridge 协议（R03）
- 不修改 GUI 界面（R05）

### 预期改动文件

- `PlayCoverMCP/Tools/Host/CaptureTools.swift`（新增）或 `PlayCoverMCP/Tools/Session/CaptureTools.swift`（新增）
- `PlayCoverMCP/main.swift`
- `PlayCover/Services/MCPManager.swift`（如适用）
- `PlayCoverMCPTests/CaptureToolsTests.swift`（新增）
- `LocalDocs/RenderCapture/` 相关文档

### 实施细节

#### 1. Tool 定义

参考现有工具注册模式（如 `AppTools.swift`、`SettingsTools.swift`），定义：

**`capture_metal_frame`**：

```json
{
    "name": "capture_metal_frame",
    "description": "Capture a Metal GPU frame from a running PlayCover-managed iOS app. Produces a .gputrace file that can be opened in Xcode for render pipeline analysis.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "bundle_id": {
                "type": "string",
                "description": "Bundle identifier of the running app to capture from"
            },
            "output_path": {
                "type": "string",
                "description": "Optional custom output path for the .gputrace file. If not provided, a default path will be used."
            },
            "duration_ms": {
                "type": "integer",
                "description": "Capture duration in milliseconds. Default: 100 (enough for 1-2 frames at 60fps)",
                "default": 100
            }
        },
        "required": ["bundle_id"]
    }
}
```

**`get_capture_status`**：

```json
{
    "name": "get_capture_status",
    "description": "Get the Metal capture service status for a running PlayCover-managed iOS app.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "bundle_id": {
                "type": "string",
                "description": "Bundle identifier of the running app to query"
            }
        },
        "required": ["bundle_id"]
    }
}
```

#### 2. 工具实现

工具实现需要：

1. 通过 `bundle_id` 找到对应的活跃 session
2. 通过 `BridgeClient` 向目标 app 的 runtime 发送 Bridge 命令
3. 等待并返回响应

```swift
// capture_metal_frame 的 handler 伪代码
func handleCaptureTool(params: [String: Any]) async throws -> [String: Any] {
    guard let bundleId = params["bundle_id"] as? String else {
        throw MCPError.invalidParams("bundle_id is required")
    }
    
    // 找到 session
    guard let session = sessionRegistry.findSession(bundleId: bundleId) else {
        throw MCPError.invalidParams("No active session for \(bundleId)")
    }
    
    // 构造 Bridge 命令
    let bridgeParams: [String: Any] = [
        "output_path": params["output_path"] ?? NSNull(),
        "duration_ms": params["duration_ms"] ?? 100
    ]
    
    // 通过 BridgeClient 发送命令
    let response = try await session.bridgeClient.sendCommand("capture_frame", params: bridgeParams)
    
    return [
        "success": response.success,
        "output_path": response.data["output_path"] ?? "",
        "message": response.data["message"] ?? ""
    ]
}
```

#### 3. 工具放置位置的考虑

截帧工具涉及两个层面：
- **Host 层**：需要找到目标 app 的 session
- **Session 层**：需要通过 Bridge 与 runtime 通信

参考现有 Session 相关工具（如 `SessionTools.swift`、`TouchTools.swift`、`InputTools.swift`），截帧工具应该放在 `Tools/Session/` 下，因为它需要与 runtime 交互。

但如果工具只需要 `bundle_id` 而不是 `session_id`，也可以放在 `Tools/Host/` 下，内部通过 bundle_id 查找 session。

**建议**：查看已有工具的分类逻辑后决定。

### 验收标准

1. MCP server 能够暴露 `capture_metal_frame` 和 `get_capture_status` 工具
2. 工具定义的 JSON Schema 正确
3. 通过 MCP 协议调用工具能够正确触发截帧
4. 基本的单元测试通过
5. PlayCoverMCP 和 PlayCoverMCPTests 编译通过

### 验证步骤

1. 构建验证：`xcodebuild -scheme PlayCoverMCP build`
2. 测试验证：`xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64'`
3. MCP 冒烟测试：通过 stdio 发送 `tools/list` 确认新工具出现在列表中

### 实施结果

_（任务完成后由执行 agent 填写）_

- **实际改动文件**：
- **关键决策**：
- **已知问题**：
- **Commit Hash**：
