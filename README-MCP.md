# PlayCoverMCP — MCP Server for PlayCover

PlayCoverMCP 是 PlayCover 的 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) Server，允许 AI Agent 通过标准化协议管理 iOS 应用的安装、启动、输入模拟等操作。

## 运行模式

PlayCover MCP Server 当前支持 **三种传输方式**：

### 模式 1：GUI 内嵌 Streamable HTTP（推荐）

启动 `PlayCover.app` 后，GUI 进程会自动启动内嵌 MCP Server，并在默认端点 `http://127.0.0.1:19820/mcp` 上提供 **Streamable HTTP** 服务。

- 默认传输：`streamable-http`
- 默认监听：`127.0.0.1:19820`
- 支持 `POST /mcp`、`GET /mcp`、`DELETE /mcp`
- 支持 `Mcp-Session-Id` 会话管理、SSE primer event、Origin 校验
- 可在 **Settings → MCP Server** 查看状态、端点、会话数，并切换为 Legacy TCP

> **运行时可用性**：`StreamableHTTPTransport` 依赖 Hummingbird，要求 **macOS 14+**。在更低系统版本上，GUI 会自动回退到 Legacy TCP。

### 模式 2：GUI 内嵌 TCP（Legacy）

为了兼容旧客户端，GUI 仍保留 TCP 传输选项，可在 Settings 中切换。

- 地址格式：`tcp://127.0.0.1:19820`
- 协议：换行分隔 JSON-RPC
- **仅建议旧客户端兼容使用**

### 模式 3：独立 CLI（stdio）

使用 `PlayCoverMCP` 命令行工具，通过 stdio 与 Agent 通信。适用于不使用 GUI、自动化脚本，或客户端只支持 `stdio` transport 的场景。

## 架构概览

```text
模式 1（GUI 内嵌 Streamable HTTP）:
┌───────────────────────────────────────────────────────────────┐
│ PlayCover.app (GUI 进程)                                      │
│                                                               │
│  ┌──────────┐   ┌───────────┐   ┌──────────────────────────┐ │
│  │ SwiftUI  │   │MCPManager │   │ Streamable HTTP          │◄── Agent
│  │  Views   │   │           │   │ http://127.0.0.1:19820   │ │
│  └────┬─────┘   └─────┬─────┘   │ /mcp                     │ │
│       │               │         └──────────┬───────────────┘ │
│       │         ┌─────▼─────┐              │                 │
│       │         │ MCPServer │◄─────────────┘                 │
│       │         └─────┬─────┘                                │
│       │               │                                      │
│       │         NotificationCenter                           │
│       │               │                                      │
│       ◀───────────────┘                                      │
└───────────────────────────────────────────────────────────────┘

模式 3（独立 CLI stdio）:
┌──────────────┐    stdio (JSON-RPC)    ┌────────────────┐
│  MCP Client  │◄──────────────────────►│  PlayCoverMCP  │
│  (AI Agent)  │                        │  (CLI 进程)     │
└──────────────┘                        └────────────────┘
```

**共通特性**：
- **Host 侧**：直接调用 PlayCover 本地能力（应用管理、签名、Keymap 等）
- **Session 侧**：通过 loopback TCP bridge 与运行中的 iOS 应用通信（触控、键盘输入等）
- **CLI 协议**：换行分隔 JSON-RPC
- **GUI 协议**：MCP 2025-11-25 Streamable HTTP

## 系统要求

