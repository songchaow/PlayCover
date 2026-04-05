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
   - 最终截帧效果：live + `.gputrace` 人工确认
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息下沉到归档，主体保持简洁，**不要只做追加**
7. 整理代码与改动内容；若本轮新增的测试样本、回放脚本或 corpus 工具对后续仍有价值，也应一并整理并提交
8. 收尾完成后执行 `git commit`

> **严禁对着最终目标死磕，每个 agent 只完成一个任务。**

## 验证方式

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

若本轮目标是 `E-006d`（重复启动画面不一致 / 随机渲染异常），除常规部署外，还应尽量保持**同一 app 版本、同一场景、同一停留界面、相同画质设置**，至少做 2~3 轮对照启动；并增加一组**不做替换**的稳定对照。每轮都保留 `manifest.jsonl` 增量、`ShaderCorpus/` 新增模块、`ShaderSourceDiagnostics/` 新文件、聚合 MSL 与 `.gputrace`，用于比较“输入是否相同、生成源码是否相同、是否真的发生替换、替换与不替换时的最终效果差异是否稳定存在”。

### 最终验证（保留）

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。若当前处理的是 `E-006d`，还需补充确认：在同一界面重复启动时，相关 Draw Call 的 shader 来源、render pass 行为与视觉结果是否保持一致；并对照**替换**与**不替换**两种运行方式的最终效果差异。

## 当前主线

- **E-006d（当前最高优先级）**：调查“用 PlayCover 打开原神，在同一界面重复启动时，画面表现每次都不完全一样；mesh 不变，但局部渲染结果异常”的现象。当前**不能实锤是 shader 改坏**：因为原神是延迟管线，base pass 对比看起来也可能类似，异常也可能来自后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置差异。当前最保守的稳定结论只有：**进行了反编译/重编译替换**与**完全不做替换**时，最终效果确实不一样；后续需围绕这个稳定对照继续逐层归因。
- **当前最该做的事**：不是继续扩 lowering，也不是继续证明“源码可见”，而是用现有 `E-006d1 ~ E-006d7` 工具，先形成一组**replacement=off / on 各 2~3 轮**的稳定 run 矩阵，并把结论收敛到“输入漂移 / 输出漂移 / 替换命中漂移 / 更后续 render pipeline 差异”四类之一。
- **当前执行口径**：dashboard 只保留“现在最该做什么、做到什么算推进、有哪些基线已经可直接复用”；`E-006d-GenshinRenderingNondeterminism.md` 负责承载当前主线的详细判断路径与技术细节。
- **E-006c（✅ 已关闭，但仅作为里程碑基线）**：Xcode 人工确认 `capture_20260404_roadE_e006c3_final.gputrace` 中 Draw Call shader 面板可见 MSL 源码，说明“源码可见”链路已打通；但后续仍需对“渲染是否稳定正确”继续验证。
- **E-006a（扩展真实 corpus 覆盖面）** / **E-007（UI/MCP 工具暴露）**：仍保留，但在 `E-006d` 完成根因归因前暂不作为最高优先级。

## 最新基线

