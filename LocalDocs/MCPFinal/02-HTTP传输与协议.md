## PlayCover HTTP MCP 传输与协议

### 一、当前 HTTP 端点

GUI 默认对外暴露的 MCP 端点是：

```text
http://127.0.0.1:19820/mcp
```

实际 host / port 可在 GUI 的 MCP 设置页中调整，但路径固定为：

```text
/mcp
```

### 二、为什么这是当前主方案

当前 GUI 传输层使用 `StreamableHTTPTransport`，它实现的是 **MCP Streamable HTTP** 形态，而不是旧式 raw TCP 行分隔 JSON-RPC。

因此：

- 当前 GUI MCP 的主入口是 **HTTP**
- 旧的 `nc localhost 19820` raw TCP 手测步骤已经不再代表默认路径

### 三、HTTP 方法

`/mcp` 支持三个方法：

| 方法 | 作用 | 典型用途 |
|---|---|---|
| `POST /mcp` | 发送 JSON-RPC 消息 | `initialize`、`tools/list`、`tools/call`、`resources/read` |
| `GET /mcp` | 打开 SSE 流 | 接收日志、任务状态、服务端通知 |
| `DELETE /mcp` | 终止 session | 显式关闭 MCP 会话 |
| `POST /upload` | 上传文件 | 跨机器文件传输，结果可被 tool 参数引用 |

### 四、POST /mcp 行为

#### 1. 请求体

请求体是标准 JSON-RPC 消息。

#### 2. initialize

`initialize` 是特殊请求：

- 服务端会创建 MCP HTTP session
- 在响应头中返回 `Mcp-Session-Id`
- 协议版本协商结果通过 `Mcp-Protocol-Version` 体现

#### 3. 普通 request

普通请求（如 `tools/list`、`tools/call`）要求：

- 带 `Mcp-Session-Id`
- 协议已协商完成
- 若客户端显式带 `Mcp-Protocol-Version`，其值必须可接受

#### 4. notification / response

对于无需返回 body 的消息，服务端可以返回 `202 Accepted`。

### 五、GET /mcp 行为

`GET /mcp` 用于建立 **SSE 监听流**。

其核心用途是接收服务端主动推送：

- `notifications/message`
- `notifications/tasks/status`

#### 1. primer event

SSE 建立后，服务端会立即发送一个 **primer event**：

- 带 `id`
- `data` 为空

这样客户端可以尽快确认流已建立。

#### 2. 匿名 GET

当前实现允许先建立匿名 `GET /mcp` SSE 探测流，用于兼容部分客户端在 `initialize` 前先探测 SSE 能力的行为。

#### 3. 绑定 session 的 GET

一旦进入正式会话，推荐始终带：

- `Mcp-Session-Id`
- `Mcp-Protocol-Version`

### 五点五、POST /upload 行为

`POST /upload` 是一个**辅助 HTTP 端点**，不属于 MCP JSON-RPC 协议，但与 `/mcp` 并列在同一 HTTP server 上，用于跨机器文件传输。

#### 1. 典型场景

Agent 位于远端机器，IPA 文件在 Agent 侧。Agent 先将文件 `POST /upload` 到 PlayCover MCP，再通过 `install_ipa` 的 `@filename` 引用安装。

#### 2. 请求格式

| 项目 | 值 |
|---|---|
| Content-Type | `application/octet-stream` |
| 必需 Header | `Mcp-Session-Id`（必须先 `initialize`）、`X-Filename`（原始文件名） |
| 可选 Header | `X-Checksum-SHA256`（用于校验） |
| 请求体 | 原始文件二进制内容 |
| 大小限制 | 默认 500 MB |

#### 3. 成功响应

```json
{
  "filename": "game.ipa",
  "storedName": "a1b2c3d4-game.ipa",
  "size": 123456789,
  "sha256": "e3b0c44298fc1c14...",
  "expiresIn": 3600,
  "reference": "@a1b2c3d4-game.ipa"
}
```

`reference` 字段可直接传给 `install_ipa` 或 `export_patched_ipa` 的 `ipaPath` 参数。

#### 4. 错误状态码

| HTTP 状态码 | 场景 |
|---|---|
| `400` | 缺少 `X-Filename` 或 `Mcp-Session-Id` |
| `404` | session 不存在或过期 |
| `413` | 文件超过大小限制 |
| `422` | SHA256 校验失败 |

#### 5. 文件生命周期

上传文件存储在 `~/Library/Containers/io.playcover.PlayCover/tmp/mcp-uploads/<session-id>/` 目录下，按 session 隔离。

清理时机：

- session 终止（`DELETE /mcp`）→ 清理该 session 所有上传文件
- session 超时过期 → 同上
- MCP server 停止 → 清理整个上传目录
- 文件 TTL 到期（默认 1 小时）→ 单文件级清理

#### 6. 与 CLI 的关系

