### 任务编号与标题

- **ID**：`S01`
- **标题**：Session 生命周期与资源建模

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S00`、`H03`
- **阻塞任务**：`S02`、`S03`、`S04`、`S05`
- **建议执行顺序**：第 14 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S00-Session桥接协议与Runtime通道骨架.md`
- `Tasks/H03-Host应用索引与只读Resources.md`

### 任务目标

实现 Session 的基础控制面：

- `create_session`
- `list_sessions`
- `close_session`
- `playcover://sessions`
- `playcover://sessions/{sessionId}`

### 范围内

- session registry
- session 状态模型
- Host 侧 create / list / close 接口
- sessions resources

### 范围外

- 不实现具体输入命令
- 不在本任务里做高级恢复 / 重连策略
- 不实现 attach debugger

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCP/Tools/Session/`
- `PlayCoverMCP/Resources/Session/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- `create_session` 可以包含“等待 runtime 注册”的最小逻辑
- `close_session` 先支持 host registry 注销与连接关闭即可
- `list_sessions` 要明确区分 `starting / ready / disconnected / closed`

### 测试要求

至少完成：

- create/list/close 测试
- session resource 测试
- fake runtime 下的握手 + create 冒烟测试
- 至少一条 MCP 冒烟路径

### 验收标准

- Session 生命周期工具可用
- Sessions resources 可读
- 状态模型明确，后续输入命令可复用
- 自动化测试覆盖主流程

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 session lifecycle 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add session lifecycle tools and resources`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