| 样本 / 基线 | 结论 |
|---|---|
| 流程基线（2026-04-03，offline-first 切换完成） | Road E 的日常迭代主回路已经明确为 **采集 corpus → 离线 replay → 批量编译 → 最小 live 复测 → `.gputrace` 最终确认** |
| 当前落盘能力（2026-04-05，`E-006d2` 后） | 成功路径按 `ShaderCorpus/<bundleId>/modules/<moduleKey>/` 落盘单模块 `.bc/.ll/.metal/.meta.json`，并新增 `ShaderCorpus/<bundleId>/replacements/<timestamp>_<selector>_<cacheKey>/aggregate.generated.metal + replacement.meta.json` 记录成功聚合替换产物；失败路径在 `ShaderSourceDiagnostics/<baseName>_modules/<moduleKey>/` 落盘 `.bc/.ll/.metal/.meta.json`；三条路径均可进入 `E-006d` 离线 diff / replay 主路径 |
| 当前最小离线验证基线（2026-04-04，`E-006c3` 后） | `test-data/*.ll`（19 个，含新增 `test_struct_array_field.ll`）replay + compile **全部成功**；`ShaderCorpus/com.miHoYo.Yuanshen/modules/` 全部 **91 个**真实 module replay + compile **91/91 成功**，preflight rejected `0`，regression `0` |
| 当前构建验证基线（2026-04-04，`E-006c3` 后） | `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`（**BUILD SUCCEEDED**）；`./BuildScripts/build_and_install.sh`（**BUILD SUCCEEDED**，签名验证通过） |
| 当前 live 验证状态（2026-04-04，第三次 fresh capture，PID 26460） | `remove_playtools → inject_playtools → launch_app → create_session`：session 返回 `ready` 并保持稳定；manifest 从 304 → 394 行（+90 条），corpus 从 43 → **91 模块**（+48 个全新成功样本），diagnostics 文件数不变（18），**本轮零失败样本** |
| 当前 `.gputrace` 源码可见性检查（2026-04-04，`E-006c` 已关闭） | `capture_20260404_roadE_e006c3_final.gputrace`（765 文件，968 index 引用）：`valid_msl_files: 2`（两个 PlayTools 注入的 MSL 文件，首行 `// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection`，包含完整 `#include <metal_stdlib>` 与结构体/函数定义）。**Xcode 人工确认：Draw Call shader 面板可见 MSL 源码**。覆盖率 2/11（18%）source 文件为 MSL，其余为 bplist（原始 metallib）。
| 当前异常基线（2026-04-05，`E-006d` 新开） | 用 PlayCover 打开原神并停留在**同一界面**时，重复启动后画面表现会出现差异；**mesh 布局没有变化**，但局部渲染结果异常。当前仍**不能实锤是 shader 本身改坏**：由于原神是延迟管线，base pass 对比看起来也可能类似，问题也可能位于后处理、着色阶段，或 render pipeline 顺序 / 配置。当前最稳定的复现对照，是**做替换**与**不做替换**时最终效果稳定不同；该现象尚未完成更细的层级归因。 |
| 当前控制面基线（2026-04-05，`E-006d3` 后） | 已新增 `shaderSourceReplacementEnabled` runtime 开关：关闭后 `PlayTools` 在 `LibrarySourceInjectionSwizzles` 入口直接返回原始 `MTLLibrary`，不再进入 `IR -> MSL -> makeLibrary(source:)` 替换链路；可用 `python3 Scripts/set_shader_replacement_mode.py --bundle-id <bundleId> --mode on/off` 直接切换单 app 的“替换 / 不替换” live 对照模式。 |
| 当前 run 固化基线（2026-04-05，`E-006d7` 后） | `Scripts/snapshot_capture_run.py` 现可在原有 `manifest.jsonl + modules/ (+ replacements/) + diagnostics + app settings` 快照基础上，额外通过 `--gputrace /path/to/xxx.gputrace` 一并固化最终截帧，并写出 `gputrace-source-summary.json`、`gputrace-attribution-index.json` 与 `snapshot.meta.json.gputraceAttribution` 摘要；`Scripts/compare_capture_runs.py` 的 `snapshotComparison` 也会同步比较 `attributedVisibleMSLHashes`、`attributedModuleKeys`、`attributedReplacementDirectories` 与 `visibleMSLContentSHA256`，把最终 trace 中可见源码直接回连到 `modules/` 与 `replacements/`。 |
| 当前下一步（2026-04-05，`E-006d8` 待执行） | 用已落地的 `set_shader_replacement_mode.py + snapshot_capture_run.py + analyze_capture_run_matrix.py + compare_capture_runs.py`，先形成 **replacement=off / on 各 2~3 轮**的稳定矩阵；完成标准不是再加新工具，而是输出“同模式是否稳定、跨模式是否稳定不同，以及第一层明确归因落点”。 |
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

