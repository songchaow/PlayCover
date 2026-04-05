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

**补充约束（当前最高优先级）**：`E-006c` 证明“.gputrace 中源码可见”已经打通，但这**不等于**“替换后的渲染结果已经稳定正确”。如果同一 app、同一界面、同一 mesh 布局下，多次启动仍出现随机渲染差异或局部异常，必须优先进入 `E-006d` 做**渲染一致性 / 非确定性归因**，不能再以“compile green”或“Xcode 能看到源码”作为阶段完成标准。当前最保守、最稳定的对照，不是直接认定“shader 改坏了”，而是比较**进行了反编译/重编译替换**与**完全不做替换**时的最终画面、draw call 行为与渲染链路差异。

**分工原则**：
- **live 的职责**：采集 corpus、扩覆盖、做最终真实验证
- **离线的职责**：日常回归、归因分析、批量编译验证、diff 与收敛 blocker
- **`test-data/` 的职责**：承载手工构造的最小样本，用于单点 lowering 验证
- **`ShaderCorpus/` 的职责**：承载真实运行时采集的样本，用于批量 replay、diff 和回归基线
- **最终目标不变**：真实 `.gputrace` 可见源码；只是把实现过程从"高成本 live 试错"改成"低成本离线迭代"

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
   - 最终用 `.gputrace` 做人工确认

## Agent 工作流

1. 读取本文档，先理解**当前主线**与 **TODO** 的最新状态
2. 从 **TODO** 中选取当前最高优先级的 **一个** 未完成任务执行
3. 若任务过大，先拆分到 TODO，再只完成其中一个
4. **优先做离线测试**：若本轮涉及 `IRToMSLConverter` / corpus / replay，先补最小样本与离线回放；仅在确有必要时做 live
5. 若本轮实现了新功能，执行相应验证：
   - 离线功能：最小样本 / corpus replay / Metal 编译
   - runtime 导出链路：构建 + 安装 + 最小 live 采集；**若本轮修复来源于 `ShaderSourceDiagnostics/` 的 compile blocker，且对应样本尚未进入 `ShaderCorpus/`，不能只用既有 corpus green 结束，需补一次 post-fix fresh capture 或明确记录失败路径导出仍未闭环**
   - 最终截帧效果：agent 完成 live 启动、等待、截帧、快照固化与自动检查；**仅在最后一步保留 Xcode 人工确认**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息下沉到归档，主体保持简洁，**不要只做追加**
7. 整理代码与改动内容；若本轮新增的测试样本、回放脚本或 corpus 工具对后续仍有价值，也应一并整理并提交
8. 收尾完成后执行 `git commit`

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
- 需要扩充真实 shader 覆盖面

执行方式：

```bash
./BuildScripts/build_and_install.sh
open /Applications/PlayCover.app
remove_playtools / inject_playtools / launch_app
```

若本轮目标是 `E-006d`（重复启动画面不一致 / 随机渲染异常），除常规部署外，还应尽量保持**同一 app 版本、同一停留界面、相同画质设置**，至少做 2~3 轮对照启动；并增加一组**不做替换**的稳定对照。对原神当前链路，默认可把“启动后数十秒自动停在登录界面”视为稳定复现面：agent 可以独立完成 `launch_app`、等待进入该界面、执行 Metal capture / `.gputrace` 固化、保存 `manifest.jsonl` 增量、`ShaderCorpus/` 新增模块、`ShaderSourceDiagnostics/` 新文件与聚合 MSL；**不要求人工登录、选场景或手动把界面摆到指定位置**。只有当本轮问题明确依赖登录后场景、账号态或其它人工交互条件时，才需要额外人工介入并在文档中单独说明。

### 最终验证（保留）

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。若当前处理的是 `E-006d`，还需补充确认：在同一界面重复启动时，相关 Draw Call 的 shader 来源、render pass 行为与视觉结果是否保持一致；并对照**替换**与**不替换**两种运行方式的最终效果差异。除这一步外，前置的 live 启动、等待、截帧、快照固化与自动脚本分析都默认由 agent 独立完成。

## 当前主线

