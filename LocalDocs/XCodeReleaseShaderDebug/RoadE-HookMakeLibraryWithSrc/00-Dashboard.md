## Road E: Hook `makeLibrary` 注入 Shader 源码

## 问题背景

外网 Release 包体截帧后，Xcode 打开 `.gputrace` 时大部分 shader 显示 `Shader source not found`，因为原始 metallib 通常未嵌入源码或可用调试信息。

## 最终目标

在 PlayTools 运行时中 hook `MTLDevice.makeLibrary(...)` 系列 API，从 metallib 中提取 LLVM Bitcode，经 `llvm-dis` 反汇编为 LLVM IR，再**逐指令翻译为语义等价的 MSL 源码**，通过 `makeLibrary(source:)` 重新编译并替换原始返回，使后续真实截帧的 `.gputrace` 自动携带 shader 源码。

**核心约束（按优先级）**：
1. **语义等价**：生成的 MSL 必须与原始 IR 逐指令语义等价
2. **可编译**：生成的 MSL 必须能通过 `makeLibrary(source:)` 编译，且函数签名与原始 metallib 一致
3. **可读性**：在满足 1、2 的前提下尽量提升

## 当前阶段目标

本阶段的**日常主回路**已经确定为：

```text
live 采集一次或少量几次真实 shader
  ↓
导出可复用 corpus（.bc / .ll / .metal / manifest）
  ↓
离线 replay：IR -> MSL -> Metal 编译 / diff / 归因
  ↓
批量修复 IRToMSLConverter
  ↓
仅在阶段性收敛后做少量 live 复测
  ↓
最终真实截帧确认源码可见
```

**补充约束（当前最高优先级）**：`E-006c` 已证明“.gputrace 中源码可见”链路本身已经打通，但当前阶段不再把 `E-006d`“同一界面重复启动出现随机画面异常”作为日常最高优先级主线继续深挖。该问题已确认是**偶现问题**，现阶段**暂时搁置**；其已有进度保留在 `E-006d-GenshinRenderingNondeterminism.md`，但主文档不再展开其细节，且在优先级恢复前，**不要求继续读取其子文档作为默认工作入口**。`E-006g` 已在 2026-04-08 夜间完成收口：`6BECB...` targeted bypass 已移除，fresh `case E` latest run 达到 `replacement_attempt_started=65 / replacement_compile_started=65 / replacement_succeeded=65`，latest failure surfaces=0。当前更需要优先收敛的，是两个仍未收口的确定性问题：
1. **`原神` 在“进入游戏”后出现 `31-4302` 完整性异常，怀疑与 hook / replacement 副作用有关**
2. **`QQ飞车` 在同时启用 `metal capture + shader replacement` 时启动崩溃，但当前最新矩阵未稳定复现**

**分工原则**：
- **live 的职责**：采集 corpus、扩覆盖、做最终真实验证
- **离线的职责**：日常回归、归因分析、批量编译验证、diff 与收敛 blocker
- **`test-data/` 的职责**：承载手工构造的最小样本，用于单点 lowering 验证
- **`ShaderCorpus/` 的职责**：承载真实运行时采集的样本，用于批量 replay、diff 和回归基线
- **最终目标不变**：真实 `.gputrace` 可见源码；只是把实现过程从“高成本 live 试错”改成“低成本离线迭代”

## 技术路线

仍采用逐指令机械翻译（方案 A）。LLVM 生态没有可直接用于 Metal AIR → MSL 的通用工具，因此主线仍是：

```text
metallib / wrapper payload
  ↓
BitcodeModule.data
  ↓
llvm-dis
  ↓
LLVM IR 文本
  ↓
IRToMSLConverter
  ↓
可编译的 MSL 源码
  ↓
makeLibrary(source:)
```

但**流程组织方式**改为三层：