> **当前 TODO 口径**：这里只保留“现在最该做什么”和“各已完成子项产出了什么能力”；更细的技术细节、判断顺序与历史问题链路统一下沉到 `E-006d-GenshinRenderingNondeterminism.md`、`E-004-MetallibSourceExtraction.md`、`E-005-OfflineReplayBatchCompileDiff.md` 与 archive。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | ✅ DONE | [E-004](E-004-MetallibSourceExtraction.md) |
| E-004f | ↳ corpus 导出与闭环策略 | ✅ DONE | |
| E-004f1 | ↳ 成功路径保存 `.bc/.ll/.metal/.json` | ✅ DONE | |
| E-004f2 | ↳ corpus 目录结构、去重键与 manifest 规范 | ✅ DONE | |
| E-004f3 | ↳ 扩展 `makeLibrary(URL/default/file)` 路径的采集覆盖 | ✅ DONE | |
| E-004f4 | ↳ 失败样本闭环：`compile_failed` 样本的 re-capture / 导出策略 | ✅ DONE | [E-004f4-Closure](E-004-CorpusClosureAndRecapturePolicy.md) |
| E-005 | **离线 replay / batch compile / diff 工具链** | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-005a | ↳ `IR -> MSL` 离线回放 runner | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-005b | ↳ 批量 Metal 编译与失败报告 | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-005c | ↳ 新旧转换结果 diff / 回归基线 | ✅ DONE | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | ✅ DONE（源码可见里程碑） | |
| E-006d | ↳ 调查原神同一界面重复启动时的随机渲染异常 / shader 语义漂移 | TODO | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
| E-006d1 | ↳ 两轮采集输入/输出一致性离线对比工具 | ✅ DONE | |
| E-006d2 | ↳ 成功替换聚合 MSL 落盘 + run-vs-run 聚合 diff | ✅ DONE | |
| E-006d3 | ↳ “替换 vs 不替换” runtime 开关与 plist 切换脚本 | ✅ DONE | |
| E-006d4 | ↳ 单次 run 快照固化脚本 | ✅ DONE | |
| E-006d5 | ↳ run 快照补齐 `.gputrace` 固化与 trace-level diff 摘要 | ✅ DONE | |
| E-006d6 | ↳ 多轮 run 矩阵汇总脚本 | ✅ DONE | |
| E-006d7 | ↳ `.gputrace` 可见源码归因索引 | ✅ DONE | |
| E-006d8 | ↳ replacement=off/on 多轮矩阵结论与第一层归因 | TODO | [E-006d](E-006d-GenshinRenderingNondeterminism.md) |
|  | 目标：先拿到 **off / on 各 2~3 轮**稳定 run 快照，输出矩阵结论（同模式是否稳定、跨模式是否稳定不同），并把下一层工作明确收敛到“输入漂移 / 输出漂移 / 替换命中漂移 / 更后续 pipeline 差异”之一 | | |
| E-006a | ↳ 扩展真实 corpus 覆盖面 | TODO | |
|  | 在进入新地图 / 新场景 / 新画质设置时追加采集，逐步逼近"尽量全"的真实 shader 集合 | | |
| E-006b | ↳ 离线批量 green 后做最小 live 复测 | ✅ DONE | |
| E-006b1 | ↳ 收敛 metadata 缺失导致的"缺参未声明" compile blocker | ✅ DONE | |
| E-006b2 | ↳ 收敛 metadata / shader type / resource kind 识别不足的 compile blocker | ✅ DONE | |
| E-006b3 | ↳ 收敛 texture access qualifier / write 参数顺序 compile blocker | ✅ DONE | |
| E-006b4 | ↳ 收敛 `___metal_fast_*` intrinsic fast 前缀 compile blocker | ✅ DONE | |
| E-006b5 | ↳ 收敛 load/store signedness mismatch compile blocker | ✅ DONE | |
| E-006b6 | ↳ 收敛 builtin 参数 IR/MSL 类型不匹配 compile blocker | ✅ DONE | |
| E-006b7 | ↳ 收敛 GEP/load 类型缩窄 compile blocker | ✅ DONE | |
| E-006b8 | ↳ 收敛 `filterTextureArgs` 误过滤 compile blocker | ✅ DONE | |
| E-006b9 | ↳ 收敛 `metal::_atomic` 类型支持 compile blocker | ✅ DONE | |
| E-006c | ↳ 最终 `.gputrace` 源码可见确认 | ✅ DONE | |
|  | `capture_20260404_roadE_e006c3_final.gputrace` 中已有 2 个 valid MSL 文件（PlayTools 注入），离线回归全绿；**Xcode 人工确认 Draw Call shader 面板显示 MSL 源码（2026-04-04）** | |
| E-006c1 | ↳ 修复多模块 metallib 重复函数名导致替换静默失败 | ✅ DONE | |
| E-006c2 | ↳ 修复 metadata 字段类型与 IR 结构体类型不一致的数组字段（IR 交叉检查） | ✅ DONE | |
| E-006c3 | ↳ post-fix fresh capture 入 corpus 确认 + 新 blocker 修复 | ✅ DONE | |
|  | post-fix fresh capture 已闭环：新增结构体类型名一致性与数组字段 `elementCount` 修复；corpus 43 → 91，manifest 304 → 394，零失败样本，`valid_msl_files = 2`。更细的 blocker 细节见 archive / `E-006d-GenshinRenderingNondeterminism.md`。 | |
| E-007 | **PlayCover settings / MCP / 工具暴露** | TODO | |
|  | 为 corpus 导出 / replay 增加 UI 或 MCP 能力，使后续采集与回放不依赖手工路径操作 | | |

