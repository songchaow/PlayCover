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

`RIPC-010-C1` 仍是默认当前主线：`RIPC-010-B1` 已完成并落盘 `build/ripc-010b-diff.json`，代码侧复核也已确认 `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` 中已经存在 bundle-scoped 的 `Saved/Paks` 归一化链（`ripc006_try_normalize_pak_path()`、`pdt006_convert_replacement()`、构造函数中的 `pdt006_install_convert_patch_once()`）。`2026-04-29` 的 **完整 `Release` GUI 重建 + 已安装 `~/Applications/PlayCover.app` fresh run** 再次证明：`pdt006_ngr_convert_patch status=installed` 稳定出现，但同轮仍没有 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`，`QtsFileSystem Create Failed!!` 继续发生。因此当前最高优先级不是继续证明“补丁已安装”，也不是直接进入 `RIPC-010-C2`，而是解释 **`ConvertToPlatformPath` replacement 为什么没有留下调用 / 命中证据**。只有在后续已证实 normalize 命中但 QtsFS 仍 fail 时，才转向 `RIPC-010-C2` 收紧 pre-`1c8` caller / helper state；只有在 `C1/C2` 之后仍出现新的未闭合样本时，才回开 `RIPC-010-B2`。长期方法、矩阵结论与 installed-GUI `C1` 结果统一维护在 `RIPC-010-真机materializer采集与双端对比.md`；同主题独立 execution note 不再作为事实来源。

### 当前状态摘要

- 真机环境、签名与双端基线已闭合：`RIPC-001～004` 完成，真机稳定基线见 `build/ripc-003-ipad-baseline.json`，PlayCover 同构基线见 `build/ripc-004-playcover-baseline.json`。
- `RIPC-005` + `RIPC-010-B1` 的联合结论已稳定：问题不是 HOME/TMPDIR 的值本身，也不是“绝对路径”这一概念本身，而是 PlayCover 的 **`/Users/.../Saved/Paks/...`** path class 与当前 caller/helper state 组合在 materializer compare ladder 上稳定落到 fail 语义；真机 accepted classes 现已确认至少包含 `/var/mobile/.../Saved/Paks/...` 与 `../../../NGR/Content/Paks/...`。
- `RIPC-010-B1` 的默认决策已经成立：`build/ripc-010b-diff.json` 足以让主线从“继续补采”切到 `RIPC-010-C` 的闭环验证。pre-`1c8` caller/helper state 仍是 residual uncertainty，但不是当前第一优先级。
- 代码侧复核已确认 `PlayLoader.m` 中存在现成链路：`ripc006_try_normalize_pak_path()` → `pdt006_convert_replacement()` → `pdt006_install_convert_patch_once()`。因此当前不是重想 remap 方向，而是解释这条链为什么没有留下 replacement 调用证据。
- `2026-04-29 17:35` 的 installed GUI fresh run 已吸收到长期维护文档中：使用 `Release` 完整 GUI 重建与 `~/Applications/PlayCover.app` fresh run，`build/ripc-010c1-live-report-v2.json` 选中 `processLaunchId=launch-48548-f2a3231c-a329-4b88-aca4-39a1081c7405`，同轮出现 `pdt006_ngr_convert_patch status=installed`，但没有 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`，且仍出现 `hok014_ngr_alert_suppressed message="QtsFileSystem Create Failed!!"` 与新 crash `NGR-2026-04-29-173545.ips`。这已经排除了“工作区 app 副本 / move-to-Applications”变量。
- 文档整合状态：`RIPC-010-B1` 与 installed-GUI `RIPC-010-C1` 的长期有效信息现已统一回收到本文与 `RIPC-010-真机materializer采集与双端对比.md`；本目录下同主题独立 execution note 不再保留为事实来源。

### RIPC-005 根因链

