### 任务编号与标题

- **ID**：`H08`
- **标题**：Host 签名与 Entitlements

### Dashboard

- **状态**：`TODO`
- **优先级**：`P0`
- **预计工作量**：`M`
- **建议耗时**：`0.5 ~ 1.0 天`
- **依赖任务**：`H02`、`H03`
- **阻塞任务**：无硬阻塞，但影响高级修复能力
- **建议执行顺序**：第 9 个
- **预期提交数**：`1`

### 开工前必读

- 通用前置文档全读
- `PlayCover/Utils/Entitlements.swift`
- `PlayCover/Model/PlayApp.swift`
- `PlayCover/Utils/Shell.swift`

### 任务目标

实现：

- `preview_entitlements`
- `validate_app_signing`
- `resign_app`

### 范围内

- entitlement 组合预览
- signing 校验结果结构化
- 重新签名执行器
- 长任务接入（如实现需要）

### 范围外

- 不做任意原始 entitlement 覆写
- 不实现注入 / 移除 `PlayTools`
- 不处理 Session 运行态

### 预期改动目录

- `PlayCoverMCP/HostServices/Signing/`
- `PlayCoverMCP/Tools/Host/`
- `PlayCoverMCP/Resources/Host/`（如需要）
- `PlayCoverMCPTests/`
- `LocalDocs/MCP/`

### 实施提示

- 优先暴露受控、结构化的结果，而不是把原始 shell 输出直接透传
- `validate_app_signing` 可整合 entitlement 是否一致、`Info.plist` 签名状态等检查
- `resign_app` 建议接入 `tasks` 基础设施

### 测试要求

至少完成：

- entitlement 组合测试
- signing 校验测试
- `resign_app` 调度测试
- 至少一条 MCP 冒烟测试
- 若真实 codesign 难在自动化中跑稳，需补 mock / fake shell 层测试

### 验收标准

- 三个工具可调用
- 返回结构清晰，不暴露难消费的杂乱命令行文本
- 自动化测试覆盖成功与失败路径
- 文档明确哪些能力是受控暴露，哪些没有开放

### 收工要求

- 更新当前任务卡
- 更新 `06-全局任务看板.md`
- 记录 signing 测试命令
- 单独 `git commit`

### 推荐 commit message

- `feat(mcp): add signing and entitlements tools`

### 执行记录

- **开始时间**：
- **完成时间**：
- **执行人 / agent**：
- **测试命令**：
- **测试结果**：
- **遗留问题**：
- **commit hash**：