`/upload` 仅在 HTTP transport 下可用。CLI（stdio）不支持文件上传。如果 CLI 模式下 tool 参数使用了 `@filename` 引用，会返回明确错误。

### 六、DELETE /mcp 行为

`DELETE /mcp` 用于：

- 显式终止某个 `Mcp-Session-Id`
- 清理其会话状态
- 关闭关联的 SSE 流
- 清理该 session 通过 `/upload` 上传的所有临时文件

### 七、关键 Header

| Header | 作用 |
|---|---|
| `Content-Type: application/json` | POST JSON-RPC 请求体 |
| `Accept: application/json, text/event-stream` | POST 同时声明 JSON / SSE 能力 |
| `Accept: text/event-stream` | GET SSE 流 |
| `Mcp-Session-Id` | 标识当前 HTTP MCP session |
| `Mcp-Protocol-Version` | 声明当前会话使用的 MCP 协议版本 |
| `Origin` | 浏览器场景下用于安全校验 |

### 八、协议版本

当前代码中的 MCP 协议版本常量为：

- `2025-11-25`
- `2025-06-18`
- `2025-03-26`

其中：

- **latest**：`2025-11-25`
- **supportedVersions**：`2025-11-25`、`2025-06-18`、`2025-03-26`

旧的 `2024-11-05` 常量仍在类型定义里，但**不在当前支持列表中**。

### 九、HTTP session 管理

`MCPSessionManager` 负责 HTTP 会话，而不是 runtime bridge session。

它当前承担：

- 创建 session
- 校验 session
- 标记 initialized
- 记录协商后的 protocol version
- 终止 session
- 清理过期 session
- 区分 `notFound` / `expired` / `terminated`

#### 默认时间策略

| 项目 | 当前值 |
|---|---|
| `sessionTimeout` | 30 分钟 |
| `terminatedSessionRetention` | 30 分钟 |

### 十、Origin 校验

当前实现对 `Origin` 进行本地安全校验，用于防 DNS rebinding：

- 允许 `localhost`
- 允许 `127.0.0.1`
- 允许它们的任意端口变体
- **没有 Origin 也放行**，以兼容 `curl`、CLI 客户端和多数本地 Agent SDK

无效 Origin 会返回：

- **`403 Forbidden`**

### 十一、SSE 机制

#### 1. 编码方式

SSE 事件由 `SSEEncoder` 负责编码，基本格式为：

```text
id: <event-id>
data: <json>

```

空 `data` 的 primer event 也由同一编码器输出。

#### 2. 推送来源

当前 SSE 推送主要来自两处：

- `MCPLogger.onLog` → `notifications/message`
- `TaskManager.onStatusChange` → `notifications/tasks/status`

#### 3. 推送接线

接线方式是：

1. `MCPServer` 暴露 `notificationSink`
2. `StreamableHTTPTransport` 在初始化时接入 `notificationSink`
3. `MCPServer.wireNotifications()` 将 logger / task manager 回调接入该 sink
4. sink 再将消息路由到 SSE 流

### 十二、当前行为边界

#### 1. GUI 主路径已经是 HTTP

当前 GUI 端口 `19820` 的默认意义是：

- **HTTP MCP 端点**

不是：

- 默认 raw TCP JSON-RPC socket

#### 2. TCP 仍然保留

但 TCP 只在以下场景仍有意义：

- 用户显式切换为 TCP transport
- 运行环境低于 macOS 14，自动回退到 TCP
- 兼容旧联调环境

#### 3. CLI 不受 HTTP 方案影响

CLI 继续使用 `StdioTransport`，不依赖 Hummingbird。

### 十三、实现锚点

| 文件 | 作用 |
|---|---|
| `PlayCoverMCP/Transport/StreamableHTTPTransport.swift` | `/mcp` 的 POST / GET / DELETE 路由 + `/upload` 路由 |
| `PlayCoverMCP/Transport/MCPSessionManager.swift` | HTTP session 生命周期 |
| `PlayCoverMCP/Transport/UploadManager.swift` | 文件上传暂存、`@filename` 引用解析、清理 |
| `PlayCoverMCP/Transport/SSEEncoder.swift` | SSE 编码 |
| `PlayCoverMCP/Server/MCPServer.swift` | `notificationSink` 与推送接线 |
| `PlayCover/Services/MCPManager.swift` | GUI 默认选 HTTP、低版本回退 TCP |

### 十四、对接建议

如果你要对接 PlayCover GUI 内嵌 MCP，请默认按以下假设编写客户端：

1. 使用 `POST /mcp` 发送 `initialize`
2. 保存返回的 `Mcp-Session-Id`
3. 建立 `GET /mcp` SSE 流
4. 后续所有 `tools/list`、`tools/call`、`resources/read` 均带 session header
5. 完成后用 `DELETE /mcp` 关闭会话

不要再默认假设 GUI MCP 使用旧的 raw TCP 握手路径。