### 任务编号与标题

- **ID**：`H02`
- **标题**：MCP `logging`、`tasks` 与错误模型基础设施

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H01`
- **阻塞任务**：`H04`、`H08`、`H09`、`S05`
- **建议执行顺序**：第 3 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/H01-MCP协议握手与Stdio服务骨架.md`

### 任务目标

为后续长任务型工具建立统一的：

- `logging` 输出通道
- `tasks` 状态模型
- 错误分类与结构化返回

### 范围内

- server capabilities 中声明 `logging` / `tasks`
- 任务模型：创建、查询、完成、失败、取消占位
- 统一错误类型与错误到 MCP 响应的映射
- 基础日志适配层
- 为后续长任务工具预留公共执行器

### 范围外

- 不实现具体业务工具
- 不实现所有 task UI / fancy progress
- 不做 Session runtime 错误处理细节

### 预期改动目录

- `PlayCoverMCP/Protocol/`
- `PlayCoverMCP/Tasks/`
- `PlayCoverMCP/Logging/`
- `PlayCoverMCP/Common/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 统一定义 `TaskState`、`TaskResult`、`TaskError`
- 对工具输入错误、业务错误、系统错误分层
- `logging` 先满足服务端可发消息，不必一开始做花哨分级体系
- 设计时考虑后续 `install_ipa`、`export_patched_ipa`、`resign_app`、`inject_playtools` 会复用

### 测试要求

至少完成：

- task 创建 / 状态流转测试
- 结构化错误映射测试
- `logging` 最小通知测试或 message emission 测试
- 一条长任务占位冒烟路径

### 验收标准

- 后续长任务工具无需再各自发明状态机
- 错误返回结构统一
- `logging`、`tasks` 能通过自动化测试证明基本可用
- 文档中明确后续任务应如何接入公共执行器

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 task / logging 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add task runtime logging and error abstractions`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
