## RealIPadCompare Dashboard

> **单一来源规则**：本文档是"真机 iPad 对比调试"方向的唯一主线维护文档。
> 当前主线、TODO、验证口径只在本文维护；长日志、历史推理细节、脚本细节
> 下沉到对应子文档。主文档保持可快速通读。
>
> **与 HOKCrash/00-Dashboard.md 的关系**：本方向的最终目标与 HOKCrash
> 主线一致（消除 `QtsFileSystem Create Failed!!`），但技术路线完全不同——
> 本方向通过**真机 iPad 对比**来定位 PlayCover 环境与真实 iOS 环境的
> **通用差异**，而非在 PlayCover 运行时层面逐一矫正 app 行为。
>
> **execution note 处理规则**：同主题 execution note 的长期有效结论在回收后只
> 维护到本文与 `RIPC-010-真机materializer采集与双端对比.md`；execution note
> 本身不再作为事实来源。

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

`RIPC-010-C1` 仍是默认当前主线，但基于当前代码与日志证据，我认为它现在应进一步具体化为一个更可执行的动作：**先摆脱 `PDT006_CONVERT_FUNC_UNSLID = 0x10463f204` 这个 stale hardcoded anchor，改为在当前 binary 的真实 `ConvertToPlatformPath` 热路径上建立 runtime-located coverage probe / patch point，然后重跑 installed GUI verify**。这样做的目的仍然是回答 failing `/Users/.../Saved/Paks/1/1.db` flow 是否进入 `ConvertToPlatformPath`，只是最该做的第一步不再是围绕旧锚点做抽象证明，而是先让 observability 跟上当前热路径。`RIPC-010-B1` 矩阵、`2026-04-29` installed GUI fresh run 与 `2026-04-30` installed-binary anchor revalidation 的长期结论均已吸收到本文与 `RIPC-010-真机materializer采集与双端对比.md`：`PlayLoader.m` 内已有 bundle-scoped 的 `Saved/Paks` 归一化链，`pdt006_ngr_convert_patch status=installed` 稳定出现，但 live verify 仍无 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`，且 `build/pdt-005-current-installed.json` 表明旧硬编码锚点已不能直接等同于当前 `/var/` 热路径入口。因此当前不进入 `RIPC-010-C2`，也不重想 remap；先完成 **runtime-located coverage probe / re-anchor 并重跑 live verify**。若 coverage 建立后仍无 `convert_call`，再继续追当前热路径上游 caller；若 coverage 建立后出现 `convert_call`，再读 `x1` 真实形态；仅当 normalize 已命中但 QtsFS 仍 fail 时，才转向 `C2`；仅当 `C1/C2` 后仍有新未闭合样本时，才回开 `B2`。

### 当前状态摘要

- **双端基线已闭合**：`RIPC-001～004` 完成，真机与 PlayCover 基线分别见 `build/ripc-003-ipad-baseline.json` 与 `build/ripc-004-playcover-baseline.json`。
- **路径类根因已闭合**：`RIPC-005 + RIPC-010-B1` 已确认 PlayCover 稳定 failing class 是 `/Users/.../Saved/Paks/...`，真机 accepted classes 至少包含 `/var/mobile/.../Saved/Paks/...` 与 `../../../NGR/Content/Paks/...`；当前应比较的是 **path class + caller/helper state**，而不是“绝对 vs 相对”。
- **现成 normalize 链已存在**：`PlayLoader.m` 已有 `ripc006_try_normalize_pak_path()` → `pdt006_convert_replacement()` → `pdt006_install_convert_patch_once()`，因此当前不是缺“修法”，而是缺 failing flow 的入口覆盖 / replacement 调用证据。
- **installed GUI fresh run 已排除 app 副本变量**：`~/Applications/PlayCover.app` 的 `Release` fresh run 中 `pdt006_ngr_convert_patch status=installed` 出现，但仍无 `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize`，且继续出现 `QtsFileSystem Create Failed!!`。
- **installed-binary anchor revalidation 已收紧 `C1`**：`build/pdt-005-current-installed.json` 显示当前 `/var/` 字面量窗口位于 `0x107d009c4`，而旧锚点 `0x10463f204` 首条指令立即 branch 到 `0x1000a4a08` 的 `/Users/` fast-path helper；这说明 `pdt006_ngr_convert_patch status=installed` 只能证明旧锚点地址可写并已打补丁，尚不能单独证明 failing flow 必然进入当前 replacement 覆盖范围。
- **维护方式已统一**：`RIPC-010-B1`、installed GUI `C1`、installed-binary anchor revalidation 的长期结论只维护在本文与 `RIPC-010-真机materializer采集与双端对比.md`；同主题 execution note 不再作为事实来源。

### RIPC-005 根因链

```text
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
3. ~~**RIPC-006～007**~~（已完成）：`Saved/Paks` 归一化链与 W^X 合规 patch 安装链已完成。
4. ~~**RIPC-008**~~（已完成）：runtime object graph / `FString` size 字段修补假设已证伪，路线终止。
5. **RIPC-010**（当前主线）：先闭合 `RIPC-010-C1` 的旧锚点覆盖证明，再决定是否进入 `RIPC-010-C2`。