1. **采集层（runtime / host）**
   - 在真实 app 中拦截 shader 加载
   - 成功替换样本进入 `ShaderCorpus/`，失败样本上下文进入 `ShaderSourceDiagnostics/`
   - 若 blocker 首次来自 `ShaderSourceDiagnostics/` 且样本尚未进入 `ShaderCorpus/`，修复后需通过 fresh capture 或失败路径补齐 `.bc/.ll` 导出完成闭环
2. **离线回放层（offline replay）**
   - 对 corpus 做 `IR -> MSL -> Metal 编译` 批量验证
   - 作为 `IRToMSLConverter` 的日常回归主路径
3. **真实验证层（minimal live）**
   - 对已通过离线批量验证的一组改动做最小次数 live 复测
   - 最终用 `.gputrace` 做确认；日常依赖 `Scripts/check_gputrace_sources.py` 自动检查，仅在阶段性收敛或关单前才辅以 Xcode 人工确认

当前阶段在这三层之上额外增加一条约束：**优先收敛“startup injection / capture / replacement 并存时的启动兼容性”和“进入游戏后的完整性检测副作用”**，而不是继续把主文档的控制面放在偶发性的随机画面异常上。

## Agent 工作流

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的 **一个** 未完成任务执行
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助，且无法通过先做其他任务来解除该阻塞），**必须停下来汇报**，禁止跳过阻塞去执行低优先级任务
4. 若任务过大，先拆分到 TODO，再只完成其中一个
5. **优先做离线测试**：若本轮涉及 `IRToMSLConverter` / corpus / replay，先补最小样本与离线回放；仅在确有必要时做 live
6. 若本轮实现了新功能，执行相应验证：
   - 离线功能：最小样本 / corpus replay / Metal 编译
   - runtime 导出链路：构建 + 安装 + 最小 live 采集；**若本轮修复来源于 `ShaderSourceDiagnostics/` 的 compile blocker，且对应样本尚未进入 `ShaderCorpus/`，不能只用既有 corpus green 结束，需补一次 post-fix fresh capture 或明确记录失败路径导出仍未闭环**
   - 最终截帧效果：agent 完成 live 启动、等待、截帧、快照固化与自动检查；**仅在阶段性收敛或关单前的最后一步保留 Xcode 人工确认，日常推进不以人工操作为 gate**
7. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息下沉到归档，主体保持简洁，**不要只做追加**
8. 整理代码与改动内容；若本轮新增的测试样本、回放脚本或 corpus 工具对后续仍有价值，也应一并整理并提交
9. 收尾完成后执行 `git commit`

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

## 验证方式

> ⚠️ **新增 build / test / validation 方法时，默认要求 agent 可通过脚本或命令独立完成。** 若某一步需要人工登录、摆场景、点按钮或其它交互，它不能成为日常 gate；只有当该步对当前 blocker 确属必要，且已得到用户明确确认后，才可作为例外保留。

### 日常验证（默认）

仅在修改 `IRToMSLConverter`、导出链路或离线工具时执行：

- 在 `test-data/` 下补对应 `.ll` / `.metal` 样本
- 用工具链确认目标 IR 模式确实出现
- 对样本或 corpus 执行 **离线 replay**：
  - `LLVM IR -> MSL`
  - `MSL -> Metal 编译`
  - 必要时做新旧输出 diff
- 运行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 确认 PlayTools 编译通过

### 运行时链路验证（只在必要时）

仅在修改以下内容时执行：
- makeLibrary hook / 导出目录 / host bridge / corpus 持久化
- `build_and_install.sh` 部署相关逻辑
- `metal capture + startup injection + shader replacement` 并存时的启动兼容性
- 需要进入登录后 UI 才能触发的完整性 / 反篡改问题
- 需要扩充真实 shader 覆盖面

执行方式：

```bash
./BuildScripts/build_and_install.sh
open ~/Applications/PlayCover.app
remove_playtools / inject_playtools / launch_app / create_session
```

补充约束：

