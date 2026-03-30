## T06：Host 会话基础设施启动

### 目标

修复 RT03 的 host 侧基础设施缺口：当前 GUI 与 CLI 虽然都创建了 `SessionRegistry` / `SessionService`，但**没有真正启动 `RegistrationListener`**，也没有看到完整的 stale session 监控接线。

这意味着：就算 runtime 侧未来实现了注册逻辑，host 侧也可能根本没在监听。

---

### 建议先读

- `LocalDocs/RuntimeTest/01-应用与运行时问题.md`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `PlayCover/Services/MCPManager.swift`
- `PlayCoverMCP/main.swift`
- `PlayCoverMCP/Session/RegistrationListener.swift`
- `PlayCoverMCP/Session/SessionHealthMonitor.swift`
- `PlayCoverMCP/Session/SessionRegistry.swift`
- `PlayCoverMCP/Session/SessionService.swift`
- `PlayCoverMCP/Resources/Session/SessionResources.swift`
- 相关 session tests

---

### 当前已确认的缺口

1. `MCPManager.swift` 里只创建了 `SessionRegistry` / `SessionService`
2. `PlayCoverMCP/main.swift` 里也只注册了 session/touch/input/capture tools
3. 没看到 `RegistrationListener` 的启动、生命周期管理、或 stop 清理逻辑
4. 因此 session host bootstrap 当前并不完整

---

### 推荐工作内容

1. 在 GUI 与 CLI 两条 server 启动路径中，都把以下对象纳入完整生命周期：
   - `SessionRegistry`
   - `RegistrationListener`
   - `SessionHealthMonitor`（如果当前设计需要）
2. 明确 listener 的启动时机、停止时机、错误处理和日志
3. 避免 session registry 在不同 service 之间被误建成多个实例
4. 如有必要，对外增加更易诊断的状态日志或资源
   - 例如 listener 是否已启动、监听端口是多少
5. 如会影响 `create_session` 错误行为，补充测试与文案

---

### 验收标准

完成后应满足：

1. GUI 与 CLI 两条入口都会启动 host registration listener
2. session 相关 service / tool / resource 共享同一个 registry
3. 退出 / stop 时 listener 与 monitor 能被正确清理
4. 新增或补强测试，覆盖至少：
   - listener 启动成功
   - 共享 registry 不被重复创建
   - 生命周期 stop / cleanup 正常

---

### 建议测试

优先跑 session focused tests：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/SessionLifecycleTests -only-testing:PlayCoverMCPTests/SessionReliabilityTests -only-testing:PlayCoverMCPTests/SessionTests
```

然后跑全量回归：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

```bash
cd /Users/songdogwang/Codes/PlayCover && WITH_REGRESSION=1 DERIVED_DATA_PATH=/tmp/PlayCover-DerivedData /bin/bash /Users/songdogwang/Codes/PlayCover/Scripts/test_http_mcp.sh
```

如果你补了 GUI / CLI 启动日志，也建议做一次实际启动冒烟验证。

---

### 非目标

- 不要求在本任务里实现 runtime 侧 `BridgeListener` 逻辑；那是 `T07`
- 不要求在本任务里完成真实 app 的人工输入验证；那是 `T08`

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档中的“生命周期设计 / 入口改动 / 测试覆盖”
