## T07：PlayTools Runtime 桥接与启动接线

### 目标

修复 RT03 的 runtime 侧根因：`BridgeListener.swift` 当前仍是骨架实现，而且尚未接入 `PlayCover.launch()`。  
也就是说，**真实 app 进程里的 PlayTools runtime 现在不会自动完成 host 注册与命令监听**。

本任务是整个 runtime 修复链里最重的一块。

---

### 依赖

建议在 `T06` 完成后进行。  
原因：runtime 侧即使实现了注册，如果 host 侧没有 listener，也无法完成真实联调。

---

### 建议先读

- `LocalDocs/RuntimeTest/01-应用与运行时问题.md`
- `60-T06-Host会话基础设施启动.md`
- `99-经验教训.md`

---

### 重点代码区域

优先检查：

- `Carthage/Checkouts/PlayTools/PlayTools/Controls/Backend/Bridge/BridgeListener.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `PlayCoverMCP/Session/BridgeProtocol.swift`
- `PlayCoverMCP/Session/BridgeClient.swift`
- `PlayCoverMCP/Session/TouchService.swift`
- `PlayCoverMCP/Session/InputService.swift`
- `PlayCoverMCP/Session/CaptureService.swift`
- 相关 session / input / touch tests

---

### 当前已确认的缺口

1. `BridgeListener.start(...)` 还是 TODO 骨架
2. 没有真正启动 runtime command listener
3. 没有真正连接 host registration port 并发送 `register`
4. 没有 heartbeat loop
5. `PlayCover.launch()` 没有接入 runtime bridge 启动

---

### 推荐工作内容

1. 在 PlayTools 侧实现完整 runtime bridge：
   - 本地 command listener 启动
   - 向 host registration port 注册
   - register_ack 校验
   - heartbeat / ping-pong
   - close / cleanup
2. 把现有 `handleCommand(...)` 真正接入网络收发路径
3. 在合适的 app 生命周期点启动 bridge
   - 初步候选：`PlayCover.launch()`
4. 在 app 退出 / 窗口关闭 / bridge 失联时做清理
5. 如果需要额外配置（例如 registration port 来源），请尽量采用与当前架构兼容的最小改法

---

### 验收标准

完成后应满足：

1. 真实 PlayTools runtime 启动后，能向 host 注册 session
2. host 可通过现有 `TouchService` / `InputService` / `CaptureService` 与 runtime 通信
3. bridge 断开、关闭、错误路径有明确处理
4. 新增或补强测试，覆盖至少：
   - register / ack
   - command / commandResponse
   - ping / pong / heartbeat
   - close / cleanup

---

### 建议测试

先跑 session / touch / input focused tests：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES -only-testing:PlayCoverMCPTests/SessionTests -only-testing:PlayCoverMCPTests/SessionTouchTests -only-testing:PlayCoverMCPTests/SessionInputTests -only-testing:PlayCoverMCPTests/SessionReliabilityTests
```

然后跑全量回归：

```bash
cd /Users/songdogwang/Codes/PlayCover && xcodebuild test -scheme PlayCoverMCP -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/PlayCover-DerivedData FASTLANE=1 CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

```bash
cd /Users/songdogwang/Codes/PlayCover && WITH_REGRESSION=1 DERIVED_DATA_PATH=/tmp/PlayCover-DerivedData /bin/bash /Users/songdogwang/Codes/PlayCover/Scripts/test_http_mcp.sh
```

如果本任务改到了 `Carthage/Checkouts/PlayTools/`，请务必补一次**真实 app 端的冒烟验证**，否则不能证明修复真的生效。

---

### 本次实现结果

#### runtime 启动点

- 已在 `PlayCover.launch()` 中调用 `BridgeListener.shared.start(bundleId:)`
- 已在窗口关闭终止路径中调用 `BridgeListener.shared.stop()`，补齐 close / cleanup

#### 协议实现

`BridgeListener.swift` 已从骨架改为可工作的 runtime bridge，当前包含：

- 本地 command listener 启动并监听 ephemeral port
- 连接 host `registrationPort`，发送 `register`，校验 `registerAck`
- 保持 registration channel，并定时发送 `ping` heartbeat
- 处理 command channel 上的 `command` / `ping` / `close`
- 对 `tap` / `long_press` / `swipe` / `drag` 真正接入 `Toucher.touchcam(...)`
- 对 `press_key` / `type_text` 提供最小可用输入转发；复杂 modifier 组合仍保留为后续增强点
- 对 `toggle_debug_overlay` / `capture_frame` / `get_capture_status` 接入现有 runtime 能力

#### 自动化验证结果

- `xcodebuild test -scheme PlayCoverMCP ... -only-testing:...`：本次主要作为 focused 编译检查，命令返回成功，但未实际执行测试用例
- `xcodebuild test -scheme PlayCoverMCP ...`：**669 tests passed，1 skipped，0 failures**
- `Scripts/test_http_mcp.sh`：**通过**
- `xcodebuild build -scheme PlayCover ...`：**通过**，但这一步后来证明**不能单独作为“runtime 新源码已进入 live framework”的证据**；GUI 默认复制的是 `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`
- `xcodebuild -project Carthage/Checkouts/PlayTools/PlayTools.xcodeproj -scheme PlayTools -configuration Release -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' FASTLANE=1`：**通过**

#### 真机 / 真实 app 冒烟结果

- 已通过本机 `playcover` GUI 内嵌 Streamable HTTP 做 fresh live smoke
- 先修复了 `SessionTools.swift` 对整型 `timeout` 的解析；live `create_session(timeout=1)` 已不再错误回落为 `10s`
- 随后定位出真正的 runtime 根因：`PlayTools.xcodeproj` 之前没有把 `BridgeListener.swift` / `MetalCaptureService.swift` 纳入 `PlayTools` target，且 GUI 构建只复制 `Carthage/Build/PlayTools.xcframework` 预编译 framework，导致真实 app 长期加载旧 `PlayTools.framework`
- 在补齐 `PlayTools.xcodeproj` target membership、重建 `PlayTools.framework`、替换 `Carthage/Build/PlayTools.xcframework/ios-arm64/PlayTools.framework`、重装并重启 GUI 后，原神 live 成功完成：
  - `launch_app` 成功
  - `list_sessions` 返回 `ready` session：`runtime-21654-df323da1-3010-483f-b133-679dd7c60055`
  - `create_session(timeout=5)` 成功返回同一 session，`runtimePort=60054`
  - 进程侧可见 `Yuanshen` 已加载 `~/Library/Frameworks/PlayTools.framework/Versions/A/PlayTools`，并建立 `127.0.0.1:59635 -> 127.0.0.1:52741` 注册连接
  - `close_session` 返回成功，`list_sessions` 回读为空
- 同时补充了 runtime 系统日志，`log show` 可见：`PlayCover.launch bundleId=...`、`BridgeListener starting`、`registration connection ready`、`received registration response` 等完整链路

---

### 非目标

- 不要求在本任务里完成最终人工回归矩阵；那是 `T08`
- 不要求在本任务里处理无 ARM64 IPA 的负例安装体验；那是 `T05`

---

### 完成后必须更新

- `01-任务状态.md`
- `99-经验教训.md`
- 本文档中的“runtime 启动点 / 协议实现 / 真机冒烟结果”
