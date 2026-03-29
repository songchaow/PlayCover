# H02：SSE 编码器与会话管理器

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ⬜ 待开始 |
| **前置依赖** | H01（SPM 依赖已配置） |
| **预估工时** | 1-1.5 天 |
| **风险等级** | 低 |

## 目标

1. 实现 `SSEEncoder`：将 JSON-RPC 消息编码为 SSE 事件格式
2. 实现 `MCPSessionManager`：管理 Streamable HTTP 会话生命周期
3. 这两个组件**不依赖 Hummingbird**（仅使用 Foundation），可在所有三个 target 中编译和测试

## 设计规格

### SSEEncoder

**文件位置**：`PlayCoverMCP/Transport/SSEEncoder.swift`

**Target membership**：PlayCover + PlayCoverMCP + PlayCoverMCPTests

```swift
import Foundation

/// Encodes JSON-RPC messages into Server-Sent Events format.
///
/// SSE event format:
/// ```
/// id: <event-id>\n
/// data: <json-line>\n
/// \n
/// ```
///
/// Reference: https://html.spec.whatwg.org/multipage/server-sent-events.html
public enum SSEEncoder {

    /// A single SSE event
    public struct Event: Equatable, Sendable {
        /// Optional event ID (for resumability)
        public let id: String?
        /// Optional event type
        public let event: String?
        /// The data payload (JSON-RPC message as a string)
        public let data: String
        /// Optional retry interval in milliseconds
        public let retry: Int?

        public init(id: String? = nil, event: String? = nil, data: String, retry: Int? = nil) {
            self.id = id
            self.event = event
            self.data = data
            self.retry = retry
        }
    }

    /// Encode a JSON-RPC message into an SSE event.
    /// - Parameters:
    ///   - message: The JSON-RPC message to encode
    ///   - eventId: Optional SSE event ID
    ///   - retry: Optional retry interval in milliseconds
    /// - Returns: UTF-8 encoded SSE event data, ready to write to the stream
    public static func encode(_ message: JSONRPCMessage, eventId: String? = nil, retry: Int? = nil) throws -> Data {
        let jsonData = try message.encode()
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SSEEncoderError.encodingFailed
        }
        let event = Event(id: eventId, data: jsonString, retry: retry)
        return encode(event)
    }

    /// Encode an SSE event into raw bytes.
    public static func encode(_ event: Event) -> Data {
        var result = ""
        if let id = event.id {
            result += "id: \(id)\n"
        }
        if let eventType = event.event {
            result += "event: \(eventType)\n"
        }
        if let retry = event.retry {
            result += "retry: \(retry)\n"
        }
        // data field - each line of data gets its own "data:" prefix
        let lines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            result += "data: \(line)\n"
        }
        // Empty data case
        if event.data.isEmpty {
            result += "data: \n"
        }
        result += "\n" // blank line terminates the event
        return result.data(using: .utf8) ?? Data()
    }

    /// Encode a "primer" event (empty data with ID) used to establish SSE stream resumability.
    /// MCP spec: "server SHOULD immediately send an SSE event consisting of an event ID and an empty data field"
    public static func encodePrimerEvent(eventId: String) -> Data {
        let event = Event(id: eventId, data: "")
        return encode(event)
    }

    /// Encode a retry-only event (sent before server closes connection).
    public static func encodeRetryEvent(milliseconds: Int) -> Data {
        var result = "retry: \(milliseconds)\n\n"
        return result.data(using: .utf8) ?? Data()
    }
}

public enum SSEEncoderError: Error, LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode message as UTF-8 string"
        }
    }
}
```

### MCPSessionManager

**文件位置**：`PlayCoverMCP/Transport/MCPSessionManager.swift`

**Target membership**：PlayCover + PlayCoverMCP + PlayCoverMCPTests

```swift
import Foundation

/// Manages MCP Streamable HTTP sessions.
///
/// Each session represents a client that has completed the `initialize` handshake.
/// Sessions are identified by a cryptographically secure session ID (`Mcp-Session-Id` header).
public final class MCPSessionManager: @unchecked Sendable {

    /// Session state
    public struct Session: Sendable {
        public let id: String
        public let createdAt: Date
        public var lastActivityAt: Date
        public var isInitialized: Bool  // true after receiving `notifications/initialized`
        public var protocolVersion: String?

        public init(id: String) {
            self.id = id
            self.createdAt = Date()
            self.lastActivityAt = Date()
            self.isInitialized = false
            self.protocolVersion = nil
        }
    }

    /// Session timeout interval (default: 30 minutes)
    public var sessionTimeout: TimeInterval = 30 * 60

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Session Lifecycle

