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

`RIPC-010 是当前主线`：在真机 iPad 上对 materializer（`0x10432a068`）下断点，
精确采集 3 次调用的 `entryX1`（x1 寄存器）实参与返回值（x0）。通过与 PlayCover
侧已采集的调用参数做结构化对比，直接回答：失败是因为 PlayCover 上 UE4 传入的
路径格式与真机不同（**路径生成阶段差异**），还是两端传入相同格式但 materializer
在 macOS 环境下行为不同（**materializer 跨平台行为差异**）。

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
4. ~~**RIPC-007**~~（已完成）：W^X 合规修复 → 全部 hook 安装成功。
5. ~~**RIPC-008**~~（已完成）：embedded path rewrite 已验证可行，但 QtsFS 仍
   fail，size 字段假设被证伪。结论：运行时内存修补不可靠，需换路线。
6. **RIPC-010**（当前主线）：真机 materializer 断点采集与双端参数对比，
   直接确定失败根因属于路径生成阶段还是 materializer 行为差异。

### RIPC-008 embedded path rewrite + 验证结论

**核心结论**：通过系统化 object graph 遍历（4 层深度扫描 + 128 条目去重），
每次启动可修复 2~4 处 `/Users/…` UTF-16 路径。进一步通过内存 dump 精确定位
`selectedObj + 0x10` 处为 UE4 `FString` 结构（`Data` 指针 + `ArrayNum` +
`ArrayMax`），并实现了 parent-aware 同步修复（`ArrayNum/ArrayMax` 129→33）。
`launch-events.jsonl` 验证长度字段已正确改写。

**但 QtsFS 仍 100% 失败**，说明 compare ladder 的失败点 **不在** `FString`
长度元数据。size 字段假设被证伪，**运行时内存修补思路终止**，转向真机
materializer 断点采集，从路径生成源头重新定位根因。

