# G09：MCP 服务端口与监听地址配置

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | ✅ 已完成 |
| **前置依赖** | G06（UI 状态指示已实现） |
| **预估工时** | 0.5 天 |
| **风险等级** | 低 |
| **优先级** | P1 |

## 目标

允许用户在 Settings → MCP Server 面板中配置 MCP Server 的监听端口和监听地址，并持久化到 UserDefaults。具体包括：

1. **端口配置**：支持自定义端口号（范围 1024–65535），默认 19820
2. **监听地址配置**：可选 `127.0.0.1`（仅本机）或 `0.0.0.0`（允许网络访问），默认 `127.0.0.1`
3. **应用并重启**：修改配置后一键 stop → start 生效
4. **恢复默认**：一键重置为 `127.0.0.1:19820`

## 设计方案

### 持久化方案

使用 `UserDefaults`（非 `@AppStorage`，因为 `MCPManager` 不是 View），两个 key：

| Key | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `MCPServerPort` | `Int` | `19820` | 端口号 |
| `MCPServerHost` | `String` | `"127.0.0.1"` | 监听 IP |

### 监听地址枚举

在 `TCPTransport` 中新增 `ListenHost` 枚举，与 `NWEndpoint.Host` 映射：

```swift
public enum ListenHost: String, CaseIterable, Equatable {
    case loopback = "127.0.0.1"        // → .ipv4(.loopback)
    case allInterfaces = "0.0.0.0"     // → .ipv4(.any)

    var nwHost: NWEndpoint.Host {
        switch self {
        case .loopback: return .ipv4(.loopback)
        case .allInterfaces: return .ipv4(.any)
        }
    }
}
```

### UI 布局

在 G06 创建的 `MCPStatusView` 中扩展，新增以下 UI 元素：

1. **监听地址 Picker**：下拉选择 `127.0.0.1` 或 `0.0.0.0`，每项带本地化描述
2. **安全警告**：选择 `0.0.0.0` 时显示橙色警告文字
3. **端口输入框**：`TextField`，带实时验证
4. **"应用并重启"按钮**：修改后可用，同时保存 port + host，执行 stop → start
5. **"恢复默认"按钮**：恢复为 `127.0.0.1:19820`

### 向后兼容

- `TCPTransport.init` 的 `host` 参数默认值为 `.loopback`，现有测试（只传 `port: 0`）无需修改
- 首次启动时 UserDefaults 无值，自动回退到默认配置

## 变更文件清单

### 1. `PlayCoverMCP/Transport/TCPTransport.swift`

- **新增** `ListenHost` 枚举（含 `rawValue` 为 IP 字符串、`nwHost` 计算属性）
- **新增** `public let host: ListenHost` 属性
- **修改** `init` 签名：新增 `host: ListenHost = .loopback` 参数
- **修改** `startOnQueue()` 中 `NWListener` 参数：使用 `host.nwHost` 替代硬编码 `.ipv4(.loopback)`
- **修改** 日志：动态显示 `host.rawValue`

### 2. `PlayCover/Services/MCPManager.swift`

- **新增** 常量：`defaultHost = .loopback`、`hostKey = "MCPServerHost"`、`portRange`、`portKey`
- **新增** `@Published var listenHost: TCPTransport.ListenHost`
- **新增** `savedHost` 计算属性（`UserDefaults` 读写，key=`"MCPServerHost"`）
- **新增** `savedPort` 计算属性（`UserDefaults` 读写，key=`"MCPServerPort"`）
- **新增** `static func isValidPort(_:) -> Bool`（验证 1024–65535）
- **新增** `func restart(withPort:host:)`：保存设置 → stop → start
- **修改** `init()`：从 `savedPort` / `savedHost` 加载持久化值
- **修改** `start()`：传递 `host` 参数给 `TCPTransport`
- **修改** `onStateChange` 回调中 `.running(let actualPort)` 分支更新 `self.port`

### 3. `PlayCover/Views/Settings/MCPStatusView.swift`

- **新增** `@State selectedHost: TCPTransport.ListenHost`
- **新增** 监听地址 `Picker`（两个选项 + 本地化描述）
- **新增** 安全警告（选择 `0.0.0.0` 时可见）
- **新增** 端口 `TextField` + 实时验证逻辑
- **新增** "应用并重启" / "恢复默认" 按钮
- **新增** `hasChanges` / `canApply` / `isDefault` 计算属性
- **修改** `frame` 高度从 160 → 280

### 4-6. 三语言本地化文件

**`PlayCover/en.lproj/Localizable.strings`**、**`PlayCover/zh-Hans.lproj/Localizable.strings`**、**`PlayCover/zh-Hant.lproj/Localizable.strings`**

新增的本地化 key：

