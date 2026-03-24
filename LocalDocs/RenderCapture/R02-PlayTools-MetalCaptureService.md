### 任务编号与标题

- **ID**：`R02`
- **标题**：PlayTools MetalCaptureService 核心实现

### Dashboard

- **状态**：`DONE`
- **优先级**：`P0`
- **预计工作量**：`M`（中型）
- **依赖任务**：`R01`
- **阻塞任务**：`R03`
- **建议执行顺序**：第 2 个
- **预期提交数**：`1`

### 开工前必读

- `00-主文档.md`
- `R01-Host设置与安装管线改动.md`（确认已完成）
- 本文档

### 任务目标

在 PlayTools（运行在目标 app 进程内）中实现 `MetalCaptureService`，封装 `MTLCaptureManager` API，提供编程式截帧能力。

### 范围内

1. **新增 `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`**
   - 封装 `MTLCaptureManager` 的截帧 API
   - 提供 `captureFrame()` 方法
   - 提供截帧状态查询
2. **修改 `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`**
   - 在 `launch()` 中初始化 `MetalCaptureService`（仅当 `metalCaptureEnabled` 时）
3. **确保 `.gputrace` 文件输出到沙箱可写路径**
4. 文档更新

### 范围外

- 不修改 Bridge 协议（R03）
- 不修改 MCP（R04）
- 不修改 GUI（R05）

### 预期改动文件

- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`（新增）
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`（修改）
- `LocalDocs/RenderCapture/` 相关文档

### 实施细节

#### 1. MetalCaptureService 核心类

```swift
import Foundation
import Metal

/// 封装 MTLCaptureManager 的编程式截帧服务
@objc public class MetalCaptureService: NSObject {
    @objc public static let shared = MetalCaptureService()
    
    private var captureManager: MTLCaptureManager?
    private var isCapturing = false
    
    /// 初始化截帧服务
    /// 仅当 Info.plist 中 MetalCaptureEnabled = YES 且 PlaySettings.metalCaptureEnabled 时生效
    @objc public func initialize() {
        guard PlaySettings.shared.metalCaptureEnabled else {
            print("[PlayTools] MetalCaptureService: disabled by settings")
            return
        }
        
        captureManager = MTLCaptureManager.shared()
        
        if let manager = captureManager {
            let supportsTrace = manager.supportsDestination(.gpuTraceDocument)
            print("[PlayTools] MetalCaptureService initialized. supportsGPUTrace: \(supportsTrace)")
        } else {
            print("[PlayTools] MetalCaptureService: MTLCaptureManager not available")
        }
    }
    
    /// 执行一次帧截取，输出 .gputrace 到指定路径
    /// - Parameter outputURL: 输出文件路径（.gputrace），传 nil 则使用默认路径
    /// - Returns: 截帧结果
    @objc public func captureFrame(outputURL: URL? = nil) -> CaptureResult {
        guard let manager = captureManager else {
            return CaptureResult(success: false, message: "MTLCaptureManager not available", outputPath: nil)
        }
        
        guard !isCapturing else {
            return CaptureResult(success: false, message: "Capture already in progress", outputPath: nil)
        }
        
        guard manager.supportsDestination(.gpuTraceDocument) else {
            return CaptureResult(success: false, message: "GPU trace document not supported", outputPath: nil)
        }
        
        let url = outputURL ?? defaultOutputURL()
        
        let descriptor = MTLCaptureDescriptor()
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url
        
        // 截取默认 Metal device 上的命令
        if let device = MTLCreateSystemDefaultDevice() {
            descriptor.captureObject = device
        }
        
        do {
            isCapturing = true
            try manager.startCapture(with: descriptor)
            
            // 注意：startCapture 开始后，需要等到下一帧的 GPU 命令提交完成后调用 stopCapture
            // 实际的帧边界检测和 stopCapture 调用需要与 CADisplayLink 或 drawable 提交配合
            // 这里先提供同步接口，在 R03 中通过 Bridge 命令触发时会添加帧边界检测
            
            return CaptureResult(success: true, message: "Capture started", outputPath: url.path)
        } catch {
            isCapturing = false
            return CaptureResult(success: false, message: "startCapture failed: \(error.localizedDescription)", outputPath: nil)
        }
    }
    
    /// 停止当前截帧
    @objc public func stopCapture() -> CaptureResult {
        guard let manager = captureManager, isCapturing else {
            return CaptureResult(success: false, message: "No capture in progress", outputPath: nil)
        }
        
        manager.stopCapture()
        isCapturing = false
        return CaptureResult(success: true, message: "Capture stopped", outputPath: nil)
    }
    
    /// 查询截帧状态
    @objc public func getStatus() -> CaptureStatus {
        let available = captureManager != nil
        let supportsTrace = captureManager?.supportsDestination(.gpuTraceDocument) ?? false
        return CaptureStatus(
            available: available,
            supportsGPUTrace: supportsTrace,
            isCapturing: isCapturing,
            enabled: PlaySettings.shared.metalCaptureEnabled
        )
    }
    
    // MARK: - Private
    
    private func defaultOutputURL() -> URL {
        // 输出到 PlayCover 的 container 目录，避免沙箱限制
        let container = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Captures")
        
        // 确保目录存在
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        
        // 用时间戳作为文件名
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        
        return container
            .appendingPathComponent("\(bundleId)_\(timestamp)")
            .appendingPathExtension("gputrace")
    }
}

/// 截帧操作结果
@objc public class CaptureResult: NSObject {
    @objc public let success: Bool
    @objc public let message: String
    @objc public let outputPath: String?
    
    @objc public init(success: Bool, message: String, outputPath: String?) {
        self.success = success
        self.message = message
        self.outputPath = outputPath
    }
}

/// 截帧服务状态
@objc public class CaptureStatus: NSObject {
    @objc public let available: Bool
    @objc public let supportsGPUTrace: Bool
    @objc public let isCapturing: Bool
    @objc public let enabled: Bool
    
    @objc public init(available: Bool, supportsGPUTrace: Bool, isCapturing: Bool, enabled: Bool) {
        self.available = available
        self.supportsGPUTrace = supportsGPUTrace
        self.isCapturing = isCapturing
        self.enabled = enabled
    }
}
```

