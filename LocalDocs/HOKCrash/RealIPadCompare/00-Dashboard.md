## RealIPadCompare Dashboard

> **单一来源规则**：本文档是"真机 iPad 对比调试"方向的唯一主线维护文档。
> 当前主线、TODO、验证口径只在本文维护；长日志、历史推理细节、脚本细节
> 下沉到对应子文档。主文档保持可快速通读。
>
> **与 HOKCrash/00-Dashboard.md 的关系**：本方向的最终目标与 HOKCrash
> 主线一致（消除 `QtsFileSystem Create Failed!!`），但技术路线完全不同——
> 本方向通过**真机 iPad 对比**来定位 PlayCover 环境与真实 iOS 环境的
> **通用差异**，而非在 PlayCover 运行时层面逐一矫正 app 行为。

## 最终目标

- 让 `com.tencent.ngr`（王者荣耀世界）在 PlayCover 中**稳定启动并持续
  存活**，不再出现 `QtsFileSystem Create Failed!!` 导致的启动期 fatal /
  僵尸态。
- **核心策略**：将同一 app 部署到真实 iPad 并进行 LLDB 真机调试，采集
  **QtsFileSystem 初始化成功路径**的关键运行时上下文（文件系统路径、沙盒
  结构、环境变量、entitlements、NSBundle/NSSearchPath 返回值等），与
  PlayCover 环境做**结构化差异对比**，定位导致 `Create Failed` 的
  **通用环境差异根因**。
- 重点是对齐"PlayCover 环境与真实 iPad 环境的通用差异"，而不是在
  PlayCover 的 app 运行时层面针对 app 做各种行为矫正。
- 找到根因后，在 PlayCover/PlayTools 层做**最小、可逆、bundle-scoped**
  的环境对齐修复。

## 全局约束

- 对 `com.tencent.ngr` 的修复默认**按 bundle 精准生效**，不扩大为全局
  行为改动。
- agent 日常构建、验证、证据收集必须能**自主完成**；任何需要用户介入的
  步骤（手工登录、手工点 UI、手工观察窗口表现等），都要先得到用户确认。
- 真机调试使用开发者证书重签名；重签名后的 app 只用于调试，不用于分发。
- 所有真机 trace 产物存放在 `build/ripc-*.json` / `build/ripc-*.log`。

## 主线任务

### 当前主线一句话

`RIPC-001-C`：最小 test app 已完成签名构建、真机安装与真机启动；当前主线只剩
LLDB attach 验证，其中 `ios-deploy --debug` 仍卡在旧式 `DeviceSupport` 查找，
本机 `lldb device select` 也尚未稳定完成设备选择。

### 当前状态摘要

- 真机已连接：`Songchao的iPad`（iPadOS 26.4.1），UDID
  `00008103-0011050A0E3B001E`。
- Xcode 16.4 可用，签名身份 `BB36AD6577F23F304F93A1A75A940DAE92559A7B`
  （Apple Development）有效。
- IPA 源文件：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`（3.07 GB，
  已解密 `cryptid=0`）。
- PlayCover 已安装副本在
  `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`。
- **工具链状态**：`ios-deploy` 已通过 Homebrew 安装并用
  `ios-deploy --version` 验证为 `1.12.2`；`libimobiledevice` 系列仍未安装，
  当前不是生成 provisioning profile 的前置阻塞项。
- **常用 Xcode Team**：后续自动签名默认使用 `Songchao Wang`
  （Team ID `L7CZY6S98T`）；不要再把 `WSA8H7MN7D` 当作 RIPC 主线的默认
  auto-sign Team。
- **001B bootstrap 工程**：已在 `build/ripc-profile-bootstrap/` 生成一次性
  iOS 工程 `RIPCProfileBootstrap.xcodeproj`；当前工程已持久化为 Team
  `L7CZY6S98T`，bundle ID 为 `com.songdog.ripc.debug`。
- **001B 产物**：Xcode 已生成显式 iOS App Development profile
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision`，
  名称 `iOS Team Provisioning Profile: com.songdog.ripc.debug`，`get-task-allow=true`，
  且 `ProvisionedDevices` 已包含 iPad UDID `00008103-0011050A0E3B001E`。