- macOS 12.0+
- Apple Silicon (arm64)
- [PlayCover](https://github.com/PlayCover/PlayCover) 已安装
- Xcode 14+（仅构建时需要）
- **GUI Streamable HTTP 建议 macOS 14+**

## 构建

```bash
# 克隆仓库
git clone https://github.com/PlayCover/PlayCover.git
cd PlayCover
```

### 构建 PlayCover.app（包含内嵌 MCP Server）

```bash
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCover \
  -configuration Release \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build
```

### 安装 GUI 验证包（推荐）

> **重要**：不要直接启动 `build/.../PlayCover.app` 或 `DerivedData/.../PlayCover.app` 做 GUI 验证。PlayCover 会执行 `AppIntegrity` 检查；若不在 **Applications 文件夹** 中（`/Applications/PlayCover.app` 或 `~/Applications/PlayCover.app`），会弹出移动提示。

推荐使用仓库内脚本安装并重签名：

```bash
./BuildScripts/build_and_install.sh
```

该脚本会：

- 构建 `PlayCover` scheme
- **优先**安装到 `/Applications/PlayCover.app`
- 如果当前会话无法无提示写入 `/Applications`，则**自动回退**到 `~/Applications/PlayCover.app`
- 对整个 `.app` 做 ad-hoc 重签名，修复 Sparkle 等内嵌 framework 的 Team ID 不匹配问题

### Render Capture 实验性启动环境

针对 `supports_gpu_trace=false` / `gpu_trace_document_unsupported` 的环境级排查，`update_app_settings` 额外支持一个实验性布尔字段：

- `injectMetalCaptureEnvironment`: 为目标 app 的启动链路注入 `METAL_DEVICE_WRAPPER_TYPE=1`、`METAL_CAPTURE_ENABLED=1`、`METAL_FRAME_CAPTURE_ENABLED=1`、`MTLCaptureEnabled=1`

用途：在**不改动被测 app 包内容**的前提下，验证特殊启动环境是否会改变 `get_capture_status` 中的 `supports_gpu_trace` / `supports_developer_tools`。

注意：

- 这是 **实验性排查开关**，默认关闭
- 修改后需要重新启动目标 app 才会生效
- 它不会替代 `metalCaptureEnabled`，两者需要分别理解：
  - `metalCaptureEnabled`：让 runtime 初始化 `MTLCaptureManager`
  - `injectMetalCaptureEnvironment`：让 host 在启动目标 app 时注入额外 Metal capture 环境变量

### 构建 PlayCoverMCP CLI（独立命令行工具）

```bash
xcodebuild -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -configuration Release \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build
```

构建产物位于：

```text
/tmp/PlayCover-DerivedData/Build/Products/Release/PlayCoverMCP
```

## 验证连接

### GUI 内嵌模式（Streamable HTTP）

启动已安装的 `PlayCover.app` 后（优先 `/Applications/PlayCover.app`，无管理员权限时也可为 `~/Applications/PlayCover.app`）：

1. **查看 UI 状态**：打开 **Settings → MCP Server**，确认状态为 Running，端点显示为 `http://127.0.0.1:19820/mcp`
2. **命令行验证**：

```bash
# initialize
curl -i -X POST http://127.0.0.1:19820/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# initialized
curl -i -X POST http://127.0.0.1:19820/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# tools/list
curl -X POST http://127.0.0.1:19820/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -H "Mcp-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

如需完整集成验证，请使用：

```bash
./Scripts/test_http_mcp.sh
```

如果要让脚本自动拉起 GUI，请先确保已经安装到 Applications 文件夹，然后执行以下任一命令：

```bash
PLAYCOVER_APP_PATH=/Applications/PlayCover.app ./Scripts/test_http_mcp.sh
PLAYCOVER_APP_PATH=~/Applications/PlayCover.app ./Scripts/test_http_mcp.sh
```

### GUI Legacy TCP 模式

如客户端尚未支持 Streamable HTTP，可在 Settings 中切到 TCP，然后使用：

```text
tcp://127.0.0.1:19820
```

### CLI 模式（stdio）

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  | /tmp/PlayCover-DerivedData/Build/Products/Release/PlayCoverMCP 2>/dev/null | head -1
```

## Agent 侧配置

根据运行模式选择对应的配置方式。

---

### GUI 内嵌模式（Streamable HTTP，推荐）

> **前提**：已安装的 `PlayCover.app` 正在运行（优先 `/Applications/PlayCover.app`，无管理员权限时也可使用 `~/Applications/PlayCover.app`），且 Settings 中的 transport 为 **Streamable HTTP**。

#### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "playcover": {
      "transport": "streamable-http",
      "url": "http://127.0.0.1:19820/mcp"
    }
  }
}
```

#### CodeBuddy

```json
{
  "mcpServers": {
    "playcover": {
      "transport": "streamable-http",
      "url": "http://127.0.0.1:19820/mcp"
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
      "transport": "streamable-http",
      "url": "http://127.0.0.1:19820/mcp"
    }
  }
}
```

#### 安全说明

- POST 请求必须携带 `Accept: application/json, text/event-stream`
- GET 请求必须携带 `Accept: text/event-stream`
- `initialize` 之后，后续 **POST / DELETE** 请求必须携带 `Mcp-Session-Id`
- 已建立会话的后续请求**建议**携带 `Mcp-Protocol-Version: 2025-11-25`；若客户端漏发但服务端已有协商结果，PlayCover 会回退到会话内已协商版本
- 为兼容部分 IDE，**未初始化的 `GET /mcp` 探测**也会返回 `200` + SSE primer；只有显式携带无效协议版本时才返回 `400`
- 非法 `Origin` 会返回 `403`
- 显式无效的协议版本会返回 `400`
- 已失效 session 会返回 `404`

---

### GUI 内嵌模式（TCP，Legacy）

仅在旧客户端需要时使用：

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

---

### CLI 模式（stdio）

#### Claude Desktop

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
- **command**：`PlayCoverMCP` 二进制路径
- **transport**：`stdio`
- 无需额外参数

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
# PlayCoverMCP 全量测试
xcodebuild test -project PlayCover.xcodeproj \
  -scheme PlayCoverMCP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PlayCover-DerivedData \
  FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES

# HTTP 集成测试（要求 GUI 已在 /Applications 中安装并运行）
./Scripts/test_http_mcp.sh
```