#### 2. 帧边界检测策略

编程式截帧的难点是**确定帧的边界**——什么时候开始，什么时候结束。有几种策略：

**策略 A：定时截帧（推荐先实现）**
- `startCapture()` 开始截帧
- 等待一段时间（如 100ms，足以覆盖 1-2 帧）
- `stopCapture()` 结束截帧
- 优点：简单可靠
- 缺点：可能截取多帧

**策略 B：CADisplayLink 对齐**
- 利用 `CADisplayLink` 在 vsync 时触发
- 在 vsync 回调中 `startCapture()`，下一个 vsync 时 `stopCapture()`
- 优点：精确一帧
- 缺点：实现复杂，需要 hook 到 runloop

**策略 C：Metal Command Buffer 回调**
- 使用 `MTLCommandBuffer.addCompletedHandler` 回调
- 在下一个 command buffer 提交后停止截帧
- 优点：与 GPU 执行精确对齐
- 缺点：需要 hook Metal API（swizzle 或 interpose）

**本任务先实现策略 A**，如果效果不佳，后续可以升级到策略 B 或 C。

#### 3. PlayCover.swift 初始化

在 `PlayCover.launch()` 中添加 `MetalCaptureService` 初始化：

```swift
@objc static public func launch() {
    quitWhenClose()
    AKInterface.initialize()
    PlayScreen.shared.initialize()
    PlayInput.shared.initialize()
    DiscordIPC.shared.initialize()
    
    // 初始化 Metal 截帧服务
    MetalCaptureService.shared.initialize()
    
    if PlaySettings.shared.rootWorkDir {
        FileManager.default.changeCurrentDirectoryPath("/")
    }
}
```

#### 4. 输出路径与沙箱

