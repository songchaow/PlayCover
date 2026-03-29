# H04：MCPServer 双向通道改造

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ⬜ 待开始 |
| **前置依赖** | H03（StreamableHTTPTransport 基础可用） |
| **预估工时** | 1.5-2 天 |
| **风险等级** | 高 |

## 目标

1. 为 `MCPServer` 增加服务端主动推送能力（`notificationSink` 回调）
2. 将 `MCPLogger.onLog` 和 `TaskManager.onStatusChange` 桥接到推送通道
3. 在 `StreamableHTTPTransport` 中实现 SSE 推送：通过 GET SSE 流和 POST SSE 响应向客户端推送通知
4. 支持 POST 请求的 SSE 流响应模式（可在最终响应前发送中间通知）

## 背景

### 当前问题

`MCPServer.handle()` 是**纯同步的请求-响应模型**：

```swift
public func handle(_ message: JSONRPCMessage) -> JSONRPCMessage?
```

这意味着：
- 服务端不能在处理完请求后主动推送通知给客户端
- `TaskManager.onStatusChange`（任务进度更新）没有途径发送到客户端
- `MCPLogger.onLog`（日志消息）没有途径发送到客户端

### Streamable HTTP 需要

MCP 规范允许服务端在以下场景推送消息：
1. **POST SSE 流**：处理 request 时，可以在返回最终 response 前发送中间通知
2. **GET SSE 流**：服务端可以随时向客户端发送通知/请求

## 设计规格

### MCPServer 变更

**最小侵入性改动**：不改变 `handle()` 的签名，而是新增一个可选的推送回调：

```swift
// MCPServer.swift 新增

/// Callback for sending server-initiated notifications to clients.
/// The transport layer sets this to route notifications through the appropriate channel.
/// - Parameter message: The JSON-RPC notification to send
public var notificationSink: ((JSONRPCMessage) -> Void)?

/// Convenience: send a notification through the sink.
public func sendNotification(_ notification: JSONRPCNotification) {
    let message = JSONRPCMessage.notification(notification)
    notificationSink?(message)
}

/// Wire up logger and task manager to send notifications.
/// Call this after setting notificationSink.
public func wireNotifications() {
    // Wire logger notifications
    logger?.onLog = { [weak self] entry in
        guard let self = self, self.isInitialized else { return }
        let params = LoggingMessageParams(level: entry.level, data: entry.message, logger: entry.logger)
        if let paramsAnyCodable = try? AnyCodable(params) {
            let notif = JSONRPCNotification(method: "notifications/message", params: paramsAnyCodable)
            self.sendNotification(notif)
        }
    }

    // Wire task manager notifications
    taskManager?.onStatusChange = { [weak self] taskId, status in
        guard let self = self, self.isInitialized else { return }
        if let statusAnyCodable = try? AnyCodable(status) {
            let params: [String: Any] = ["taskId": taskId, "status": statusAnyCodable.value as Any]
            let notif = JSONRPCNotification(method: "notifications/tasks/update", params: AnyCodable(params))
            self.sendNotification(notif)
        }
    }
}
```

### StreamableHTTPTransport 变更

#### SSE Stream Manager

管理每个 session 的 SSE 连接（GET 流和 POST 流）：

```swift
/// Manages SSE streams for a session.
/// Each session can have:
/// - One or more GET SSE streams (for server-initiated messages)
/// - Zero or more POST SSE streams (for request processing)
final class SSEStreamManager {
    
    /// A registered SSE stream
    struct StreamInfo {
        let sessionId: String
        let streamId: String
        let continuation: AsyncStream<ByteBuffer>.Continuation
        let type: StreamType
        let createdAt: Date

        enum StreamType {
            case get     // GET /mcp SSE stream
            case post    // POST /mcp SSE stream (for a specific request)
        }
    }

    private var streams: [String: StreamInfo] = [:]  // streamId -> StreamInfo
    private let lock = NSLock()

    /// Register a new SSE stream.
    func register(sessionId: String, streamId: String, continuation: AsyncStream<ByteBuffer>.Continuation, type: StreamInfo.StreamType) {
        lock.lock()
        streams[streamId] = StreamInfo(sessionId: sessionId, streamId: streamId, continuation: continuation, type: type, createdAt: Date())
        lock.unlock()
    }

    /// Remove a stream (on disconnect or completion).
    func remove(streamId: String) {
        lock.lock()
        if let info = streams.removeValue(forKey: streamId) {
            info.continuation.finish()
        }
        lock.unlock()
    }

    /// Send an SSE event to a specific stream.
    func send(streamId: String, data: Data) {
        lock.lock()
        if let info = streams[streamId] {
            info.continuation.yield(ByteBuffer(data: data))
        }
        lock.unlock()
    }

    /// Send a notification to ONE of the session's GET streams.
    /// Per MCP spec: "MUST send each JSON-RPC message on only one of the connected streams"
    func sendToSession(sessionId: String, data: Data) {
        lock.lock()
        // Find the first GET stream for this session
        let getStream = streams.values.first { $0.sessionId == sessionId && $0.type == .get }
        if let stream = getStream {
            stream.continuation.yield(ByteBuffer(data: data))
        }
        lock.unlock()
    }

    /// Close all streams for a session.
    func closeSession(sessionId: String) {
        lock.lock()
        let sessionStreams = streams.filter { $0.value.sessionId == sessionId }
        for (id, info) in sessionStreams {
            info.continuation.finish()
            streams.removeValue(forKey: id)
        }
        lock.unlock()
    }
}
```