```
PlayCover 启动 → UE4 用 macOS sandbox HOME 派生 SavedDir
→ 出现 `/Users/.../Saved/Paks/...` path class
→ readiness B 进入 materializer compare ladder
→ `../../../NGR/Content/Paks/1/1.db` 在 PlayCover 可成功返回 non-null
→ `/Users/.../Saved/Paks/1/1.db` 稳定走 fail 分支并返回 0
→ helper+0x18 保持 0 / errValue=0x9000b
→ create-table 返 null → "QtsFileSystem Create Failed!!"
```

**关键结论**：问题不是 HOME/TMPDIR 值本身，也不是“absolute path”这一概念本身，而是 **PlayCover 的 `/Users/.../Saved/Paks/...` path class 没有被当前 materializer 匹配链接受**。`RIPC-010-B1` 之后，这个结论应始终与“caller/helper state 仍可能参与分流”一起理解。

### 修复路线概览

1. ~~**RIPC-001～004**~~（已完成）：环境预检、重签名部署、真机/PlayCover 双端基线采集已完成。
2. ~~**RIPC-005**~~（已完成）：结构化差异对比与根因定位已完成。
3. ~~**RIPC-006**~~（已完成）：`ConvertToPlatformPath` 的 `Saved/Paks` 归一化链已在代码中存在。
4. ~~**RIPC-007**~~（已完成）：W^X 合规修复完成，patch 安装不再是主阻塞。
5. ~~**RIPC-008**~~（已完成）：embedded path rewrite / size 字段假设已证伪，路线终止。
6. **RIPC-010**（当前主线）：主线已从“继续补采 / 重想修复”收敛到 **先闭合 `RIPC-010-C1` 的 replacement 调用缺口，再决定是否进入 `RIPC-010-C2`**。

### RIPC-008 embedded path rewrite + 验证结论

`RIPC-008` 已经给出稳定否定结论：运行时 object graph / `FString` 长度元数据修补**不能**消除 `QtsFileSystem Create Failed!!`。因此这条路线只保留为已证伪背景，不再占用当前主线；需要复盘扫描策略、dump 方法或 parent-aware 修补细节时，再回看 `build/ripc-008a/` 与 `PlayLoader.m` 代码注释。**一般无需读取。**

### 当前卡点

1. **当前第一缺口是 replacement 调用证据，而不是 patch 安装证据**：`pdt006_ngr_convert_patch` 已稳定出现，但 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize` 仍为 0。当前首要问题是：PlayCover 的 `/Users/.../Saved/Paks/...` 流量究竟没有经过 `ConvertToPlatformPath`，还是 `x1` 参数形态与当前 UTF-8 `/Users/...` 假设不符。
2. **只有当 normalize 已命中但 QtsFS 仍 fail，`C2` 才成立**：这时才说明主分叉不止 path class，需要把优先级切到 pre-`1c8` caller/helper state。
3. **补采仍是条件性回退项**：只有在 `RIPC-010-C1/C2` 之后仍暴露新的未闭合 path class / caller tuple，才应打开 `RIPC-010-B2` 做定向真机补采。

### 下一步默认规划

1. ~~**RIPC-008（已完成）**~~：保留为已证伪背景，当前不再投入时间。
2. ~~**RIPC-010-A1～A4（已完成）**~~：真机 LLDB 采集链与 `v5` 基线稳定可复用，详见 `RIPC-010-真机materializer采集与双端对比.md`。
3. ~~**RIPC-010-B1（已完成）**~~：`build/ripc-010b-diff.json` 已提供 path class / caller tuple / return semantics 决策矩阵。
4. **RIPC-010-C1（当前默认主线）**：解释现有 `RIPC-006` 归一化链为何未闭环
   - 已通过完整 `Release` GUI 重建 + 已安装实例 fresh run 确认 `pdt006_ngr_convert_patch status=installed`；
   - 当前未闭合项是 `pdt006_convert_replacement()` 为什么没有产生 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`；
   - 需要判断 failing `/Users/.../Saved/Paks/...` path flow 是否根本未经过 `ConvertToPlatformPath`，或参数编码 / 形态与现有 replacement 假设不一致。