    /// Create a new session and return its ID.
    /// Called when `initialize` request is received.
    public func createSession() -> String {
        let sessionId = generateSessionId()
        let session = Session(id: sessionId)

        lock.lock()
        sessions[sessionId] = session
        lock.unlock()

        return sessionId
    }

    /// Validate a session ID. Returns the session if valid, nil if expired/not found.
    /// Also updates the last activity timestamp.
    public func validateSession(_ sessionId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }

        guard var session = sessions[sessionId] else {
            return nil
        }

        // Check expiry
        if Date().timeIntervalSince(session.lastActivityAt) > sessionTimeout {
            sessions.removeValue(forKey: sessionId)
            return nil
        }

        // Update last activity
        session.lastActivityAt = Date()
        sessions[sessionId] = session
        return session
    }

    /// Mark a session as fully initialized (after receiving `notifications/initialized`).
    public func markInitialized(_ sessionId: String) {
        lock.lock()
        sessions[sessionId]?.isInitialized = true
        lock.unlock()
    }

    /// Set the negotiated protocol version for a session.
    public func setProtocolVersion(_ sessionId: String, version: String) {
        lock.lock()
        sessions[sessionId]?.protocolVersion = version
        lock.unlock()
    }

    /// Terminate a session. Called on DELETE request or timeout.
    /// Returns true if the session existed and was removed.
    @discardableResult
    public func terminateSession(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.removeValue(forKey: sessionId) != nil
    }

    /// Get the number of active sessions.
    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    /// Remove all expired sessions.
    public func removeExpiredSessions() {
        lock.lock()
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivityAt) <= sessionTimeout
        }
        lock.unlock()
    }

    /// Get a session without updating its activity timestamp.
    public func getSession(_ sessionId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]
    }

    // MARK: - Private

    /// Generate a cryptographically secure session ID.
    private func generateSessionId() -> String {
        // UUID is cryptographically secure on Apple platforms
        return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
```

## 实现步骤

### Step 1：创建 SSEEncoder.swift

- 在 `PlayCoverMCP/Transport/` 目录下创建
- 添加到三个 target 的 Sources build phase

### Step 2：创建 MCPSessionManager.swift

- 在 `PlayCoverMCP/Transport/` 目录下创建
- 添加到三个 target 的 Sources build phase

### Step 3：创建 SSEEncoderTests.swift

在 `PlayCoverMCPTests/` 下创建：

```swift
import XCTest

final class SSEEncoderTests: XCTestCase {

    func testEncodeSimpleEvent() {
        let event = SSEEncoder.Event(data: "hello")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "data: hello\n\n")
    }

    func testEncodeEventWithId() {
        let event = SSEEncoder.Event(id: "evt-1", data: "hello")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "id: evt-1\ndata: hello\n\n")
    }

    func testEncodeEventWithRetry() {
        let event = SSEEncoder.Event(data: "hello", retry: 5000)
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "retry: 5000\ndata: hello\n\n")
    }

    func testEncodeJSONRPCMessage() throws {
        let response = JSONRPCResponse.success(id: .integer(1), result: AnyCodable(["ok": true] as [String: Any]))
        let message = JSONRPCMessage.response(response)
        let encoded = try SSEEncoder.encode(message, eventId: "evt-1")
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(str.hasPrefix("id: evt-1\n"))
        XCTAssertTrue(str.contains("data: "))
        XCTAssertTrue(str.contains("\"jsonrpc\""))
        XCTAssertTrue(str.hasSuffix("\n\n"))
    }

    func testEncodePrimerEvent() {
        let encoded = SSEEncoder.encodePrimerEvent(eventId: "primer-1")
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "id: primer-1\ndata: \n\n")
    }

    func testEncodeMultilineData() {
        let event = SSEEncoder.Event(data: "line1\nline2\nline3")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "data: line1\ndata: line2\ndata: line3\n\n")
    }

    func testEncodeRetryEvent() {
        let encoded = SSEEncoder.encodeRetryEvent(milliseconds: 3000)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "retry: 3000\n\n")
    }
}
```

### Step 4：创建 MCPSessionManagerTests.swift

```swift
import XCTest

final class MCPSessionManagerTests: XCTestCase {