- **`E-006g`（`恋与深空` 三开关启动崩溃）**：默认走**全自动最小五象限对照**（`metalCaptureEnabled` / `injectMetalCaptureEnvironment` / `shaderSourceReplacementEnabled`）+ `RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl` + crash 证据汇总，不引入人工 gate。推荐优先比较 `C=true/true/false` 与 `E=true/true/true`，先判断是 startup injection 本身、还是 startup injection + replacement 并存触发。
- **`E-006f`（`原神 31-4302`）**：允许把 `launch_app -> create_session -> tap` 视为 agent 可独立完成的**轻量 UI 触发**。默认最小路径是：`create_session` 进入 `ready` 后固定等待数秒，再点击屏幕中心 1 次；若 session 仍存活且 diagnostics 没有产生新的自动化信号，可在短等待后**最多补第 2 次 tap**，每轮不做任意 UI 探索。日常 gate 记录的是 replacement `off/on` 对照下的 session / diagnostics / 进程存活差异，而**不是人工看弹窗**；若当前仍缺少稳定自动信号，只能把结论记为“触发路径未稳定”，不得直接下根因结论。直接对已安装 app bundle 做 `strings` / `otool` / 反汇编等工作区外二进制分析，不属于日常 gate；若要正式执行这条路径，需要用户明确确认。
- **`E-006e`（`QQ飞车` 启动崩溃）**：保留为自动化四象限对照参考线；在优先级恢复前，不再作为默认运行时 gate 入口。
- **`E-006d`（随机画面异常）**：当前已下调为搁置问题；除非优先级恢复，不再要求把“同一界面重复启动 2~3 轮对照”作为默认运行时 gate。

### 最终验证（保留）

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。**这一步仅在阶段性收敛或关单前执行，不属于日常 gate。** 若当前处理的是 `E-006g` / `E-006f` / `E-006e`，还需补充确认：
- **`E-006g`**：在 `恋与深空` 上同时启用 `metal capture + startup injection + shader replacement` 后，应用可稳定启动，且不会为了绕过崩溃而牺牲最终的源码可见性目标
- **`E-006f`**：在 `原神` 上完成“进入游戏”触发后，不再出现 `31-4302`，且截帧/源码链路仍保持有效；若最终方案依赖 patch / selective bypass，也必须明确确认不会把 Road E 退化成“只能关替换才能进游戏”
- **`E-006e`**：在 `QQ飞车` 上同时启用 `metal capture + shader replacement` 后，应用可稳定启动，且不会为了绕过崩溃而牺牲最终的源码可见性目标

除这一步外，前置的 live 启动、等待、截帧、快照固化与自动脚本分析都默认由 agent 独立完成。

## 当前主线

- **`E-006f`（当前最高优先级）**：解决 `原神` 在“进入游戏”后出现的 `31-4302` 完整性异常。**当前最该做的是先把 `launch_app -> create_session -> tap` 的最小触发路径与“非视觉自动判定信号”稳定下来，再做 replacement `off/on` 对照；只有当这两步仍不足以定位时，才升级到工作区外静态分析，且仍需用户确认。** 详细路径见 `E-006f-GenshinIntegrityCheck-314302.md`。
- **`E-006e`（当前第二优先级）**：继续保留 `QQ飞车` 在同时启用 `metal capture + shader replacement` 时的启动兼容性问题，但由于最新四象限未稳定复现，当前不再作为默认工作入口。**默认仅在 `E-006f` 收敛后，或 `QQ飞车` fresh `D=true/true` 再次稳定复现 crash 时恢复优先级；恢复后首要任务不是盲修，而是解释历史 crash 与当前未复现基线之间的差异。** 详细记录见 `E-006e-QQSpeedCaptureReplacementStartupCrash.md`。
- **`E-006g`（已完成，保留回归观察）**：`6BECB...` targeted bypass 已移除；历史 failure-path `moduleKey=a6638ee7b4b9f8cc9f19a24bb78b0892cc4b2c098cd97e3eb05833ce2283b28b` replay + `xcrun metal -c` 与 fresh `case E` live 均已通过。最新 `processLaunchId=launch-85332-99130214-8f39-45b7-99c0-4d156a4e65ce` 在默认 10 秒 settle window 下 `replacement_attempt_started=65`、`replacement_compile_started=65`、`replacement_succeeded=65`，latest failure surfaces=0；`analyze` 中残留的 `6BECB...` 仅是旧 runs 的 aggregate historical hotspot，不再代表 active blocker。详细路径见 `E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md`。
- **`E-006d`（暂时搁置）**：随机画面异常已确认是偶现问题，现阶段仅保留已有调查进度；主文档不再继续展开，也不再要求默认读取其子文档跟进细节。仅在 `E-006f` / `E-006e` 收敛后，才考虑是否恢复优先级。
- **`E-006a / E-007`**：继续维持降级状态，不抢占当前主线。