- **001C 构建重跑成功**：`xcodebuild` 已重新完成 `RIPCProfileBootstrap` 的真机构建与
  签名，产物仍带 `application-identifier=L7CZY6S98T.com.songdog.ripc.debug`
  与 `get-task-allow=true`；见 `build/ripc-001c-bootstrap-build.log` 与
  `build/ripc-001c-summary.json`。
- **001C 安装成功**：`ios-deploy` 已将 `RIPCProfileBootstrap.app` 安装到 iPad，且
  `devicectl device info apps` 能在真机侧枚举到 `com.songdog.ripc.debug`；见
  `build/ripc-001c-deploy.log`、`build/ripc-001c-apps.json`。
- **001C 真机启动成功**：`devicectl device process launch` 已可成功启动
  `com.songdog.ripc.debug`，普通启动进程 PID 为 `1389`，`--start-stopped` 启动进程
  PID 为 `1397`；见 `build/ripc-001c-launch-after-trust.json` 与
  `build/ripc-001c-launch-start-stopped.json`。
- **`ios-deploy --debug` 仍有工具链兼容阻塞**：在启动已成功的前提下重新执行
  `ios-deploy --debug`，仍停在旧式 `DeviceSupport/*/DeveloperDiskImage.dmg` 查找；
  当前 host 上 `xcrun devicectl list preferredDDI`
  显示 Xcode 16.4 走的是 CoreDevice 外置 DDI
  `file:///Library/Developer/DeveloperDiskImages/iOS_DDI/`，但 `ios-deploy 1.12.2`
  的 debug 启动路径仍在查找旧式 `DeviceSupport/*/DeveloperDiskImage.dmg`，因此
  install / launch 已成功后仍会在 debug 阶段失败；见 `build/ripc-001c-deploy-after-trust.log` 与
  `build/ripc-001c-summary.json`。
- **现代 LLDB CLI attach 仍未打通**：当前直接 attach 尝试里，
  `device select DBE867A3-4E28-5C1C-B3B3-07BD0521C3CE` 会报
  `timed out waiting for shell command to complete`，随后
  `device process attach -p 1397` 提示 `no device selected`；见
  `build/ripc-001c-lldb-expect-attach.log`。

### 修复路线概览（优先级从高到低）

1. **环境预检与工具链准备**（RIPC-001 系列）：安装缺失工具、生成
   provisioning profile、验证签名链路。
2. **重签名与真机部署**（RIPC-002 系列）：对 `com.tencent.ngr.app`
   做完整重签名（主二进制 + 41 个 embedded framework）、修改 bundle ID、
   注入 provisioning profile、部署到真机。
3. **真机启动行为基线采集**（RIPC-003 系列）：在真机上启动 app 并
   通过 LLDB 采集 QtsFileSystem 初始化路径的关键上下文：
   `NSHomeDirectory()`、`NSBundle.mainBundle`、
   `NSSearchPathForDirectoriesInDomains`、`NSTemporaryDirectory()`、
   环境变量、cwd、entitlements 实际值等。
4. **PlayCover 环境同构采集**（RIPC-004 系列）：在 PlayCover 环境下
   采集同一组上下文数据。
5. **结构化差异对比与根因定位**（RIPC-005 系列）：对比两组数据，
   定位导致 `QtsFileSystem Create Failed` 的环境差异根因。
6. **PlayTools 环境对齐修复**（RIPC-006 系列）：在 PlayTools 层
   做最小 bundle-scoped 环境对齐，消除差异根因。
7. **端到端验证**（RIPC-007）：验证修复后 PlayCover 启动不再触发
   `QtsFileSystem Create Failed`。

### 当前卡点

1. `ios-deploy 1.12.2` 的 debug 启动链仍停留在旧式 `DeviceSupport` 查找路径，和
   Xcode 16.4 的 CoreDevice DDI 路径不一致，见 `build/ripc-001c-deploy-after-trust.log`
   与 `build/ripc-001c-summary.json`。
2. 本机 `lldb` 的 `device select` 目前仍会超时，随后 CLI attach 会因为
   `no device selected` 未完成，见 `build/ripc-001c-lldb-expect-attach.log`。

### 下一步默认规划

1. 保持 `com.songdog.ripc.debug` 作为最小 attach 验证目标，继续聚焦现代
   CoreDevice / LLDB 调试链路，而不再把启动问题与 attach 问题混在一起。
