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

`RIPC-007`：端到端验证 RIPC-006 Direction A 修复效果。

### 当前状态摘要

- 真机已连接：`Songchao的iPad`（iPadOS 26.4.1），UDID
  `00008103-0011050A0E3B001E`。
- Xcode 16.4 可用，签名身份 `BB36AD6577F23F304F93A1A75A940DAE92559A7B`
  （Apple Development）有效。
- IPA 源文件：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`（3.07 GB，
  已解密 `cryptid=0`）。
- PlayCover 已安装副本在
  `~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`。
- **常用 Xcode Team**：后续自动签名默认使用 `Songchao Wang`
  （Team ID `L7CZY6S98T`）。
- **Provisioning Profile**：已生成显式 iOS App Development profile
  （`87ea3316-9677-4523-a1eb-ec9a4a55f7f8.mobileprovision`），
  `get-task-allow=true`，已包含目标 iPad UDID。
- **RIPC-001～004 结论**：签名→部署→真机/PlayCover 双端基线采集完成。
  数据见 `build/ripc-003-ipad-baseline.json` / `build/ripc-004-playcover-baseline.json`。
- **RIPC-005 结论（根因已定位）**：完整差异报告见 `build/ripc-005-diff.json`。
  根因 **不是** HOME/TMPDIR/环境变量值本身，而是 **UE4 pak 路径在
  QtsFileSystem materializer 的 UTF-16 compare ladder 中不匹配**。具体见
  下方"根因链"小节。

### RIPC-005 根因链

```
App 在 PlayCover 启动 → HOME = macOS container '/Users/…/Containers/…/Data'
→ UE4 FPaths 用 HOME 派生 SavedDir → 所有 Saved 路径带 '/Users/' 前缀
→ QtsFileSystem init → 创建 main chunk 到 rootB（成功）
→ readiness B 调用 materializer（0x10432a068），共 3 次调用：
   ✓ 2× entryX1 = "../../../NGR/Content/Paks/1/1.db"（UE4 相对路径，
     compare ladder x22=0x21→0x3，match → 返回 non-null）
   ✗ 1× entryX1 = "/Users/…/Saved/Paks/1/1.db"（绝对 macOS 路径，
     compare ladder x22=0x31→0x4，mismatch → 返回 0）
