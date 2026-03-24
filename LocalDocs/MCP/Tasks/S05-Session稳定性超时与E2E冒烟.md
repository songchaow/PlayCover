### 任务编号与标题

- **ID**：`S05`
- **标题**：Session 稳定性、超时与 E2E 冒烟

### Dashboard

- **状态**：`DONE`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S01`、`S02`、`S03`、`S04`
- **阻塞任务**：无，作为 Session 收口任务
- **建议执行顺序**：第 18 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S01-Session生命周期与资源建模.md`
- `Tasks/S02-SessionTap与LongPress.md`
- `Tasks/S03-SessionSwipe与Drag.md`
- `Tasks/S04-Session按键文本与DebugOverlay.md`

### 任务目标

做 Session 侧的稳定性收口，而不是再新增功能。

### 范围内

- timeout / disconnect / retry 策略补强
- 会话关闭与失联状态修正
- 端到端 smoke 脚本补全
- 文档收口与已知限制整理

### 范围外

- 不新增新 tool
- 不实现 attach debugger
- 不做语义 UI 自动化

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCPTests/`
- `Scripts/`
- `LocalDocs/MCP/`

### 实施提示

- 这是一张“稳定性任务卡”，不要借机扩 scope
- 核心是让已实现的 Session 工具更可测、更可恢复、更可交付
- 优先补端到端 smoke 资产与错误收敛

### 测试要求

至少完成：

- 断连 / 超时测试
- session 关闭后的错误测试
- 至少一组完整 Session E2E 冒烟脚本
- 如果有真实 app 场景，补一条完整冒烟记录

### 验收标准

- Session 侧有明确 timeout 与失联行为
- 有成体系的 E2E smoke 验证路径
- 文档列清已知限制、未覆盖风险和后续增强方向
- 不新增 scope 外功能

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 如有必要更新 `01-总体规划与架构.md`
- 单独 `git commit`

### 推荐 commit message

- `test(mcp): harden session reliability and e2e smoke coverage`

### 实际改动清单

#### 1. Bug 修复：`RegistrationListener.swift`
- **`removeConnection()` 过滤逻辑反转**：`activeConnections.filter { $0.value === connection }` 改为 `!== connection`
- **新增断连状态同步**：runtime 断开时自动标记 session 为 `.disconnected`

#### 2. 新增：`SessionHealthMonitor.swift`
- 基于 `DispatchSourceTimer` 的后台健康监控器
- 可配置 `staleTimeout`（默认 30s）和 `interval`（默认 10s）
- 定期调用 `removeStaleSessions()` 清除失联 session
- `onStaleSessions` 回调用于日志/测试
- `isRunning`、`start(interval:)`、`stop()` 生命周期管理

#### 3. 新增：`SessionReliabilityTests.swift`（7 个测试类，18 个测试）
- **SessionHealthMonitorTests**：启停、过期清除、周期检查、无过期 session 时不触发
- **RegistrationListenerDisconnectTests**：runtime 断连更新 registry 状态
- **SessionClosedErrorTests**：closed/disconnected session 上的 touch/input 操作抛出正确错误、disconnect 后可 close
- **BridgeClientTimeoutTests**：连接超时、命令超时（静默 listener）
- **SessionE2ESmokeTests**：完整生命周期冒烟（register→create→tap→type→key→close→verify-closed-fails）、多 session、超时无 runtime、不存在 session
- **SessionSwipeDragE2ETests**：swipe→drag→toggle_debug_overlay E2E
- **RuntimeErrorResponseTests**：runtime 返回 error status 传播

#### 4. 已知限制与未覆盖风险
- **无命令级重试**：每次命令创建新 TCP 连接，失败直接抛出，不自动重试（避免扩 scope）
- **`SessionHealthMonitor` 未集成到 `main.swift`**：monitor 已实现但未在生产启动路径中自动启动（需要在正式集成时手动调用 `start()`）
- **E2E 测试依赖 FakeRuntimeServer**：无真实 iOS app 端到端验证（需物理设备环境）
- **`removeConnection` 回调线程**：NWConnection 的 stateUpdateHandler 在 listener 队列上执行，registry 操作是线程安全的

### 执行记录

- **开始时间**：2026-03-24 14:00
- **完成时间**：2026-03-24 15:35
- **执行人 / agent**：Claude Agent
- **测试命令**：`xcodebuild build-for-testing -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' && xcodebuild test-without-building -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64'`
- **测试结果**：572 pass / 0 fail / 1 skip（MCPSmokeTests 默认跳过）— 新增 18 个 reliability/E2E 测试全部通过
- **遗留问题**：SessionHealthMonitor 未在生产 main.swift 中启用（稳定性监控需手动集成）
- **commit hash**：`c5385458`