    func testCreateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertEqual(manager.activeSessionCount, 1)
    }

    func testValidateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        let session = manager.validateSession(sessionId)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, sessionId)
        XCTAssertFalse(session!.isInitialized)
    }

    func testValidateNonexistentSession() {
        let manager = MCPSessionManager()
        XCTAssertNil(manager.validateSession("nonexistent"))
    }

    func testTerminateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()
        XCTAssertEqual(manager.activeSessionCount, 1)

        let removed = manager.terminateSession(sessionId)
        XCTAssertTrue(removed)
        XCTAssertEqual(manager.activeSessionCount, 0)

        // Validate should fail after termination
        XCTAssertNil(manager.validateSession(sessionId))
    }

    func testTerminateNonexistentSession() {
        let manager = MCPSessionManager()
        let removed = manager.terminateSession("nonexistent")
        XCTAssertFalse(removed)
    }

    func testMarkInitialized() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        manager.markInitialized(sessionId)
        let session = manager.getSession(sessionId)
        XCTAssertTrue(session!.isInitialized)
    }

    func testSetProtocolVersion() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        manager.setProtocolVersion(sessionId, version: "2025-11-25")
        let session = manager.getSession(sessionId)
        XCTAssertEqual(session?.protocolVersion, "2025-11-25")
    }

    func testSessionExpiry() {
        let manager = MCPSessionManager()
        manager.sessionTimeout = 0.1 // 100ms for test

        let sessionId = manager.createSession()
        XCTAssertNotNil(manager.validateSession(sessionId))

        // Wait for expiry
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertNil(manager.validateSession(sessionId))
    }

    func testRemoveExpiredSessions() {
        let manager = MCPSessionManager()
        manager.sessionTimeout = 0.1

        _ = manager.createSession()
        _ = manager.createSession()
        XCTAssertEqual(manager.activeSessionCount, 2)

        Thread.sleep(forTimeInterval: 0.2)

        manager.removeExpiredSessions()
        XCTAssertEqual(manager.activeSessionCount, 0)
    }

    func testMultipleSessions() {
        let manager = MCPSessionManager()
        let id1 = manager.createSession()
        let id2 = manager.createSession()
        let id3 = manager.createSession()

        XCTAssertEqual(manager.activeSessionCount, 3)
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id2, id3)

        manager.terminateSession(id2)
        XCTAssertEqual(manager.activeSessionCount, 2)
        XCTAssertNotNil(manager.validateSession(id1))
        XCTAssertNil(manager.validateSession(id2))
        XCTAssertNotNil(manager.validateSession(id3))
    }

    func testSessionIdFormat() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        // Should be a 32-character hex string (UUID without dashes)
        XCTAssertEqual(sessionId.count, 32)
        XCTAssertTrue(sessionId.allSatisfy { $0.isHexDigit })
    }

    func testConcurrentAccess() {
        let manager = MCPSessionManager()
        let iterations = 100

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        var sessionIds: [String] = []
        let lock = NSLock()

        for _ in 0..<iterations {
            group.enter()
            queue.async {
                let id = manager.createSession()
                lock.lock()
                sessionIds.append(id)
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(manager.activeSessionCount, iterations)
        XCTAssertEqual(Set(sessionIds).count, iterations) // All unique
    }
}
```

### Step 5：将文件添加到 pbxproj

向 pbxproj 添加以下文件的引用：

| 文件 | PBXFileReference | PlayCover Sources | PlayCoverMCP Sources | PlayCoverMCPTests Sources |
|------|:-:|:-:|:-:|:-:|
| `SSEEncoder.swift` | ✅ | ✅ | ✅ | ✅ |
| `MCPSessionManager.swift` | ✅ | ✅ | ✅ | ✅ |
| `SSEEncoderTests.swift` | ✅ | ❌ | ❌ | ✅ |
| `MCPSessionManagerTests.swift` | ✅ | ❌ | ❌ | ✅ |

### Step 6：编译与测试

```bash
# 编译 GUI target
xcodebuild -scheme PlayCover -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

# 编译 CLI target
xcodebuild -scheme PlayCoverMCP -configuration Release build \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

# 运行全量测试（包括新增的 SSEEncoder 和 MCPSessionManager 测试）
xcodebuild test -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

## 验收标准

- [ ] `SSEEncoder.swift` 已创建，编码格式符合 SSE 规范
- [ ] `MCPSessionManager.swift` 已创建，支持创建/验证/终止/过期清理
- [ ] SSEEncoder 和 MCPSessionManager 均不依赖 Hummingbird
- [ ] SSEEncoderTests 全部通过
- [ ] MCPSessionManagerTests 全部通过
- [ ] 三个 scheme 编译通过
- [ ] MCP 全量测试通过（回归无破坏）
- [ ] `plutil -lint` OK

## 注意事项

1. **SSE 格式严格性**：每个事件以双换行 `\n\n` 结束；多行 data 每行都需要 `data:` 前缀
2. **Session ID 安全性**：使用 `UUID().uuidString`（Apple 平台上是密码学安全的）
3. **线程安全**：`MCPSessionManager` 使用 `NSLock` 保护，与 `MCPServer` 和 `TaskManager` 一致的模式
4. **SSEEncoder 是无状态工具类**：使用 `enum` 命名空间，所有方法都是 `static`