5. **RIPC-010-C2（条件性第二优先级）**：仅当 `C1` 已证实现有 normalize 链命中但 QtsFS 仍 fail，再转向 **pre-`1c8` caller/helper state 对齐**。
6. **RIPC-010-B2（条件性回退项）**：仅当 `C1/C2` 验证后仍有未闭合样本时，再围绕缺失 path class / caller tuple 做定向真机补采；默认沿用 `--pre-inject-delay 5`。

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
- **Xcode GUI 自动化（agent 必须自主使用）**：`LocalDocs/XCodeOperation/`
  目录提供了一套基于 JXA/Accessibility API 的 Xcode GUI 自动化工具库
  (`xcode_general_ops.py` / `xcode_gpu_ops.py`)。agent 在执行任何涉及
  Xcode 交互式操作的步骤时，**必须优先使用这套工具**，通过菜单点击、
  Navigator 操作、Debug Console 读写等方式完成自动化。**如果现有脚本
  缺少所需功能，agent 必须自行扫描 Xcode UI 结构（`dump_ui_tree` /
  `uitree`），定位目标控件后立刻将可复用操作沉淀回
  `xcode_general_ops.py`，严禁以"缺少功能"为由向用户求助。**
- **真机 materializer 采集（RIPC-010）**：默认使用
  `Scripts/ripc_010a_real_ipad_lldb_driver.py` + `--pre-inject-delay 5`
  生成 per-run 产物；当前稳定基线是
  `build/ripc-010a-real-ipad-lldb-run-v5.json` /
  `build/ripc-010a-ipad-materializer-args-v5.json`。详细步骤、fallback 与
  调试经验见 `RIPC-010-真机materializer采集与双端对比.md`。**当前主线涉及
  `RIPC-010-B / RIPC-010-C` 时总是建议读取。**
- **PlayCover 侧验证**：使用 PlayCover MCP `launch_app` 工具启动 app，
  通过 `launch-events.jsonl` 检查 hook 事件和 QtsFS 状态。
