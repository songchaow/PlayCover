# G03：TCPTransport 实现

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | G02（MCP 代码在 GUI target 可编译） |
| **预估工时** | 1-1.5 天 |
| **风险等级** | 中 |

## 目标

实现 `TCPTransport`，基于 Apple `Network.framework`，在 GUI 进程内提供 TCP MCP 服务。与 `StdioTransport` 的 `MessageHandler` 接口完全兼容。

## 设计规格

### 核心参数

| 参数 | 值 |
|------|---|
| 监听地址 | `127.0.0.1`（仅 loopback） |
| 默认端口 | `19820` |
| 协议 | 行分隔 JSON-RPC over TCP |
| 并发 | 支持多客户端 |
| 线程模型 | 后台 `DispatchQueue`，不阻塞主线程 |
| 框架依赖 | `Network.framework` |

### 接口设计

```swift
import Network

/// TCP transport for MCP server, compatible with StdioTransport's MessageHandler interface.
public final class TCPTransport {
    
    /// Same signature as StdioTransport.MessageHandler
    public typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?
    
    /// Current state
    public enum State {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(Error)
    }
    
    /// Observable state for UI binding
    public private(set) var state: State = .stopped
    
    /// Number of connected clients
    public private(set) var connectedClientCount: Int = 0
    
    /// Start listening
    public func start() { ... }
    
    /// Stop listening and disconnect all clients
    public func stop() { ... }
    
    init(port: UInt16 = 19820, handler: @escaping MessageHandler) throws { ... }
}
```

### 文件位置

**新建文件**：`PlayCoverMCP/Transport/TCPTransport.swift`

将此文件添加到 **PlayCover.app target**（因为 CLI 不需要它）和 **PlayCoverMCP target**（保持代码组织一致性，但 CLI 不使用它）。

> 或者只添加到 PlayCover.app target，这样更清晰。根据实际编译需求决定。

### 连接生命周期

```
TCPTransport.start()
  ├── NWListener 创建 (127.0.0.1:19820)
  ├── listener.stateUpdateHandler → 状态变更回调
  ├── listener.newConnectionHandler → 新连接到达
  │     ├── connection.start(queue:)
  │     ├── 添加到 connections 数组
  │     ├── setupReceive(connection) → 循环读取
  │     │     ├── connection.receive(minimumIncompleteLength:maximumLength:)
  │     │     ├── 累积数据，按 \n 分割行
  │     │     ├── 对每个完整行：
  │     │     │     ├── 解析 JSONRPCMessage
  │     │     │     ├── 调用 handler(message)
  │     │     │     └── 将 response 编码为 JSON + \n 写回连接
  │     │     └── 继续 setupReceive（递归）
  │     └── connection.stateUpdateHandler → 断开时从 connections 移除
  └── listener.start(queue:)

TCPTransport.stop()
  ├── listener.cancel()
  └── 所有 connection.cancel()
```

## 实现步骤

### Step 1：创建 TCPTransport.swift

参考 `StdioTransport.swift` 的结构，但使用 `NWListener` 替代 stdin/stdout。

关键实现要点：

1. **NWListener 配置**：
   ```swift
   let params = NWParameters.tcp
   params.requiredLocalEndpoint = NWEndpoint.hostPort(
       host: .ipv4(.loopback),
       port: NWEndpoint.Port(rawValue: port)!
   )
   let listener = try NWListener(using: params)
   ```

2. **数据读取与行分割**：
   TCP 是流式协议，一次 `receive` 可能收到半行或多行数据。需要维护一个缓冲区，按 `\n` 分割完整行：
   ```swift
   private var buffer: Data = Data()  // 每个连接一个缓冲区
   
   // 收到数据后追加到 buffer，然后：
   while let range = buffer.range(of: Data("\n".utf8)) {
       let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
       buffer.removeSubrange(buffer.startIndex...range.lowerBound)
       // 处理 lineData
   }
   ```

3. **每连接状态**：
   建议创建一个内部 `ClientConnection` 类来管理每个客户端的连接状态（缓冲区、NWConnection 引用等）。

4. **线程安全**：
   - connections 数组的访问需要同步（`NSLock` 或 `DispatchQueue` 序列化）
   - handler 调用可能在并发队列上，但 `MCPServer.handle()` 已有 `NSLock` 保护

5. **错误处理**：
   - bind 失败（端口被占用）→ 设置 `state = .failed(error)`
   - 连接读取错误 → 断开该连接，不影响其他连接
   - handler 抛异常 → 返回 JSON-RPC error response

### Step 2：添加到 Xcode 工程

将 `TCPTransport.swift` 添加到 PlayCover.app target 的 Sources build phase。

如果同时添加到 PlayCoverMCP target，需要条件编译或确保 CLI 不引用它。

