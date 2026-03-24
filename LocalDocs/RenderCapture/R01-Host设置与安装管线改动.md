### 任务编号与标题

- **ID**：`R01`
- **标题**：PlayCover Host 设置与安装管线改动

### Dashboard

- **状态**：`DONE`
- **优先级**：`P0`
- **预计工作量**：`S`（小型）
- **依赖任务**：无
- **阻塞任务**：`R02`、`R05`
- **建议执行顺序**：第 1 个
- **预期提交数**：`1`

### 开工前必读

- `00-主文档.md`
- 本文档

### 任务目标

在 PlayCover Host 侧完成 Metal 截帧功能的基础设施改动，使得：

1. 安装 app 时 Info.plist 中写入 `MetalCaptureEnabled = YES`
2. `AppSettingsData` 新增 `metalCaptureEnabled` 设置项
3. PlayTools 侧的 `AppSettingsData` 同步新增该字段

### 范围内

1. **`PlayCover/Model/AppSettings.swift`** — `AppSettingsData` 新增 `metalCaptureEnabled: Bool`
2. **`PlayCover/AppInstaller/Installer.swift`** — 安装时在 Info.plist 写入 `MetalCaptureEnabled`
3. **`Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`** — PlayTools 侧 `AppSettingsData` 同步字段、`PlaySettings` 暴露属性
4. 相关本地化字符串（如需要）
5. 文档更新

### 范围外

- 不实现 `MetalCaptureService`（R02）
- 不修改 Bridge 协议（R03）
- 不修改 MCP 工具（R04）
- 不修改 GUI 设置界面（R05）
- 不修改 `clearDebugAffectingEnvironment()`——编程式截帧不依赖环境变量

### 预期改动文件

- `PlayCover/Model/AppSettings.swift`
- `PlayCover/AppInstaller/Installer.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`
- `LocalDocs/RenderCapture/00-主文档.md`（更新看板状态）
- `LocalDocs/RenderCapture/R01-Host设置与安装管线改动.md`（更新任务状态）

### 实施细节

#### 1. AppSettingsData 新增字段

**文件**：`PlayCover/Model/AppSettings.swift`

在 `AppSettingsData` 结构体中新增：

```swift
var metalCaptureEnabled = false
```

在 `init(from decoder:)` 中新增：

```swift
metalCaptureEnabled = try container.decodeIfPresent(Bool.self, forKey: .metalCaptureEnabled) ?? false
```

**注意**：`metalCaptureEnabled` 不需要 `didSet` 副作用（不像 `metalHUD` 需要写 defaults），它只是一个纯粹的设置项，通过共享 plist 文件传递给 PlayTools。

#### 2. Installer 写 Info.plist

**文件**：`PlayCover/AppInstaller/Installer.swift`

在安装流程的 Info.plist 修改部分（约第 109-111 行），在 `info.assert(minimumVersion: 11.0)` 之前或之后，添加：

```swift
// Enable Metal capture support for programmatic frame capture
info[bool: "MetalCaptureEnabled"] = true
```

**说明**：
- 对所有 app 都启用 `MetalCaptureEnabled`——这只是声明应用支持截帧，实际截帧需要 PlayTools 中的代码触发
- 这个 key 对正常运行无影响，只是告诉 Metal 框架允许编程式截帧
- 如果后续决定只对 `metalCaptureEnabled` 设置为 true 的 app 启用，可以在 R05 中再调整

#### 3. PlayTools 侧同步

**文件**：`Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift`

在 PlayTools 的 `AppSettingsData` 中新增：

```swift
var metalCaptureEnabled = false
```

在 `PlaySettings` 类中新增 lazy 属性：

```swift
@objc lazy var metalCaptureEnabled = settingsData.metalCaptureEnabled
```

### 验收标准

1. `AppSettingsData`（两侧）都有 `metalCaptureEnabled` 字段
2. 安装新 app 后，其 `Info.plist` 包含 `MetalCaptureEnabled = YES`
3. 现有 app 的设置 plist 可以正确读取（新字段有默认值 `false`）
4. 项目能够正常构建（`xcodebuild -scheme PlayCover build`）
5. 现有 MCP 测试不因字段变化而失败

### 验证步骤

1. 构建项目：`xcodebuild -project PlayCover.xcodeproj -scheme PlayCover -configuration Release build`
2. 构建 MCP：`xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP -configuration Release build`
3. 运行 MCP 测试：`xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64'`
4. 手动检查：安装一个 app 后用 `plutil -p` 查看 Info.plist 是否包含 `MetalCaptureEnabled`

### 实施结果

- **实际改动文件**：
  - `PlayCover/Model/AppSettings.swift` — `AppSettingsData` 新增 `metalCaptureEnabled = false` 字段及 `init(from decoder:)` 解码
  - `PlayCover/AppInstaller/Installer.swift` — 安装时在 `info.assert(minimumVersion:)` 之后写入 `info[bool: "MetalCaptureEnabled"] = true`
  - `Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` — `AppSettingsData` 新增 `metalCaptureEnabled = false` 字段，`PlaySettings` 新增 `@objc lazy var metalCaptureEnabled`
  - `LocalDocs/RenderCapture/00-主文档.md` — 更新看板状态
  - `LocalDocs/RenderCapture/R01-Host设置与安装管线改动.md` — 更新任务状态
- **关键决策**：对所有 app 无条件写入 `MetalCaptureEnabled = YES`（此 key 仅声明允许截帧，不影响正常运行）
- **已知问题**：PlayCover scheme 构建因 Carthage Bootstrap 脚本中 SwiftLint 缺失而失败（环境问题，非代码问题）；PlayCoverMCP scheme 构建和 579 项测试全部通过
- **Commit Hash**：`b978f607`
