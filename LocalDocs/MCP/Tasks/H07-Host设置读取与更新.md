### 任务编号与标题

- **ID**：`H07`
- **标题**：Host 设置读取与更新

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：无硬阻塞，但影响 Host 配置闭环
- **建议执行顺序**：第 8 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Model/AppSettings.swift`
- `Tasks/H03-Host应用索引与只读Resources.md`

### 任务目标

实现：

- `get_app_settings`
- `update_app_settings`
- `reset_app_settings`
- `playcover://apps/{bundleId}/settings`

### 范围内

- settings 读写服务
- patch 式更新语义
- reset 语义
- settings resource

### 范围外

- 不在本任务里实现 entitlements / signing
- 不在本任务里实现 keymap
- 不顺手扩展无关设置项

### 预期改动目录

- `PlayCoverMCP/HostServices/Settings/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCP/Resources/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 建议把 `AppSettingsData` 做成稳定的 MCP 可序列化结构
- `update_app_settings` 要避免“全量覆盖误伤”，优先 patch 语义
- 对 bool / enum / 数值类字段的校验要明确

### 测试要求

至少完成：

- settings 读取测试
- patch 更新测试
- reset 测试
- resource 读取测试
- MCP 冒烟测试至少一条

### 验收标准

- 三个工具可用
- settings resource 可读
- 更新后的 settings 会真实持久化
- 自动化测试覆盖主要字段与错误输入

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 settings 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add app settings tools and resources`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
