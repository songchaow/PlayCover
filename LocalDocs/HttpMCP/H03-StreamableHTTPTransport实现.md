# H03：StreamableHTTPTransport 核心实现

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | H02（SSEEncoder + MCPSessionManager 已实现） |
| **预估工时** | 2-3 天 |
| **风险等级** | 高 |

## 目标

实现 `StreamableHTTPTransport`，基于 Hummingbird HTTP 框架，完整实现 MCP 2025-11-25 规范中的 Streamable HTTP 传输协议。

## 设计规格

### 核心接口

```swift
import Foundation
#if canImport(Hummingbird)
import Hummingbird

/// Streamable HTTP transport for MCP server.
/// Implements the MCP 2025-11-25 Streamable HTTP specification.
///
/// Provides a single HTTP endpoint (/mcp) that supports:
/// - POST: Client sends JSON-RPC messages
/// - GET: Client opens SSE stream for server-to-client messages
/// - DELETE: Client terminates session
public final class StreamableHTTPTransport {

    // MARK: - Types

    /// Same signature as TCPTransport.MessageHandler / StdioTransport.MessageHandler
    public typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?

    /// Transport state
    public enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    /// Listen host configuration (reuse TCPTransport.ListenHost pattern)
    public enum ListenHost: String, CaseIterable, Equatable {
        case loopback = "127.0.0.1"
        case allInterfaces = "0.0.0.0"
    }

    // MARK: - Public Properties

    public private(set) var state: State = .stopped
    public let port: UInt16
    public let host: ListenHost
    public let endpointPath: String  // default: "/mcp"

    /// Callback for state changes (dispatched to main queue)
    public var onStateChange: ((State) -> Void)?

    /// Callback for session count changes (dispatched to main queue)
    public var onSessionCountChanged: ((Int) -> Void)?

    /// Current active session count
    public var activeSessionCount: Int { sessionManager.activeSessionCount }

    // MARK: - Internal

    let sessionManager = MCPSessionManager()

    // MARK: - Init

    public init(
        port: UInt16 = 19820,
        host: ListenHost = .loopback,
        endpointPath: String = "/mcp",
        handler: @escaping MessageHandler
    )

    // MARK: - Lifecycle

    /// Start the HTTP server. Non-blocking.
    public func start()

    /// Stop the HTTP server.
    public func stop()
}
#endif
```

### 文件位置

**新建文件**：`PlayCoverMCP/Transport/StreamableHTTPTransport.swift`

**Target membership**：仅 PlayCover GUI target（因为依赖 Hummingbird，CLI 不需要）

> 如果后续需要在测试中使用，可以也添加到 PlayCoverMCPTests target。

### HTTP 路由设计

| 方法 | 路径 | 功能 | 响应 |
|------|------|------|------|
| **POST** | `/mcp` | 客户端发送 JSON-RPC 消息 | JSON 或 SSE 流 |
| **GET** | `/mcp` | 客户端监听服务端推送 | SSE 流 或 405 |
| **DELETE** | `/mcp` | 客户端终止会话 | 200 或 405 |

### POST 处理流程

```
POST /mcp
  ├── 验证 Origin Header（如果存在，检查合法性）
  │     └── 不合法 → 403 Forbidden
  ├── 解析 Content-Type: application/json
  ├── 解析请求体为 JSONRPCMessage
  │     └── 解析失败 → 400 Bad Request (JSON-RPC parse error)
  ├── 判断消息类型：
  │     ├── Notification / Response:
  │     │     ├── 处理 handler(message)
  │     │     └── 返回 202 Accepted (无 body)
  │     └── Request:
  │           ├── 特殊处理 "initialize":
  │           │     ├── 创建 session (MCPSessionManager)
  │           │     ├── handler(message) → response
  │           │     ├── 在响应 Header 中返回 Mcp-Session-Id
  │           │     └── Content-Type: application/json
  │           ├── 其他 request:
  │           │     ├── 验证 Mcp-Session-Id Header
  │           │     ├── 验证 Mcp-Protocol-Version Header
  │           │     ├── handler(message) → response
  │           │     └── 返回 JSON 或 SSE（Phase 1 先只返回 JSON）
  │           └── session 无效:
  │                 └── 404 Not Found
```

### GET 处理流程

```
GET /mcp
  ├── 验证 Origin Header
  ├── 验证 Accept: text/event-stream
  ├── 验证 Mcp-Session-Id Header
  │     └── 无效 → 400 Bad Request
  ├── 验证 Mcp-Protocol-Version Header
  ├── 返回 Content-Type: text/event-stream
  ├── 发送 primer event (id + empty data)
  └── 保持连接打开，等待服务端推送
       └── （H04 实现后才有实际推送内容）
```

