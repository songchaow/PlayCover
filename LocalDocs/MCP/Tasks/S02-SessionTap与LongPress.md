### 任务编号与标题

- **ID**：`S02`
- **标题**：Session `tap` 与 `long_press`

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S01`
- **阻塞任务**：`S03`、`S04`
- **建议执行顺序**：第 15 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S01-Session生命周期与资源建模.md`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/PTFakeTouch/PTFakeMetaTouch.*`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`

### 任务目标

实现 Session 侧第一批真实输入命令：

- `tap`
- `long_press`

### 范围内

- Host 到 runtime 的命令发送
- runtime 对单点按下 / 抬起的执行
- `durationMs` 语义（用于 long press）
- 坐标校验与错误语义

### 范围外

- 不实现 drag / swipe
- 不实现键盘输入
- 不实现 UI tree

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCP/Tools/Session/`
- `Carthage/Checkouts/PlayTools/PlayTools/...`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- `tap` 与 `long_press` 应共享同一条单点触控执行通路
- runtime 侧尽量复用 `Toucher.touchcam(...)`
- 要明确坐标系约定，并在文档 / schema 中写清楚

### 测试要求

至少完成：

- 命令编码测试
- host/fake runtime 集成测试
- runtime 执行器单元测试或等效测试
- MCP 冒烟测试至少一条
- 如能做真实 app smoke，更佳

### 验收标准

- `tap` / `long_press` 可通过 session 执行
- 输入参数与错误返回稳定
- 自动化测试覆盖主路径
- 坐标与时长语义清晰

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录输入命令测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add tap and long press session tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