- 目标 app 运行在 app-sandbox 中
- `~/Library/Containers/io.playcover.PlayCover/Captures/` 路径：
  - PlayCover Host 可以无限制读写（这是它自己的 container）
  - 目标 app 是否能写入取决于 entitlements 中的沙箱规则
  - 当前 `Entitlements.swift` 的 `composeEntitlements()` 已经添加了 `com.apple.security.files.downloads.read-write`
  - **可能需要额外的沙箱规则**来允许写入 PlayCover 的 container 目录——需要测试确认
- 如果沙箱限制阻止了写入，替代方案：
  - 输出到目标 app 自己的 container（`~/Library/Containers/{app.bundleId}/`）
  - 然后由 PlayCover Host 或 MCP 从那里复制出来

### 验收标准

1. `MetalCaptureService.swift` 能够编译通过
2. `PlayCover.swift` 的 `launch()` 中正确初始化截帧服务
3. `captureFrame()` 方法能够正确调用 `MTLCaptureManager` API
4. `getStatus()` 正确返回截帧服务状态
5. `.gputrace` 文件能够写入到指定路径
6. PlayTools framework 能够正常构建

### 测试（参照统一测试策略）

**本 task 新增检查项**：C08 ~ C11

| # | 检查项 | 层级 |
|---|--------|------|
| C08 | `MetalCaptureService.swift` 存在且编译通过 | L3 |
| C09 | `PlayCover.swift` 中初始化 `MetalCaptureService` | L3 |
| C10 | `MetalCaptureService` 含 `captureFrame` 方法 | L3 |
| C11 | `MetalCaptureService` 含 `getStatus` 方法 | L3 |

**完成后验证范围**：C01 ~ C11（含 R01 的 C01~C07 回归）

**执行方式**：`./Scripts/verify_render_capture.sh`

**人工验证**（需要实际 Metal app）：
1. 安装一个使用 Metal 的 app
2. 确认 `MetalCaptureService.shared.getStatus()` 返回正确状态
3. 调用 `captureFrame()` 并检查 `.gputrace` 文件生成

### 风险与注意事项

1. **MTLCaptureManager 在 Mac Catalyst 上的行为**：PlayCover 将 iOS app 转换为 Catalyst 运行，`MTLCaptureManager` 在这种模式下的行为需要实际测试确认
2. **沙箱写入权限**：需要实际测试目标 app 是否能写入 PlayCover 的 container 目录
3. **PlayTools 编译**：PlayTools 作为 Carthage 依赖，修改后需要确保 framework 正确编译
4. **线程安全**：`MTLCaptureManager` 的 API 调用需要注意线程安全

### 实施结果

- **实际改动文件**：
  - `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`（新增）— 封装 MTLCaptureManager 的截帧服务，含 `captureFrame()`、`stopCapture()`、`getStatus()` 方法及 `CaptureResult`/`CaptureStatus` 结果类型
  - `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`（修改）— 在 `launch()` 中添加 `MetalCaptureService.shared.initialize()` 调用
  - `.gitignore`（修改）— 为 `MetalCaptureService.swift` 和 `PlayCover.swift` 添加例外规则，使其纳入 git 管理
  - `LocalDocs/RenderCapture/00-主文档.md`（修改）— 更新任务看板
  - `LocalDocs/RenderCapture/R02-PlayTools-MetalCaptureService.md`（修改）— 更新状态和实施结果
- **关键决策**：
  - 采用**策略 A（定时截帧）**：`startCapture()` 后 100ms 自动 `stopCapture()`，简单可靠，足以覆盖 1-2 帧
  - 截帧前自动删除已存在的同名 `.gputrace` 文件（MTLCaptureManager 不会覆盖已有文件）
  - `.gputrace` 默认输出到 `~/Library/Containers/io.playcover.PlayCover/Captures/`
  - `PlayCover.swift` 也纳入 `.gitignore` 例外管理（与 `PlaySettings.swift` 同样的逐级打洞模式）
- **已知问题**：
  - 沙箱写入权限需要实际 Metal app 测试确认（目标 app 是否能写入 PlayCover 的 container 目录）
  - 定时策略可能截取多帧，如效果不佳后续可升级到 CADisplayLink 或 Command Buffer 回调方案
- **Commit Hash**：`45255d7a`