### DELETE 处理流程

```
DELETE /mcp
  ├── 验证 Mcp-Session-Id Header
  ├── 终止会话 (sessionManager.terminateSession)
  └── 返回 200 OK
```

## 实现步骤

### Step 1：创建 StreamableHTTPTransport.swift

关键实现要点：

1. **Hummingbird 应用创建**：

```swift
let router = Router()

// POST /mcp
router.post(endpointPath) { request, context -> Response in
    return await self.handlePost(request: request, context: context)
}

// GET /mcp
router.get(endpointPath) { request, context -> Response in
    return await self.handleGet(request: request, context: context)
}

// DELETE /mcp
router.delete(endpointPath) { request, context -> Response in
    return self.handleDelete(request: request, context: context)
}

let app = Application(
    router: router,
    configuration: .init(
        address: .hostname(host.rawValue, port: Int(port))
    )
)
```

2. **异步启动**：Hummingbird 的 `app.run()` 是 `async`，需要在 Task 中运行：

```swift
public func start() {
    guard case .stopped = state else { return }
    setState(.starting)

    Task {
        do {
            // ... 创建 router 和 app ...
            try await app.run()
        } catch {
            await MainActor.run {
                self.setState(.failed(error.localizedDescription))
            }
        }
    }
}
```

3. **POST handler 核心逻辑**：

```swift
private func handlePost(request: Request, context: some RequestContext) async -> Response {
    // 1. Origin validation
    if let origin = request.headers[.origin], !isValidOrigin(origin) {
        return Response(status: .forbidden)
    }

    // 2. Parse body as JSON-RPC message
    guard let body = try? await request.body.collect(upTo: 1_048_576), // 1MB limit
          let message = try? JSONRPCMessage.parse(Data(body)) else {
        return Response(status: .badRequest, body: .init(string: "Parse error"))
    }

    // 3. Route by message type
    switch message {
    case .notification(let notif):
        // Handle notification (e.g., notifications/initialized)
        if notif.method == "notifications/initialized" {
            if let sessionId = request.headers["Mcp-Session-Id"] {
                sessionManager.markInitialized(sessionId)
            }
        }
        _ = handler(message)
        return Response(status: .accepted)

    case .response:
        _ = handler(message)
        return Response(status: .accepted)

    case .request(let req):
        // Special handling for initialize
        if req.method == "initialize" {
            return handleInitialize(message: message, request: request)
        }

        // Validate session
        guard let sessionId = request.headers["Mcp-Session-Id"],
              sessionManager.validateSession(sessionId) != nil else {
            return Response(status: .notFound)
        }

        // Validate protocol version
        // (on first request after initialize, allow missing for backward compat)

        // Process request
        if let response = handler(message) {
            let jsonData = try! response.encode()
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: jsonData))
            )
        }
        return Response(status: .accepted)
    }
}
```

4. **Initialize 特殊处理**：

```swift
private func handleInitialize(message: JSONRPCMessage, request: Request) -> Response {
    let sessionId = sessionManager.createSession()

    if let response = handler(message) {
        let jsonData = try! response.encode()
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/json",
                HTTPField.Name("Mcp-Session-Id")!: sessionId
            ],
            body: .init(byteBuffer: ByteBuffer(data: jsonData))
        )
    }
    return Response(status: .internalServerError)
}
```

5. **GET handler（SSE 流）**：

```swift
private func handleGet(request: Request, context: some RequestContext) async -> Response {
    // Validate Accept header
    guard request.headers[.accept]?.contains("text/event-stream") == true else {
        return Response(status: .methodNotAllowed)
    }

    // Validate session
    guard let sessionId = request.headers["Mcp-Session-Id"],
          sessionManager.validateSession(sessionId) != nil else {
        return Response(status: .badRequest)
    }

    // Create SSE response with async stream
    let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

    // Send primer event
    let primerData = SSEEncoder.encodePrimerEvent(eventId: "stream-\(UUID().uuidString.prefix(8))")
    continuation.yield(ByteBuffer(data: primerData))

    // Store continuation for later pushes (H04 will use this)
    // For now, just keep the stream open

    return Response(
        status: .ok,
        headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
        body: .init(asyncSequence: stream)
    )
}
```

### Step 2：Origin 验证