#### 连接 MCPServer.notificationSink

在 `StreamableHTTPTransport` 的初始化中：

```swift
// 设置 MCPServer 的 notificationSink
server.notificationSink = { [weak self] message in
    guard let self = self else { return }
    // Route notification to appropriate session's SSE stream
    // For now, broadcast to all sessions (TODO: per-session routing)
    do {
        let eventId = "evt-\(UUID().uuidString.prefix(8))"
        let sseData = try SSEEncoder.encode(message, eventId: eventId)
        // Send to all sessions' GET streams
        for sessionId in self.sessionManager.allSessionIds {
            self.sseStreamManager.sendToSession(sessionId: sessionId, data: sseData)
        }
    } catch {
        // Log encoding error
    }
}
```

#### POST SSE 响应模式

对于可能需要中间通知的请求（如 `tools/call` 触发的长时间操作），改为 SSE 流响应：

```swift
// 在 handlePost 中，对 request 类型：
case .request(let req):
    // 判断是否需要 SSE 流（基于客户端 Accept 和请求类型）
    let acceptsSSE = request.headers[.accept]?.contains("text/event-stream") == true

    if acceptsSSE {
        // SSE 流模式
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let streamId = "post-\(UUID().uuidString.prefix(8))"

        // 1. Send primer event
        let primerData = SSEEncoder.encodePrimerEvent(eventId: streamId)
        continuation.yield(ByteBuffer(data: primerData))

        // 2. Register stream for intermediate pushes
        sseStreamManager.register(
            sessionId: sessionId,
            streamId: streamId,
            continuation: continuation,
            type: .post
        )

        // 3. Process request (may trigger onLog/onStatusChange → push to this stream)
        if let response = handler(message) {
            let sseData = try SSEEncoder.encode(response, eventId: "\(streamId)-final")
            continuation.yield(ByteBuffer(data: sseData))
        }

        // 4. Finish stream
        sseStreamManager.remove(streamId: streamId)

        return Response(
            status: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
            body: .init(asyncSequence: stream)
        )
    } else {
        // Simple JSON response mode (existing behavior)
        ...
    }
```

## 实现步骤

### Step 1：修改 MCPServer.swift

1. 添加 `notificationSink` 属性
2. 添加 `sendNotification()` 方法
3. 添加 `wireNotifications()` 方法

**关键约束**：
- `notificationSink` 是可选的 → 不设置时行为与现在完全一致
- 不改变 `handle()` 签名 → 所有现有调用方无需修改
- CLI 模式（StdioTransport）也可以利用这个接口：`transport.send(_:)` 已存在

### Step 2：创建 SSEStreamManager

在 `StreamableHTTPTransport.swift` 中添加（或作为单独内部文件）。

### Step 3：更新 StreamableHTTPTransport

1. 集成 SSEStreamManager
2. 将 `notificationSink` 连接到 SSE 推送
3. 更新 POST handler 支持 SSE 流响应
4. 更新 GET handler 注册到 SSEStreamManager

### Step 4：添加 MCPSessionManager.allSessionIds

在 `MCPSessionManager` 中添加：

```swift
/// Get all active session IDs.
public var allSessionIds: [String] {
    lock.lock()
    defer { lock.unlock() }
    return Array(sessions.keys)
}
```

### Step 5：编写测试

```swift
// 1. 验证 notificationSink 被调用
// 2. 验证 SSE 流中能收到 notifications/message
// 3. 验证 POST SSE 流包含最终 response
// 4. 验证 GET SSE 流收到服务端推送
// 5. 验证不设置 notificationSink 时行为不变（回归）
```

### Step 6：编译与测试

完整运行三个 target 的编译 + 全量测试。

## 验收标准

- [ ] `MCPServer.notificationSink` 属性已添加
- [ ] `MCPServer.wireNotifications()` 已实现，正确桥接 logger 和 taskManager
- [ ] SSEStreamManager 正确管理多个 SSE 流
- [ ] POST 请求可以返回 SSE 流响应
- [ ] GET SSE 流可以接收服务端推送
- [ ] 不设置 notificationSink 时，现有行为不受影响
- [ ] CLI 模式（StdioTransport）不受影响
- [ ] MCP 全量测试通过
- [ ] 新增单元测试覆盖推送机制

## 注意事项

1. **线程安全**：`notificationSink` 可能从任何线程调用（MCPLogger 和 TaskManager 的回调在不同线程），SSEStreamManager 需要自己的锁
2. **不改变 handle() 签名**：这是最关键的约束，保证所有现有代码（Tools、Resources、Services）零改动
3. **per-session 路由**：当前 `MCPServer` 是单实例的，不知道当前在处理哪个 session 的请求。推送通知时需要确定发送到哪个 session。简化方案：所有 session 共享一个 MCPServer 实例，通知广播到所有 session 的 GET 流
4. **MCPNotificationPoster vs notificationSink**：`MCPNotificationPoster` 是进程内 `NotificationCenter` 通知（GUI 刷新用），与 `notificationSink` 完全不同。两者并行存在
5. **CLI 模式也能受益**：如果 `main.swift` 设置 `server.notificationSink = { msg in try? transport.send(msg) }`，CLI 模式也能推送日志和任务进度到客户端。但这不是本任务的范围