> **建议**：只添加到 PlayCover.app target。PlayCoverMCP CLI 继续使用 StdioTransport，不需要 TCPTransport。

### Step 3：Entitlements 检查

TCP 监听可能需要 `com.apple.security.network.server` entitlement。

检查 `PlayCover/PlayCover.entitlements`（当前为空 dict）：
- 如果 PlayCover.app 没有 App Sandbox，则不需要额外 entitlement
- 如果有 Sandbox，需要添加网络服务权限

```bash
# 检查 PlayCover.app 是否启用了 sandbox
grep -i sandbox PlayCover.xcodeproj/project.pbxproj
```

### Step 4：编写单元测试

在 `PlayCoverMCPTests/` 下新建 `TCPTransportTests.swift`：

```swift
import XCTest
import Network

final class TCPTransportTests: XCTestCase {
    
    func testStartAndStop() throws {
        let transport = try TCPTransport(port: 0, handler: { _ in nil })
        // port: 0 让系统分配随机端口，避免测试端口冲突
        transport.start()
        // 等待启动
        Thread.sleep(forTimeInterval: 0.5)
        // 验证状态
        if case .running = transport.state { } else {
            XCTFail("Expected running state")
        }
        transport.stop()
    }
    
    func testEchoMessage() throws {
        // 启动 transport
        // 用 NWConnection 连接
        // 发送 JSON-RPC 消息
        // 验证收到响应
    }
    
    func testMultipleClients() throws {
        // 启动 transport
        // 连接多个客户端
        // 验证都能收发消息
    }
    
    func testDisconnect() throws {
        // 连接后断开
        // 验证 connectedClientCount 正确
    }
    
    func testPortInUse() throws {
        // 先占用端口
        // 再尝试启动 → 应该 state = .failed
    }
}
```

### Step 5：手动冒烟测试

如果 G04 尚未实现，可以写一个简单的测试入口来验证：

```bash
# 在 transport 启动后，用 nc 连接测试
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | nc localhost 19820
```

## 验收标准

- [ ] `TCPTransport.swift` 已创建并能编译
- [ ] 仅监听 loopback（127.0.0.1），不接受外部连接
- [ ] 行分隔 JSON-RPC 协议正确处理（包括半行、多行数据）
- [ ] 支持多客户端并发连接
- [ ] 不阻塞主线程
- [ ] `start()` / `stop()` 生命周期正确
- [ ] 端口被占用时优雅处理（不 crash）
- [ ] 单元测试覆盖核心路径
- [ ] `xcodebuild -scheme PlayCover build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过
- [ ] `xcodebuild -scheme PlayCoverMCP build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过（不受影响）
- [ ] MCP 全量测试通过

## 测试计划

1. **单元测试**：TCPTransportTests 覆盖启停、收发、多客户端、断连、端口冲突
2. **编译测试**：两个 scheme build 通过
3. **回归测试**：MCP 全量测试通过
4. **手动冒烟**（可选）：nc 连接发送 JSON-RPC

## 实际测试结果

### 单元测试（TCPTransportTests）

7 个测试全部通过，覆盖：
- `testStartAndStop` - 启停生命周期 ✅
- `testEchoMessage` - JSON-RPC 请求/响应回显 ✅
- `testMultipleClients` - 3 个并发客户端 ✅
- `testDisconnect` - 断连后 connectedClientCount 正确 ✅
- `testPortInUse` - 端口被占时 state = .failed ✅
- `testPartialLineHandling` - 分段发送，缓冲区正确拼接 ✅
- `testDoesNotBlockMainThread` - 不阻塞主线程 ✅

### 编译测试

- `xcodebuild -scheme PlayCover build` → **BUILD SUCCEEDED** ✅
- `xcodebuild -scheme PlayCoverMCP build` → **BUILD SUCCEEDED** ✅

### 回归测试

- MCP 全量测试：**579 tests, 0 failures, 1 skipped** ✅
- plutil -lint：**OK** ✅

---

## 注意事项

1. **TCP 是流式协议**：一次 `receive` 可能收到不完整的行，必须维护缓冲区按 `\n` 分割
2. **不要在主线程运行**：NWListener 和 NWConnection 都应在后台 DispatchQueue 上运行
3. **参考但不复制 StdioTransport**：两者的 `MessageHandler` 接口相同，但生命周期管理完全不同
4. **Network.framework 需要 import Network**：确保 PlayCover.app target 链接了 Network.framework（系统框架，通常自动链接）
5. **测试用端口 0**：单元测试中用 `port: 0` 让系统分配随机端口，避免与正在运行的实例冲突
6. **每连接独立缓冲区**：不要共享缓冲区，每个 `ClientConnection` 有自己的 `Data` 缓冲
