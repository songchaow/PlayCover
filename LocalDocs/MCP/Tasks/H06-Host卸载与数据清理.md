### 任务编号与标题

- **ID**：`H06`
- **标题**：Host 卸载与数据清理

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：无硬阻塞，但影响 Host 功能完整性
- **建议执行顺序**：第 7 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Views/Uninstaller.swift`
- `PlayCover/Model/PlayApp.swift`
- `Tasks/H03-Host应用索引与只读Resources.md`

### 任务目标

实现：

- `uninstall_app`
- `clear_app_data`
- `clear_playchain_data`
- `clear_app_settings`
- `clear_app_entitlements`
- `clear_app_keymaps`

### 范围内

- 破坏性 tool 的结构化输入输出
- 对各清理项做显式参数化
- 卸载组合逻辑
- 错误与日志映射

### 范围外

- 不实现 stop app 后再清理的复杂流程
- 不实现 attach / running session 感知
- 不把多个独立任务并成额外大重构

### 预期改动目录

- `PlayCoverMCP/HostServices/Cleanup/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 现有 UI 里的弹窗 / 复选框必须改成显式 tool 参数
- 对破坏性操作要有清晰错误提示与 destructive 注解信息
- 若检测到目标不存在，应返回稳定的业务错误

### 测试要求

至少完成：

- 参数组合测试
- 单项清理测试
- 卸载组合测试
- 一条 MCP 冒烟测试
- 若真实文件删除不好测，使用 fixture 目录验证

### 验收标准

- 清理类工具都有明确边界
- `uninstall_app` 支持组合选项
- 自动化测试能验证文件系统副作用
- 文档清楚标注破坏性操作风险

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录清理类测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add uninstall and cleanup tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
