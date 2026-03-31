## Metal 截帧按钮

### 功能概述

在 App 库的 app 条目上，当该 app 存在 `ready` 状态的 runtime session 时，显示一个 Metal GPU 截帧按钮（`camera.viewfinder` 图标）。点击后触发对该 app 的 Metal frame capture，产出 `.gputrace` 文件。

### 视觉表现

#### 列表模式

在 session 状态指示器右侧、版本号左侧显示：

```
[图标] QQ飞车  ────  🟢 Connected  📷  1.56.036637
                                    ↑ 截帧按钮
```

#### 网格模式

app 图标右下角显示紧凑版按钮：

```
     ┌──────┐ 🟢   ← session 状态点（右上）
     │ icon │
     └──────┘ 📷   ← capture 按钮（右下）
```

#### 按钮状态

| 条件 | 按钮表现 |
|---|---|
| 无 session / 非 ready | 不显示 |
| session ready，可截帧 | `📷` 图标，accent color |
| 截帧进行中 | 旋转 `ProgressView` |
| 截帧完成 | Alert："帧捕获完成" + "在 Finder 中显示" |
| 截帧失败 | Alert："帧捕获失败" + 错误信息 |

### 调用链路

```text
CaptureButton (View)
  │ Button action
  ▼
MCPManager.captureFrame(bundleId:)          ← async, GUI 入口
  │ 1. 查找第一个 ready session
  │ 2. capturingBundleIds.insert(bundleId)   ← UI 进度状态
  │ 3. captureService.captureFrame(sessionId:, params:)
  │    └→ BridgeClient → runtime
  │ 4. capturingBundleIds.remove(bundleId)
  ▼
Result<String, String>
  │ .success(outputPath) → Alert + "Show in Finder"
  │ .failure(message)    → Alert + 错误信息
  ▼
CaptureButton.showCaptureResult alert
```

### 前提条件

Metal 截帧能力有多层前提（参见 `LocalDocs/MCPFinal/01-架构与设计.md` 第九节）：

1. **App 设置中 `metalCaptureEnabled` 必须开启**
2. **修改该设置后需要重新安装 app**
3. **App 必须正在运行且有 ready session**
4. **Runtime 侧 PlayTools 必须具备 capture 能力**

GUI 层的截帧按钮只负责第 3 点（有 ready session 才显示），其余前提由底层 `CaptureService` 在执行时校验并返回错误。

### MCPManager 暴露的接口

```swift
/// 保存的 captureService 引用（registerServices 中创建）
private var captureService: CaptureService?

/// 正在截帧的 bundleId 集合（@Published，驱动 UI 进度状态）
@Published var capturingBundleIds: Set<String> = []

/// 是否可以截帧：有 ready session 且不在截帧中
func canCapture(bundleId: String) -> Bool

/// 是否正在截帧
func isCapturing(bundleId: String) -> Bool

/// 触发截帧，返回 .success(outputPath) 或 .failure(errorMessage)
func captureFrame(bundleId: String) async -> Result<String, String>
```

### 默认参数

GUI 按钮使用默认参数调用截帧：

- `durationMs`: 100（约 1-2 帧 @60fps）
- `captureTarget`: `.device`
- `outputPath`: 由 runtime 自动生成

如需更精细的控制（自定义时长、输出路径、capture target），仍应通过 MCP 工具 `capture_metal_frame` 调用。

### 视图组件

#### `CaptureButton`

```swift
struct CaptureButton: View {
    let bundleId: String
    let canCapture: Bool
    let isCapturing: Bool
    var compact: Bool = false       // 网格模式使用紧凑尺寸
}
```

- 列表模式：`compact = false`，20pt 图标
- 网格模式：`compact = true`，16pt 图标，通过 `.overlay(alignment: .bottomTrailing)` 定位

内置 `.alert` 处理截帧结果：
- 成功时提供 "Show in Finder" 按钮（调用 `NSWorkspace.shared.selectFile`）
- 失败时显示错误信息

### 本地化

| Key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `capture.tooltip` | Capture Metal GPU Frame | 捕获 Metal GPU 帧 | 擷取 Metal GPU 幀 |
| `capture.inProgress` | Capturing… | 捕获中… | 擷取中… |
| `capture.unavailable` | No active session for capture | 无可用会话 | 無可用工作階段 |
| `capture.success.title` | Frame Captured | 帧捕获完成 | 幀擷取完成 |
| `capture.failure.title` | Capture Failed | 帧捕获失败 | 幀擷取失敗 |
| `capture.revealInFinder` | Show in Finder | 在 Finder 中显示 | 在 Finder 中顯示 |

### 源码锚点

| 文件 | 位置 |
|---|---|
| `PlayCover/Views/App Views/PlayAppView.swift` | `CaptureButton`、`PlayAppConditionalView` 中的按钮放置 |
| `PlayCover/Services/MCPManager.swift` | `captureService` 持有、`captureFrame(bundleId:)`、`canCapture()`、`isCapturing()`、`capturingBundleIds` |
| `PlayCoverMCP/Session/CaptureService.swift` | `captureFrame(sessionId:params:)`、`getCaptureStatus(sessionId:)` |
| `PlayCoverMCP/Session/BridgeClient.swift` | runtime 通信 |

### 已知限制

1. **GUI 按钮只使用默认截帧参数**：高级用法（自定义 duration、target、output path）需通过 MCP 工具
2. **截帧成功不代表 `.gputrace` 内容有效**：受制于 Apple Metal capture API 的系统级限制（见 `LocalDocs/MCPFinal/Problems/RenderCapture/`）
3. **按钮不会检查 `metalCaptureEnabled` 设置**：如果设置未开启，底层会返回错误，由 alert 呈现给用户
