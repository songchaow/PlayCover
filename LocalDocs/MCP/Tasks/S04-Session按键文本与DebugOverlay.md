### 任务编号与标题

- **ID**：`S04`
- **标题**：Session 按键、文本与 Debug Overlay

### Dashboard

- **状态**：`DONE`
- **优先级**：`P1`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`S01`
- **阻塞任务**：`S05`
- **建议执行顺序**：第 17 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `Tasks/S01-Session生命周期与资源建模.md`
- `Tasks/S00-Session桥接协议与Runtime通道骨架.md`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/MenuController.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/DebugOverlay/DebugController.swift`

### 任务目标

实现：

- `press_key`
- `type_text`
- `toggle_debug_overlay`

### 范围内

- Host 到 runtime 的按键命令
- 文本输入命令建模
- 调试叠加层切换命令
- 对失败与不支持情况做稳定返回

### 范围外

- 不实现复杂 IME / 输入法兼容层
- 不做 UI tree
- 不做 attach debugger

### 预期改动目录

- `PlayCoverMCP/Session/`
- `PlayCoverMCP/Tools/Session/`
- `Carthage/Checkouts/PlayTools/PlayTools/...`
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- `press_key` 与 `type_text` 需要先定义可接受的 key / text 范围
- 如果 runtime 当前没有完整文本输入通路，可先做最小可用实现，但必须写清限制
- `toggle_debug_overlay` 应优先复用现有 `DebugController.toggleDebugOverlay()`

### 测试要求

至少完成：

- 命令模型测试
- fake runtime 集成测试
- `toggle_debug_overlay` 行为测试
- MCP 冒烟测试至少一条
- 文本输入若难完全自动化，需写清人工 smoke 步骤

### 验收标准

- 三个工具可调用
- 限制条件清晰，不隐瞒当前 runtime 约束
- 自动化测试覆盖尽可能完整
- Session 工具集至此基本闭环

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add session key text and debug overlay tools`

### 执行记录

- **开始时间**：2026-03-24
- **完成时间**：2026-03-24
- **执行人 / agent**：Claude agent
- **测试命令**：`xcodebuild test-without-building -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64'`
- **测试结果**：554 pass / 0 fail / 1 skip（其中 70 个 Input 相关测试全部通过）
- **遗留问题**：runtime 侧按键/文本输入为最小可用实现（BridgeListener 接受命令但不做真实键盘注入），复杂 IME 不支持
- **commit hash**：待提交

### 新增文件

| 文件 | 用途 |
| --- | --- |
| `PlayCoverMCP/Session/InputService.swift` | 输入服务层：KeyPressParams、TypeTextParams、InputResult、InputError、SupportedKeys 验证、InputServiceProtocol、InputService（真实实现）、FakeInputService（测试替身） |
| `PlayCoverMCP/Tools/Session/InputTools.swift` | MCP 工具注册：press_key、type_text、toggle_debug_overlay 三个工具的 schema 定义与 handler |
| `PlayCoverMCPTests/SessionInputTests.swift` | 10 个测试类：InputParamsTests、InputResultTests、InputErrorTests、SupportedKeysTests、InputErrorMCPMappingTests、FakeInputServiceTests、InputServiceValidationTests、InputCommandEncodingTests、InputToolsRegistrationTests、InputBridgeIntegrationTests |
| `Scripts/add_s04_files.py` | pbxproj 集成脚本 |

### 修改文件

| 文件 | 改动 |
| --- | --- |
| `PlayCoverMCP/main.swift` | 注册 InputService 和 InputTools |
| `PlayCoverMCP/Common/MCPErrorExtensions.swift` | 添加 InputError → PlayCoverMCPError 映射 |
| `PlayCover.xcodeproj/project.pbxproj` | 添加新文件到 PlayCoverMCP 和 PlayCoverMCPTests targets |