## 踩坑与经验

- **核心原则：优先沉淀成功样本，再去扩 lowering**：失败的 `.metal` 已经会写入 `ShaderSourceDiagnostics/`，异常 payload 已有 `ShaderPayloadSamples/`；成功路径会把 canonical `.bc/.ll/.metal/.json` 写入 `ShaderCorpus/`，并通过 `manifest.jsonl` 记录 capture 事件，后续应优先围绕这些真实样本做 replay、diff 和回归，而不是重新回到高成本 live 试错
- **当前 `ShaderCorpus/` 不是"所有 live 样本"的同义词**：它目前只覆盖成功替换样本；`ShaderSourceDiagnostics/` 中的 `compile_failed` live 样本，如果未额外 re-capture 或补 `.bc/.ll` 导出，并不会自动进入离线回归主路径
- **修复来源于 diagnostics 的 blocker 后，不能只看既有 corpus green**：若该样本从未进入 `ShaderCorpus/`，修复完成后必须补一次 post-fix fresh capture，或（`E-004f4` 后）直接对 `ShaderSourceDiagnostics/<baseName>_modules/` 中的 `.ll` 做离线 replay + compile 验证；否则只能证明"现有 corpus 无退化"，不能证明"新样本已闭环"
- **`moduleKey` 与 `cacheKey` 分层使用**：`moduleKey = sha256(module.bc)` 是长期稳定的 module 级去重键；`cacheKey` 只用于 metallib 级上下文与运行时缓存，不能再拿来当持久化目录主键
- **最终目标不变，但日常主回路必须切到离线**：live 负责采集和最终验证，不适合作为日常 blocker 归因与回归主路径
- **`test-data/` 和 `ShaderCorpus/` 不能混用**：`test-data/` 是手工构造的最小样本，适合验证单个 lowering；`ShaderCorpus/` 是真实运行时样本，适合批量 replay、diff 与回归基线
- **`newLibraryWithData:error:` 仍是当前最可靠的真实采集入口，但已不再是唯一入口**：`URL/default/file` 代码路径现已接入统一导出逻辑；其中 default 路径当前通过 bundle 显式名称 + `.metallib` 资源扫描保守定位，后续仍需结合真实 app 命中情况继续做最小 live 验证
- **`build_and_install.sh` 是更新运行时 framework 的唯一可靠路径**：`sync_playtools_xcframework.sh` 只更新构建产物；涉及 live 时必须 `build_and_install.sh`，否则注入的还是旧 framework
- **`valid_msl_files=0` 是 `E-006c` 的快速失败信号**：对现有 `.gputrace` 批量跑 `Scripts/check_gputrace_sources.py` 时，如果 `valid_msl_files` 全为 `0`，就不要把"Xcode 能打开 / 能步进"误判成"源码已可见"；前者只说明 trace 结构可分析，后者仍取决于 library 替换是否真的把可读 MSL 带进 trace
- **`session ready` 不是"capture-ready 且稳定"的充分条件**：`2026-04-04` 这轮 fresh 原神复测里，`create_session` 先返回 `ready`，但紧接着变为 `disconnected`，并新增 `Yuanshen-2026-04-04-015803.ips`（`EXC_BAD_ACCESS / SIGSEGV`）；因此 live 收尾仍要同时核对 session 状态、capture 目录和 `DiagnosticReports`
- **多 module 聚合仍要坚持"全成全退"**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **离线 replay 可以替代大部分回归，但不能替代最终真实渲染验证**：`IR -> MSL -> Metal 编译` 只能证明"更接近正确"，不能替代真实 GPU 渲染、时序与 `.gputrace` 可见性的最终确认
- **已知坏 MSL 不要继续盲编译**：preflight、batch compile 和 diagnostics 的价值，是把问题从"运行时崩溃"前移到"可离线定位的源码问题"
- **failure cluster 报告比手翻 diagnostics 更适合作为日常 blocker 看板**：`compile-summary.json` 现在会同时保留 `clusterKey`、`primaryDiagnostic` 与局部 `sourceContext`，优先按簇归因，再回到单样本源码查看细节
- **E-005c 的 baseline 应保存"结果 + 生成源码"双份快照**：仅保存 `replay-summary.json` 不足以做稳定 MSL diff；当前 `baseline.json + generated-sources/` 的组合既能比较 replay / compile 状态，也能对归一化后的 generated MSL 做哈希与 unified diff
- **离线回归的失败判定要把"回归"与"当前失败"分开**：当前 runner 会在 replay / compile 失败时返回非 0，也会在与 baseline 对比发现 regression 时返回非 0；前者适合新功能验证，后者适合已有 corpus 的防退化守门
- **源码可见不等于渲染语义正确**：`E-006c` 已证明 `.gputrace` 中能看到 MSL，但 `E-006d` 关注的是“同一输入是否在重复启动下保持同一视觉结果”；两者必须分开验收
- **当前最保守的稳定对照是“替换 vs 不替换”**：在还不能实锤具体根因位于哪个 pass / stage 之前，先确认“做替换”和“完全不做替换”时的最终效果是否稳定不同，这是 `E-006d` 最低风险的比较基线
- **“不做替换”对照必须复用统一开关**：`E-006d3` 后统一通过 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py` 控制，避免因手工改代码、临时删逻辑或脏 plist 导致对照本身不可靠
- **run 快照也必须统一固化方式**：`E-006d5` 后统一通过 `Scripts/snapshot_capture_run.py` 保留单次 run 的 `manifest.jsonl` / `modules/` / `replacements/` / diagnostics / app settings；若本轮已有 `.gputrace`，也应通过 `--gputrace` 一并纳入同一快照，避免把 replacement 开关状态、聚合产物与最终 trace 证据混淆
- **`.gputrace` 可见源码现在需要继续看“归因是否闭环”**：`E-006d7` 后不只看 `validMSLFiles` 或 hash 集合是否变化，还要看 `gputrace-attribution-index.json` 是否已把这些可见 MSL 回连到 `module.generated.metal` 或 `aggregate.generated.metal`；若可见 hash 无法归因，说明最终 trace 证据与 corpus / replacement 侧仍未闭环
- **多轮对照要先看矩阵结论，再下钻单对 run**：`E-006d6` 后优先用 `Scripts/analyze_capture_run_matrix.py` 汇总 `2~3` 轮 `replacement=off/on` 快照，先回答“同模式是否稳定、跨模式是否稳定不同”；只有矩阵层已形成稳定结论时，才继续回到 `Scripts/compare_capture_runs.py` 下钻单对 run 差异
- **同一界面重复启动出现差异时，不要过早收敛为 shader root cause**：当前已知现象是 mesh 不变，但原神为延迟管线；base pass 看起来类似并不能排除后处理、着色阶段，或 render pipeline 顺序 / 配置差异
- **`E-006d` 的归因顺序必须固定**：先做“替换 vs 不替换”稳定对照，再对齐“输入是否相同”（metallib / moduleKey / functionTypes），再比较“输出是否相同”（单模块 `.metal` / 聚合 MSL / compile 结果），最后才看“运行时是否真的使用了替换后的 library”以及更后续的 pass / pipeline 行为
- **`Scripts/compare_capture_runs.py` 是 `E-006d` 的第一层离线守门**：当两轮都已保留 `manifest.jsonl` 与 `modules/` 快照时，优先先跑该脚本，快速回答“哪些 `moduleKey` 只出现在单边”“相同 `moduleKey` 的 `.bc/.ll/.metal/.meta` 是否一致”，避免一上来就手翻 corpus 或直接回到 live 猜测
- **`E-006d` 不能只盯单模块 `.metal`**：成功替换是否稳定，还要保留并比较每轮的聚合 `aggregate.generated.metal`；否则即使单模块输出一致，也无法快速回答聚合顺序、去重结果或最终替换源码是否漂移
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
