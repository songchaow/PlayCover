### 任务编号与标题

- **ID**：`H09`
- **标题**：Host 注入、运行环境切换与分类

### Dashboard

- **状态**：`IN_PROGRESS`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：`S00` 之前的 Session 可用性
- **建议执行顺序**：第 10 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Utils/PlayTools.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Model/AppInfo.swift`

### 任务目标

实现：

- `inject_playtools`
- `remove_playtools`
- `check_playtools_installed`
- `set_introspection_enabled`
- `set_ios_frameworks_enabled`
- `set_application_category`

### 范围内

- `PlayTools` 注入 / 移除 / 检测
- DYLD_LIBRARY_PATH 两类切换
- app 分类设置
- 相关错误处理与测试

### 范围外

- 不实现 Session bridge
- 不在本任务里处理实际触控命令
- 不在本任务里做 keymap

### 预期改动目录

- `PlayCoverMCP/HostServices/Injection/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 注入 / 移除是破坏性文件改动，需配合结构化错误返回
- 环境切换本质上是可控字段变更，不要暴露任意 DYLD 写入能力
- `set_application_category` 改动后可能联动签名，注意与 H08 的边界配合

### 测试要求

至少完成：

- 注入 / 移除 service 调度测试
- 检测工具测试
- introspection / iOS frameworks 切换测试
- category 变更测试
- MCP 冒烟测试至少一条

### 验收标准

- 六个工具都可调用
- 破坏性行为有清晰的结构化返回
- 自动化测试覆盖成功 / 失败路径
- 不开放任意 DYLD 或任意 plist 改写能力

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录相关测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add playtools injection and runtime config tools`

### 执行记录

- **开始时间**：2026-03-23 22:20
- **完成时间**：2026-03-23 23:13
- **执行人 / agent**：CodeBuddy (GLM-5.0-Turbo)
- **测试命令**：`xcodebuild test-without-building -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64'`
- **测试结果**：277 tests passed, 0 failures, 1 skipped
- **遗留问题**：add_h09_files.py 脚本有 HostServices group ID 硬编码错误的 bug，需要修复（手动修复了 pbxproj）
- **commit hash**：待提交