- **PlayTools 构建部署流程（结论性 GUI 验证）**：
  1. 修改 `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` /
     `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
  2. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release`
  3. `PLAYCOVER_INSTALL_MODE=user ./BuildScripts/build_and_install.sh Release`
  4. `python3 Scripts/hok015_ngr_live_verify.py --playcover-app-path ~/Applications/PlayCover.app --output build/ripc-010c1-live-report-vN.json`
  5. 读取 `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  6. 如需专看本轮事件，按 `processLaunchId` 过滤 `pdt006_ngr_convert_patch` /
     `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize` /
     `hok014_ngr_alert_suppressed`

  **备注**：当前 `PlayCover` target 只有 `Release` / `Nightly` 两套 GUI 配置；
  `build_gui.sh Debug` 不应用作 `RIPC-010-C1` 的结论性证据。
- **证据存放**：真机 trace 产物 → `build/ripc-*.json`；对比报告 →
  `build/ripc-*-diff.json`。

### 需要用户确认后才能继续的事项

- 任何需要用户 Apple ID 登录 Xcode / 手工信任开发者证书的步骤。
- 任何需要用户在真机上手工操作（输入密码、点击信任弹框等）的步骤。
- 任何需要用户提供额外私有材料（账号、验证码等）的步骤。

## agent的工作流程介绍

1. 读取本文档，先理解**当前主线**与**TODO**的最新状态。
2. 严格按优先级只选取最高优先级的**一个**未完成任务执行。
3. 若最高优先级任务已阻塞（如需人工或外部协助），立即停止并汇报；严禁转做与解除该阻塞无关的任务。手头所有工作都搁置，不要进行收尾、git commit。等待用户指示
4. 若任务过大，先拆出新的子任务并追加到 TODO 的原位置，再只完成其中一个。
5. 若本次实现了新功能，尽可能靠 skills 或 mcp 做**实际测试**；受环境限制时，至少做**模拟性质、离线或最小样本测试**。
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的executions文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务 TODO 状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| RIPC-001 | DONE | 环境预检与工具链准备：签名构建、真机安装、启动与 debug 全链路已验证 | `RIPC-001-环境预检与工具链准备.md` |
| RIPC-002 | DONE | 重签名 NGR 并部署到 iPad：IPA 解包 → 重签 → 部署 → UE4 启动验证通过 | — |
| RIPC-003 | DONE | 真机基线采集：RIPCProbe dylib 注入 + console 捕获，17 类运行时上下文。真机无 QtsFS 失败 | `RIPC-003-真机启动行为基线采集.md` |
| RIPC-004 | DONE | PlayCover 环境同构采集：LLDB attach + ObjC expression evaluation，17 类运行时上下文 | — |
| RIPC-005 | DONE | 结构化差异对比与根因定位：PlayCover 稳定 fail 的是 `/Users/.../Saved/Paks/...` path class，而不是绝对路径概念本身 | `build/ripc-005-diff.json` |
| RIPC-006 | DONE | Direction A：ConvertToPlatformPath hook 增加 Saved/Paks 路径归一化 | — |
| RIPC-007 | DONE | W^X 修复使全部 hook 安装成功；端到端验证发现失败点在 materializer 返回 object 的下游 compare ladder | `build/ripc-007-verification-report.json` |
| RIPC-008 | DONE | 内存 dump 定位 `selectedObj + 0x10` 处 UE4 `FString`；parent-aware `ArrayNum/ArrayMax` 同步修复（129→33）已验证生效，但 QtsFS 仍 100% 失败，size 字段假设被证伪。产物：`build/ripc-008a/` | — |
| RIPC-010 | IN-PROGRESS | 真机 materializer 采集与对比基线已稳定；当前主线是解释 replacement 调用证据为何缺失，而不是继续泛化补采 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A1 | **DONE** | 开发 LLDB Python 采集脚本 `Scripts/ripc_010a_materializer_probe.py`：在 materializer entry/return 处设置断点，自动采集 x1/x0/lr，输出结构化 JSON | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A2 | **DONE** | 开发 Xcode GUI 自动化 attach 脚本 `LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py`：利用 xcode_general_ops.py 基础能力自动执行 Debug → Attach to Process | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A3 | **DONE** | 验证并迭代 Debug Console 命令输入自动化：JXA `inputArea.value` 直接赋值方案已验证可行，绕过 `AXValue.setValue()` 类型转换错误 (-1700) | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A4 | DONE | delayed injection + decoder fix 已形成稳定真机基线 `v5`；不再是阻塞项 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B | IN-PROGRESS | `B1` 已完成并落盘；`B2` 仅在 `C1/C2` 验证后仍有新的未闭合样本时按需打开 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B1 | DONE | 已基于真机 `v5` 与 PlayCover `HOK-016-C.2.7` 证据，对齐 path class / caller tuple / return semantics，并产出 `build/ripc-010b-diff.json` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B2 | TODO | 若 `RIPC-010-C1/C2` 验证后仍有未闭合 path class / caller tuple，再做定向真机补采；默认 `--pre-inject-delay 5` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C | IN-PROGRESS | `C1` 为默认当前主线：优先解释现有 `RIPC-006` 归一化链为何没有留下 replacement 调用证据；仅当 `C1` 已命中但仍失败时，再进入 `C2` 做 pre-`1c8` caller/helper state 对齐 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C1 | IN-PROGRESS（默认当前主线） | 已确认 installed GUI fresh run 中 patch installed，但尚未出现 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`；当前继续追 replacement 调用缺口 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C2 | TODO（条件性） | 若 `C1` 已证实 normalize 命中但 QtsFS 仍失败，再转向 pre-`1c8` caller/helper state 对齐 | `RIPC-010-真机materializer采集与双端对比.md` |

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
- **真机 materializer 采集（RIPC-010）**：默认使用
  `Scripts/ripc_010a_real_ipad_lldb_driver.py` + `--pre-inject-delay 5`
  生成 per-run 产物；当前稳定基线是
  `build/ripc-010a-real-ipad-lldb-run-v5.json` /
  `build/ripc-010a-ipad-materializer-args-v5.json`。详细步骤、fallback 与
  调试经验见 `RIPC-010-真机materializer采集与双端对比.md`。**当前主线涉及
  `RIPC-010-B / RIPC-010-C` 时总是建议读取。**

