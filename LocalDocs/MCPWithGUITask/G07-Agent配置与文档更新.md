# G07：Agent 配置与文档更新

## 任务概述

| 属性 | 值 |
|------|---|
| **状态** | 🔲 待开始 |
| **前置依赖** | G04（MCPManager 已工作，TCP 可连接） |
| **预估工时** | 0.5 天 |
| **风险等级** | 低 |

## 目标

更新 `README-MCP.md` 和相关文档，说明两种使用模式（CLI stdio / GUI TCP），提供 Agent 客户端的 TCP 配置示例。

## 实现步骤

### Step 1：更新 README-MCP.md

在现有文档中添加以下内容：

#### 1.1 两种运行模式说明

```markdown
## 运行模式

PlayCover MCP Server 支持两种运行模式：

### 模式 1：GUI 内嵌（推荐）

启动 PlayCover.app 后，MCP Server 自动在 TCP 端口 19820 上监听。
无需手动操作，Agent 直接通过 TCP 连接。

### 模式 2：独立 CLI

使用 PlayCoverMCP 命令行工具，通过 stdio 与 Agent 通信。
适用于不使用 GUI 或需要自动化场景。
```

#### 1.2 Agent 配置示例

提供主流 Agent 客户端的 TCP 配置示例：

```markdown
## Agent 配置

### Claude Desktop（GUI 模式 TCP）

在 `~/Library/Application Support/Claude/claude_desktop_config.json` 中添加：

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

### Claude Desktop（CLI 模式 stdio）

```json
{
  "mcpServers": {
    "playcover": {
      "command": "/path/to/PlayCoverMCP"
    }
  }
}
```
```

#### 1.3 验证连接

```markdown
## 验证连接

启动 PlayCover.app 后，可用以下命令验证 MCP Server 是否正常运行：

```bash
# 检查端口
lsof -i :19820

# 发送测试请求
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | nc localhost 19820
```
```

### Step 2：检查并更新其他文档

- `LocalDocs/MCPWithGUI/` 中的文档如有过时信息，更新之
- 检查 `LocalDocs/MCP/` 中是否有需要同步更新的内容

## 验收标准

- [ ] `README-MCP.md` 包含两种运行模式说明
- [ ] 提供了 TCP 连接的 Agent 配置示例
- [ ] 提供了验证连接的方法
- [ ] 文档准确且可直接使用

## 测试计划

1. **文档审查**：确认配置示例格式正确
2. **功能验证**：按文档步骤实际测试一遍 TCP 连接

## 实际测试结果

> （由执行 agent 在完成后填写）

---

## 注意事项

1. 确认 TCP 配置格式是否与 Agent 客户端（Claude Desktop / Cursor 等）兼容
2. 不同 Agent 对 TCP MCP 的支持程度可能不同，注明已知限制
3. 保持文档简洁，用户能快速找到自己需要的配置
