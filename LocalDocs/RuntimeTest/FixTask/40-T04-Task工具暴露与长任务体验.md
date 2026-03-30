## T04：Task 工具暴露与长任务体验

### 目标

修复 RT05：`install_ipa` / `export_patched_ipa` 返回 taskId 后，普通 MCP tool 使用者**无法通过标准 tool 路径**继续查询任务状态。

本任务目标是：**不用再走原始 HTTP JSON-RPC，直接通过正常 MCP tools 就能查询 / 列表 / 取消任务。**

---

### 依赖

建议在 `T03` 完成后进行。  
如果 `T03` 尚未完成，至少要避免新工具继续放大协议不一致。

---

### 建议先读

- `LocalDocs/RuntimeTest/02-任务与协议问题.md`
- `30-T03-Task协议与通知对齐.md`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `PlayCoverMCP/Server/MCPServer.swift`
- `PlayCoverMCP/Tools/InstallerTools.swift`
- `PlayCover/Services/MCPManager.swift`
- `PlayCoverMCP/main.swift`
- 可能新增：task 相关 tool 注册文件
- 相关测试：`PlayCoverMCPTests/MCPServerTests.swift`、`TaskManagerTests.swift`、installer / smoke tests

---

### 推荐工作内容

1. 新增标准 tool 能力，例如：
   - `get_task`
   - `list_tasks`
   - `cancel_task`
   - 如有必要，可加 `get_task_result`
2. 在 GUI 与 CLI 两条启动路径都注册这些工具
3. 调整 `install_ipa` / `export_patched_ipa` 返回文案
   - 不要再只写“Use tasks/get”
   - 应明确告诉调用方新的标准 tool 名称
4. 若 tool 返回结构与底层 task schema 不同，需写清映射关系并补测试

---

### 验收标准

完成后应满足：

1. 标准 MCP tool 路径可直接查看任务状态
2. 不需要再借助原始 HTTP JSON-RPC 才能拿到安装失败原因
3. GUI / CLI 两条 server 启动路径对 task tools 的暴露保持一致
4. 新增测试覆盖至少：
   - 查询任务
   - 列表任务
   - 取消任务
   - `install_ipa` / `export_patched_ipa` 的返回文案更新

---

### 建议测试

优先跑 task + installer 相关 focused tests；如果新增了专门 task tool tests，也要把它们纳入。

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/MCPServerTests -only-testing:PlayCoverMCPTests/TaskManagerTests -only-testing:PlayCoverMCPTests/InstallerServiceTests
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

- 不要求在本任务里修好无 ARM64 IPA 的实际兼容性；那是 `T05`
- 不要求在本任务里修 session / runtime 问题

---

### 新增 task tools / 返回文案 / 测试入口

- 标准 MCP tools 已新增：
  - `get_task`
  - `list_tasks`
  - `cancel_task`
- 三个工具当前直接复用底层 task schema：
  - `get_task` 返回 `GetTaskResult`
  - `list_tasks` 返回 `ListTasksResult`
  - `cancel_task` 返回取消后的 `GetTaskResult`
- GUI 与 CLI 两条入口都已注册这些工具：
  - `PlayCover/Services/MCPManager.swift`
  - `PlayCoverMCP/main.swift`
- `install_ipa` / `export_patched_ipa` 返回文案已从“Use tasks/get”改为指向标准 tool，并附带 `trackingTools` 字段
- 2026-03-30 验证结果：
  - focused tests 通过（`MCPServerTests` / `TaskManagerTests` / `MCPSmokeTests`）
  - `PlayCoverMCP` 全量测试通过
  - `Scripts/test_http_mcp.sh` 回归通过

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档中的“新增 task tools / 返回文案 / 测试入口”
