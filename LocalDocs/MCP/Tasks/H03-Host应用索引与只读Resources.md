### 任务编号与标题

- **ID**：`H03`
- **标题**：Host 应用索引与只读 `resources`

### Dashboard

- **状态**：`IN_PROGRESS`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H01`
- **阻塞任务**：`H04`、`H05`、`H06`、`H07`、`H08`、`H09`、`H10`、`H11`
- **建议执行顺序**：第 4 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/H01-MCP协议握手与Stdio服务骨架.md`
- `PlayCover/ViewModel/AppsVM.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/AppInfo.swift`

### 任务目标

先把**只读、低风险、最容易验证**的一批 Host 能力落成：

- `list_installed_apps`
- `get_app_info`
- 相关 `resources`

### 范围内

- 应用扫描服务
- `bundleId` 解析与校验
- `list_installed_apps`
- `get_app_info`
- `playcover://apps`
- `playcover://apps/{bundleId}`

### 范围外

- 不实现安装 / 启动 / 卸载
- 不实现设置写入
- 不实现 Session 相关能力

### 预期改动目录

- `PlayCoverMCP/HostServices/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCP/Resources/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 不要直接把 `AppsVM` 这种带 UI 生命周期假设的对象硬塞进 server
- 更建议抽一个纯服务：按 `PlayTools.playCoverContainer/Applications` 枚举 app
- `AppInfo` 可以复用，但要小心 UI 依赖与副作用

### 测试要求

至少完成：

- 基于 fixture 目录的应用枚举测试
- `bundleId` 查找测试
- `tools/call` 到 `list_installed_apps` / `get_app_info` 的集成测试
- `resources/read` 冒烟测试

### 验收标准

- `list_installed_apps` 返回稳定结构
- `get_app_info` 能按 `bundleId` 查询
- 对应 resources 可读取
- 自动化测试不依赖真实安装 app 也能跑通

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 fixture 与冒烟命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add app listing info tools and resources`

### 执行记录

- **开始时间**：2026-03-23
- **完成时间**：2026-03-23
- **执行人 / agent**：CodeBuddy Agent
- **测试命令**：`xcodebuild test-without-building -scheme PlayCoverMCP -destination 'platform=macOS'`
- **测试结果**：全部通过（AppServiceTests 7/7, AppToolsAndResourcesTests 10/10）
- **遗留问题**：无
- **commit hash**：待提交