→ materializer 返 0 → helper+0x18=NULL → err=9 → storage+0x30=0x9000b
→ create-table 返 null → readiness B = 0 → "QtsFileSystem Create Failed!!"
→ GameThread 退出 → 僵尸态
```

**关键结论**：根因不是 HOME/TMPDIR 的值本身，也不是环境变量泄漏，
而是 **UE4 将 Saved/Paks 路径解析为绝对 macOS 路径后，QtsFileSystem
materializer 的 UTF-16 compare ladder 无法匹配该路径格式**。

### 修复路线概览

1. ~~**RIPC-001～004**~~（已完成）：环境预检 → 重签名部署 → 双端基线采集。
2. ~~**RIPC-005**~~（已完成）：结构化差异对比 → 根因定位。
3. ~~**RIPC-006**~~（已完成）：Direction A — 在 PDT-006 ConvertToPlatformPath
   hook 中增加 Saved/Paks 路径归一化，使 materializer compare ladder 匹配。
4. **RIPC-007**（当前主线）：端到端验证。

### RIPC-006 修复方案（已实施 Direction A）

**Direction A：在 ConvertToPlatformPath hook 点归一化 pak-path**。
materializer 的 2 次成功调用使用 `../../../NGR/Content/Paks/1/1.db`，
失败调用使用 `/Users/.../Saved/Paks/1/1.db`。Direction A 在 PDT-006 的
ConvertToPlatformPath 替换函数中增加归一化逻辑：对 `/Users/.../Saved/Paks/<X>`
格式路径转为 `../../../NGR/Content/Paks/<X>`。实现见
`ripc006_try_normalize_pak_path()` + `pdt006_convert_replacement()` 增强。

- **RIPC-006 结论（Direction A 已实施）**：在 PDT-006 的 ConvertToPlatformPath
  hook 中增加 RIPC-006 Direction A 归一化逻辑：将
  `/Users/.../Saved/Paks/<X>` 转为 `../../../NGR/Content/Paks/<X>`，使
  materializer compare ladder 能匹配。代码在 PlayLoader.m 的
  `ripc006_try_normalize_pak_path()` + `pdt006_convert_replacement()` 增强。
  诊断事件 `ripc006_pak_path_normalize` 写入 `launch-events.jsonl`。

### 当前卡点

1. 暂无阻塞。RIPC-006 已完成，待 RIPC-007 端到端验证。

### 下一步默认规划

1. 进入 `RIPC-007`：在 PlayCover 中启动 NGR，验证 `QtsFileSystem Create
   Failed!!` 不再出现。
2. 检查 `launch-events.jsonl` 确认 `ripc006_pak_path_normalize` 事件正常记录。
3. 若通过，更新 HOKCrash 主线 Dashboard 标记 QtsFS 问题已修复。

## 构建与验证

### 日常默认方法

- **真机连接验证**：`xcrun xctrace list devices` 确认 iPad 在线。
- **重签名工具链**：`Scripts/ripc_resign.sh`（封装了 IPA 解包 + 平台检查 +
  `codesign` + `security` + `/usr/libexec/PlistBuddy`）。默认从原始 IPA
  解包原生 iOS 二进制。用法：`./Scripts/ripc_resign.sh [--dry-run]`，
  支持 `--ipa`、`--source`、`--bundle-id`、`--profile`、`--identity`、
  `--output` 覆盖。
- **真机部署**：`ios-deploy --bundle <path>` 或 Xcode Devices window。
- **真机 LLDB**：优先使用 Xcode 原生调试入口（如 Xcode Debug → Attach to Process
  或直接从 Xcode 发起调试会话）；`ios-deploy --debug` 在当前
  `Xcode 16.4 + iPadOS 26.4.1` 组合下仅保留为已知不兼容对照项，不再作为默认 attach
  方法。
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
| RIPC-001 | DONE | 环境预检与工具链准备：签名构建、真机安装、启动与 debug 全链路已验证 | `RIPC-001-环境预检与工具链准备.md` |
| RIPC-002 | DONE | 重签名 NGR 并部署到 iPad：IPA 解包 → 重签 → 部署 → UE4 启动验证通过 | — |
| RIPC-003 | DONE | 真机基线采集：RIPCProbe dylib 注入 + console 捕获，17 类运行时上下文。真机无 QtsFS 失败 | `RIPC-003-真机启动行为基线采集.md` |
| RIPC-004 | DONE | PlayCover 环境同构采集：LLDB attach + ObjC expression evaluation，17 类运行时上下文 | — |
| RIPC-005 | DONE | 结构化差异对比与根因定位：根因是 materializer compare ladder 不匹配绝对 macOS pak 路径 | `build/ripc-005-diff.json` |
| RIPC-006 | DONE | Direction A：ConvertToPlatformPath hook 增加 Saved/Paks 路径归一化 | — |
| RIPC-007 | TODO（当前主线） | 端到端验证：PlayCover 启动不再触发 `QtsFileSystem Create Failed`，且满足 HOKCrash 主线最终目标 | 待建 |

## 高频复用经验

- **IPA 已解密**：`com.tencent.ngr` 的 `cryptid=0`，无需额外脱壳。
- **app 体积巨大**：主二进制 230 MB + 39 个 embedded framework + 16 个
  resource bundle + 资产，IPA 总计 3.07 GB。重签名时必须对每个 framework
  单独 `codesign`，否则安装失败。签名顺序：先 frameworks → 再主 bundle。
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
- **Xcode 原生调试入口可作为真机 attach 基线**：当 `ios-deploy --debug` 与直接
  `lldb device select` 不稳定时，可直接复用 Xcode GUI 调试入口。详情见
  `RIPC-001-环境预检与工具链准备.md` §最小 Test App 全链路验证。
- **真机 bundle ID 必须修改**：原 `com.tencent.ngr` 不在开发者账号下，
  必须改为 provisioning profile 覆盖的 ID（如 wildcard `*` 或自定义
  `com.dev.ngr-debug`）。改 bundle ID 可能影响 app 运行时的
  `keychain-access-groups` 和部分 SDK 初始化，但对我们关注的
  QtsFileSystem 路径差异无影响。
- **PlayCover 安装副本不能用于真机部署**：PlayCover 会将二进制的
  `LC_BUILD_VERSION` 从 `platform 2`（iOS）改写为 `platform 6`
  （macCatalyst），导致真机上 dyld 拒绝加载系统框架（"wrong platform to
  load into process"）。**真机部署必须从原始 IPA 解包**获取原生 iOS 二进制。
  `ripc_resign.sh` 已内置平台安全检查，会自动拦截 macCatalyst 源。
- **真机调试需要 `get-task-allow=true`**：开发者 provisioning profile
  自动包含此 entitlement，允许 LLDB attach。
- **真机启动验证基线**：重签名后的 NGR 在 iPad 上成功启动，UE4 引擎完成
  初始化进入 LANDSCAPE mode。**无 `QtsFileSystem Create Failed`**。
- **RIPCProbe dylib 采集方法**：编译 ObjC dylib → `insert_dylib` 注入
  LC_LOAD_DYLIB → 重签名 → 部署 → `--console` 捕获 NSLog。比 CLI LLDB
  attach 更稳定（CoreDevice 下 CLI `lldb` 无法直接 attach 真机进程）。
  `insert_dylib` 从 [github.com/tyilo/insert_dylib](https://github.com/tyilo/insert_dylib)
  源码编译。
- **真机 iOS sandbox 路径规范**：`/var/mobile` = `/private/var/mobile`
  （symlink）。NSHomeDirectory 不带 `/private`，NSTemporaryDirectory 带
  `/private`。cwd 为 `/`。Home 目录本身不可写，Documents/Library/tmp 可写。
  sandbox uid=501(mobile)，bundle uid=33(_www)。
- **PlayCover 环境 LLDB 采集方法**：直接 `lldb --batch --source` attach 到
  运行中的 NGR 进程，逐一 evaluate ObjC 表达式。对标量用 `expr -l objc --`，
  对集合（NSArray/NSDictionary）用 `po`。采集脚本为
  `Scripts/ripc_004_playcover_probe.py`。
- **PlayCover sandbox 特征**：HOME 在 `~/Library/Containers/<bundleId>/Data`
  （macOS App Sandbox container），非 iOS 标准路径。home/Documents/Library/tmp
  均可写。uid=501(当前 macOS 用户)/gid=20(staff)。环境变量大量泄漏宿主
  macOS 状态（43 个，真机仅 13 个）。Library 下 31 个 macOS 标准子目录
  （真机仅 12 个）。
- **RIPC-005 根因定位**：QtsFS 失败的直接原因是 materializer compare
  ladder（UTF-16 case-fold）不匹配绝对 macOS 路径 `/Users/.../Saved/Paks/1/1.db`。
  成功路径用相对形式 `../../../NGR/Content/Paks/1/1.db`。根因不是
  HOME/TMPDIR 值本身，不是 env var 泄漏，不是 uid/gid，不是目录结构差异。
- **Saved/Paks/1 目录已存在但为空**：QtsFS 在 crash 前成功创建了
  `Library/NGR/Saved/Paks/1/` 目录和 `main/Watchdog/*.db`，但 `1/1.db`
  未被写入（因 materializer 在此之前已失败）。
- **1.db 在 bundle 中存在**：`cookeddata/ngr/content/paks/1/1.db`（20 MB）
  及 `1_0.db` ~ `1_15.db`（各 ~200 MB）。
- **PDT-006 已有但不够**：`ConvertToPlatformPath` patch 透传 `/Users/` 前缀
  路径，防止进一步拼接错误；但路径 **已经** 是绝对形式了，materializer
  compare ladder 仍不匹配。**RIPC-006 Direction A 在此基础上增加归一化**：
  对 `/Users/.../Saved/Paks/<X>` 转为 `../../../NGR/Content/Paks/<X>`。

## 参考信息

### 关键路径

- IPA 源：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`
- IPA 解包缓存：`build/ripc-ipa-extract/Payload/NGR.app`（原生 iOS，platform 2）
- 重签名产物：`build/ripc-resigned/NGR.app`（bundle ID: `com.songdog.ripc.debug`）
- PlayCover 安装副本（仅供 macOS 端分析）：`~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`
- 签名身份：`BB36AD6577F23F304F93A1A75A940DAE92559A7B`（Apple Development）
- iPad UDID：`00008103-0011050A0E3B001E`（iPadOS 26.4.1）
- 真机证据产物：`build/ripc-*.json` / `build/ripc-*.log`
- RIPC-003 结构化基线：`build/ripc-003-ipad-baseline.json`
- RIPC-003 Probe 源码：`build/ripc-003-probe/RIPCProbe.m`
- RIPC-004 结构化基线：`build/ripc-004-playcover-baseline.json`
- RIPC-004 LLDB 日志：`build/ripc-004-lldb.log`
- RIPC-004 采集脚本：`Scripts/ripc_004_playcover_probe.py`
- RIPC-005 差异报告：`build/ripc-005-diff.json`

### 关联文档

- `LocalDocs/HOKCrash/00-Dashboard.md`：HOKCrash 主线 Dashboard，了解
  `QtsFileSystem Create Failed` 的已有分析与兜底链路。**阅读建议：需要
  理解 QtsFileSystem 失败的已有根因分析或兜底防线时读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：QtsFileSystem
  失败的详细根因链与已证伪路径。**阅读建议：需要确定真机对比的具体
  断点地址或需要理解 storage create-table 链时读取。**
- `RIPC-001-环境预检与工具链准备.md`：RIPC-001 完整实验细节、验证产物
  与踩坑记录。**阅读建议：需要复现具体命令、核查原始产物、或排查
  profile / codesign / deploy / attach 异常时按需读取；一般无需读取。**
- `RIPC-003-真机启动行为基线采集.md`：真机 iPad 运行时上下文详细数据
  表格、Probe 方法说明与产物索引。**阅读建议：进行 RIPC-006 修复
  时需要查阅真机侧具体路径值时读取。一般使用
  `build/ripc-003-ipad-baseline.json` 即可。**
- `HOK-016-appendix-C27.md`（HOKCrash 子文档）：materializer compare
  ladder 的逐层证据，是 RIPC-005 根因定位的关键证据来源。**阅读建议：
  需要理解 materializer 内部控制流、success/fail tuple 差异时读取。**
