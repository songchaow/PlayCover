## Session 状态指示器

### 功能概述

在 App 库中的每个 app 条目上，实时显示该 app 的 MCP runtime session 状态。当 app 通过 PlayCover 启动并被 PlayTools runtime 注册后，对应条目会出现状态指示器。

### 视觉表现

#### 列表模式

在版本号左侧显示：`🟢 Connected` / `🟠 Connecting` / `🔴 Disconnected`

```
[图标] QQ飞车  ────────────  🟢 Connected  1.56.036637
```

- 绿色圆点 + "Connected"：session 状态为 `ready`
- 橙色圆点 + "Connecting"：session 状态为 `starting`
- 红色圆点 + "Disconnected"：session 状态为 `disconnected`
- 若同一 app 有多个 session，额外显示 `×N` 计数

#### 网格模式

app 图标右上角显示对应颜色的小圆点（带窗口背景色描边），hover 时显示 tooltip。

### 状态优先级

当同一 bundleId 存在多个 session 时，显示"最好"的状态：

```
ready > starting > disconnected
```

不显示 `closed` 或 `pending-` 前缀的临时 session。

### 数据流

```text
SessionRegistry (PlayCoverMCP)
  │ register / unregister / updateStatus / removeStaleSessions
  │ → notifyChange() → DispatchQueue.main.async
  ▼
onChange callback
  │ 过滤 pending- 前缀的临时 session
  │ 按 bundleId 分组，转为 RuntimeSessionSnapshot
  ▼
MCPManager.runtimeSessions (@Published, [String: [RuntimeSessionSnapshot]])
  ▼
PlayAppConditionalView (@ObservedObject mcpManager)
  │ sessions(for: bundleIdentifier)
  │ sessionIndicatorStatus 计算属性
  ▼
SessionIndicatorView (列表模式) / SessionDotView (网格模式)
```

### 关键类型

#### `MCPManager.RuntimeSessionSnapshot`

```swift
struct RuntimeSessionSnapshot: Identifiable, Equatable {
    let id: String          // sessionId
    let bundleId: String
    let status: String      // "starting" | "ready" | "disconnected" | "closed"
    let pid: Int32
}
```

定义在 GUI target 的 `MCPManager.swift` 中，避免跨 target 依赖。通过 `SessionStatus.rawValue` 字符串桥接。

#### `SessionRegistry.onChange`

```swift
public var onChange: (([SessionInfo]) -> Void)?
```

在 `SessionRegistry` 的每个变更方法（`register`、`unregister`、`unregisterByBundleId`、`updateStatus`、`removeStaleSessions`、`removeAll`）末尾调用。回调在 `DispatchQueue.main.async` 中执行。

默认值为 `nil`，CLI 入口不设置此回调，无副作用。

### 视图组件

#### `SessionIndicatorView`

列表模式专用。显示圆点 + 本地化状态文字 + 可选的 `×N` 计数。

#### `SessionDotView`

网格模式专用。10pt 圆点 + 窗口背景色描边，通过 `.overlay(alignment: .topTrailing)` 定位在 app 图标右上角。

### 本地化

| Key | en | zh-Hans | zh-Hant |
|---|---|---|---|
| `session.status.ready` | Connected | 已连接 | 已連線 |
| `session.status.starting` | Connecting | 连接中 | 連線中 |
| `session.status.disconnected` | Disconnected | 已断开 | 已斷線 |

### 源码锚点

| 文件 | 位置 |
|---|---|
| `PlayCover/Views/App Views/PlayAppView.swift` | `PlayAppConditionalView`、`SessionIndicatorView`、`SessionDotView` |
| `PlayCover/Services/MCPManager.swift` | `RuntimeSessionSnapshot`、`runtimeSessions`、`sessions(for:)`、`hasActiveSession(for:)` |
| `PlayCoverMCP/Session/SessionRegistry.swift` | `onChange`、`notifyChange()` |
