## T03：Task 协议与通知对齐

### 目标

修复以下协议层问题：

- RT06：`tasks/get` / `tasks/cancel` 只接受裸字符串参数
- RT07：SSE 任务通知 method 实际为 `notifications/tasks/update`，与预期规范不一致

本任务的重点是：**先把底层 JSON-RPC / MCP 语义对齐**。

---

### 建议先读

- `LocalDocs/RuntimeTest/02-任务与协议问题.md`
- `mcp-docs/modelcontextprotocol/schema/2025-11-25/schema.ts`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `PlayCoverMCP/Server/MCPServer.swift`
- `PlayCoverMCP/Tasks/TaskManager.swift`
- `PlayCoverMCPTests/MCPServerTests.swift`
- `PlayCoverMCPTests/MCPServerNotificationTests.swift`
- `PlayCoverMCPTests/TaskManagerTests.swift`

---

### 推荐工作内容

1. 对齐 `tasks/get` / `tasks/cancel` 参数形状
   - 优先支持规范式对象参数，如 `{ "taskId": "task-1" }`
   - 如果兼容成本低，建议保留对旧字符串参数的向后兼容
2. 对齐任务状态通知 method
   - 从 `notifications/tasks/update` 统一到 `notifications/tasks/status`
   - 若历史兼容必要，可短期同时兼容，但文档与默认实现必须明确主方法名
3. 检查错误文案
   - 不要再写成 `requires a string 'id' param` 这种与最终对象参数不一致的提示
4. 确保单测、通知测试、协议文档描述同步更新

---

### 验收标准

完成后应满足：

1. `tasks/get` / `tasks/cancel` 可按对象参数正常调用
2. 任务状态 SSE / notification 默认 method 与规范一致
3. 现有 task 相关测试通过，且新增测试覆盖：
   - 对象参数调用成功
   - 若保留兼容，字符串参数仍可调用
   - 任务状态通知 method 正确

---

### 建议测试

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/MCPServerTests -only-testing:PlayCoverMCPTests/MCPServerNotificationTests -only-testing:PlayCoverMCPTests/TaskManagerTests
```

然后跑全量回归：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

```bash
cd /Users/songdogwang/Codes/PlayCover && WITH_REGRESSION=1 DERIVED_DATA_PATH=/tmp/PlayCover-DerivedData /bin/bash /Users/songdogwang/Codes/PlayCover/Scripts/test_http_mcp.sh
```

---

### 非目标

- 本任务不负责把 task 能力暴露成标准 tool；那是 `T04`
- 本任务不负责 installer 的错误诊断细化；那是 `T05`

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档中的“协议决策 / 兼容策略 / 新增测试”