当前测试覆盖包括：

- `PlayCoverMCP` 单元/集成测试：**655 tests, 1 skipped, 0 failures**
- `Scripts/test_http_mcp.sh`：HTTP 握手、SSE、Origin、Session、Protocol Version、DELETE 会话终止

## 故障排查

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| **HTTP 模式**：Agent 无法连接 | PlayCover.app 未运行，或 Settings 中当前 transport 不是 Streamable HTTP | 启动已安装的 `PlayCover.app`（优先 `/Applications/PlayCover.app`，也可为 `~/Applications/PlayCover.app`），检查 Settings → MCP Server 状态与端点 |
| **HTTP 模式**：启动时弹出“移到应用程序文件夹” | 你直接打开了 `build/.../PlayCover.app` | 改用 `./BuildScripts/build_and_install.sh` 安装到 Applications 文件夹，然后从安装后的路径启动 |
| **HTTP 模式**：端口 19820 不可达 | 端口被其他进程占用 | `lsof -i :19820` 检查占用情况，关闭冲突进程 |
| **HTTP 模式**：返回 400 | 缺少必需的 `Accept`，或显式携带了无效的 `Mcp-Protocol-Version`，或 POST/DELETE 缺少 `Mcp-Session-Id` | 按 README 示例补齐请求头；若是 IDE 的裸 GET SSE 探测，当前版本已兼容并应返回 `200` |
| **HTTP 模式**：返回 403 | `Origin` 非本地来源 | 使用本地客户端或移除无效 `Origin` |
| **HTTP 模式**：返回 404 | Session 已过期或已被 DELETE 终止 | 重新发送 `initialize` 获取新 session |
| **TCP 模式**：旧客户端无法连接 | GUI 当前没有切到 Legacy TCP | 在 Settings → MCP Server 中切换 transport 为 TCP |
| **CLI 模式**：Agent 无法连接 | 二进制路径错误 | 确认路径正确且有执行权限 (`chmod +x`) |
| `create_session` 超时 | Runtime 未启动或未注入 PlayTools | 先 `launch_app`，确保应用已注入 PlayTools |
| 触控/键盘命令失败 | Session 状态为 disconnected/closed | 检查 `list_sessions`，必要时重新创建 session |
| `install_ipa` 无响应 | 长任务执行中 | 通过 task 机制查询进度，等待完成 |

## 开发文档

本轮 HTTP 改造实施文档位于 `LocalDocs/HttpMCP/`，旧版 MCP 文档位于 `LocalDocs/MCP/`，包含架构规划、任务看板、测试策略、经验教训等，供开发者和 AI Agent 参考。

## 协议版本

- **MCP 协议**：`2025-11-25`
- **Server 版本**：`0.2.0`
- **Server 名称**：`playcover-mcp`（CLI）/ `playcover-mcp-gui`（GUI 内嵌）
- **GUI 默认 HTTP 端点**：`http://127.0.0.1:19820/mcp`
- **GUI Legacy TCP 默认端口**：`19820`

## License

与 PlayCover 主项目相同，采用 GPLv3 协议。详见 [LICENSE](LICENSE)。