2. 继续收敛 `lldb device select` 超时的具体原因；若 CLI attach 始终不稳定，则把
   `RIPC-001-C` 的 attach 验证切换到 Xcode 调试入口，同时保留 `ios-deploy` 作为
   install-only 工具。
3. 只有在“可启动 + 可 attach”都拿到结构化证据后，才将 `RIPC-001-C` 标记完成，
   并结束 `RIPC-001`；完成后再进入 `RIPC-002`。

## 构建与验证

### 日常默认方法

- **真机连接验证**：`xcrun xctrace list devices` 确认 iPad 在线。
- **重签名工具链**：`codesign` + `security` + `/usr/libexec/PlistBuddy`，
  脚本化后存放在 `Scripts/ripc_resign.sh`（待建）。
- **真机部署**：`ios-deploy --bundle <path>` 或 Xcode Devices window。
- **真机 LLDB**：`ios-deploy --debug --bundle <path>` 启动并自动 attach
  LLDB；或 Xcode Debug → Attach to Process。
- **PlayCover 侧验证**：复用 HOKCrash 主线的 `launch_app` +
  `launch-events.jsonl` 流程。
- **证据存放**：真机 trace 产物 → `build/ripc-*.json`；对比报告 →
  `build/ripc-*-diff.json`。

### 需要用户确认后才能继续的事项

- 任何需要用户 Apple ID 登录 Xcode / 手工信任开发者证书的步骤。
- 任何需要用户在真机上手工操作（输入密码、点击信任弹框等）的步骤。
- 任何需要用户提供额外私有材料（账号、验证码等）的步骤。

## agent 的工作流程介绍

1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 执行完毕后必须整理本文档：删除过时信息，更新主线 / TODO / 踩坑 / 优先级变化，并把真正高频复用的手工流程收敛成脚本；主文档保持简洁，不能只追加不整理(已完成事项不能堆积成流水账，应当总结概括)，也不能改变本文档章节结构。
   - **主文档 vs 子文档分工**：局部细节、大段日志、方法论细节下沉到对应子文档；主文档只保留当前主线、TODO、决策信息、高频复用经验。主文档对子文档的引用，需要注明阅读子文档的必要性，如需要什么信息时才需要读取。
   - **任务状态只在本文档维护**：子文档**不允许**出现 `DONE / TODO / DEFERRED / BLOCKED / 已完成 / 已落地 / 待执行 / 下一步 / 结论 / handoff` 这类任务状态或进度字样。
   - **子文档不写时间戳快照**：引用某次 live run 改为指向 `build/` 下的结构化报告文件名。
   - **子文档不写任务状态信息**: 任务状态、卡点、下一步等信息，统一在主dashboard文档维护。
7. 复盘当前技术路线；除最终目标不能改变外，中间方案可根据新发现随时调整。
8. 收尾后执行 `git commit`。

## 所有任务 TODO 状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| RIPC-001 | BLOCKED（当前主线） | 环境预检与工具链准备：签名构建、真机安装与真机启动已验证，当前卡在现代 LLDB attach 链路验证 | 待建 |
| RIPC-001-A | DONE | 安装 `ios-deploy`（`brew install ios-deploy`），并用 `ios-deploy --version` 验证为 `1.12.2` | — |
| RIPC-001-B | DONE | 通过 Xcode 空项目为 iPad 自动生成 provisioning profile；当前采用 Team `Songchao Wang`（`L7CZY6S98T`），产出显式 profile `87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision` | — |
| RIPC-001-C | BLOCKED（当前主线） | 用最小 test app 验证签名 → 真机部署 → LLDB attach 全链路；目前已完成构建签名、安装与启动，`ios-deploy --debug` 仍受旧式 `DeviceSupport` 查找路径限制，本机 `lldb device select` 也尚未稳定完成 attach 前的设备选择 | — |
| RIPC-002 | TODO | 重签名 NGR：解包 .app → 修改 bundle ID → 注入 profile → 重签主二进制 + 41 frameworks → 部署到 iPad | 待建 |
| RIPC-002-A | TODO | 编写重签名脚本 `Scripts/ripc_resign.sh` | — |
| RIPC-002-B | TODO | 执行重签名并部署到 iPad，验证 app 可启动 | — |
| RIPC-003 | TODO | 真机启动行为基线采集：LLDB attach 后采集 QtsFileSystem 初始化路径的关键运行时上下文（文件路径、沙盒结构、环境变量、entitlements 等） | 待建 |
| RIPC-004 | TODO | PlayCover 环境同构采集：在 PlayCover 下采集同一组上下文数据 | 待建 |
| RIPC-005 | TODO | 结构化差异对比与根因定位：对比真机与 PlayCover 两组数据，定位导致 `QtsFileSystem Create Failed` 的环境差异根因 | 待建 |
| RIPC-006 | TODO | PlayTools 环境对齐修复：在 PlayTools 层做最小 bundle-scoped 环境对齐 | 待建 |
| RIPC-007 | TODO | 端到端验证：PlayCover 启动不再触发 `QtsFileSystem Create Failed`，且满足 HOKCrash 主线最终目标 | 待建 |