## 最新基线

### 当前可复用的自动化能力（agent 全链路独立完成）

| 能力 | 工具 / 路径 |
|---|---|
| 日常构建验证 | `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`（PlayTools 编译） |
| 运行时部署 | `./BuildScripts/build_and_install.sh` → `inject_playtools` / `launch_app` |
| 运行时三开关切换 | `get_app_settings` / `update_app_settings`（`metalCaptureEnabled` / `injectMetalCaptureEnvironment` / `shaderSourceReplacementEnabled`） |
| 离线 replay + compile + baseline diff | `Scripts/corpus_replay_runner.py --compile --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus` |
| replacement 模式切换 | `Scripts/set_shader_replacement_mode.py --mode off/on` |
| live run 快照固化 | `Scripts/e006d_matrix_runner.py prepare-run / finalize-run --latest-gputrace [--capture-target device|scope]` |
| `E-006g1` 五象限启动矩阵 | `Scripts/e006g_launch_matrix_runner.py prepare-case / finalize-case / analyze --bundle-id com.papegames.lysk`（`finalize-case` / `analyze` 已内建 replacement failure cluster 摘要） |
| `.gputrace` 自动检查 / 归因 | `Scripts/check_gputrace_sources.py /path/to/xxx.gputrace [--bundle-dir /path/to/ShaderCorpus/<bundleId>]` |
| runtime launch 诊断 | `RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl` + `Scripts/runtime_launch_diagnostics_summary.py`（按 `processLaunchId` 聚合 replacement counts / failure clusters，并结合 `ShaderCorpus/<bundleId>/manifest.jsonl` 输出带 `moduleKeys` 的 failure surfaces；同时支持 cross-run hotspot 聚合，便于识别反复出现的 startup blocker） |
| 运行时输入自动化 | `launch_app` → `create_session` → `tap / swipe / press_key`（适用于“进入游戏”这类轻量 UI 触发） |

补充说明（2026-04-07）：`E-006g` 的 case 固化不能只看 `create_session` / `playcover_launch_complete`。`Scripts/e006g_launch_matrix_runner.py finalize-case` 现默认带 **10 秒 settle window**，用于把 launch 后数秒内出现的 startup replacement `compile_failed` / failure surfaces 一并写入 `case.meta.json`，避免矩阵快照错误地把 late crash 样本记成“已通过启动兼容性”。该窗口来自当前已知 late crash / replacement compile failure 多发生在 launch 后约 **7~8 秒** 的经验基线；日常复测默认直接使用脚本默认值，不让 agent 自行调参。

### 关键数据基线