- **E-006d（当前最高优先级）**：调查“用 PlayCover 打开原神，在同一界面重复启动时，画面表现每次都不完全一样；mesh 不变，但局部渲染结果异常”的现象。当前**不能实锤是 shader 改坏**：因为原神是延迟管线，base pass 对比看起来也可能类似，异常也可能来自后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置差异。最新 `off1/off2/on1/on2` 四轮快照已经稳定排除了 **captured corpus / 单模块 artifact 层面的随机漂移**，但**还没有形成“跨模式稳定不同”的 corpus / trace 级证据**；因此 `replacement=off / on` 仍是最低风险的对照口径，但不能再表述成“已经稳定证明差异存在”的结论。
- **当前最该做的事**：`E-006d8` 的第一轮 run matrix 已经够用，下一步**不是**继续机械补 run，也不是回头扩 lowering；而是优先收敛两个 blocker：1）`replacement=on` 时为什么始终没有 aggregate / 成功 replacement 证据；2）`create_session -> get_capture_status / capture_metal_frame` 为什么会在 `ready` 后仍然超时掉线。只有先恢复**至少一轮 `replacement=on` 且带 `.gputrace + aggregate source` 的稳定样本**，矩阵才有资格继续回答“替换 vs 不替换”是否稳定不同。
- **当前执行口径**：dashboard 只保留“现在最该做什么、做到什么算推进、有哪些基线已经可直接复用”；`E-006d-GenshinRenderingNondeterminism.md` 负责承载当前主线的详细判断路径、归因顺序与技术细节。
- **E-006c（✅ 已关闭，但仅作为里程碑基线）**：Xcode 人工确认 `capture_20260404_roadE_e006c3_final.gputrace` 中 Draw Call shader 面板可见 MSL 源码，说明“源码可见”链路已打通；但后续仍需对“渲染是否稳定正确”继续验证。
- **E-006a（扩展真实 corpus 覆盖面）** / **E-007（UI/MCP 工具暴露）**：仍保留，但在 `E-006d` 完成根因归因前暂不作为最高优先级。

## 最新基线

