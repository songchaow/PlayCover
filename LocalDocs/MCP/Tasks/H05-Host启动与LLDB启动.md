### 任务编号与标题

- **ID**：`H05`
- **标题**：Host 启动与 LLDB 启动

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：`S01` 之前的真实 session 工作
- **建议执行顺序**：第 6 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Shell.swift`
- `Tasks/H03-Host应用索引与只读Resources.md`

### 任务目标

实现：

- `launch_app`
- `launch_app_with_lldb`

并把启动前检查与错误返回做成稳定的 server 行为。

### 范围内

- bundleId -> app 解析
- 普通启动 tool
- LLDB 启动 tool
- 启动失败错误映射
- 至少一条启动 smoke 路径

### 范围外

- 不实现运行中 attach debugger
- 不实现 stop / restart
- 不在本任务里实现 session registry

### 预期改动目录

- `PlayCoverMCP/HostServices/Launch/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 需要保留 `PlayApp.launch()` 里的前置校验语义
- LLDB 启动要把 `terminalWindow` 等参数显式化
- 若真实启动难自动化，至少把参数处理与 host service 调度做足自动化测试
- 可考虑补一个 `preflight` 内部帮助层，但不必强行对外暴露

### 测试要求

至少完成：

- bundleId 解析与参数测试
- 普通启动 / LLDB 启动 service 调度测试
- MCP tool 集成测试
- 如能自动化真实启动，则补一条真实 smoke；否则记录人工验证步骤

### 验收标准

- 两个工具都可被 `tools/call` 调用
- 参数和错误结构稳定
- LLDB 启动路径有单独测试
- 文档明确“本任务不含 attach debugger”

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录启动验证命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add app launch and lldb launch tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
