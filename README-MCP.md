# PlayCoverMCP — MCP Server for PlayCover

PlayCoverMCP 是 PlayCover 的 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) Server，允许 AI Agent 通过标准化协议管理 iOS 应用的安装、启动、输入模拟等操作。

## 运行模式

PlayCover MCP Server 支持两种运行模式：

### 模式 1：GUI 内嵌（推荐）

启动 PlayCover.app 后，MCP Server **自动**在 TCP 端口 `19820` 上监听（`127.0.0.1` loopback）。无需手动操作，Agent 直接通过 TCP 连接即可。

- 可在 **Settings → MCP Server** 中查看服务状态、端口号和已连接客户端数
- 支持多个 Agent 同时连接
- 应用关闭时自动停止 MCP Server

### 模式 2：独立 CLI（stdio）

使用 `PlayCoverMCP` 命令行工具，通过 stdio 与 Agent 通信。适用于不使用 GUI 或需要自动化脚本的场景。

## 架构概览

```
模式 1（GUI 内嵌 TCP）:
┌─────────────────────────────────────────────────────────┐
│  PlayCover.app (GUI 进程)                                │
│                                                          │
│  ┌──────────┐   ┌───────────┐   ┌───────────────────┐  │
│  │ SwiftUI  │   │MCPManager │   │ TCP:19820         │◄── Agent (Claude/Cursor/...)
│  │   Views  │   │           │   │ (TCPTransport)    │  │
│  └────┬─────┘   └─────┬─────┘   └────┬──────────────┘  │
│       │               │              │                   │
│       │         ┌─────▼─────┐        │                   │
│       │         │ MCPServer │◄───────┘                   │
│       │         └─────┬─────┘                            │
│       │               │                                  │
│       │    NotificationCenter                            │
│       │               │                                  │
│       ◀───────────────┘                                  │
│  (GUI 自动刷新)                                           │
└─────────────────────────────────────────────────────────┘

模式 2（独立 CLI stdio）:
┌──────────────┐    stdio (JSON-RPC)    ┌────────────────┐
│  MCP Client  │◄──────────────────────►│  PlayCoverMCP  │
│  (AI Agent)  │                        │  (CLI 进程)     │
└──────────────┘                        └────────────────┘
```

**共通特性**：
- **Host 侧**：直接调用 PlayCover 本地能力（应用管理、签名、Keymap 等）
- **Session 侧**：通过 loopback TCP bridge 与运行中的 iOS 应用通信（触控、键盘输入等）
- **协议**：行分隔 JSON-RPC（两种模式消息格式完全一致）

## 系统要求

- macOS 12.0+
- Apple Silicon (arm64)
- [PlayCover](https://github.com/PlayCover/PlayCover) 已安装
- Xcode 14+（仅构建时需要）

## 构建

```bash
# 克隆仓库
git clone https://github.com/PlayCover/PlayCover.git
cd PlayCover
```

### 构建 PlayCover.app（包含内嵌 MCP Server）

```bash
xcodebuild -scheme PlayCover \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build
```

构建完成后启动 PlayCover.app，MCP Server 自动在 `127.0.0.1:19820` 上监听。

### 构建 PlayCoverMCP CLI（独立命令行工具）

```bash
xcodebuild -scheme PlayCoverMCP \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build
```

构建产物位于：

```
~/Library/Developer/Xcode/DerivedData/PlayCover-<hash>/Build/Products/Release/PlayCoverMCP
```

> **提示**：可以将二进制复制到方便的位置，例如 `/usr/local/bin/PlayCoverMCP`。

## 验证连接

### GUI 内嵌模式（TCP）

启动 PlayCover.app 后：

1. **查看 UI 状态**：打开 Settings → MCP Server，确认状态显示为 "Running"
2. **命令行验证**：

```bash
# 检查端口是否在监听
lsof -i :19820

# 发送测试请求（initialize 握手）
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | nc localhost 19820
```

如果连接正常，会返回包含 `serverInfo` 的 JSON 响应。

### CLI 模式（stdio）

```bash
# 确认二进制可执行
/path/to/PlayCoverMCP --help 2>/dev/null; echo $?

# 快速测试协议握手（发送 initialize 请求）
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | /path/to/PlayCoverMCP 2>/dev/null | head -1
```

## Agent 侧配置

根据运行模式选择对应的配置方式。

---

### GUI 内嵌模式（TCP，推荐）

> **前提**：PlayCover.app 正在运行。

#### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "playcover": {
      "transport": "tcp",
      "host": "127.0.0.1",
      "port": 19820
    }
  }
}
```

#### CodeBuddy

在项目根目录或全局 MCP 配置中添加：

```json
{
  "mcpServers": {
    "playcover": {
      "host": "127.0.0.1",
      "port": 19820,
      "transport": "tcp"
    }
  }
}
```

#### Cursor

编辑 `.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "playcover": {
      "transport": "tcp",
      "host": "127.0.0.1",
      "port": 19820
    }
  }
}
```

#### 其他支持 MCP TCP 的客户端

配置要素：
- **transport**：`tcp`
- **host**：`127.0.0.1`
- **port**：`19820`

> **注意**：不同 Agent 客户端对 TCP transport 的支持程度可能不同。如果您的客户端尚不支持 TCP MCP，请使用下方的 CLI stdio 模式。

---

### CLI 模式（stdio）

#### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "playcover": {
      "command": "/path/to/PlayCoverMCP"
    }
  }
}
```

