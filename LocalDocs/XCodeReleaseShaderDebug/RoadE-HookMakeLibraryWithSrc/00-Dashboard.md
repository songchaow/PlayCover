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

**补充约束（当前最高优先级）**：`E-006c` 证明".gputrace 中源码可见"已经打通，但这**不等于**"替换后的渲染结果已经稳定正确"。如果同一 app、同一界面、同一 mesh 布局下，多次启动仍出现随机渲染差异或局部异常，必须优先进入 `E-006d` 做**渲染一致性 / 非确定性归因**，不能再以"compile green"或"Xcode 能看到源码"作为阶段完成标准。当前最保守、最稳定的对照，不是直接认定"shader 改坏了"，而是比较**进行了反编译/重编译替换**与**完全不做替换**时的最终画面、draw call 行为与渲染链路差异。

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
open ~/Applications/PlayCover.app
remove_playtools / inject_playtools / launch_app
```

若本轮目标是 `E-006d`（重复启动画面不一致 / 随机渲染异常），除常规部署外，还应尽量保持**同一 app 版本、同一停留界面、相同画质设置**，至少做 2~3 轮对照启动；并增加一组**不做替换**的稳定对照。对原神当前链路，默认可把"启动后数十秒自动停在登录界面"视为稳定复现面：agent 可以独立完成 `launch_app`、等待进入该界面、执行 Metal capture / `.gputrace` 固化、保存 `manifest.jsonl` 增量、`ShaderCorpus/` 新增模块、`ShaderSourceDiagnostics/` 新文件与聚合 MSL；**不要求人工登录、选场景或手动把界面摆到指定位置**。只有当本轮问题明确依赖登录后场景、账号态或其它人工交互条件时，才需要额外人工介入并在文档中单独说明。

### 最终验证（保留）

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。若当前处理的是 `E-006d`，还需补充确认：在同一界面重复启动时，相关 Draw Call 的 shader 来源、render pass 行为与视觉结果是否保持一致；并对照**替换**与**不替换**两种运行方式的最终效果差异。除这一步外，前置的 live 启动、等待、截帧、快照固化与自动脚本分析都默认由 agent 独立完成。

## 当前主线

- **E-006d（当前最高优先级）**：调查"用 PlayCover 打开原神，在同一界面重复启动时，画面表现每次都不完全一样；mesh 不变，但局部渲染结果异常"的现象。详细判断路径、归因顺序与技术备注见 `E-006d-GenshinRenderingNondeterminism.md`。
- **E-006d8 四条 blocker（agent 可独立推进三条，一条需 GUI 环境）**：

| # | blocker | 状态 | 推进方式 |
|---|---|---|---|
| 1 | capture bridge reachability：`create_session(bundleId)` 仍可能超时，但已有 ready session 可直接执行 capture | 进行中 | 对照 `list_sessions` 现成 session 与 `create_session` 的选取 / probe 行为差异 |
| 2 | capture 输出路径：容器外自定义路径权限边界未明 | 短期绕过 | 继续用默认容器路径 + `--latest-gputrace` |
| 3 | trace 合法 MSL 覆盖偏低（`~3/12`） | 进行中 | 归因已有合法 MSL 对应的 draw call / replacement 路径 |
| 4 | 绘制内容差异未正式产出 | 工具就绪，需 GUI 环境 | `e006d_render_diff.py` 已就绪，需 Xcode GUI / Accessibility / `cliclick` |

- **绘制内容差异分支**：这条线依赖 Xcode GUI 环境、Accessibility 权限与 `cliclick`。**它是重要专项分析分支，不是默认日常 gate**。详细方法见 `E-006d-RenderingPathDiffReference.md`。
- **E-006c（✅ 已关闭）**：Xcode 人工确认 shader 面板源码可见，"源码可见"链路已打通。
- **E-006a / E-007**：在 `E-006d` 明确根因前暂不作为最高优先级。

## 最新基线

### 当前可复用的自动化能力（agent 全链路独立完成）

| 能力 | 工具 / 路径 |
|---|---|
| 日常构建验证 | `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`（PlayTools 编译） |
| 运行时部署 | `./BuildScripts/build_and_install.sh` → `inject_playtools` / `launch_app` |
| 离线 replay + compile + baseline diff | `Scripts/corpus_replay_runner.py --compile --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus` |
| replacement 模式切换 | `Scripts/set_shader_replacement_mode.py --mode off/on` |
| live run 快照固化 | `Scripts/e006d_matrix_runner.py prepare-run / finalize-run --latest-gputrace` |
| `.gputrace` 自动检查 | `Scripts/check_gputrace_sources.py /path/to/xxx.gputrace` |
| runtime launch 诊断 | `RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl` + `Scripts/runtime_launch_diagnostics_summary.py` |

### 关键数据基线

| 基线 | 结论 |
|---|---|
| 落盘与闭环能力 | 成功路径 → `ShaderCorpus/<bundleId>/modules/<moduleKey>/{.bc,.ll,.metal,.meta.json}`；replacement → `replacements/<timestamp>_<selector>_<cacheKey>/aggregate.generated.metal`；失败路径 → `ShaderSourceDiagnostics/<baseName>_modules/<moduleKey>/{.bc,.ll,.metal,.meta.json}`。三条路径均已进入离线 replay / diff / 归因主回路。详见 `E-004-CorpusClosureAndRecapturePolicy.md` |
| corpus 编译基线（2026-04-05） | `test-data/*.ll`（19 个）replay + compile **全绿**；`ShaderCorpus/com.miHoYo.Yuanshen/modules/` **91/91** replay + compile **全绿**，preflight rejected `0`，regression `0` |
| `.gputrace` 里程碑（2026-04-04） | `capture_20260404_roadE_e006c3_final.gputrace` Xcode 人工确认 shader 面板源码可见（`E-006c` 已关闭） |
| E-006d8 第一层矩阵（2026-04-06） | `off1/off2/on1~on9` 十一轮快照：**同模式输入稳定**、共享 `moduleKey=91/91`、单模块本体未漂移；`mode=on missingAttemptWhileEnabledPairs=13`；**尚未形成"跨模式稳定不同"证据** |

### 已完成的 session / capture 基础设施修复（2026-04-06，全部已落地 + 测试覆盖）

- host split-brain 修复（stale cleanup 同步断链）
- `create_session` 收紧到 bridge `ping` 成功
- `get_capture_status` 去 lazy-load + 去 `valueOnMainSync`
- 默认容器 `Captures/` 回收闭环（`--latest-gputrace`）
- 绘制内容差异 runner（`e006d_render_diff.py`，需 GUI 环境）

> 更细的修复历史见 `E-006d-GenshinRenderingNondeterminism.md` 技术备注与 [00-Dashboard-Archive](00-Dashboard-Archive.md)

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

> **优先级更新（2026-04-06）**：当前主线为 **`E-006d`：原神重复启动时的随机渲染异常归因**。在 `E-006d` 明确根因前，`E-006a` / `E-007` 均下调一级。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | ✅ DONE | [E-004](E-004-MetallibSourceExtraction.md) |
| E-005 | **离线 replay / batch compile / diff 工具链** | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | ✅ DONE | [Archive](00-Dashboard-Archive.md) |
| E-006d | **原神同一界面重复启动时的随机渲染异常归因** | **TODO（当前主线）** | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d1~d8a | ↳ 对照工具链 + 基础设施修复（全部已落地） | ✅ DONE | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d8 | ↳ 四条 blocker 收敛 | **TODO** | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d8b1 | ↳ 标准化 render-diff runner | ✅ DONE | [E-006d8b 参考](E-006d-RenderingPathDiffReference.md) |
| E-006d8b | ↳ 绘制内容差异结构对比 | **TODO**（需 GUI 环境） | [E-006d8b 参考](E-006d-RenderingPathDiffReference.md) |
| E-006a | ↳ 扩展真实 corpus 覆盖面 | TODO（已降级） | |
| E-007 | **PlayCover settings / MCP / 工具暴露** | TODO（已降级） | |

## 踩坑与经验

- **核心原则：优先沉淀成功样本，再去扩 lowering**：后续应优先围绕 `ShaderCorpus/`、`manifest.jsonl`、`replacements/` 与失败路径导出样本做 replay、diff 和回归，而不是重新回到高成本 live 试错
- **`test-data/` 和 `ShaderCorpus/` 不能混用**：`test-data/` 用于验证单个 lowering；`ShaderCorpus/` 用于真实样本的批量 replay、diff 与回归基线
- **`build_and_install.sh` 是更新运行时 framework 的唯一可靠路径**：`sync_playtools_xcframework.sh` 只更新构建产物；涉及 live 时必须走 `BuildScripts/build_and_install.sh`
- **源码可见 / compile green 都不等于渲染语义正确**：`E-006d` 关注的是相同输入下最终视觉结果、trace 与 replacement 证据是否稳定一致
- **当前最低风险的比较基线仍是"替换 vs 不替换"**：统一通过 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py` 控制
- **`E-006d` 的归因顺序必须固定**：先"替换 vs 不替换"对照 → 再对齐"输入是否相同" → 再比较"输出是否相同" → 最后看 runtime / render pipeline / post-processing 行为
- **session / capture 基础设施修复已全部落地 + 测试覆盖**：stale cleanup、`create_session` bridge ping、`get_capture_status` 去 lazy-load——详见 `E-006d-GenshinRenderingNondeterminism.md`
- **更细的 lowering 经验、历史 live blocker 链路与已完成轮次已下沉到独立参考文档**：见 `E-004-MetallibSourceExtraction-Archive.md`、`E-006d-RenderingPathDiffReference.md` 与 `00-Dashboard-Archive.md`

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 历史归档：live blocker 时间线 / 已完成轮次 | `00-Dashboard-Archive.md` |
| 失败样本闭环 / re-capture 策略参考 | `E-004-CorpusClosureAndRecapturePolicy.md` |
| `E-006d` 随机渲染异常调查 / 技术细节参考 | `E-006d-GenshinRenderingNondeterminism.md` |
| 绘制内容差异（draw call / render pass / pipeline）专项参考 | `E-006d-RenderingPathDiffReference.md` |
| Xcode GPU GUI 自动化工具说明 | `../../XCodeOperation/README.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL / corpus 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| 离线 replay / batch compile / diff 工具链 | `E-005-OfflineReplayBatchCompileDiff.md` |
| Library API 入口与覆盖优先级 | `E-002-MTLDevice-Library-API.md` |
| swizzle 骨架与 hook 覆盖面 | `E-003-LibrarySwizzleSkeleton.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
