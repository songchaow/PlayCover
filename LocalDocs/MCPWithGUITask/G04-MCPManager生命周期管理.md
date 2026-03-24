# G04：MCPManager 生命周期管理

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | G03（TCPTransport 已实现） |
| **预估工时** | 0.5 天 |
| **风险等级** | 中 |

## 目标

创建 `MCPManager` 类，管理嵌入式 MCP Server 的完整生命周期。在 GUI app 启动时自动启动 MCP 服务，退出时停止。

## 设计规格

### MCPManager 类

```swift
import Foundation

/// 管理嵌入式 MCP Server 的生命周期。
/// 在 PlayCover.app 启动时自动启动 TCP MCP 服务，退出时停止。
class MCPManager: ObservableObject {
    static let shared = MCPManager()
    
    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var port: UInt16 = 19820
    @Published var lastError: String?
    
    private var server: MCPServer?
    private var transport: TCPTransport?
    
    /// 启动 MCP Server
    func start() { ... }
    
    /// 停止 MCP Server
    func stop() { ... }
}
```

### 文件位置

**新建文件**：`PlayCover/Services/MCPManager.swift`

> 放在 `PlayCover/Services/` 而非 `PlayCoverMCP/` 下，因为它是 GUI 侧的管理器，不属于 MCP CLI。

### 集成点

**修改文件**：`PlayCover/Views/PlayCoverApp.swift`

```swift
// AppDelegate 中新增：
func applicationDidFinishLaunching(_ notification: Notification) {
    // ... 现有代码保持不变 ...
    MCPManager.shared.start()   // 在最后新增
}

// 新增方法：
func applicationWillTerminate(_ notification: Notification) {
    MCPManager.shared.stop()
}
```

## 实现步骤

### Step 1：创建 MCPManager.swift

**核心逻辑**：复现 `PlayCoverMCP/main.swift` 的 bootstrap，但使用 `TCPTransport`。

```swift
import Foundation

class MCPManager: ObservableObject {
    static let shared = MCPManager()
    
    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var port: UInt16 = 19820
    @Published var lastError: String?
    
    private var server: MCPServer?
    private var transport: TCPTransport?
    private var logger: MCPLogger?
    private var taskManager: TaskManager?
    
    private init() {}
    
    func start() {
        guard !isRunning else { return }
        
        do {
            // 1. 创建基础设施
            let logger = MCPLogger(minLevel: .info)
            let taskManager = TaskManager()
            
            let serverInfo = Implementation(
                name: "playcover-mcp-gui",
                version: "0.2.0"
            )
            let capabilities = ServerCapabilities(
                tools: ToolCapabilities(listChanged: false),
                resources: ResourceCapabilities(subscribe: false, listChanged: false),
                logging: true,
                tasks: true
            )
            
            // 2. 创建 server
            let server = MCPServer(
                serverInfo: serverInfo,
                capabilities: capabilities,
                logger: logger,
                taskManager: taskManager
            )
            
            // 3. 注册所有 Service、Tools、Resources
            //   （参考 main.swift 的完整注册顺序）
            registerServices(on: server, taskManager: taskManager)
            
            // 4. 创建并启动 TCP transport
            let transport = try TCPTransport(port: port) { message in
                server.handle(message)
            }
            transport.start()
            
            // 5. 保存引用
            self.server = server
            self.transport = transport
            self.logger = logger
            self.taskManager = taskManager
            self.isRunning = true
            self.lastError = nil
            
            logger.log(.info, "MCP Server started on port \(port)")
            
        } catch {
            self.lastError = error.localizedDescription
            self.isRunning = false
        }
    }
    
    func stop() {
        transport?.stop()
        transport = nil
        server = nil
        logger = nil
        taskManager = nil
        isRunning = false
        connectedClients = 0
    }
    
    /// 注册所有 MCP service、tools 和 resources
    private func registerServices(on server: MCPServer, taskManager: TaskManager) {
        // 完整复现 main.swift 中的注册逻辑
        let appService = AppService.defaultService()
        AppTools.register(on: server, appService: appService)
        
        let settingsService = SettingsService.defaultService()
        AppResources.register(on: server, appService: appService, settingsService: settingsService)
        SettingsResources.register(on: server)
        SettingsTools.register(on: server, settingsService: settingsService)
        
        let installerService = InstallerService.defaultService()
        InstallerTools.register(on: server, installerService: installerService, taskManager: taskManager)
        
        let launchService = LaunchService.defaultService()
        LaunchTools.register(on: server, launchService: launchService)
        
        let cleanupService = CleanupService.defaultService()
        CleanupTools.register(on: server, cleanupService: cleanupService)
        
        let signingService = SigningService.defaultService()
        SigningTools.register(on: server, signingService: signingService, taskManager: taskManager)
        
        let injectionService = InjectionService.defaultService()
        InjectionTools.register(on: server, injectionService: injectionService)
        
        let keymapService = KeymapService.defaultService()
        KeymapTools.register(on: server, keymapService: keymapService)
        
        let sessionRegistry = SessionRegistry()
        let sessionService = SessionService(registry: sessionRegistry)
        SessionTools.register(on: server, sessionService: sessionService)
        SessionResources.register(on: server, sessionService: sessionService)
        
        let touchService = TouchService(registry: sessionRegistry)
        TouchTools.register(on: server, touchService: touchService)
        
        let inputService = InputService(registry: sessionRegistry)
        InputTools.register(on: server, inputService: inputService)
    }
}
```