| 基线 | 结论 |
|---|---|
| 落盘与闭环能力 | 成功路径 → `ShaderCorpus/<bundleId>/modules/<moduleKey>/{.bc,.ll,.metal,.meta.json}`；replacement → `replacements/<timestamp>_<selector>_<cacheKey>/aggregate.generated.metal`；失败路径 → `ShaderSourceDiagnostics/<baseName>_modules/<moduleKey>/{.bc,.ll,.metal,.meta.json}`。三条路径均已进入离线 replay / diff / 归因主回路。详见 `E-004-CorpusClosureAndRecapturePolicy.md` |
| corpus 编译基线 | 较旧的离线回归统计与样本数量已下沉到 [00-Dashboard-Archive](00-Dashboard-Archive.md) 与 `E-005-OfflineReplayBatchCompileDiff.md`；当前日常 gate 仍以 `test-data` / `ShaderCorpus` 的 replay + compile 自动回归为准。 |
| `恋与深空` 三开关启动兼容性 blocker（2026-04-08 夜间） | `air.front_facing` lowering 修复后，`4010578BBE3B30E1_4673 / e3c0894b...` 已退出 latest compile blocker：真实 failure-path 样本与最小样本 `test_fragment_front_facing.{ll,metal}` 均已通过离线 replay + `metal -c`；fresh `case E` 在默认 10 秒 settle window 下 `replacement_attempt_started=23`、`replacement_compile_started=22`、`replacement_succeeded=22`、`replacement_compile_failed=0`，session 仍保持 `ready`。当前 latest / aggregate failure surface 只剩 `cacheKey=6BECB97B0B4BCBFD_7123` 的 `replacement_attempt_skipped(reason=bundle_cachekey_bypass)`，默认下一入口已前移到 `E-006g4`。 |
| `E-006e1` 四象限基线（2026-04-07） | `QQ飞车` 当前 fresh `A/B/C/D` 四象限均能到达 `playcover_launch_complete`；该线保留为自动化参考基线，若优先级恢复则从 `E-006e2` 解释“历史 crash 为何出现、当前为何未复现”继续。 |
| `原神` 完整性 blocker | 当前默认推进路径仍是 **先稳定最小进入游戏触发，再做 replacement `off/on` 对照**；工作区外字符串 / xref / 反汇编定位仅属于升级路径，执行前需用户确认。 |
| `.gputrace` 里程碑 | `E-006c` 的样本名、阶段性 milestone 与更早基线已下沉到 [00-Dashboard-Archive](00-Dashboard-Archive.md)；当前主文档只保留“自动检查 + 最终人工确认”的工作流。 |

### 已完成的 session / capture 基础设施修复（2026-04-06）

相关基础设施修复均已落地并完成测试覆盖；当前主文档不再展开其细节，统一以下沉到 [00-Dashboard-Archive](00-Dashboard-Archive.md) 的阶段性基线与历史 live 脉络为准。

## 整体架构

```text
PlayCover 主应用 (macOS)
  ├── LLVMToolManager
  │     → 下载/管理宿主 llvm-dis
  ├── RegistrationListener / MCPManager
  │     → 承接 injected runtime 的 host bridge 命令
  ├── 现有 diagnostics
  │     → ShaderSourceDiagnostics/   (失败的 .metal + .txt)
  │     → ShaderSourceDiagnostics/<baseName>_modules/  (E-004f4: .bc/.ll/.metal/.meta.json)
  │     → ShaderPayloadSamples/      (异常 payload)
  └── 目标：ShaderCorpus/
        → 稳定承载成功样本：.bc / .ll / .metal / manifest
        → E-004f4 后失败样本也携带可离线 replay 的 .bc/.ll 产物

PlayTools.framework (注入到 iOS app)
  ├── LibrarySourceInjectionSwizzles
  │     → hook makeLibrary 系列 API
  ├── MetallibParser
  │     → 解析 metallib、提取 BitcodeModule
  ├── LLVMDisassembler
  │     → 优先经 host bridge 请求宿主执行 llvm-dis
  ├── IRToMSLConverter
  │     → LLVM IR -> 语义等价 MSL
  └── LibrarySourceInjectionService
        → 聚合单/多 module MSL，编译替换原始 library
```

## TODO

