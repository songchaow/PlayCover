### 任务编号与标题

- **ID**：`S05`
- **标题**：Session 稳定性、超时与 E2E 冒烟

### Dashboard

- **状态**：`TODO`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S01`、`S02`、`S03`、`S04`
- **阻塞任务**：无，作为 Session 收口任务
- **建议执行顺序**：第 18 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S01-Session生命周期与资源建模.md`
- `Tasks/S02-SessionTap与LongPress.md`
- `Tasks/S03-SessionSwipe与Drag.md`
- `Tasks/S04-Session按键文本与DebugOverlay.md`

### 任务目标

做 Session 侧的稳定性收口，而不是再新增功能。

### 范围内

- timeout / disconnect / retry 策略补强
- 会话关闭与失联状态修正
- 端到端 smoke 脚本补全
- 文档收口与已知限制整理

### 范围外

- 不新增新 tool
- 不实现 attach debugger
- 不做语义 UI 自动化

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCPTests/`
- `Scripts/`
- `LocalDocs/MCP/`

### 实施提示

- 这是一张“稳定性任务卡”，不要借机扩 scope
- 核心是让已实现的 Session 工具更可测、更可恢复、更可交付
- 优先补端到端 smoke 资产与错误收敛

### 测试要求

至少完成：

- 断连 / 超时测试
- session 关闭后的错误测试
- 至少一组完整 Session E2E 冒烟脚本
- 如果有真实 app 场景，补一条完整冒烟记录

### 验收标准

- Session 侧有明确 timeout 与失联行为
- 有成体系的 E2E smoke 验证路径
- 文档列清已知限制、未覆盖风险和后续增强方向
- 不新增 scope 外功能

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 如有必要更新 `01-总体规划与架构.md`
- 单独 `git commit`

### 推荐 commit message

- `test(mcp): harden session reliability and e2e smoke coverage`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
