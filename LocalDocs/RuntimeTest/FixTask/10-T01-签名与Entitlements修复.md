## T01：签名与 Entitlements 修复

### 目标

修复以下问题：

- RT01：`preview_entitlements` 对真实 app 直接失败
- RT02：`validate_app_signing` 与 `preview_entitlements` 的语义不一致

目标不是“强行让所有 app 都有 entitlements”，而是让以下三件事成立：

1. **解析逻辑更稳**
2. **无 entitlements 场景能优雅返回**
3. **两个工具对同一 app 的结论互相一致、可解释**

---

### 建议先读

- `LocalDocs/RuntimeTest/01-应用与运行时问题.md`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `PlayCoverMCP/HostServices/Signing/SigningService.swift`
- `PlayCoverMCP/Tools/Host/SigningTools.swift`
- `PlayCoverMCP/HostServices/MCPShell.swift`
- `PlayCoverMCPTests/SigningServiceTests.swift`

---

### 推荐工作内容

1. 先复核 `codesign` / entitlement dump 的真实输入输出
   - 尤其要看：空输出、非 XML plist、前后有杂质文本、stderr/stdout 混用等情况
2. 修复 `dumpEntitlementsFromBinary(...)` 的兼容性
3. 明确“无 entitlements”与“entitlements 解析失败”是两种不同结果
4. 让 `validate_app_signing` 的字段语义与工具输出一致
   - 重点关注 `entitlementsMatch` / `entitlementsPresent` 的实际含义
5. 如有必要，优化工具返回文案，让调用方能区分：
   - 未签名
   - 已签名但无 entitlements
   - entitlements 存在但解析失败

---

### 验收标准

完成后应满足：

1. `preview_entitlements` 对“无 entitlements”场景不再直接抛出误导性错误
2. `validate_app_signing` 与 `preview_entitlements` 对同一二进制的结论可互相解释
3. 新增或补强测试，覆盖至少以下场景：
   - 有效 entitlements
   - 无 entitlements
   - 非法 / 不可解析 entitlement 数据
4. 若 live app 仍返回“无 entitlements”，文案必须足够明确

---

### 建议测试

先跑 focused tests：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/SigningServiceTests
```

完成后跑全量回归：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

```bash
cd /Users/songdogwang/Codes/PlayCover && WITH_REGRESSION=1 DERIVED_DATA_PATH=/tmp/PlayCover-DerivedData /bin/bash /Users/songdogwang/Codes/PlayCover/Scripts/test_http_mcp.sh
```

如果能稳定复现 live app 问题，建议把复现步骤补回 `LocalDocs/RuntimeTest/01-应用与运行时问题.md`。

---

### 非目标

- 不要求在本任务里处理 session / runtime / task 问题
- 不要求让没有 entitlements 的 app 变成有 entitlements

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档（简短写明最终结论、测试覆盖、是否还有残留边界）