### RIPC-008 embedded path rewrite + 验证结论

`RIPC-008` 已形成稳定否定结论：运行时 object graph / `FString` 长度元数据修补**不能**消除 `QtsFileSystem Create Failed!!`。这条路线只保留为已证伪背景；需要复盘 scan / dump / parent-aware 修补细节时，再回看 `build/ripc-008a/` 与 `PlayLoader.m` 注释。**一般无需读取。**

### 当前卡点

1. **当前第一缺口已经具体化为 stale hardcoded anchor 与当前热路径脱节**：`PDT006_CONVERT_FUNC_UNSLID = 0x10463f204` 仍能稳定产生 `pdt006_ngr_convert_patch`，但 `build/pdt-005-current-installed.json` 与 live verify 联合表明它不再足以代表当前 `ConvertToPlatformPath` 热路径；因此第一动作应是把 coverage probe / patch point 改为 runtime-located，而不是继续把“patch installed”当作 coverage 证据。
2. **只有在 runtime-located coverage 建立后，`pdt006_ngr_convert_call` 字段才是第一判读口径**：这时再围绕 `pathPreview`、`pathBytesHex`、`matchesUsers`、`containsSavedPaks`、`looksUtf16UsersPrefix`、`normalized` 判断 `x1` 的真实编码与形态。
3. **如果 runtime-located coverage 建立后仍完全没有调用证据，下一步应改为追当前热路径上游 caller，而不是直接进入 `C2`**：这时问题首先是调用链缺口，而不是 pre-`1c8` compare 机制。
4. **只有 normalize 已命中但 QtsFS 仍 fail，`C2` 才成立；`B2` 始终是条件性回退项**：只有在 `C1/C2` 后仍出现新的未闭合 path class / caller tuple，才回到定向真机补采。

### 下一步默认规划

1. ~~**已完成背景项**~~：`RIPC-010-A1～A4`、`RIPC-010-B1` 与 `RIPC-008` 均已形成稳定结论，细节统一维护在 `RIPC-010-真机materializer采集与双端对比.md`。
2. **RIPC-010-C1（当前唯一默认主线）**：先把 `PDT-006` 从 stale hardcoded anchor 升级为 **runtime-located coverage probe / patch point**，并重跑 installed GUI verify，确认 failing `/Users/.../Saved/Paks/1/1.db` 是否进入当前 `ConvertToPlatformPath` 热路径。
   - 若 coverage 建立后出现 `pdt006_ngr_convert_call`，再利用 `pathPreview` / `pathBytesHex` / `matchesUsers` / `containsSavedPaks` / `looksUtf16UsersPrefix` / `normalized` 判断 `x1` 的真实编码与形态；
   - 若 coverage 建立后仍完全没有 `pdt006_ngr_convert_call`，优先把探针 / hook 前移到当前热路径的上游 caller，而不是直接升级到 `RIPC-010-C2`。
3. **RIPC-010-C2（条件性第二优先级）**：仅当 `C1` 已证实现有 normalize 链命中但 QtsFS 仍 fail，再转向 **pre-`1c8` caller/helper state 对齐**。
4. **RIPC-010-B2（条件性回退项）**：仅当 `C1/C2` 验证后仍有未闭合样本时，再围绕缺失 path class / caller tuple 做定向真机补采；默认沿用 `--pre-inject-delay 5`。

## 构建与验证

### 日常默认方法