#### CodeBuddy

```json
{
  "mcpServers": {
    "playcover": {
      "command": "/path/to/PlayCoverMCP",
      "args": [],
      "transport": "stdio"
    }
  }
}
```

#### Cursor

编辑 `.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "playcover": {
      "command": "/path/to/PlayCoverMCP"
    }
  }
}
```

#### 其他客户端

配置要素：
- **command**：PlayCoverMCP 二进制路径
- **transport**：`stdio`
- 无需额外的 args 或环境变量

## 功能列表

### Tools（42 个）

#### 应用管理

| Tool | 说明 |
|------|------|
| `list_installed_apps` | 列出所有已安装的 iOS 应用 |
| `get_app_info` | 获取指定应用的详细信息 |

#### 安装与导出

| Tool | 说明 |
|------|------|
| `install_ipa` | 安装 IPA 文件（长任务，支持 task 追踪） |
| `export_patched_ipa` | 导出已修补的 IPA（长任务） |

#### 启动

| Tool | 说明 |
|------|------|
| `launch_app` | 启动指定应用 |
| `launch_app_with_lldb` | 以 LLDB 调试模式启动应用 |

#### 卸载与清理

| Tool | 说明 |
|------|------|
| `uninstall_app` | 卸载指定应用 |
| `clear_app_data` | 清除应用数据 |
| `clear_playchain_data` | 清除 PlayChain 数据 |
| `clear_app_settings` | 清除应用配置 |
| `clear_app_entitlements` | 清除应用 Entitlements |
| `clear_app_keymaps` | 清除应用按键映射 |

#### 配置

| Tool | 说明 |
|------|------|
| `get_app_settings` | 获取应用配置 |
| `update_app_settings` | 更新应用配置 |
| `reset_app_settings` | 重置应用配置为默认值 |

#### 签名

| Tool | 说明 |
|------|------|
| `preview_entitlements` | 预览应用 Entitlements |
| `validate_app_signing` | 验证应用签名有效性 |
| `resign_app` | 重签名应用（长任务） |

#### 注入与运行环境

| Tool | 说明 |
|------|------|
| `inject_playtools` | 注入 PlayTools |
| `remove_playtools` | 移除 PlayTools |
| `check_playtools_installed` | 检查 PlayTools 是否已注入 |
| `set_introspection_enabled` | 启用/禁用 Introspection |
| `set_ios_frameworks_enabled` | 启用/禁用 iOS Frameworks |
| `set_application_category` | 设置应用分类 |

#### Keymap 管理

| Tool | 说明 |
|------|------|
| `list_keymaps` | 列出指定应用的所有 Keymap |
| `get_keymap` | 获取指定 Keymap 内容 |
| `create_keymap` | 创建新 Keymap |
| `rename_keymap` | 重命名 Keymap |
| `delete_keymap` | 删除 Keymap |
| `reset_keymap` | 重置 Keymap 为默认值 |
| `import_keymap` | 从文件路径导入 Keymap |
| `export_keymap` | 导出 Keymap 到文件路径 |

#### Session 管理

| Tool | 说明 |
|------|------|
| `create_session` | 创建运行时 Session（等待 runtime 注册） |
| `list_sessions` | 列出所有 Session |
| `close_session` | 关闭指定 Session |

#### 触控输入（需要活跃的 Session）

| Tool | 说明 |
|------|------|
| `tap` | 点击指定坐标 |
| `long_press` | 长按指定坐标 |
| `swipe` | 滑动（从起点到终点） |
| `drag` | 拖拽（从起点到终点） |

#### 键盘输入（需要活跃的 Session）

