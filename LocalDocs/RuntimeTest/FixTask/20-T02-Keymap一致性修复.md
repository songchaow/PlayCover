## T02：Keymap 一致性修复

### 目标

修复 RT04：`delete_keymap` 返回成功后，`list_keymaps` 立即回读仍可能看到旧项。

这个问题至少要从两条线排查：

1. **服务层真实一致性**：文件、`.config.plist`、`listKeymaps()` 返回值是否同步
2. **通知 / 刷新链路**：state-changing 操作后是否都正确发出了 keymap 更新通知

---

### 建议先读

- `LocalDocs/RuntimeTest/01-应用与运行时问题.md`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `PlayCoverMCP/HostServices/Keymap/KeymapService.swift`
- `PlayCoverMCP/Tools/Host/KeymapTools.swift`
- `PlayCoverMCP/Common/MCPNotifications.swift`
- `PlayCoverMCPTests/KeymapServiceTests.swift`

必要时再查 GUI 侧对 `.mcpKeymapsChanged` 的消费方。

---

### 推荐工作内容

1. 先补一个**稳定复现**当前问题的测试
   - 尤其是：create -> rename -> delete -> immediate list
2. 检查以下操作是否都正确维护了 config 与通知：
   - create
   - rename
   - delete
   - reset
   - import
3. 检查 `listKeymaps()` 是否可能从旧的 `keymapOrder`、磁盘目录、或隐藏文件处理逻辑里重复把已删除项加回来
4. 如果问题主要是通知缺失，也要补测试证明 GUI / observer 侧可感知变化

---

### 已知可疑点

从当前代码看，`createKeymap` / `importKeymap` 会发 `postKeymapsChanged`，但 `renameKeymap` / `deleteKeymap` / `resetKeymap` 没有明显对称处理。  
不过 **不要只凭这个点就直接收工**，必须先用测试证明根因和修复效果。

---

### 验收标准

完成后应满足：

1. `create -> rename -> delete -> list` 的回读结果立即一致
2. keymap 变更操作的通知行为对称、可解释
3. 新增测试至少覆盖：
   - 删除后立即 list
   - rename 后 list
   - reset 不改变 keymap 集合
   - 相关通知 / 刷新行为（若代码路径可测）

---

### 建议测试

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/KeymapServiceTests
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

- 不要求在本任务里处理 session / runtime / installer 问题
- 不要求重做整个 keymapping GUI

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档中的“最终结论 / 新增测试 / 剩余风险”