- **真机连接验证**：`xcrun xctrace list devices` 确认 iPad 在线。
- **重签名工具链**：`Scripts/ripc_resign.sh`（封装 IPA 解包 + 平台检查 + `codesign` + `security` + `/usr/libexec/PlistBuddy`）。默认从原始 IPA 解包原生 iOS 二进制；用法：`./Scripts/ripc_resign.sh [--dry-run]`，支持 `--ipa`、`--source`、`--bundle-id`、`--profile`、`--identity`、`--output` 覆盖。
- **真机部署**：`ios-deploy --bundle <path>` 或 Xcode Devices window。
- **真机 LLDB**：优先使用 Xcode 原生调试入口；`ios-deploy --debug` 在当前 `Xcode 16.4 + iPadOS 26.4.1` 组合下只保留为已知不兼容对照项，不作为默认 attach 方法。
- **Xcode GUI 自动化（agent 必须自主使用）**：`LocalDocs/XCodeOperation/` 目录提供基于 JXA/Accessibility API 的 Xcode GUI 自动化工具库（`xcode_general_ops.py` / `xcode_gpu_ops.py`）。任何涉及 Xcode 交互式操作的步骤，agent 都必须优先复用这套工具；若缺少能力，必须先扫描 UI 结构（`dump_ui_tree` / `uitree`）并把新增能力沉淀回脚本，再继续主线。
- **真机 materializer 采集（RIPC-010）**：默认使用 `Scripts/ripc_010a_real_ipad_lldb_driver.py` + `--pre-inject-delay 5` 生成 per-run 产物；当前稳定基线是 `build/ripc-010a-real-ipad-lldb-run-v5.json` / `build/ripc-010a-ipad-materializer-args-v5.json`。详细步骤、fallback 与调试经验见 `RIPC-010-真机materializer采集与双端对比.md`。**当前主线涉及 `RIPC-010-B / RIPC-010-C` 时总是建议读取。**
- **PlayCover 侧验证**：使用 PlayCover MCP `launch_app` 工具启动 app，通过 `launch-events.jsonl` 检查 hook 事件和 QtsFS 状态。
- **PlayTools 构建部署流程（结论性 GUI 验证）**：
  1. 修改 `Carthage/Checkouts/PlayTools/PlayTools/PlayLoader.m` / `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
  2. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh Release`
  3. `PLAYCOVER_INSTALL_MODE=user ./BuildScripts/build_and_install.sh Release`
  4. `python3 Scripts/hok015_ngr_live_verify.py --playcover-app-path ~/Applications/PlayCover.app --output build/ripc-010c1-live-report-vN.json`
  5. 读取 `~/Library/Containers/io.playcover.PlayCover/RuntimeLaunchDiagnostics/com.tencent.ngr/launch-events.jsonl`
  6. 如需专看本轮事件，按 `processLaunchId` 过滤 `pdt006_ngr_convert_patch` / `pdt006_ngr_convert_call` / `ripc006_pak_path_normalize` / `hok014_ngr_alert_suppressed`

  **备注**：当前 `PlayCover` target 只有 `Release` / `Nightly` 两套 GUI 配置；`build_gui.sh Debug` 不应用作 `RIPC-010-C1` 的结论性证据。
- **证据存放**：真机 trace 产物 → `build/ripc-*.json`；对比报告 → `build/ripc-*-diff.json`。

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
6. 写文档，必须将本次执行的信息完整写到独立的新文档。新文档放到与主文档同目录的 `executions/` 文件夹下，文件名带上时间戳。
8. 收尾后执行 `git commit`。

## 所有任务 TODO 状态

