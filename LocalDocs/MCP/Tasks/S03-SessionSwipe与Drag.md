### 任务编号与标题

- **ID**：`S03`
- **标题**：Session `swipe` 与 `drag`

### Dashboard

- **状态**：`DONE`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S02`
- **阻塞任务**：`S05`
- **建议执行顺序**：第 16 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S02-SessionTap与LongPress.md`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Action/PlayAction.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`

### 任务目标

实现：

- `swipe`
- `drag`

### 范围内

- 多阶段触控命令
- 起点 / 终点 / duration / steps 语义
- drag 与 swipe 的最小差异化建模
- 结构化结果与错误处理

### 范围外

- 不实现多指手势
- 不实现键盘输入
- 不实现 UI 语义选择器

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCP/Tools/Session/`
- `Carthage/Checkouts/PlayTools/PlayTools/...`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- `swipe` / `drag` 应共用路径插值与 phase 编排逻辑
- 若 drag 需要“按下保持再移动”，要把语义写在 schema 和文档里
- 避免把复杂手势系统一次做太满

### 测试要求

至少完成：

- 路径插值测试
- 命令编码测试
- host/fake runtime 集成测试
- MCP 冒烟测试至少一条

### 验收标准

- `swipe` / `drag` 可通过 session 执行
- duration / steps 等参数语义明确
- 自动化测试覆盖主流程和错误输入
- 代码没有侵入性地污染其他输入命令实现

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add swipe and drag session tools`

### 执行记录

- **开始时间**：2026-03-24
- **完成时间**：2026-03-24
- **执行人 / agent**：Claude agent
- **测试命令**：`xcodebuild test -scheme PlayCoverMCP -only-testing PlayCoverMCPTests`
- **测试结果**：484 pass / 0 fail / 1 skip（新增 43 个测试）
- **遗留问题**：无
- **commit hash**：`f862711e`