### Step 2：修改 PlayCoverApp.swift

在 `AppDelegate` 中添加两处修改：

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    // ... 现有属性不变 ...
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ... 现有代码全部保持不变 ...
        
        // 在最后添加：
        MCPManager.shared.start()
    }
    
    // 新增方法：
    func applicationWillTerminate(_ notification: Notification) {
        MCPManager.shared.stop()
    }
    
    // ... 其他现有方法不变 ...
}
```

### Step 3：处理日志问题

MCP 的 `MCPLogger` 默认向 stderr 写日志。在 GUI 进程中：
- **方案 A**（简单）：保持 stderr 输出，GUI 进程中 stderr 通常也可用（输出到 Console.app）
- **方案 B**（可选优化）：为 GUI 模式创建自定义 log handler，写入文件或使用 `os.log`

建议 G04 先用方案 A（最小改动），后续可以优化。

### Step 4：添加文件到 Xcode 工程

将 `PlayCover/Services/MCPManager.swift` 添加到 PlayCover.app target。

如果 `PlayCover/Services/` 目录不存在，需要在 Xcode 工程中创建对应的 group。

### Step 5：编译验证

```bash
# GUI target
xcodebuild -scheme PlayCover -configuration Release build 2>&1 | tail -10

# CLI target（不应受影响）
xcodebuild -scheme PlayCoverMCP -configuration Release build 2>&1 | tail -10
```

### Step 6：功能验证

启动 PlayCover.app 后，用 `nc` 或 Python 脚本验证：

```bash
# 检查端口是否在监听
lsof -i :19820

# 发送 initialize 请求
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | nc localhost 19820
```

如果收到正确的 `initialize` 响应，说明 MCP Server 已在 GUI 进程内正常运行。

## 验收标准

- [ ] `MCPManager.swift` 已创建，包含完整的 server bootstrap 逻辑
- [ ] `PlayCoverApp.swift` 中已添加 `MCPManager.shared.start()` 和 `applicationWillTerminate`
- [ ] 启动 PlayCover.app 后端口 19820 在监听
- [ ] 通过 TCP 发送 `initialize` 请求能收到正确响应
- [ ] 退出 PlayCover.app 后端口释放
- [ ] `xcodebuild -scheme PlayCover build` 通过
- [ ] `xcodebuild -scheme PlayCoverMCP build` 通过
- [ ] MCP 全量测试通过

## 测试计划

1. **编译测试**：两个 scheme build 通过
2. **功能测试**：
   - 启动 GUI → `lsof -i :19820` 显示监听
   - `nc localhost 19820` 发送 initialize → 收到正确响应
   - 发送 `tools/list` → 收到工具列表
   - 退出 GUI → `lsof -i :19820` 无结果
3. **回归测试**：MCP 全量测试通过
4. **错误场景**：端口被占用时 GUI 仍能正常启动（MCP 服务降级，不影响 GUI 功能）

## 实际测试结果

### 编译测试
- ✅ `xcodebuild -scheme PlayCover -configuration Release build` — **BUILD SUCCEEDED**
- ✅ `xcodebuild -scheme PlayCoverMCP -configuration Release build` — **BUILD SUCCEEDED**
- ✅ `plutil -lint PlayCover.xcodeproj/project.pbxproj` — **OK**

### 回归测试
- ✅ MCP 全量单元测试：**579 tests, 1 skipped, 0 failures** — **TEST SUCCEEDED**

### 功能测试
- 需要启动 PlayCover.app 后手动验证（`lsof -i :19820` 检查端口监听、`nc localhost 19820` 发送 initialize 请求）
- TCP 功能已在 G03 的 TCPTransport 单元测试中覆盖

### 实现说明
- `MCPManager.swift` 创建在 `PlayCover/Services/` 目录下
- 在 `AppDelegate.applicationDidFinishLaunching` 末尾调用 `MCPManager.shared.start()`
- 新增 `applicationWillTerminate` 方法调用 `MCPManager.shared.stop()`
- 使用 `TCPTransport.onStateChange` 回调更新 `@Published` 属性
- 日志保持 stderr 输出（方案 A，最小改动）
- server 标识为 `playcover-mcp-gui` 与 CLI 的 `playcover-mcp` 区分

---

## 注意事项

1. **MCPManager 是 GUI 侧代码**，放在 `PlayCover/Services/` 下，不放在 `PlayCoverMCP/` 下
2. **不修改 main.swift**：CLI 入口保持不变，MCPManager 只在 GUI 中使用
3. **start() 不应阻塞**：确保 TCPTransport.start() 是异步的，不阻塞主线程
4. **优雅降级**：如果 MCP 启动失败（如端口冲突），GUI 其他功能不受影响
5. **server 版本标识**：GUI 版本用 `"playcover-mcp-gui"`，与 CLI 的 `"playcover-mcp"` 区分
6. **注意 `PlayCover/Services/` 目录**：可能需要在 pbxproj 中创建新的 PBXGroup