| 样本 / 基线 | 结论 |
|---|---|
| 流程与验收口径（当前默认） | Road E 的日常主回路已经稳定为 **采集 corpus → 离线 replay / compile / diff → 最小 live 复测 → `.gputrace` 最终确认**；除最终 Xcode 验收外，前置 build / test / live 采集 / 快照固化 / 自动检查都默认由 agent 独立完成 |
| 当前日常自动化验证基线（2026-04-05） | `test-data/*.ll`（19 个）replay + compile **全部成功**；`ShaderCorpus/com.miHoYo.Yuanshen/modules/` 全部 **91/91** replay + compile **成功**，preflight rejected `0`，regression `0`；`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 与 `./BuildScripts/build_and_install.sh` 都已形成可复用的标准构建验证路径 |
| 当前落盘 / 闭环能力（2026-04-05） | 成功路径按 `ShaderCorpus/<bundleId>/modules/<moduleKey>/` 落盘单模块 `.bc/.ll/.metal/.meta.json`；成功 replacement 额外落盘 `ShaderCorpus/<bundleId>/replacements/<timestamp>_<selector>_<cacheKey>/aggregate.generated.metal + replacement.meta.json`；失败路径在 `ShaderSourceDiagnostics/<baseName>_modules/<moduleKey>/` 落盘 `.bc/.ll/.metal/.meta.json`。三条路径都已能进入离线 replay / diff / 归因主回路 |
| 当前控制面与统一工作流（2026-04-05） | 已统一使用 `shaderSourceReplacementEnabled` + `Scripts/set_shader_replacement_mode.py` 控制 `replacement=off/on`；使用 `Scripts/snapshot_capture_run.py` / `Scripts/e006d_matrix_runner.py` 统一固化单轮 run 与矩阵分析；使用 `Scripts/check_gputrace_sources.py` 做 `.gputrace` 自动检查。当前这组日常方法都可由 agent 自主执行，不要求人工登录、摆场景或手工拷目录 |
| `.gputrace` 里程碑基线（2026-04-04，`E-006c` 已关闭） | `capture_20260404_roadE_e006c3_final.gputrace` 已被 Xcode 人工确认可在 Draw Call shader 面板中看到 MSL 源码；这说明“源码可见”链路已打通，但它只作为里程碑基线，不再代表 `E-006d` 已完成 |
| 当前 `E-006d8` 第一层矩阵结论（2026-04-05） | `off1/off2/on1/on2` 四轮快照已经足够证明：**同模式输入稳定**、共享 `moduleKey` 为 **91/91**、单模块 `.bc/.ll/.metal` 本体未出现语义级随机漂移；脚本已显式忽略 `captureCount`、`sourceCacheKeys` 等 benign metadata 漂移 |
| 当前尚未证明的部分（2026-04-05） | 现阶段**仍未形成“跨模式稳定不同”的 corpus / trace 级证据**：`crossMode.offVsOnPairSummary.allPairsDifferent=false`，且四轮都没有可比较的 replacement aggregate；因此当前还不能把结论提前收敛为“替换开启后一定稳定引入了最终差异” |
| 当前 replacement 证据基线（2026-04-05） | `LibrarySourceInjectionSwizzles` 现会把每次 runtime replacement 尝试都追加为 `manifest.jsonl` 中的 `event=replacement_attempt`，至少记录 `outcome` / `reasonCode` / `moduleKeys` / `invalidModuleCount` / `dumpPath`；`Scripts/compare_capture_runs.py` 与 `Scripts/analyze_capture_run_matrix.py` 也已同步汇总 latest replacement attempt，用于先回答“replacement 根本没命中，还是命中了但固定 fallback” |
| 当前 blocker 与下一步（2026-04-05） | 真正的 blocker 已收敛为两件事：1）`replacement=on` 时为什么始终没有 aggregate / 成功 replacement 证据；2）`create_session -> get_capture_status / capture_metal_frame` 为什么会在 `session=ready` 后仍超时掉线。下一步应先恢复**至少一轮 `replacement=on` 且带 `.gputrace + aggregate source` 的稳定样本**，再继续回答“替换 vs 不替换”是否稳定不同 |
| 历史 live blocker 时间线 | 见 [00-Dashboard-Archive](00-Dashboard-Archive.md) |

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

> **E-006c 已关闭（2026-04-04）**：Xcode 人工确认 `capture_20260404_roadE_e006c3_final.gputrace` shader 面板源码可见，**Road E 的“源码可见”目标已经达成**。

> **优先级更新（2026-04-05）**：当前主线已切换到 **`E-006d`：原神重复启动时的随机渲染异常归因**。在 `E-006d` 明确根因前，`E-006a` / `E-007` 均下调一级优先级。

> **当前 TODO 口径**：这里只保留“现在最该做什么”和“各已完成阶段目前产出了什么能力”；已完成但不再直接影响当前决策的细项统一下沉到 `E-006d-GenshinRenderingNondeterminism.md`、`E-004-MetallibSourceExtraction.md`、`E-005-OfflineReplayBatchCompileDiff.md` 与 archive。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | ✅ DONE（含 `E-004f1 ~ E-004f4`，当前作为 corpus / 闭环参考底座） | [E-004](E-004-MetallibSourceExtraction.md) |
| E-005 | **离线 replay / batch compile / diff 工具链** | ✅ DONE（含 `E-005a ~ E-005c`，当前作为日常自动化回归底座） | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | ✅ DONE（源码可见里程碑；`E-006b1 ~ E-006b9` 与 `E-006c1 ~ E-006c3` 已关闭并下沉） | [00-Dashboard-Archive](00-Dashboard-Archive.md) |
| E-006d | ↳ 调查原神同一界面重复启动时的随机渲染异常 / shader 语义漂移 | **TODO（当前主线）** | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d1 ~ E-006d7 | ↳ 输入 diff、aggregate diff、replacement 开关、run 快照、`.gputrace` 固化、run matrix、trace 归因索引 | ✅ DONE（工具已齐） | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d8 | ↳ replacement=off/on 多轮矩阵结论与第一层归因 | **TODO** | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
|  | 当前已拿到 `off1/off2/on1/on2` 四轮快照：已稳定排除 **captured corpus / 单模块 artifact 层面的 drift**，但**跨模式稳定不同尚未成立**，且四轮都没有可比较的 replacement aggregate。下一步应优先下钻 **replacement 成功路径为什么始终未命中 / 未落盘** 与 **live capture/session 为什么会在 ready 后掉线**；在恢复至少一轮 `replacement=on` 且带 `.gputrace + aggregate source` 的稳定样本前，不应继续把结论过早推向 shader lowering 或更后续 pipeline。 | | |
| E-006a | ↳ 扩展真实 corpus 覆盖面 | TODO（已降级） | |
|  | 仅在 `E-006d` 当前 blocker 收敛后，再继续进入新地图 / 新场景 / 新画质设置追加采集，逐步逼近“尽量全”的真实 shader 集合 | | |
| E-007 | **PlayCover settings / MCP / 工具暴露** | TODO（已降级） | |
|  | 为 corpus 导出 / replay 增加 UI 或 MCP 能力，使后续采集与回放不依赖手工路径操作；但若新增方法无法保持 agent 日常自主执行，则不能提前升级为当前主线 gate | | |

## 踩坑与经验

- **核心原则：优先沉淀成功样本，再去扩 lowering**：后续应优先围绕 `ShaderCorpus/`、`manifest.jsonl`、`replacements/` 与失败路径导出样本做 replay、diff 和回归，而不是重新回到高成本 live 试错
- **当前 `ShaderCorpus/` 不是“所有 live 样本”的同义词**：它主要覆盖成功替换样本；只落在 `ShaderSourceDiagnostics/` 的 blocker，如不补失败路径导出或 post-fix fresh capture，并不会自动进入离线主路径
- **修复来源于 diagnostics 的 blocker 后，不能只看既有 corpus green**：若该样本从未进入 `ShaderCorpus/`，修复完成后必须补一次 post-fix fresh capture，或直接对 `ShaderSourceDiagnostics/<baseName>_modules/` 中的 `.ll` 做离线 replay + compile 验证
- **`moduleKey` 与 `cacheKey` 必须分层使用**：`moduleKey = sha256(module.bc)` 是长期稳定的 module 级去重键；`cacheKey` 只用于 metallib 级上下文与运行时缓存，不能再拿来当持久化目录主键
- **最终目标不变，但日常主回路必须切到离线**：live 负责采集和最终验证，不适合作为日常 blocker 归因与回归主路径
- **`test-data/` 和 `ShaderCorpus/` 不能混用**：`test-data/` 用于验证单个 lowering；`ShaderCorpus/` 用于真实样本的批量 replay、diff 与回归基线
- **`build_and_install.sh` 是更新运行时 framework 的唯一可靠路径**：`sync_playtools_xcframework.sh` 只更新构建产物；涉及 live 时必须走 `BuildScripts/build_and_install.sh`
- **`session ready` 不是“capture-ready 且稳定”的充分条件**：live 收尾仍要同时核对 session 状态、capture 目录、`DiagnosticReports` 与对应快照是否完整固化
- **多 module 聚合仍要坚持“全成全退”**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **源码可见 / compile green 都不等于渲染语义正确**：`.gputrace` 中能看到 MSL 只证明“源码可见”链路已通；`E-006d` 关注的是相同输入下最终视觉结果、trace 与 replacement 证据是否稳定一致
- **当前最低风险的比较基线仍是“替换 vs 不替换”**：但最新四轮矩阵**尚未**形成“跨模式稳定不同”的 corpus / trace 级证据；因此它当前只是正确的比较口径，不是已经坐实的结论
- **“不做替换”对照必须复用统一开关**：统一通过 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py` 控制，避免因手工改代码或手改 plist 导致对照本身不可靠
- **run 快照必须统一固化**：统一通过 `Scripts/snapshot_capture_run.py` 或 `Scripts/e006d_matrix_runner.py finalize-run` 保留 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings；若已有 `.gputrace`，也应通过 `--gputrace` 一并纳入同一快照
- **当前原神的 live 复现默认不要求人工摆场景**：以“启动后数十秒自动停在登录界面”为稳定复现面；只有当 blocker 明确依赖登录后场景或其它人工交互时，才允许提升人工参与级别
- **`.gputrace` 可见源码还要继续看“归因是否闭环”**：不只看 `validMSLFiles` 或 hash 集合是否变化，还要看 `gputrace-attribution-index.json` 是否已把可见 MSL 回连到 `module.generated.metal` 或 `aggregate.generated.metal`
- **多轮对照要先看矩阵结论，再下钻单对 run**：优先用 `Scripts/analyze_capture_run_matrix.py` 回答“同模式是否稳定、跨模式是否稳定不同”，只有矩阵层已有稳定结论时，才回到 `Scripts/compare_capture_runs.py` 下钻单对 run 差异
- **`module.meta.json` 的 benign 漂移不能误判成输入/输出漂移**：`captureCount`、`sourceCacheKeys` 等 bookkeeping 字段变化不等于 `.bc/.ll/.metal` 本体变化，矩阵判断应优先看真实 artifact 与 aggregate source
- **同一界面重复启动出现差异时，不要过早收敛为 shader root cause**：当前已知现象是 mesh 不变，但原神为延迟管线；base pass 看起来类似并不能排除后处理、着色阶段或 render pipeline 顺序 / 配置差异
- **`E-006d` 的归因顺序必须固定**：先做“替换 vs 不替换”对照，再对齐“输入是否相同”，再比较“输出是否相同”，最后才看 runtime 是否真的使用了替换后的 library 以及更后续的 pass / pipeline 行为
- **更细的 lowering 经验、历史 live blocker 链路与已完成轮次已下沉到独立参考文档**：当前主文档只保留仍影响决策的规则；细粒度技术备注见 `E-006d-GenshinRenderingNondeterminism.md`，更早的 live / lowering 演进见 `00-Dashboard-Archive.md` 与 `E-004-MetallibSourceExtraction-Archive.md`

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 历史归档：live blocker 时间线 / 已完成轮次 | `00-Dashboard-Archive.md` |
| 失败样本闭环 / re-capture 策略参考 | `E-004-CorpusClosureAndRecapturePolicy.md` |
| `E-006d` 随机渲染异常调查 / 技术细节参考 | `E-006d-GenshinRenderingNondeterminism.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL / corpus 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| 离线 replay / batch compile / diff 工具链 | `E-005-OfflineReplayBatchCompileDiff.md` |
| Library API 入口与覆盖优先级 | `E-002-MTLDevice-Library-API.md` |
| swizzle 骨架与 hook 覆盖面 | `E-003-LibrarySwizzleSkeleton.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
