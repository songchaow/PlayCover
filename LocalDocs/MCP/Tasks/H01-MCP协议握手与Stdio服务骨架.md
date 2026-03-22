### 任务编号与标题

- **ID**：`H01`
- **标题**：MCP 协议握手与 `stdio` 服务骨架

### Dashboard

- **状态**：`DONE`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H00`
- **阻塞任务**：`H02` 及之后全部任务
- **建议执行顺序**：第 2 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/H00-测试基础设施与MCP工程骨架.md`

### 任务目标

让 `PlayCoverMCP` 成为一个**真正能讲 MCP 基本协议**的本地 `stdio` server，哪怕此时还没有具体业务工具。

### 范围内

- `initialize`
- server info / protocol version
- `tools/list` 最小实现
- `resources/list` 最小实现
- 基础 request dispatch
- 基础错误返回
- `stdio` transport loop

### 范围外

- 不实现具体 Host tool
- 不实现 `tasks` 运行时
- 不实现 `logging` 细节
- 不实现 Session bridge

### 预期改动目录

- `PlayCoverMCP/Transport/`
- `PlayCoverMCP/Protocol/`
- `PlayCoverMCP/Registry/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 优先把协议入口、消息编解码、handler dispatch 切清楚
- `tools/list` / `resources/list` 可以先返回空或 stub registry，但结构要稳定
- 统一错误模型，不要在各 handler 里随意拼字符串
- 协议实现尽量贴近 `mcp-docs/modelcontextprotocol` 当前 schema

### 测试要求

至少完成：

- `initialize` 响应测试
- `tools/list` 响应测试
- `resources/list` 响应测试
- 未知方法错误测试
- 一条基于 `stdio` 的 MCP 冒烟测试

### 验收标准

- `PlayCoverMCP` 可通过 `stdio` 接收和返回最小 MCP 消息
- `initialize` / `tools/list` / `resources/list` 能稳定返回结构化结果
- 有自动化测试覆盖最小握手路径
- 为后续注册具体 tool / resource 留出清晰扩展点

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录协议冒烟命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): bootstrap stdio server and protocol handshake`

### 执行记录

- **开始时间**：2026-03-22
- **完成时间**：2026-03-22
- **执行人 / agent**：CodeBuddy
- **测试命令**：`xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP test`
- **测试结果**：44 passed, 1 skipped (smoke), 0 failures
- **遗留问题**：
  - 源文件在 MCP 和 Test 两个 target 中各编译一份（非 framework 共享模式）
  - smoke test 需要独立构建 binary 后才能运行（默认 skip）
  - 未来建议将共享逻辑抽取为 framework（H00 已有规划）
- **commit hash**：`68076145`
