### 任务编号与标题

- **ID**：`H04`
- **标题**：Host 安装与导出 IPA

### Dashboard

- **状态**：`DONE`
- **优先级**：`P0`
- **预计工作量**：`L`
- **建议耗时**：`1.0 ~ 1.5 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：`H05` 以后大部分 Host 真实业务验证
- **建议执行顺序**：第 5 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/H02-MCP日志Tasks与错误模型基础设施.md`
- `Tasks/H03-Host应用索引与只读Resources.md`
- `PlayCover/AppInstaller/Installer.swift`
- `PlayCover/Utils/PlayTools.swift`

### 任务目标

实现 Host 侧首批长任务工具：

- `install_ipa`
- `export_patched_ipa`

### 范围内

- 明确输入 schema（路径、是否注入、可选分类）
- 对 `Installer` 现有逻辑做 headless 包装
- 接入 `tasks` 进度模型
- 将阶段信息映射到任务状态 / 日志
- 返回结构化结果

### 范围外

- 不实现启动 / 卸载
- 不实现运行时 Session
- 不实现 attach debugger
- 不在本任务里扩展额外 IPA 分析功能，除非实现必需

### 预期改动目录

- `PlayCoverMCP/HostServices/Install/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCP/Tasks/`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 当前 `Installer` 带有 UI 偏好的选择逻辑，MCP 版本必须改为显式参数
- 尽量抽象出与 UI 解耦的安装执行器
- 阶段推进可复用现有 `begin / unzip / library / playtools / wrapper / finish / failed` 语义
- 对路径错误、IPA 无效、加密 Mach-O 等失败情况，统一接入错误模型

### 测试要求

至少完成：

- 参数校验测试
- task 创建 / 状态推进测试
- 至少一条 `install_ipa` MCP 冒烟测试
- 至少一条 `export_patched_ipa` MCP 冒烟测试
- 若真实 IPA fixture 难准备，至少补 fake installer / stub integration 测试

### 验收标准

- 两个工具都能被 `tools/call` 调用
- 长任务状态可查询
- 成功与失败都返回结构化结果
- 至少有一层自动化验证覆盖安装 / 导出路径

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录任务化与冒烟验证命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add ipa install and export tools`

### 执行记录

- **开始时间**：2026-03-23
- **完成时间**：2026-03-23
- **执行人 / agent**：CodeBuddy
- **测试命令**：`xcodebuild test -project PlayCover.xcodeproj -scheme PlayCoverMCP -destination 'platform=macOS'`
- **测试结果**：全部通过 (TEST SUCCEEDED)
- **遗留问题**：无
- **commit hash**：6db0038e
