# H05：MCPManager 适配与 GUI 集成

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | H04（MCPServer 双向通道已实现） |
| **预估工时** | 1 天 |
| **风险等级** | 低-中 |

## 目标

1. 将 `MCPManager` 从使用 `TCPTransport` 切换为 `StreamableHTTPTransport`
2. 更新 GUI 状态联动（MCPStatusView）以展示 HTTP 端点信息
3. 连接 `MCPServer.notificationSink` 到 HTTP 传输层的 SSE 推送
4. 保留 TCP 作为可配置的备选传输方式（UserDefaults 可选）
5. 更新本地化字符串

## 设计规格

### MCPManager 变更

```swift
// MCPManager.swift 主要变更

class MCPManager: ObservableObject {
    // ...existing properties...

    /// Transport type selection
    enum TransportType: String, CaseIterable {
        case http = "http"     // Streamable HTTP (default)
        case tcp = "tcp"       // Legacy TCP (backward compat)
    }

    @Published var transportType: TransportType = .http

    // 新增
    private var httpTransport: StreamableHTTPTransport?

    /// Persisted transport type
    private static let transportTypeKey = "MCPServerTransportType"

    var savedTransportType: TransportType {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.transportTypeKey),
                  let type = TransportType(rawValue: raw) else {
                return .http  // Default to HTTP
            }
            return type
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.transportTypeKey)
        }
    }

    func start() {
        guard !isRunning else { return }

        let listenPort = port
        let host = listenHost

        // Create server (same as before)
        let server = createServer()

        switch transportType {
        case .http:
            startHTTPTransport(server: server, port: listenPort, host: host)
        case .tcp:
            startTCPTransport(server: server, port: listenPort, host: host)
        }
    }

    private func startHTTPTransport(server: MCPServer, port: UInt16, host: ...) {
        let httpTransport = StreamableHTTPTransport(
            port: port,
            host: ...,
            handler: { message in server.handle(message) }
        )

        httpTransport.onStateChange = { [weak self] newState in ... }
        httpTransport.onSessionCountChanged = { [weak self] count in
            self?.connectedClients = count
        }

        // Wire notifications
        server.notificationSink = { [weak httpTransport] message in
            // Route to appropriate SSE streams
            httpTransport?.pushNotification(message)
        }
        server.wireNotifications()

        httpTransport.start()
        self.httpTransport = httpTransport
        // ...save references...
    }
}
```

### MCPStatusView 变更

更新 Settings → MCP Server 面板：

1. **端点显示**：从 `tcp://127.0.0.1:19820` 改为 `http://127.0.0.1:19820/mcp`
2. **传输方式选择**（可选）：下拉选择 HTTP / TCP
3. **连接数标签**：从 "Connected Clients" 改为 "Active Sessions"
4. **Copy URL 按钮**：复制完整的 HTTP endpoint URL

### 本地化更新

| Key | en | zh-Hans | zh-Hant |
|-----|----|---------|---------|
| `mcp.transport.http` | Streamable HTTP | Streamable HTTP | Streamable HTTP |
| `mcp.transport.tcp` | TCP (Legacy) | TCP（旧版） | TCP（舊版） |
| `mcp.endpoint.label` | Endpoint | 端点 | 端點 |
| `mcp.sessions.label` | Active Sessions | 活跃会话 | 活躍會話 |
| `mcp.endpoint.copy` | Copy URL | 复制 URL | 複製 URL |

## 实现步骤

### Step 1：更新 MCPManager.swift

1. 添加 `TransportType` 枚举和持久化
2. 添加 `httpTransport` 属性
3. 修改 `start()` 按传输类型分发
4. 修改 `stop()` 停止对应传输
5. 修改 `restart()` 支持切换传输类型
6. 连接 `notificationSink`

### Step 2：更新 MCPStatusView.swift

1. 添加传输类型 Picker（可选）
2. 更新端点显示格式
3. 添加 Copy URL 按钮
4. 更新连接数标签

### Step 3：更新本地化文件

在 en/zh-Hans/zh-Hant 三个 Localizable.strings 中添加新 key。

### Step 4：更新 ListenHost 兼容性

`StreamableHTTPTransport.ListenHost` 需要与 `TCPTransport.ListenHost` 保持一致，或者抽取为共享类型。

**推荐方案**：在 `StreamableHTTPTransport` 中直接使用 `String` 作为 host 参数，不引入新的 ListenHost 类型，避免 GUI 侧需要同时了解两种 ListenHost 类型。

### Step 5：编译与测试

```bash
# GUI target
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

### Step 6：冒烟测试

启动 PlayCover.app → 检查 HTTP 端点 → 用 curl 发送 initialize/tools/list。

## 验收标准

- [ ] MCPManager 默认使用 StreamableHTTPTransport
- [ ] TCPTransport 保留为可选项
- [ ] notificationSink 正确连接到 SSE 推送
- [ ] MCPStatusView 显示 HTTP 端点 URL
- [ ] 传输方式切换功能正常
- [ ] 本地化字符串已添加
- [ ] PlayCover GUI scheme 编译通过
- [ ] PlayCoverMCP CLI scheme 编译通过
- [ ] MCP 全量测试通过
- [ ] curl 冒烟测试通过

## 注意事项

1. **不删除 TCPTransport**：保留作为向后兼容选项
2. **默认切换到 HTTP**：新安装默认使用 HTTP 传输，但已有用户的 UserDefaults 可能保留 TCP 设置
3. **端口复用**：HTTP 和 TCP 使用同一个端口配置，不同时运行
4. **ListenHost 复用**：`StreamableHTTPTransport` 的 host 参数类型需要与 UI 配置对应
