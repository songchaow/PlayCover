### 任务编号与标题

- **ID**：`S00`
- **标题**：Session 桥接协议与 Runtime 通道骨架

### Dashboard

- **状态**：`DONE`
- **优先级**：`P0`
- **预计工作量**：`L`
- **建议耗时**：`1.0 ~ 1.5 天`
- **依赖任务**：`H01`、`H02`、`H09`
- **阻塞任务**：`S01` 及之后全部 Session 任务
- **建议执行顺序**：第 13 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `01-总体规划与架构.md`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Toucher.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugController.swift`
- `PlayCover/Utils/PlayTools.swift`

### 任务目标

在 Host 与 `PlayTools` runtime 之间建立**最小可运行的桥接骨架**，但先不落具体触控命令。

### 范围内

- 定义 host/runtime 消息协议
- 定义 session registration / handshake 数据结构
- 在 host 侧建立 bridge client / registry 骨架
- 在 runtime 侧建立 listener 骨架
- 建立 fake runtime 测试夹具

### 范围外

- 不实现 `tap` / `swipe` / `drag`
- 不实现文本输入
- 不实现 attach debugger

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCP/Common/`
- `Carthage/Checkouts/PlayTools/PlayTools/...`（限最小 bridge 目录）
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 优先实现可测试的纯消息层与 transport abstraction
- runtime 与 host 间的消息建议用 JSON 编码
- listener 建议保持极简，只处理注册与 ping/pong 占位
- 尽量把改动集中在新建 bridge 目录，避免散落修改 `PlayTools`

### 测试要求

至少完成：

- 协议编解码测试
- host/fake runtime 握手测试
- session 注册测试
- 超时 / 断连基础测试

### 验收标准

- Host 能感知 runtime 注册
- 协议模型稳定可扩展
- 真实触控命令还未实现，但桥已经搭起来
- 自动化测试可在不启动真实 app 的情况下验证握手

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录协议与 fake runtime 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add session bridge protocol skeleton`

### 执行记录

- **开始时间**：2026-03-24 10:00
- **完成时间**：2026-03-24 12:21
- **执行人 / agent**：CodeBuddy AI
- **测试命令**：`xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -only-testing:PlayCoverMCPTests/BridgeProtocolTests -only-testing:PlayCoverMCPTests/SessionRegistryTests -only-testing:PlayCoverMCPTests/BridgeClientTests -only-testing:PlayCoverMCPTests/SessionHandshakeTests -only-testing:PlayCoverMCPTests/SessionErrorTests`
- **测试结果**：39 tests passed, 0 failures
- **遗留问题**：无
- **commit hash**：待提交
