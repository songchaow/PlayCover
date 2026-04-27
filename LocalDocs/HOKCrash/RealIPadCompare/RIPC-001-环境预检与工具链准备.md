# RIPC-001：环境预检与工具链准备

> **阅读建议**：本文档沉淀 RIPC-001 阶段的完整实验细节、验证产物与踩坑记录。
> 若只需了解结论，阅读 `00-Dashboard.md` 的"当前状态摘要"即可；当需要复现
> 具体命令、核查原始产物格式、或排查 profile / codesign / deploy / attach
> 阶段异常时，再展开本文。

## 环境基线

- **设备**：`Songchao的iPad`，iPadOS 26.4.1，UDID `00008103-0011050A0E3B001E`
- **Host**：Xcode 16.4
- **签名身份**：`BB36AD6577F23F304F93A1A75A940DAE92559A7B`（Apple Development）
- **默认 Team**：`Songchao Wang`（Team ID `L7CZY6S98T`）
- **IPA 源**：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`（3.07 GB，已解密 `cryptid=0`）
- **PlayCover 安装副本**：`~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`

## 工具链安装

### ios-deploy
通过 Homebrew 安装 `ios-deploy 1.12.2`，用于真机 app 安装。`xcrun devicectl` 作为 CoreDevice 时代首选命令并行使用。

### libimobiledevice
当前未安装，也不是生成 provisioning profile 的前置阻塞项。

## Provisioning Profile 生成

采用"Xcode 空项目自动生成"策略：

1. 在 `build/ripc-profile-bootstrap/` 生成一次性 iOS 工程 `RIPCProfileBootstrap.xcodeproj`，配置 Team `L7CZY6S98T`，bundle ID `com.songdog.ripc.debug`。
2. Xcode 编译后自动生成显式 iOS App Development profile：
   - 路径：`~/Library/Developer/Xcode/UserData/Provisioning Profiles/87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision`
   - 名称：`iOS Team Provisioning Profile: com.songdog.ripc.debug`
   - 关键属性：`get-task-allow=true`，`ProvisionedDevices` 包含目标 iPad UDID。
3. 该 profile 为显式 profile（非 wildcard），对最小 test app 验证已足够。

## 最小 Test App 全链路验证

### 构建与签名
使用 `xcodebuild` 完成 `RIPCProfileBootstrap` 的真机构建与签名，产物带 `application-identifier=L7CZY6S98T.com.songdog.ripc.debug` 与 `get-task-allow=true`。构建日志见 `build/ripc-001c-bootstrap-build.log`，摘要见 `build/ripc-001c-summary.json`。

### 真机部署
`ios-deploy --bundle RIPCProfileBootstrap.app` 成功安装。`devicectl device info apps` 可在真机枚举到 `com.songdog.ripc.debug`。产物：`build/ripc-001c-deploy.log`、`build/ripc-001c-apps.json`。

### 真机启动
`devicectl device process launch` 成功启动 app（普通启动与 `--start-stopped` 启动均验证通过）。产物：`build/ripc-001c-launch-after-trust.json`、`build/ripc-001c-launch-start-stopped.json`。

### Xcode 原生 debug/attach
通过 Xcode GUI（`Attach to Process` 或直接发起调试会话）验证 debug/attach 阶段：调试栏进入活动状态（`pause=true`、`Stop=true`），真机侧存在 `dtdebugproxyd`、`debugserver` 和 `RIPCProfileBootstrap` 进程。产物：`build/ripc-001c-xcode-debug-state.json`。

### ios-deploy --debug 兼容性
`ios-deploy 1.12.2` 在当前 `Xcode 16.4 + iPadOS 26.4.1` 组合下，`--debug` 仍会沿旧式 `DeviceSupport/*/DeveloperDiskImage.dmg` 路径查找并失败。因此 `ios-deploy` 在 RIPC 主线中仅作为 install-only 工具；真机 debug/attach 统一走 Xcode 原生调试入口。产物：`build/ripc-001c-deploy-after-trust.log`。

### LLDB CLI 旁路
`lldb device select` 触发内部 `Running Xcode first launch:` shell 步骤并在 60s 后超时，但这不再阻塞主线。产物：`build/ripc-001c-lldb-select-after-prepare.log`。

## 关键产物索引

| 产物 | 说明 |
|---|---|
| `build/ripc-001c-summary.json` | 001-C 全链路验证摘要 |
| `build/ripc-001c-bootstrap-build.log` | xcodebuild 构建日志 |
| `build/ripc-001c-deploy.log` | ios-deploy 安装日志 |
| `build/ripc-001c-apps.json` | 真机已安装 app 列表 |
| `build/ripc-001c-launch-after-trust.json` | 普通启动结果 |
| `build/ripc-001c-launch-start-stopped.json` | start-stopped 启动结果 |
| `build/ripc-001c-xcode-debug-state.json` | Xcode debug/attach 状态 |
| `build/ripc-001c-deploy-after-trust.log` | ios-deploy --debug 失败日志 |
| `build/ripc-001c-lldb-select-after-prepare.log` | LLDB CLI 超时日志 |
| `build/ripc-profile-bootstrap/RIPCProfileBootstrap.xcodeproj` | 001-B bootstrap 工程 |
| `~/Library/Developer/Xcode/UserData/Provisioning Profiles/87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision` | 自动生成的 provisioning profile |

## 对后续阶段的直接影响

- 签名身份与 Team 作为 RIPC-002 默认重签名参数。
- `ios-deploy` 只用于安装，不用于 debug/attach。
- Xcode 原生调试入口（GUI）作为已验证的 debug/attach 基线。
- 自动化脚本若操作 Xcode GUI，需显式处理 `Replace "<App>"?` 对话框与 `Getting Process List…` 动态子菜单。
