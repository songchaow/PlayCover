### 任务编号与标题

- **ID**：`H00`
- **标题**：测试基础设施与 MCP 工程骨架

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：无
- **阻塞任务**：`H01` 及之后全部任务
- **建议执行顺序**：第 1 个
- **预期提交数**：`1`

### 开工前必读

- `00-README-导航.md`
- `01-总体规划与架构.md`
- `02-Agent-执行入口.md`
- `03-共享前置信息.md`
- `04-测试与验证策略.md`
- `05-提交与文档更新规范.md`
- `06-全局任务看板.md`

### 任务目标

在 `PlayCover.xcodeproj` 中建立后续 MCP 开发的**最小可演进工程底座**，让后续任务可以：

- 有独立 `PlayCoverMCP` target
- 有独立测试 target
- 有最小 smoke harness
- 有清晰的代码目录与测试目录

### 范围内

- 新增 `PlayCoverMCP` 命令行 target
- 新增 `PlayCoverMCPTests` 测试 target
- 建立基础目录结构
- 建立最小可运行入口（哪怕先只输出 stub）
- 建立基础测试样例与 smoke helper 占位
- 更新相关文档与看板

### 范围外

- 不实现完整 MCP 协议握手
- 不实现具体 Host / Session tool
- 不实现 runtime bridge

### 预期改动目录

- `PlayCover.xcodeproj/`
- `PlayCoverMCP/`
- `PlayCoverMCPTests/`
- `Scripts/`（如需要）
- `LocalDocs/MCP/`

### 实施提示

- 命令行 target 名称统一使用 `PlayCoverMCP`
- 测试 scheme 优先与 target 保持一致，便于后续统一命令
- 先把目录和测试跑通，再考虑业务逻辑
- 如果需要复用工程依赖，优先复用现有 Xcode 工程的 package graph

### 测试要求

至少完成：

- `xcodebuild -project PlayCover.xcodeproj -scheme PlayCoverMCP -configuration Release build`
- `xcodebuild test -project PlayCover.xcodeproj -scheme PlayCoverMCP -destination 'platform=macOS'`
- 最小 smoke：启动 `PlayCoverMCP` 可执行文件并确认进程可正常启动 / 退出

### 验收标准

- 仓库中存在独立 `PlayCoverMCP` target
- 存在独立测试 target
- 测试命令可以执行
- 目录结构清晰，后续任务无需再重复搭架子
- 当前任务卡与全局看板已更新

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录构建与测试命令
- 单独 `git commit`

### 推荐 commit message

- `chore(mcp): create server target and test scaffolding`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