| ID | 状态 | 任务描述 | 子文档 |
|---|---|---|---|
| RIPC-001 | DONE | 环境预检、签名、部署与真机 debug/attach 链路已验证 | `RIPC-001-环境预检与工具链准备.md` |
| RIPC-002 | DONE | 重签名 NGR 并部署到 iPad：IPA 解包 → 重签 → 部署 → UE4 启动验证通过 | — |
| RIPC-003 | DONE | 真机基线采集完成：运行时上下文已落盘，真机无 `QtsFileSystem Create Failed` | `RIPC-003-真机启动行为基线采集.md` |
| RIPC-004 | DONE | PlayCover 环境同构采集完成：17 类运行时上下文已落盘 | — |
| RIPC-005 | DONE | 根因定位完成：PlayCover 稳定 fail 的是 `/Users/.../Saved/Paks/...` path class，而不是“绝对路径”概念本身 | `build/ripc-005-diff.json` |
| RIPC-006 | DONE | `ConvertToPlatformPath` hook 已加入 bundle-scoped `Saved/Paks` 归一化链 | — |
| RIPC-007 | DONE | W^X 合规修复完成，patch 安装不再是主阻塞 | `build/ripc-007-verification-report.json` |
| RIPC-008 | DONE | runtime object graph / `FString` size 字段假设已证伪，路线终止；产物见 `build/ripc-008a/` | — |
| RIPC-010 | IN-PROGRESS | 主线已固定为先用 runtime-located coverage probe / re-anchor 替代 stale hardcoded anchor，确认 failing flow 是否进入当前 `ConvertToPlatformPath` 热路径；未证实前不进入 `C2` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A1 | DONE | `Scripts/ripc_010a_materializer_probe.py` 已形成稳定的 materializer / vcall 采集能力 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A2 | DONE | Xcode GUI 自动化 attach 能力已落地并可复用 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A3 | DONE | Debug Console 命令输入自动化已稳定，不再是阻塞项 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-A4 | DONE | delayed injection + decoder fix 已形成稳定真机基线 `v5` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B | IN-PROGRESS | `B1` 已完成；`B2` 仅在 `C1/C2` 后仍出现新的未闭合样本时打开 | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B1 | DONE | 真机 `v5` 与 PlayCover 对照矩阵已落盘 `build/ripc-010b-diff.json` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-B2 | TODO | 若 `RIPC-010-C1/C2` 后仍有新的未闭合 path class / caller tuple，再做定向真机补采；默认 `--pre-inject-delay 5` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C | IN-PROGRESS | `C1` 为默认当前主线：先建立 runtime-located coverage；只有 coverage 成立后才读 `convert_call` 字段；只有 normalize-hit 后才升级到 `C2` | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C1 | IN-PROGRESS（默认当前主线） | 当前唯一默认子任务：把 `PDT-006` 从 stale hardcoded anchor 升级为 runtime-located coverage probe / patch point，并重跑 verify；coverage 建立后再判定 `x1` 形态，若仍无调用证据则改追上游 caller | `RIPC-010-真机materializer采集与双端对比.md` |
| RIPC-010-C2 | TODO（条件性） | 若 `C1` 已证实 normalize 命中但 QtsFS 仍失败，再转向 pre-`1c8` caller/helper state 对齐 | `RIPC-010-真机materializer采集与双端对比.md` |

## 高频复用经验

### 真机部署与签名

- **IPA 已解密**：`com.tencent.ngr` 的 `cryptid=0`，无需额外脱壳。
- **app 体积巨大**：IPA 总计 3.07 GB，含 39 个 embedded framework；重签名时必须先 frameworks → 再主 bundle。
- **开发者证书限制**：当前仅 1 个有效签名身份（Apple Development）；另外 2 个已 REVOKED。
- **真机 bundle ID 必须修改**：原 `com.tencent.ngr` 不在开发者账号下，需改为 profile 覆盖的 ID（如 `com.songdog.ripc.debug`）；对 QtsFS 路径差异无影响。
- **PlayCover 安装副本不能用于真机部署**：PlayCover 会将 `LC_BUILD_VERSION` 从 `platform 2`（iOS）改写为 `platform 6`（macCatalyst）；真机部署必须从原始 IPA 解包，`ripc_resign.sh` 已内置平台安全检查。
- **真机调试需要 `get-task-allow=true`**：开发者 provisioning profile 自动包含。

### 双端环境特征

- **真机 iOS sandbox 路径规范**：`/var/mobile` = `/private/var/mobile`（symlink）；`NSHomeDirectory()` 不带 `/private`，`NSTemporaryDirectory()` 带 `/private`；Home 本身不可写，Documents/Library/tmp 可写。
- **PlayCover sandbox 特征**：HOME 位于 `~/Library/Containers/<bundleId>/Data`；环境变量明显多于真机，泄漏较多宿主 macOS 状态。
- **真机启动验证基线**：重签名后的 NGR 在 iPad 上成功启动，UE4 初始化正常，**无 `QtsFileSystem Create Failed`**。

### 采集与调试方法

- **RIPCProbe dylib 采集**：编译 ObjC dylib → `insert_dylib` 注入 → 重签名 → 部署 → `--console` 捕获 NSLog。CoreDevice 下 CLI LLDB 无法直接 attach 真机时，这条链更稳定。
- **PlayCover LLDB 采集**：`lldb --batch --source` attach 运行中进程；标量用 `expr -l objc --`，集合用 `po`。脚本：`Scripts/ripc_004_playcover_probe.py`。
- **真机 materializer 采集（RIPC-010）**：默认使用 `Scripts/ripc_010a_real_ipad_lldb_driver.py` + `--pre-inject-delay 5` 生成 per-run 产物。详细步骤、fallback 与调试经验见 `RIPC-010-真机materializer采集与双端对比.md`。**当前主线涉及 `RIPC-010-B / RIPC-010-C` 时总是建议读取。**