> **优先级更新（2026-04-08）**：当前主线已切换为 **`E-006g` → `E-006f` → `E-006e`**。`E-006d` 因确认为偶现问题，暂时搁置并保留进度；`E-006a` / `E-007` 继续下调一级。`E-006g` 的 compiler-first 入口（`4010578... / e3c089...` 的 `air.front_facing` builtin lowering）已在本轮完成，默认下一入口已前移到 **fresh `case E` live 基线下剩余 `6BECB...` targeted bypass surface 的方案验证（`E-006g4`）**。补充说明：`E-006f2` 虽编号早于 `E-006f3`，但它是需要用户确认的工作区外专项分支；默认执行顺序仍为 **`E-006f1 -> E-006f3 -> E-006f2 -> E-006f4`**。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | ✅ DONE | [E-004](E-004-MetallibSourceExtraction.md) |
| E-005 | **离线 replay / batch compile / diff 工具链** | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | ✅ DONE | [Archive](00-Dashboard-Archive.md) |
| E-006c | ↳ `.gputrace` shader 源码可见性确认 | ✅ DONE | [Archive](00-Dashboard-Archive.md) |
| E-006d | ↳ 原神同一界面重复启动时的随机渲染异常归因 | **搁置（偶现，保留进度）** | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006g | ↳ **`恋与深空`：`metal capture + startup injection + shader replacement` 同开启动崩溃** | ✅ DONE（2026-04-08 夜间，当前环境已收口） | [E-006g](E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md) |
| E-006g1 | ↳ 三开关最小五象限启动矩阵 + diagnostics / crash 证据固化 | ✅ DONE（2026-04-07） | [E-006g](E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md) |
| E-006g2 | ↳ 系统性汇总 startup 期 `replacement_compile_failed` / fallback failure clusters，确认 late crash 是否由 compile failure 集合触发 | ✅ DONE（2026-04-07，结论已收敛） | [E-006g](E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md) |
| E-006g3 | ↳ 把 `compile_failed` 命中面收缩到最小 `cacheKey` / selector / module 集合，为 `E-006g4` 准备最小修复 / 旁路面 | ✅ DONE（2026-04-08） | [E-006g](E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md) |
| E-006g4 | ↳ 设计并验证“不牺牲源码可见性目标”的修复方案 | ✅ DONE（2026-04-08 夜间） | [E-006g](E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md) |
| E-006f | ↳ **`原神`：进入游戏后出现 `31-4302` 完整性异常** | **TODO（当前最高优先级）** | [E-006f](E-006f-GenshinIntegrityCheck-314302.md) |
| E-006f1 | ↳ 自动化“进入游戏”最小触发路径（`launch_app -> create_session -> tap`） | TODO（先做） | [E-006f](E-006f-GenshinIntegrityCheck-314302.md) |
| E-006f3 | ↳ 对照 replacement `off/on`，判断触发点更接近 hook、副作用还是替换产物 | TODO（默认第二步） | [E-006f](E-006f-GenshinIntegrityCheck-314302.md) |
| E-006f2 | ↳ 在原神二进制 / 资源中定位 `31-4302` / 对应字符串与引用链 | TODO（专项分支，执行前需用户确认工作区外分析） | [E-006f](E-006f-GenshinIntegrityCheck-314302.md) |
| E-006f4 | ↳ 设计并验证绕过方案：检测点 patch / selective bypass / 保持截帧有效的替代方案 | TODO | [E-006f](E-006f-GenshinIntegrityCheck-314302.md) |
| E-006e | ↳ **`QQ飞车`：`metal capture + shader replacement` 同开启动崩溃** | **TODO（当前第三优先级；恢复后从 `E-006e2` 继续）** | [E-006e](E-006e-QQSpeedCaptureReplacementStartupCrash.md) |
| E-006e1 | ↳ 四象限启动矩阵 + launch diagnostics 固化 | ✅ DONE（2026-04-07） | [E-006e](E-006e-QQSpeedCaptureReplacementStartupCrash.md) |
| E-006e2 | ↳ 解释历史 crash 与当前未复现基线之间的差异，重点对照 preload / swizzle / first replacement 时序 | TODO（保留，待优先级恢复后先做） | [E-006e](E-006e-QQSpeedCaptureReplacementStartupCrash.md) |
| E-006e3 | ↳ 验证是否与特定 selector / metallib payload / module 命中有关 | TODO（保留，待优先级恢复） | [E-006e](E-006e-QQSpeedCaptureReplacementStartupCrash.md) |
| E-006e4 | ↳ 设计并验证“不牺牲源码可见性目标”的修复方案 | TODO（保留，待优先级恢复） | [E-006e](E-006e-QQSpeedCaptureReplacementStartupCrash.md) |
| E-006a | 扩展真实 corpus 覆盖面 | TODO（已降级） | |
| E-007 | PlayCover settings / MCP / 工具暴露 | TODO（已降级） | |