| Tool | 说明 |
|------|------|
| `press_key` | 按下指定按键（支持修饰键） |
| `type_text` | 输入文本字符串 |
| `toggle_debug_overlay` | 切换调试覆盖层显示 |

### Resources

| URI | 说明 |
|-----|------|
| `playcover://apps` | 所有已安装应用列表（JSON 数组） |
| `playcover://apps/{bundleId}` | 指定应用详情（JSON 对象） |
| `playcover://apps/{bundleId}/settings` | 指定应用的配置（JSON 对象） |
| `playcover://sessions` | 所有活跃 Session 列表（JSON 数组） |
| `playcover://sessions/{sessionId}` | 指定 Session 详情（JSON 对象） |

### 其他能力

| 能力 | 说明 |
|------|------|
| **Logging** | 执行过程日志，通过 MCP logging 通知推送给客户端 |
| **Tasks** | 长耗时操作（安装、导出、重签名）以 Task 形式异步执行，支持进度查询 |

## 典型使用流程

### Host 侧操作

```
Agent: 调用 list_installed_apps
Agent: 调用 get_app_info { bundleId: "com.example.game" }
Agent: 调用 launch_app { bundleId: "com.example.game" }
```

### Session 侧（运行时输入）

```
# 1. 启动应用并创建 session
Agent: 调用 launch_app { bundleId: "com.example.game" }
Agent: 调用 create_session { bundleId: "com.example.game" }
# → 返回 sessionId，server 等待 runtime 注册

# 2. Session 就绪后，发送触控/键盘命令
Agent: 调用 tap { sessionId: "xxx", x: 100, y: 200 }
Agent: 调用 swipe { sessionId: "xxx", fromX: 100, fromY: 500, toX: 100, toY: 200, durationMs: 300 }
Agent: 调用 type_text { sessionId: "xxx", text: "hello world" }
Agent: 调用 press_key { sessionId: "xxx", key: "escape" }

# 3. 完成后关闭 session
Agent: 调用 close_session { sessionId: "xxx" }
```

## Session Bridge 工作原理

Session 侧操作依赖 Host ↔ Runtime 的双通道 TCP bridge：

1. **注册通道**：Runtime（PlayTools）启动后，向 Host 的固定端口 `52741` 发送注册消息（包含 `sessionId`、`bundleId`、`pid`、`port`）
2. **命令通道**：Host 向 Runtime 的动态端口发送命令（`tap`、`swipe`、`press_key` 等），采用换行分隔的 JSON 格式
3. **Session 状态**：`starting → ready → disconnected → closed`

> **注意**：Session 侧功能需要 PlayTools runtime 支持。如果 runtime 未启动或未注册，`create_session` 会在超时后返回错误。

## 运行测试

```bash
# 构建测试
xcodebuild build-for-testing \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64'

# 执行测试
xcodebuild test-without-building \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64'
```

当前测试覆盖：572 个测试用例，覆盖协议、注册、服务、工具、Session 生命周期、可靠性、E2E 冒烟等。

## 故障排查

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| **TCP 模式**：Agent 无法连接 | PlayCover.app 未运行 | 启动 PlayCover.app，检查 Settings → MCP Server 状态 |
| **TCP 模式**：端口 19820 不可达 | 端口被其他进程占用 | `lsof -i :19820` 检查占用情况，关闭冲突进程 |
| **TCP 模式**：Settings 显示 "Failed" | TCP 监听失败 | 检查 Settings → MCP Server 中的错误信息 |
| **CLI 模式**：Agent 无法连接 | 二进制路径错误 | 确认路径正确且有执行权限 (`chmod +x`) |
| `create_session` 超时 | Runtime 未启动或未注入 PlayTools | 先 `launch_app`，确保应用已注入 PlayTools |
| 触控/键盘命令失败 | Session 状态为 disconnected/closed | 检查 `list_sessions`，必要时重新创建 session |
| `install_ipa` 无响应 | 长任务执行中 | 通过 task 机制查询进度，等待完成 |

## 开发文档

内部实施文档位于 `LocalDocs/MCP/`，包含架构规划、任务看板、测试策略、经验教训等，供开发者和 AI Agent 参考。

## 协议版本

- **MCP 协议**：`2024-11-05`
- **Server 版本**：`0.2.0`
- **Server 名称**：`playcover-mcp`（CLI）/ `playcover-mcp-gui`（GUI 内嵌）
- **TCP 默认端口**：`19820`（仅 GUI 内嵌模式）

## License

与 PlayCover 主项目相同，采用 GPLv3 协议。详见 [LICENSE](LICENSE)。