### Xcode GUI 自动化

- **Attach to Process 菜单动态子菜单**：展开后需等待 `Getting Process List…` 完成，
  再扫描子菜单项。目标进程名可能带设备前缀（如 `NGR on Songchao的iPad`）。
- **Debug Console 输入框**：`AXTextArea | debug console | | @x,y`，使用
  `inputArea.value = command` 直接赋值后发送回车键，比 `keystroke` 更可靠。
- **Breakpoint Navigator "+" 菜单**：仅含 Swift Error / Exception / Symbolic /
  Runtime Issue / Constraint Error / Test Failure Breakpoint，**不含 Address Breakpoint**。
  地址断点必须通过 Debug Console 的 LLDB 命令设置。

### 关键技术约束

- **RIPC-005 + RIPC-010 联合结论**：PlayCover 稳定 failing class 仍是 macOS
  absolute `/Users/.../Saved/Paks/...`；真机 accepted classes 现已确认同时包含
  iOS absolute `/var/mobile/.../Saved/Paks/...` 与 UE4 relative
  `../../../NGR/Content/Paks/...`。当前需要比较的不是"绝对 vs 相对"本身，
  而是 **path class + caller/helper state**。
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
- RIPC-010-A1 LLDB 采集脚本：`Scripts/ripc_010a_materializer_probe.py`
- RIPC-010-A2 Xcode 自动化脚本：`LocalDocs/XCodeOperation/ripc_010a_xcode_debug_automation.py`
- RIPC-010-A driver：`Scripts/ripc_010a_real_ipad_lldb_driver.py`
- RIPC-010-A 稳定 run 摘要：`build/ripc-010a-real-ipad-lldb-run-v5.json`
- RIPC-010-A 稳定真机基线：`build/ripc-010a-ipad-materializer-args-v5.json`
- RIPC-010-B 双端对比报告：`build/ripc-010b-diff.json`

### 关联文档

- `LocalDocs/HOKCrash/00-Dashboard.md`：HOKCrash 主线 Dashboard，了解
  `QtsFileSystem Create Failed` 的已有分析与兜底链路。**阅读建议：需要
  理解 QtsFileSystem 失败的已有根因分析或兜底防线时读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：QtsFileSystem
  失败的详细根因链与已证伪路径。**阅读建议：需要确定真机对比的具体
  断点地址或需要理解 storage create-table 链时读取。**
- `RIPC-010-真机materializer采集与双端对比.md`：RIPC-010 阶段的稳定方法、真机 `v5` 基线、`B1` 矩阵结论，以及 installed-GUI `C1` 验证与 `C1/C2` 分叉判断口径。**阅读建议：当前主线涉及 `RIPC-010-B / RIPC-010-C1 / RIPC-010-C2` 时总是建议读取。** 该文档已经吸收同主题 execution note 的长期有效内容，作为唯一维护入口。
- `RIPC-001-环境预检与工具链准备.md`：RIPC-001 完整实验细节、验证产物
  与踩坑记录。**阅读建议：需要复现具体命令、核查原始产物、或排查
  profile / codesign / deploy / attach 异常时按需读取；一般无需读取。**
- `RIPC-003-真机启动行为基线采集.md`：真机 iPad 运行时上下文详细数据
  表格、Probe 方法说明与产物索引。**阅读建议：需要核查真机侧具体路径值、
  沙盒结构或 Probe 实现细节时按需读取；一般使用
  `build/ripc-003-ipad-baseline.json` 即可。**
- `HOK-016-appendix-C27.md`（HOKCrash 子文档）：materializer compare
  ladder 的逐层证据，是 RIPC-005 根因定位与 `RIPC-010-B` PlayCover 侧对照的
  关键证据来源。**阅读建议：需要理解 materializer 内部控制流、success/fail
  tuple 差异，或继续收紧 pre-`1c8` caller/helper state 时读取。**