## 踩坑与经验

- **源码可见 / compile green 都不等于最终可用**：当前阶段真正阻塞落地的是**启动兼容性**与**进入游戏后的完整性检查副作用**，不能只看 `.gputrace` 或 compile 指标就宣告完成
- **`恋与深空` 当前默认入口已从 `E-006g4` 切换到 `E-006f1`**：`6BECB...` targeted bypass 已通过“failure-path replay + 最小样本 + remove/inject PlayTools + fresh `case E`”闭环收回；最新 `case E` run 已是 `replacement_succeeded`，`latestReplacementFailureSurfaces=0`。`analyze` 中若仍看到 `6BECB...`，那是旧 runs 的 aggregate historical hotspot，不应再当成 active blocker。更早的 `791A...`、`F474...`、`A101...`、`45AE...`、`8ABA...` 与 `D4CA...` **均已退出 latest surface**，其前移脉络统一下沉到 `E-006g-Archive.md`
- **如果不清楚编译器行为，优先写最小样本去问编译器本身**：先自己写简单 shader、编译成 AIR、再用 `llvm-dis` 看 IR；或直接手写最小 `.ll` 做 replay / `metal -c`。只有把编译器与反编译器的真实输出看清楚后，才进入正式 lowering 修复，避免在真实 failure-path 大样本上盲猜
- **`31-4302` 更像完整性 / 反篡改问题，不宜只靠人工看弹窗推进**：默认应先做最小自动 `tap` 触发与 replacement `off/on` 对照；只有当这两步仍不足以定位时，才升级到工作区外分析，且仍需用户明确确认
- **`launch_app -> create_session -> tap` 可以视为 agent 可独立完成的轻量 UI 输入**：但直接对已安装 app bundle 做工作区外静态反汇编 / 二进制 patch 分析，不属于默认日常流程，执行前需要用户明确确认
- **`E-006d` 现阶段只保留进度，不再占据 dashboard 控制面**：它的调查结果仍有参考价值，但在优先级恢复前，不应继续消耗主文档篇幅或默认工作流注意力
- **更细的历史基线、lowering 经验与已完成轮次已统一下沉到独立参考文档**：见 `00-Dashboard-Archive.md`、`E-004-MetallibSourceExtraction-Archive.md`、`E-006g-Archive.md`、`E-006e-QQSpeedCaptureReplacementStartupCrash.md` 与 `E-006f-GenshinIntegrityCheck-314302.md`

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 历史归档：live blocker 时间线 / 已完成轮次 | `00-Dashboard-Archive.md` |
| 失败样本闭环 / re-capture 策略参考 | `E-004-CorpusClosureAndRecapturePolicy.md` |
| `E-006d` 随机渲染异常调查（已搁置，保留进度） | `E-006d-GenshinRenderingNondeterminism.md` |
| `E-006e`：`QQ飞车` 启动崩溃专项 | `E-006e-QQSpeedCaptureReplacementStartupCrash.md` |
| `E-006f`：`原神 31-4302` 完整性异常专项 | `E-006f-GenshinIntegrityCheck-314302.md` |
| `E-006g`：`恋与深空` 三开关启动崩溃专项 | `E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md` |
| `E-006g` 历史 blocker 前移 / 工具补强归档 | `E-006g-Archive.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL / corpus 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| 离线 replay / batch compile / diff 工具链 | `E-005-OfflineReplayBatchCompileDiff.md` |
| Library API 入口与覆盖优先级 | `E-002-MTLDevice-Library-API.md` |
| swizzle 骨架与 hook 覆盖面 | `E-003-LibrarySwizzleSkeleton.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