## 高频复用经验

- **IPA 已解密**：`com.tencent.ngr` 的 `cryptid=0`，无需额外脱壳。
- **app 体积巨大**：主二进制 230 MB + 41 个 embedded framework + 资产，
  IPA 总计 3.07 GB。重签名时必须对每个 framework 单独 `codesign`，
  否则安装失败。签名顺序：先 frameworks → 再主 bundle。
- **开发者证书限制**：当前只有 1 个有效签名身份
  `BB36AD6577F23F304F93A1A75A940DAE92559A7B`（Apple Development）；
  另外 2 个已 REVOKED。如果是免费个人开发者账号，profile 7 天过期、
  最多 3 个 app、10 个设备 UDID。
- **001B 实际产物是显式 profile，不是 wildcard**：Xcode 最终为
  `com.songdog.ripc.debug` 生成了显式 iOS Team Provisioning Profile；对
  `RIPC-001-C` 的最小 test app 验证已经足够，不必强求 wildcard。
- **install 成功 ≠ debug 可用**：在当前 `Xcode 16.4 + iPadOS 26.4.1` 组合下，
  `ios-deploy 1.12.2` 可以成功安装 app，但 debug 启动仍会沿旧式
  `DeviceSupport/*/DeveloperDiskImage.dmg` 路径查找并失败；应把 install 结果与
  attach 结果分开取证，并用 `xcrun devicectl list preferredDDI` 确认 host 实际走的
  是 CoreDevice 外置 DDI。
- **launch 成功 ≠ attach 成功**：即使 `devicectl device process launch` 已能正常拉起
  app，LLDB attach 仍可能独立卡在工具链层；当前证据里 `ios-deploy --debug` 与
  `lldb device select` 都还没有给出可复用的 attach 成功链路。
- **真机 bundle ID 必须修改**：原 `com.tencent.ngr` 不在开发者账号下，
  必须改为 provisioning profile 覆盖的 ID（如 wildcard `*` 或自定义
  `com.dev.ngr-debug`）。改 bundle ID 可能影响 app 运行时的
  `keychain-access-groups` 和部分 SDK 初始化，但对我们关注的
  QtsFileSystem 路径差异无影响。
- **PlayCover 安装副本可直接用**：
  `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`
  已经是解包后的 .app，无需从 IPA 重新解压。重签名时可直接复制此目录。
- **真机调试需要 `get-task-allow=true`**：开发者 provisioning profile
  自动包含此 entitlement，允许 LLDB attach。

## 参考信息

### 关键路径

- IPA 源：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`
- PlayCover 安装副本：`~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`
- 签名身份：`BB36AD6577F23F304F93A1A75A940DAE92559A7B`（Apple Development）
- iPad UDID：`00008103-0011050A0E3B001E`（iPadOS 26.4.1）
- 真机证据产物：`build/ripc-*.json` / `build/ripc-*.log`

### 关联文档

- `LocalDocs/HOKCrash/00-Dashboard.md`：HOKCrash 主线 Dashboard，了解
  `QtsFileSystem Create Failed` 的已有分析与兜底链路。**阅读建议：需要
  理解 QtsFileSystem 失败的已有根因分析或兜底防线时读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：QtsFileSystem
  失败的详细根因链与已证伪路径。**阅读建议：需要确定真机对比的具体
  断点地址或需要理解 storage create-table 链时读取。**
