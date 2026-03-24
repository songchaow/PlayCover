### 任务编号与标题

- **ID**：`R04`
- **标题**：MCP 截帧工具暴露

### Dashboard

- **状态**：`DONE`
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

### 测试（参照统一测试策略）

**本 task 新增检查项**：C15 ~ C17

| # | 检查项 | 层级 |
|---|--------|------|
| C15 | MCP `capture_metal_frame` 工具已注册 | L3/L4 |
| C16 | MCP `get_capture_status` 工具已注册 | L3/L4 |
| C17 | CaptureTools 单元测试通过 | L2 |

**完成后验证范围**：C01 ~ C17（含 R01~R03 的 C01~C14 回归）

**执行方式**：`./Scripts/verify_render_capture.sh`

**补充验证**：通过 stdio 发送 `tools/list` 确认新工具出现在列表中

### 实施结果

- **实际改动文件**：
  - `PlayCoverMCP/Session/CaptureService.swift`（新增）— CaptureFrameParams、CaptureFrameResult、CaptureStatusResult、CaptureError、CaptureServiceProtocol、CaptureService、FakeCaptureService
  - `PlayCoverMCP/Tools/Session/CaptureTools.swift`（新增）— 注册 `capture_metal_frame` 和 `get_capture_status` 两个 MCP 工具
  - `PlayCoverMCPTests/CaptureToolsTests.swift`（新增）— 8 个测试类覆盖参数、结果、错误映射、Fake 服务、验证、命令编码、工具注册与调用
  - `PlayCoverMCP/main.swift`（修改）— 注册 CaptureService 和 CaptureTools
  - `PlayCover/Services/MCPManager.swift`（修改）— GUI TCP 模式同步注册 CaptureService 和 CaptureTools
  - `PlayCoverMCP/Common/MCPErrorExtensions.swift`（修改）— 添加 CaptureError → PlayCoverMCPError 映射
  - `PlayCover.xcodeproj/project.pbxproj`（修改）— 通过 `Scripts/add_r04_files.py` 脚本添加新文件到三个 target（PlayCover Host、PlayCoverMCP、PlayCoverMCPTests）
  - `Scripts/add_r04_files.py`（新增）— pbxproj 自动化修改脚本
- **关键决策**：
  - 工具放置在 `Tools/Session/` 下，因为截帧需要通过 Bridge TCP 与 runtime 通信，遵循 TouchTools/InputTools 的 Session 工具模式
  - 使用 `sessionId` 而非 `bundle_id` 作为参数，与现有 Session 工具保持一致
  - CaptureService 验证 duration 范围 1-30000ms，超出范围抛出 invalidDuration 错误
  - 使用 `runAsync` + `DispatchSemaphore` 桥接 async 服务调用到同步 ToolHandler
  - pbxproj 脚本需要将文件添加到全部三个 target 的 Sources build phase（Host、MCP CLI、Tests）
- **已知问题**：
  - C05（PlayTools AppSettingsData 缺少 metalCaptureEnabled）和 C09（PlayCover.swift MetalCaptureService 初始化）两项验证失败，属于 R01/R02 的前序遗留问题，不在 R04 范围内
  - PlayCover Host scheme 构建失败仅因 Carthage Bootstrap 脚本（环境配置问题），非代码编译错误
- **Commit Hash**：`56d04ab5`
