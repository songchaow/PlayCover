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

- **开始时间**：2026-03-23
- **完成时间**：2026-03-23
- **执行人 / agent**：Claude Code (GLM-5.0-Turbo)
- **测试命令**：`xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP test`
- **测试结果**：217 tests passed, 0 failures, 1 skipped
- **遗留问题**：无
- **commit hash**：ea482854
- **实际改动范围**：
  - 新增 `PlayCoverMCP/HostServices/Settings/SettingsService.swift` — settings 读写/patch/reset 服务，使用 PropertyListSerialization 代替 AppSettingsData 以避免跨 target 依赖
  - 新增 `PlayCoverMCP/Tools/Host/SettingsTools.swift` — 注册 get_app_settings, update_app_settings, reset_app_settings 三个 MCP 工具
  - 新增 `PlayCoverMCP/Resources/SettingsResources.swift` — 注册 settings resource 元数据
  - 修改 `PlayCoverMCP/Resources/AppResources.swift` — 添加 settingsService 参数，统一分发 settings resource 请求
  - 修改 `PlayCoverMCP/main.swift` — 注册 SettingsService、SettingsTools、SettingsResources
  - 修改 `PlayCoverMCP/Common/MCPErrorExtensions.swift` — 添加 SettingsError 到 PlayCoverMCPError 的错误码映射
  - 新增 `PlayCoverMCPTests/SettingsServiceTests.swift` — 21 个服务层单元测试
  - 新增 `PlayCoverMCPTests/SettingsToolsAndResourcesTests.swift` — 12 个 MCP 集成测试
  - 修改 `PlayCoverMCPTests/MCPSmokeTests.swift` — 更新工具计数 (12→15) 和资源计数 (0→3)