| Key | en | zh-Hans | zh-Hant |
|-----|----|---------|---------|
| `mcp.port.label` | Port | 端口 | 連接埠 |
| `mcp.port.apply` | Apply & Restart | 应用并重启 | 套用並重啟 |
| `mcp.port.reset` | Reset to Default | 恢复默认 | 恢復預設 |
| `mcp.port.hint` | Default port: 19820. Valid range: 1024–65535 | 默认端口：19820。有效范围：1024–65535 | 預設連接埠：19820。有效範圍：1024–65535 |
| `mcp.port.error.invalid` | Port must be a number | 端口必须为数字 | 連接埠必須為數字 |
| `mcp.port.error.range` | Port must be 1024–65535 | 端口范围：1024–65535 | 連接埠範圍：1024–65535 |
| `mcp.host.label` | Listen Address | 监听地址 | 監聽位址 |
| `mcp.host.loopback` | Local only | 仅本机 | 僅本機 |
| `mcp.host.all` | All interfaces | 所有接口 | 所有介面 |
| `mcp.host.warning` | ⚠ Listening on all interfaces… | ⚠ 监听所有接口将允许… | ⚠ 監聽所有介面將允許… |

## 实施提示

1. `ListenHost` 使用 `rawValue` 为 IP 字符串，便于 UserDefaults 存储和 UI 显示
2. `restart(withPort:host:)` 先保存再 stop → start，确保崩溃后重启也能读到新配置
3. `TCPTransport.init` 的 `host` 参数设默认值 `.loopback`，现有 579 个测试全部用 `port: 0` 初始化而不传 host，无需修改
4. `onChange(of: portString)` 做实时验证但不阻止输入，仅在 "应用并重启" 时校验
5. `selectedHost == .allInterfaces` 时显示安全警告，提醒用户网络暴露风险

## 验收标准

- [x] Settings → MCP Server 面板可配置端口号
- [x] Settings → MCP Server 面板可选择监听地址（127.0.0.1 / 0.0.0.0）
- [x] 选择 0.0.0.0 时显示安全警告
- [x] "应用并重启" 按钮保存配置并重启 MCP Server
- [x] "恢复默认" 按钮重置为 127.0.0.1:19820
- [x] 端口输入有实时验证（非数字 / 超范围提示）
- [x] 配置持久化到 UserDefaults，重启应用后保留
- [x] `TCPTransport.init` 向后兼容，不传 host 默认 loopback
- [x] `xcodebuild -scheme PlayCover build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过
- [x] `xcodebuild -scheme PlayCoverMCP build FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES` 通过
- [x] MCP 全量测试通过

## 测试计划

1. **编译测试**
   - PlayCover GUI scheme build 通过
   - PlayCoverMCP CLI scheme build 通过
2. **单元/集成测试**
   - MCP 全量测试 (579 tests) 通过，验证向后兼容
3. **功能测试**（人工验证）
   - 启动 GUI → 看到当前端口和地址
   - 修改端口 → 点"应用并重启" → 新端口生效
   - 切换到 0.0.0.0 → 安全警告出现
   - 点"恢复默认" → 回到 127.0.0.1:19820
   - 重启应用 → 配置保持
4. **回归测试**
   - MCP 全量测试通过
   - Lint 零错误

## 实际测试结果

### 编译测试

- ✅ `xcodebuild -scheme PlayCover build` — **BUILD SUCCEEDED**
- ✅ `xcodebuild -scheme PlayCoverMCP build` — **BUILD SUCCEEDED**
- ✅ `xcodebuild test -scheme PlayCoverMCP` — **TEST SUCCEEDED**（579 tests, 0 failures, 1 skipped）
- ✅ `plutil -lint project.pbxproj` — OK
- ✅ Lint — 零错误

### 变更摘要

1. **TCPTransport.swift**：新增 `ListenHost` 枚举与 `host` 参数，支持选择监听地址
2. **MCPManager.swift**：新增 `savedPort` / `savedHost` 持久化、`restart()` 方法、端口验证
3. **MCPStatusView.swift**：新增端口输入框、地址 Picker、安全警告、应用/重置按钮
4. **Localizable.strings** ×3：新增 10 个本地化 key（en/zh-Hans/zh-Hant）

---

## 注意事项

1. 修改端口/地址后需要重启 MCP Server，所有已连接的客户端会断开
2. `0.0.0.0` 监听会将 MCP Server 暴露到网络，需确保用户知晓安全风险
3. 端口冲突时 `TCPTransport` 会通过 `onStateChange(.failed(...))` 报告错误，UI 会显示红色错误信息
4. 本任务不涉及 TLS 加密或认证机制；如需网络暴露的安全防护，应在后续任务中实现
