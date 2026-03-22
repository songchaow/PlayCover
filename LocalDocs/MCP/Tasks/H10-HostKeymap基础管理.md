### 任务编号与标题

- **ID**：`H10`
- **标题**：Host Keymap 基础管理

### Dashboard

- **状态**：`TODO`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：`H11`
- **建议执行顺序**：第 11 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Utils/Keymapping.swift`
- `Tasks/H03-Host应用索引与只读Resources.md`

### 任务目标

实现：

- `list_keymaps`
- `get_keymap`
- `create_keymap`
- `rename_keymap`
- `delete_keymap`
- `reset_keymap`

### 范围内

- keymap 目录与配置服务
- 基础 CRUD 工具
- keymap 列表与默认 keymap 读取

### 范围外

- 不实现导入 / 导出
- 不实现 Session 切换 keymap
- 不做运行时输入映射修改

### 预期改动目录

- `PlayCoverMCP/HostServices/Keymap/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCP/Resources/Host/`（如需要）
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 复用 `Keymapping.swift` 时，避免 UI 依赖路径
- `rename` / `delete` / `reset` 都要考虑不存在项的错误语义
- 可在结果里附带 `defaultKeymap` 与 `keymaps[]`

### 测试要求

至少完成：

- keymap 列表测试
- 创建 / 重命名 / 删除 / 重置测试
- MCP tool 集成测试
- 一条 keymap 冒烟路径

### 验收标准

- 六个工具都可用
- 基础 CRUD 通过自动化测试验证
- 返回结构稳定，错误可预测
- 文档写清楚导入 / 导出不在本任务中

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 keymap 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add basic keymap management tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