> 详细演进过程（v1→v2→v3 的扫描策略迭代、dump 分析方法、parent-aware 修复
> 实现细节）见 `build/ripc-008a/` 产物与 `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
> 代码注释。**一般无需读取。**

### 当前卡点

1. **真机 materializer 输入从未直接采集**：当前所有分析都基于 PlayCover 侧的
   单端猜测，真机侧 materializer 实际接收到的 `entryX1` 是什么路径（相对、
   绝对 iOS、还是混合）完全未知。
2. **无法区分两类根因**：
   - **假设 A**：真机上 UE4 传给 materializer 的就是相对路径，而 PlayCover 上
     因为 HOME 是 macOS 路径导致传入绝对路径 → 根因在 **UE4 路径生成阶段**。
   - **假设 B**：真机和 PlayCover 上传入的都是绝对路径，但真机的 `/var/mobile/…`
     能被 materializer 接受，PlayCover 的 `/Users/…` 不能 → 根因在
     **materializer 的路径格式容忍度**。
3. **RIPC-008 结论**：运行时内存修补（object graph 扫描 + FString 字段修复）
   已证明不可靠，同一套修补逻辑在真机侧没有对应验证基准，思路终止。

### 下一步默认规划

1. ~~**RIPC-008（已完成）**~~：embedded path rewrite 与 parent-aware size 修复已落地，
   产物见 `build/ripc-008a/`。结论：运行时内存修补不可靠，换路线。
2. **RIPC-010-A（当前主线）**：真机 materializer 断点采集
   - 在 Xcode LLDB 中对 `0x10432a068`（materializer）设置断点；
   - 记录每次 hit 时的 x1（entryX1）、x0（返回值）、lr（调用方）；
   - 同时采集调用方（readiness B）中生成 entryX1 的上游路径；
   - 产物：`build/ripc-010a-ipad-materializer-args.json`。
3. **RIPC-010-B**：双端 materializer 调用参数对比
   - 将真机采集结果与 PlayCover 侧已有参数做结构化对比矩阵（调用次数、
     entryX1、返回值、路径格式）；
   - 产物：`build/ripc-010b-diff.json`。
4. **RIPC-010-C**：根据对比结论确定修复方向
   - 若真机 entryX1 为相对路径 → 修复方向为 **源头拦截**（在
     ConvertToPlatformPath / FPaths 层阻止绝对路径生成）；
   - 若真机 entryX1 为绝对路径但成功 → 修复方向为 **路径伪装**（让
     PlayCover 的 HOME / SavedDir 看起来像 iOS 路径格式）。

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
- **PlayCover 侧验证**：使用 PlayCover MCP `launch_app` 工具启动 app，
  通过 `launch-events.jsonl` 检查 hook 事件和 QtsFS 状态。
- **PlayTools 构建部署流程**：
  1. 修改 `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
  2. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Debug`
  3. `FASTLANE=1 ./BuildScripts/build_gui.sh Debug`（**必须 FASTLANE=1**，
     否则 Carthage Bootstrap 会重置 Checkouts 源码）
  4. 复制 framework 到运行时位置：
     `rm -rf ~/Library/Frameworks/PlayTools.framework && cp -R build/Build/Products/Release/PlayCover.app/Contents/Frameworks/PlayTools.framework ~/Library/Frameworks/PlayTools.framework`
  5. MCP `launch_app` 验证
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
| RIPC-007 | DONE | W^X 修复使全部 hook 安装成功；端到端验证发现失败点在 materializer 返回 object 的下游 compare ladder | `build/ripc-007-verification-report.json` |
| RIPC-008 | DONE | 内存 dump 定位 `selectedObj + 0x10` 处 UE4 `FString`；parent-aware `ArrayNum/ArrayMax` 同步修复（129→33）已验证生效，但 QtsFS 仍 100% 失败，size 字段假设被证伪。产物：`build/ripc-008a/` | — |
| RIPC-010 | IN-PROGRESS（当前主线） | 真机 materializer 断点采集与双端参数对比：在真机 iPad 上对 materializer 下断点，采集 3 次调用的 entryX1 实参与返回值，与 PlayCover 侧做结构化对比，直接区分"路径生成差异"与"materializer 跨平台行为差异" | 待建 |

## 高频复用经验

### 真机部署与签名

- **IPA 已解密**：`com.tencent.ngr` 的 `cryptid=0`，无需额外脱壳。
- **app 体积巨大**：IPA 总计 3.07 GB，含 39 个 embedded framework。重签名顺序：
  先 frameworks → 再主 bundle，缺一不可。
- **开发者证书限制**：当前仅 1 个有效签名身份（Apple Development）；另外 2 个
  已 REVOKED。个人开发者账号 profile 7 天过期、最多 3 个 app、10 个设备。
- **真机 bundle ID 必须修改**：原 `com.tencent.ngr` 不在开发者账号下，需改为
  profile 覆盖的 ID（如 `com.songdog.ripc.debug`）。对 QtsFileSystem 路径差异
  无影响。
- **PlayCover 安装副本不能用于真机部署**：PlayCover 会将 `LC_BUILD_VERSION`
  从 `platform 2`（iOS）改写为 `platform 6`（macCatalyst），导致真机 dyld
  拒绝加载。**真机部署必须从原始 IPA 解包**。`ripc_resign.sh` 已内置平台安全检查。
- **真机调试需要 `get-task-allow=true`**：开发者 provisioning profile 自动包含。

### 双端环境特征

- **真机 iOS sandbox 路径规范**：`/var/mobile` = `/private/var/mobile`（symlink）。
  NSHomeDirectory 不带 `/private`，NSTemporaryDirectory 带 `/private`。Home 本身
  不可写，Documents/Library/tmp 可写。uid=501(mobile)，bundle uid=33(_www)。
- **PlayCover sandbox 特征**：HOME 在 `~/Library/Containers/<bundleId>/Data`
  （macOS App Sandbox）。uid=501/gid=20。环境变量 43 个（真机仅 13 个），大量
  泄漏宿主 macOS 状态。
- **真机启动验证基线**：重签名后的 NGR 在 iPad 上成功启动，UE4 初始化正常，
  **无 `QtsFileSystem Create Failed`**。

### 采集与调试方法

- **RIPCProbe dylib 采集**：编译 ObjC dylib → `insert_dylib` 注入 → 重签名 →
  部署 → `--console` 捕获 NSLog。CoreDevice 下 CLI LLDB 无法直接 attach 真机，
  dylib 注入更稳定。
- **PlayCover LLDB 采集**：`lldb --batch --source` attach 运行中进程，标量用
  `expr -l objc --`，集合用 `po`。脚本：`Scripts/ripc_004_playcover_probe.py`。

### 关键技术约束

- **RIPC-005 根因定位**：QtsFS 失败的直接原因是 materializer compare ladder
  不匹配绝对 macOS 路径 `/Users/.../Saved/Paks/1/1.db`；成功路径用相对形式
  `../../../NGR/Content/Paks/1/1.db`。根因不是 HOME/TMPDIR、env var、uid/gid
  或目录结构差异。
- **Apple Silicon W^X 策略**：`mprotect(R|W|X)` 在 Apple Silicon 上 100% 失败。
  必须分阶段：写入用 `R+W`（无 X），执行用 `R+X`（无 W）。`vm_protect` 回退使用
  `VM_PROT_COPY` 触发 copy-on-write。

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
- RIPC-007 验证报告：`build/ripc-007-verification-report.json`
- RIPC-008A 内存 dump 产物：`build/ripc-008a/`
- RIPC-008A/B 代码变更：`Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m`
- RIPC-010-A 真机 materializer 断点产物：`build/ripc-010a-ipad-materializer-args.json`
- RIPC-010-B 双端对比报告：`build/ripc-010b-diff.json`

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
  表格、Probe 方法说明与产物索引。**阅读建议：需要核查真机侧具体路径值、
  沙盒结构或 Probe 实现细节时按需读取；一般使用
  `build/ripc-003-ipad-baseline.json` 即可。**
- `HOK-016-appendix-C27.md`（HOKCrash 子文档）：materializer compare
  ladder 的逐层证据，是 RIPC-005 根因定位的关键证据来源。**阅读建议：
  需要理解 materializer 内部控制流、success/fail tuple 差异时读取。**