### Xcode GUI 自动化

- **Attach to Process 菜单动态子菜单**：展开后需等待 `Getting Process List…` 完成，再扫描子菜单项；目标进程名可能带设备前缀。
- **Debug Console 输入框**：使用 `inputArea.value = command` 直接赋值后发送回车键，比 `keystroke` 更可靠。
- **Address breakpoint 必须走 LLDB 命令**：Breakpoint Navigator 的 `+` 菜单没有 Address Breakpoint。

### 关键技术约束

- **`RIPC-005 + RIPC-010` 联合结论**：当前真正需要比较的不是“绝对 vs 相对”，而是 **path class + caller/helper state**。
- **Apple Silicon W^X 策略**：`mprotect(R|W|X)` 在 Apple Silicon 上 100% 失败；必须分阶段切换 `R+W` 与 `R+X`，必要时通过 `vm_protect(..., VM_PROT_COPY)` 触发 copy-on-write。

## 参考信息

### 关键路径

- IPA 源：`~/Downloads/com.tencent.ngr_1.0.8_und3fined.ipa`
- IPA 解包缓存：`build/ripc-ipa-extract/Payload/NGR.app`
- 重签名产物：`build/ripc-resigned/NGR.app`
- PlayCover GUI 安装副本：`~/Applications/PlayCover.app`
- PlayCover 容器内已安装 NGR：`~/Library/Containers/io.playcover.PlayCover/Applications/com.tencent.ngr.app/`
- 签名身份：`BB36AD6577F23F304F93A1A75A940DAE92559A7B`
- iPad UDID：`00008103-0011050A0E3B001E`
- 真机基线：`build/ripc-003-ipad-baseline.json`
- PlayCover 基线：`build/ripc-004-playcover-baseline.json`
- `RIPC-010` 真机稳定基线：`build/ripc-010a-ipad-materializer-args-v5.json`
- `RIPC-010-B1` 对比矩阵：`build/ripc-010b-diff.json`
- installed GUI live verify：`build/ripc-010c1-live-report-v2.json`
- installed-binary 锚点复核：`build/pdt-005-current-installed.json`
- `RIPC-010` driver：`Scripts/ripc_010a_real_ipad_lldb_driver.py`
- installed-binary locator：`Scripts/pdt005_ngr_convert_to_platform_path_locator.py`

### 关联文档

- `LocalDocs/HOKCrash/00-Dashboard.md`：HOKCrash 主线 Dashboard，了解 `QtsFileSystem Create Failed` 的已有分析与兜底链路。**阅读建议：需要理解 QtsFS 失败的大盘背景或与真机对比方向的关系时按需读取。**
- `LocalDocs/HOKCrash/HOK-016-qts-fs-create-failed.md`：QtsFileSystem 失败的详细根因链与已证伪路径。**阅读建议：需要理解 storage create-table 链、断点地址或历史兜底修复时按需读取。**
- `RIPC-010-真机materializer采集与双端对比.md`：`RIPC-010` 阶段的长期方法、`v5` 真机基线、`B1` 矩阵结论，以及 installed GUI / installed-binary `C1` 结论与判断口径。**阅读建议：当前主线涉及 `RIPC-010-B / RIPC-010-C1 / RIPC-010-C2` 时总是建议读取。**
- `RIPC-001-环境预检与工具链准备.md`：`RIPC-001` 的完整实验细节、验证产物与踩坑记录。**阅读建议：需要复现命令、核查 profile / codesign / deploy / attach 异常时按需读取；一般无需读取。**
- `RIPC-003-真机启动行为基线采集.md`：真机 iPad 运行时上下文详细表格、Probe 方法说明与产物索引。**阅读建议：需要核查真机侧具体路径值、沙盒结构或与 `RIPC-010` 样本交叉验证时按需读取；一般无需逐条通读。**
- `HOK-016-appendix-C27.md`（HOKCrash 子文档）：materializer compare ladder 的逐层证据，是 `RIPC-005` 根因定位与 `RIPC-010-B` PlayCover 侧对照的关键来源。**阅读建议：需要理解 materializer 内部控制流、success/fail tuple 差异，或继续收紧 pre-`1c8` caller/helper state 时读取。**
