### 任务编号与标题

- **ID**：`H11`
- **标题**：Host Keymap 导入导出

### Dashboard

- **状态**：`TODO`
- **优先级**：`P1`
- **预计工作量**：`S`
- **建议耗时**：`0.5 ~ 0.75 天`
- **依赖任务**：`H02`、`H10`
- **阻塞任务**：无
- **建议执行顺序**：第 12 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Utils/Keymapping.swift`
- `Tasks/H10-HostKeymap基础管理.md`

### 任务目标

实现：

- `import_keymap_from_path`
- `export_keymap_to_path`

### 范围内

- 用显式路径参数替代 `NSOpenPanel` / `NSSavePanel`
- bundleId 不一致场景的明确处理策略
- 导入 / 导出结构化结果

### 范围外

- 不再改基础 CRUD
- 不做运行态 keymap 切换
- 不做 keymap 编辑器增强

### 预期改动目录

- `PlayCoverMCP/HostServices/Keymap/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 现有 `importKeymap` / `exportKeymap` 带 UI 面板，MCP 版本必须完全 headless
- 对 bundleId 不一致的 keymap，要明确是拒绝、强制允许还是显式参数控制
- 导出路径权限错误要给稳定错误返回

### 测试要求

至少完成：

- 导入成功测试
- bundleId 不一致测试
- 导出成功测试
- 路径错误测试
- 一条 MCP 冒烟测试

### 验收标准

- 两个工具都完全不依赖 UI 面板
- 自动化测试覆盖成功与失败路径
- 导入策略在文档与 schema 上都清晰可见

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录导入导出测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add keymap import and export tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