```swift
/// Validate the Origin header to prevent DNS rebinding attacks.
/// For local servers, allow requests from localhost origins.
private func isValidOrigin(_ origin: String) -> Bool {
    // Allow requests without Origin (non-browser clients like curl, Agent SDKs)
    // Origin validation is mainly for browser-based clients
    let allowedOrigins = [
        "http://localhost",
        "http://127.0.0.1",
        "https://localhost",
        "https://127.0.0.1"
    ]
    // Allow any port on localhost
    for allowed in allowedOrigins {
        if origin == allowed || origin.hasPrefix(allowed + ":") {
            return true
        }
    }
    return false
}
```

### Step 3：创建 StreamableHTTPTransportTests.swift

```swift
// 基本测试：启停、POST initialize、POST tools/list、DELETE
// 使用 URLSession 作为 HTTP 客户端
import XCTest

final class StreamableHTTPTransportTests: XCTestCase {

    func testStartAndStop() async throws {
        // 创建 transport，port: 0 让系统分配
        // 验证 state 变为 .running
        // 停止，验证 state 变为 .stopped
    }

    func testInitializeFlow() async throws {
        // POST initialize → 收到 JSON 响应 + Mcp-Session-Id header
        // POST notifications/initialized → 202
        // POST tools/list → 收到工具列表
    }

    func testSessionValidation() async throws {
        // POST 不带 Mcp-Session-Id → 404
        // POST 带无效 Mcp-Session-Id → 404
    }

    func testDeleteSession() async throws {
        // Initialize → DELETE → 200
        // 再次请求 → 404
    }

    func testOriginValidation() async throws {
        // POST 带恶意 Origin → 403
        // POST 带 localhost Origin → 200
    }
}
```

### Step 4：添加到 Xcode 工程

将 `StreamableHTTPTransport.swift` 添加到 PlayCover GUI target 的 Sources build phase。

如果测试文件需要 Hummingbird，也添加到 PlayCoverMCPTests target。

### Step 5：编译和测试

```bash
# GUI target（包含 Hummingbird）
xcodebuild -scheme PlayCover -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

# CLI target（不受影响）
xcodebuild -scheme PlayCoverMCP -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

# 全量测试
xcodebuild test -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

### Step 6：手动冒烟测试

参考主文档 §五.3 中的 curl 命令进行冒烟测试。

## Phase 1 vs Phase 2 scope

本任务（H03）实现 **Phase 1**：

| 功能 | Phase 1 (H03) | Phase 2 (H04) |
|------|:-:|:-:|
| POST initialize | ✅ JSON 响应 | — |
| POST notification | ✅ 202 | — |
| POST request → JSON | ✅ | — |
| POST request → SSE | ❌ 暂不实现 | ✅ |
| GET SSE stream | ✅ 基础（primer 后保持连接） | ✅ 完整推送 |
| DELETE session | ✅ | — |
| Origin 验证 | ✅ | — |
| Session 管理 | ✅ | — |
| 服务端主动推送 | ❌ | ✅ |
| 断线恢复 | ❌ | ❌（可选后续） |

## 验收标准

- [ ] `StreamableHTTPTransport.swift` 已创建
- [ ] POST `/mcp` + initialize 返回正确 JSON 响应和 `Mcp-Session-Id`
- [ ] POST `/mcp` + notification 返回 202
- [ ] POST `/mcp` + request 返回 JSON 响应
- [ ] GET `/mcp` 返回 `text/event-stream`
- [ ] DELETE `/mcp` 终止会话
- [ ] Origin 验证正确（无效 Origin → 403）
- [ ] Session 验证正确（无效/缺失 → 404）
- [ ] PlayCover GUI scheme 编译通过
- [ ] PlayCoverMCP CLI scheme 编译通过
- [ ] MCP 全量测试通过
- [ ] curl 冒烟测试通过

## 注意事项

1. **Hummingbird async/await**：所有路由 handler 是 `async`，但 `MCPServer.handle()` 是同步的。可以在 async 上下文中直接调用同步方法
2. **ByteBuffer 转换**：Hummingbird 使用 NIO 的 `ByteBuffer`，需要在 `Data` 和 `ByteBuffer` 之间转换
3. **HTTP Header 名称**：Hummingbird 使用 `HTTPField.Name`，自定义 header（如 `Mcp-Session-Id`）需要用 `HTTPField.Name("Mcp-Session-Id")`
4. **端口 0**：测试中使用端口 0 让系统分配，但需要获取实际分配的端口。Hummingbird 可能需要特殊方式获取（检查 `app.server?.localAddress`）
5. **不删除 TCPTransport**：保留 `TCPTransport.swift` 作为向后兼容选项
6. **Content-Type 检查**：POST 请求应检查 `Content-Type: application/json`；GET 请求应检查 `Accept: text/event-stream`
