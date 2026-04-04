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
   - 保存成功与失败样本，形成 corpus
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
   - runtime 导出链路：构建 + 安装 + 最小 live 采集
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

### 最终验证（保留）

**自动检查**：

```bash
Scripts/check_gputrace_sources.py /path/to/xxx.gputrace
```

脚本位置：`Scripts/check_gputrace_sources.py`

**注意**：hash 文件不全是源码——原神样本中的 hash 文件是 bplist，必须以 `valid_msl_files` 而非 `source_files` 为准。

**人工确认（最终）**：Xcode 打开 `.gputrace` → 选 Draw Call → 查看 Shader 面板是否显示源码而非 `Shader source not found`。

## 当前主线

- **E-006（本轮执行：`E-006b5` load/store signedness mismatch bitcast）**：`IRToMSLConverter` 新增指针元素类型追踪（`pointerElementTypes`）并在 `translateLoad`/`translateStore` 中自动检测 signedness mismatch（如 `int4` vs `uint4`），插入 `as_type<>()` bitcast。LLVM IR 的 `i32` 无 signedness，MSL 的 `int4`/`uint4` 是不同类型；从 `device uint4*` 加载到 `<4 x i32>` 变量、或将 `<4 x i32>` 值存储到 `device uint4*` 时需要显式 bitcast。`test-data/*.ll` 回归：replay `18/18` 成功、Metal compile `14/18` 成功（上一轮 `13/18`，improvement `+1`，regression `0`）：`test_casts.ll` 从 `cannot initialize a variable of type 'int4' with an lvalue of type 'device uint4'` 提升为 compile success。
- **E-004（已完成：`E-004f3` 扩展 `makeLibrary(URL/default/file)` 路径的采集覆盖）**：`newLibraryWithURL:error:`、`newDefaultLibrary`、`newDefaultLibraryWithBundle:error:`、`newLibraryWithFile:error:` 现已读取 `.metallib` 并复用统一的 `bitcode -> IR -> MSL -> makeLibrary(source:) -> ShaderCorpus` 主链路；default 路径额外加入了 bundle 内 `.metallib` 的保守定位策略。
- **E-005（已完成：`E-005c` 新旧转换结果 diff / 回归基线）**：`Scripts/corpus_replay_runner.py` 现已支持保存 baseline snapshot、比较新旧 replay / compile 结果、输出 `baseline-diffs/` 与结构化回归统计；日常离线回归已经具备"改前 vs 改后"防退化能力。

## 最新基线

| 样本 / 基线 | 结论 |
|---|---|
| 流程基线（2026-04-03，offline-first 切换完成） | Road E 的日常迭代主回路已经明确为 **采集 corpus → 离线 replay → 批量编译 → 最小 live 复测 → `.gputrace` 最终确认** |
| 原神 6.4.0（最近一轮 live 基线） | 已确认 `ShaderSourceDiagnostics`、host bridge 与 runtime 注入主路径可用；真实 app 仍是 corpus 的生产来源与最终验证环境 |
| 当前落盘能力（2026-04-04） | 失败的 MSL 会进入 `ShaderSourceDiagnostics/`；异常 payload 会进入 `ShaderPayloadSamples/`；`attemptLibraryReplacement(...)` 成功路径现已按 `ShaderCorpus/<bundleId>/modules/<moduleKey>/` 落盘 canonical `module.bc`、`module.ll`、`module.generated.metal` 与 `module.meta.json`，并在根目录追加 `manifest.jsonl` 事件索引；`moduleKey` 由 `sha256(module.bc)` 生成，重复样本默认复用基线，不再静默覆盖；`newLibraryWithURL:error:`、`newDefaultLibrary`、`newDefaultLibraryWithBundle:error:`、`newLibraryWithFile:error:` 代码路径也已接入同一套导出与替换逻辑 |
| 当前离线 replay / batch compile / diff 能力（2026-04-03，`E-005a`/`E-005b`/`E-005c` 完成） | `Scripts/corpus_replay_runner.py` 现已支持扫描 `ShaderCorpus/` 或显式 `.ll`，读取 `module.meta.json` 中的 `functionNames/functionTypes` 做 `IRToMSLConverter.convert(...)`，并在 `--compile` 模式下继续输出 `.air`、`compile-summary.json`、逐样本 `primaryDiagnostic/sourceContext` 与 failure clusters；同时支持 `--save-baseline` 生成 `baseline.json + generated-sources/` 快照、`--baseline-report` 产出结构化 replay / compile / generated MSL 对比与 `baseline-diffs/`；`Scripts/ir_to_msl_smoketest.sh` 继续作为单样本兼容 wrapper |
| 当前最小离线验证基线（2026-04-04，`E-006b5` 完成） | 已对 `test-data/*.ll` 执行一轮 batch replay + compile：replay `18/18` 成功，Metal compile `14/18` 成功（上轮 `13/18`，improvement `+1`，regression `0`）。`test_casts.ll` 修复为 compile success（load/store signedness mismatch 自动插入 `as_type<>` bitcast）。剩余 4 个 compile blocker 为 body lowering 问题（GEP/load 类型缩窄、sample overload resolution），不属于 metadata / shader type / resource kind 识别范畴 |
| 当前构建验证基线（2026-04-04） | 已运行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 与 `PLAYCOVER_INSTALL_MODE=user ./BuildScripts/build_and_install.sh`（均 **BUILD SUCCEEDED**），PlayTools 标准构建链路、PlayCover Release 构建、安装与 ad-hoc 重签名均通过 |
| 当前最小 live 验证状态（2026-04-04） | PlayCover MCP 应用列表通道已恢复可用；已对原神 6.4.0 完成一次最小 live 复测：`remove_playtools`、`inject_playtools`、`launch_app` 成功，`create_session` 返回 `ready`（PID 98756，runtimePort 61205）；同时 `ShaderCorpus/com.miHoYo.Yuanshen/manifest.jsonl` 在 `2026-04-03T16:25:54Z`–`16:26:06Z` 追加了多条 `captureAction=conflict_preserved` / `selector=newLibraryWithData:error:` 事件，证明启动期已重新命中 hook 与 corpus 去重落盘链路。`2026-04-04 01:57` 再次 fresh `launch_app -> create_session(timeout=30)` 也曾返回 `ready`（PID 43383，runtimePort 61206），但很快转为 `disconnected`，且新增 `Yuanshen-2026-04-04-015803.ips`，说明 live 稳定性仍未收敛 |
| 当前 `.gputrace` 源码可见性检查（2026-04-04，`E-006c` 本轮执行） | 已对原神现存 6 份真实 trace 批量执行 `Scripts/check_gputrace_sources.py`：`valid_msl_files` 全部为 `0`；Xcode 可打开 `capture_20260402_roadE_e006_diag.gputrace` 并进入具体 draw call（`Command Buffer 1` / `Render Encoder 12` / draw call `7688`，`editor_mode=Bound Resources`，Step 菜单启用），因此当前结论是"trace 可开/可步进，但源码仍不可见" |
| 历史 live blocker 时间线 | 见 [00-Dashboard-Archive](00-Dashboard-Archive.md)；dashboard 主体不再重复堆叠逐轮 live 细节 |

## 整体架构

```text
PlayCover 主应用 (macOS)
  ├── LLVMToolManager
  │     → 下载/管理宿主 llvm-dis
  ├── RegistrationListener / MCPManager
  │     → 承接 injected runtime 的 host bridge 命令
  ├── 现有 diagnostics
  │     → ShaderSourceDiagnostics/   (失败的 .metal + .txt)
  │     → ShaderPayloadSamples/      (异常 payload)
  └── 目标：ShaderCorpus/
        → 成功 / 失败样本统一落盘为 .bc / .ll / .metal / manifest

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

> 当前最高优先级：`E-006c`（真实 `.gputrace` 源码可见确认）。`E-006b4` 已修复 `___metal_fast_*` intrinsic 映射（compile `13/18`）；剩余 compile blocker 均为 body lowering 问题。历史 live blocker 归因链路见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
|  | `E-004a–e` 已完成基础链路；当前主线切换为 **corpus 导出优先** | | |
| E-004f | ↳ 成功路径全量导出 corpus | 🔄 IN PROGRESS | |
| E-004f1 | ↳ 成功路径保存 `.bc/.ll/.metal/.json` | ✅ DONE | |
|  | `attemptLibraryReplacement(...)` 成功时已为每个 module 落盘 `module.bc`、`module.ll`、`module.generated.metal` 与 `module.meta.json`，后续回放不再只依赖失败 diagnostics | | |
| E-004f2 | ↳ corpus 目录结构、去重键与 manifest 规范 | ✅ DONE | |
|  | 已落地 `ShaderCorpus/<bundleId>/modules/<moduleKey>/`、`manifest.jsonl`、`moduleKey = sha256(module.bc)` 与"冲突不覆盖基线"的持久化策略；`cacheKey` 退回为 metallib 上下文信息 | | |
| E-004f3 | ↳ 扩展 `makeLibrary(URL/default/file)` 路径的采集覆盖 | ✅ DONE | |
|  | `newLibraryWithURL:error:`、`newDefaultLibrary`、`newDefaultLibraryWithBundle:error:`、`newLibraryWithFile:error:` 已在代码路径上接入统一 `bitcode -> IR -> MSL -> makeLibrary(source:) -> ShaderCorpus` 导出链路；default 路径当前通过 bundle 显式名称 + `.metallib` 资源扫描做保守定位 | | |
| E-005 | **离线 replay / batch compile / diff 工具链** | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
| E-005a | ↳ `IR -> MSL` 离线回放 runner | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
|  | 已落地 `Scripts/corpus_replay_runner.py`；支持扫描 `ShaderCorpus/`、读取 `manifest.jsonl` / `module.meta.json`、把 `functionNames/functionTypes` 传给 `IRToMSLConverter.convert(...)`，并稳定输出 replay `.metal` 与 `replay-summary.json`；`Scripts/ir_to_msl_smoketest.sh` 已改为兼容 wrapper | | |
| E-005b | ↳ 批量 Metal 编译与失败报告 | ✅ DONE | [E-005](E-005-OfflineReplayBatchCompileDiff.md) |
|  | `corpus_replay_runner.py` 已支持 `--compile`、`compile-summary.json`、`primaryDiagnostic/sourceContext`、failure clusters 与可选 preflight；`test-data/*.ll` 最小验证结果已更新为 replay `18/18` 成功、Metal compile `10/18` 成功 | | |
| E-005c | ↳ 新旧转换结果 diff / 回归基线 | ✅ DONE | |
|  | `corpus_replay_runner.py` 已支持 `--save-baseline` 保存 `baseline.json + generated-sources/` 快照、`--baseline-report` 进行 replay / compile / generated MSL 的结构化对比，并在发现回归时返回失败；同一批 `test-data/*.ll` 二次回放当前结果为 matched/new/removed `18/0/0`、replay changed `0`、generated MSL changed `0`、compile changed `0` | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | 🔄 IN PROGRESS | |
| E-006a | ↳ 扩展真实 corpus 覆盖面 | TODO | |
|  | 在进入新地图 / 新场景 / 新画质设置时追加采集，逐步逼近"尽量全"的真实 shader 集合 | | |
| E-006b | ↳ 离线批量 green 后做最小 live 复测 | ✅ DONE | |
|  | 已对 `com.miHoYo.Yuanshen` 完成一次 `remove_playtools + inject_playtools + launch_app + create_session` 最小 live；session 成功进入 `ready`，同时 `manifest.jsonl` 追加了 `captureAction=conflict_preserved` / `selector=newLibraryWithData:error:` 事件，确认启动期已再次命中 hook 与 corpus 去重链路 | | |
| E-006b1 | ↳ 收敛 metadata 缺失导致的"缺参未声明" compile blocker | ✅ DONE | |
|  | `IRToMSLConverter` 已改为只对函数体真实引用到的缺失 IR 值参数做显式签名补齐，并保守保留默认 builtin；`test_sample_compare_depth_2d.ll` 已从 `undeclared_identifier:param2` 提升为 compile success，最新 baseline compare 为 regression `0` / improvement `1` | | |
| E-006b2 | ↳ 收敛 metadata / shader type / resource kind 识别不足的 compile blocker | ✅ DONE | |
|  | `IRToMSLConverter` 已新增 `parseAttributeGroupDeclarations` 从 `attributes #N = { "air.fragment" ... }` 声明回退检测 shader 类型；新增 `parseOrphanedMetadataArgLookup` 扫描所有孤立 metadata arg 节点，按 `air.arg_name` 匹配 `air.texture` / `air.sampler` 并正确恢复为 `[[texture(N)]]` / `[[sampler(N)]]`；`generateAllParams` 为 fragment shader 的无 attribute value 参数自动添加 `[[color(N)]]`（从 1 开始避免与隐式输出冲突）。`test_metal_intrinsic_sampler_state.ll` 从 kernel 误判修复为 fragment，texture/sampler 正确识别；compile regression `0` | | |
| E-006b3 | ↳ 收敛 texture access qualifier / write 参数顺序 compile blocker | ✅ DONE | |
|  | `cleanTextureTypeName` 不再一刀切删除 access 限定符，改为将 AIR 的 `write`/`read`/`read_write` 正确映射为 `access::write`/`access::read`/`access::read_write`（仅省略默认 `access::sample`）；`generateMSLForAirCall` 对 `write` 方法交换前两个参数（AIR `(texture, coord, color)` → Metal `texture.write(color, coord)`）。`test_sample_compare.ll` 从 `no member named 'write'` 提升为 compile success，`test_builtins.ll` write 错误消除；compile improvement `+2`，regression `0` | |
| E-006b4 | ↳ 收敛 `___metal_fast_*` intrinsic fast 前缀 compile blocker | ✅ DONE | |
|  | `IRToMSLConverter.metalIntrinsicMappings` 中 `___metal_fast_*` 的 MSL 映射从 `fast_sin` 等改为同名标准函数 `sin` 等，与 `air.fast_*` 映射行为一致（Metal 标准库不提供 `fast_sin` 无前缀顶级函数）。`test_metal_intrinsic_sampler_state.ll` 从 `use of undeclared identifier 'fast_sin'` 提升为 compile success；compile improvement `+1`，regression `0` | | |
| E-006b5 | ↳ 收敛 load/store signedness mismatch compile blocker | ✅ DONE | |
|  | `IRToMSLConverter` 新增 `pointerElementTypes` 字典追踪指针元素类型（从参数 metadata 传播到 GEP），在 `translateLoad`/`translateStore` 中检测 signedness mismatch（如 `int4` vs `uint4`）并自动插入 `as_type<>()` bitcast。`test_casts.ll` 从 `cannot initialize a variable of type 'int4' with an lvalue of type 'device uint4'` 提升为 compile success；compile improvement `+1`，regression `0` | | |
| E-006c | ↳ 最终 `.gputrace` 源码可见确认 | TODO | |
|  | 本轮已完成一次真实检查：原神现存 6 份 `.gputrace` 的 `valid_msl_files` 均为 `0`；Xcode 可打开并步进，但尚未看到源码。待 live 稳定并解决当前 IR→MSL compile blocker 后，再做 fresh capture + Xcode 最终确认 | | |
| E-007 | **PlayCover settings / MCP / 工具暴露** | TODO | |
|  | 为 corpus 导出 / replay 增加 UI 或 MCP 能力，使后续采集与回放不依赖手工路径操作 | | |

## 踩坑与经验

- **核心原则：优先沉淀成功样本，再去扩 lowering**：失败的 `.metal` 已经会写入 `ShaderSourceDiagnostics/`，异常 payload 已有 `ShaderPayloadSamples/`；现在成功路径会把 canonical `.bc/.ll/.metal/.json` 写入 `ShaderCorpus/`，并通过 `manifest.jsonl` 记录 capture 事件，后续应优先围绕这些真实样本做 replay、diff 和回归，而不是重新回到高成本 live 试错
- **`moduleKey` 与 `cacheKey` 分层使用**：`moduleKey = sha256(module.bc)` 是长期稳定的 module 级去重键；`cacheKey` 只用于 metallib 级上下文与运行时缓存，不能再拿来当持久化目录主键
- **最终目标不变，但日常主回路必须切到离线**：live 负责采集和最终验证，不适合作为日常 blocker 归因与回归主路径
- **`test-data/` 和 `ShaderCorpus/` 不能混用**：`test-data/` 是手工构造的最小样本，适合验证单个 lowering；`ShaderCorpus/` 是真实运行时样本，适合批量 replay、diff 与回归基线
- **`newLibraryWithData:error:` 仍是当前最可靠的真实采集入口，但已不再是唯一入口**：`URL/default/file` 代码路径现已接入统一导出逻辑；其中 default 路径当前通过 bundle 显式名称 + `.metallib` 资源扫描保守定位，后续仍需结合真实 app 命中情况继续做最小 live 验证
- **`build_and_install.sh` 是更新运行时 framework 的唯一可靠路径**：`sync_playtools_xcframework.sh` 只更新构建产物；涉及 live 时必须 `build_and_install.sh`，否则注入的还是旧 framework
- **`session ready` + `manifest.jsonl` 新事件，是最小 live 已重新命中主链路的最低成本证据**：这轮原神复测中，即使还没进入 `.gputrace` 最终确认，`create_session` 返回 `ready`，且 `manifest.jsonl` 追加了 `captureAction=conflict_preserved` / `selector=newLibraryWithData:error:` 事件，已经足以证明注入、host bridge、hook 与 corpus 去重落盘链路重新贯通
- **`valid_msl_files=0` 是 `E-006c` 的快速失败信号**：对现有 `.gputrace` 批量跑 `Scripts/check_gputrace_sources.py` 时，如果 `valid_msl_files` 全为 `0`，就不要把"Xcode 能打开 / 能步进"误判成"源码已可见"；前者只说明 trace 结构可分析，后者仍取决于 library 替换是否真的把可读 MSL 带进 trace
- **`session ready` 不是"capture-ready 且稳定"的充分条件**：`2026-04-04` 这轮 fresh 原神复测里，`create_session` 先返回 `ready`，但紧接着变为 `disconnected`，并新增 `Yuanshen-2026-04-04-015803.ips`（`EXC_BAD_ACCESS / SIGSEGV`）；因此 live 收尾仍要同时核对 session 状态、capture 目录和 `DiagnosticReports`
- **多 module 聚合仍要坚持"全成全退"**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **离线 replay 可以替代大部分回归，但不能替代最终真实渲染验证**：`IR -> MSL -> Metal 编译` 只能证明"更接近正确"，不能替代真实 GPU 渲染、时序与 `.gputrace` 可见性的最终确认
- **IR metadata 仍是精确类型信息的主要来源**：opaque pointer 模式下，很多参数/返回类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 恢复
- **缺失值参数的 fallback 必须只覆盖"函数体真实引用到"的那部分**：把 metadata 漏掉的普通值参数一律塞进 entry signature，虽然能修掉 `undeclared_identifier`，但会在 fragment 样本里把未使用的隐式输入误补成显式参数（如 `test_fragment_depth_output.ll` 的 implicit color inputs）；本轮收敛后的策略是"仅补函数体真正引用到的缺失值参数，并继续保留默认 builtin 为 builtin"
- **已知坏 MSL 不要继续盲编译**：preflight、batch compile 和 diagnostics 的价值，是把问题从"运行时崩溃"前移到"可离线定位的源码问题"
- **failure cluster 报告比手翻 diagnostics 更适合作为日常 blocker 看板**：`compile-summary.json` 现在会同时保留 `clusterKey`、`primaryDiagnostic` 与局部 `sourceContext`，优先按簇归因，再回到单样本源码查看细节
- **E-005c 的 baseline 应保存"结果 + 生成源码"双份快照**：仅保存 `replay-summary.json` 不足以做稳定 MSL diff；当前 `baseline.json + generated-sources/` 的组合既能比较 replay / compile 状态，也能对归一化后的 generated MSL 做哈希与 unified diff
- **离线回归的失败判定要把"回归"与"当前失败"分开**：当前 runner 会在 replay / compile 失败时返回非 0，也会在与 baseline 对比发现 regression 时返回非 0；前者适合新功能验证，后者适合已有 corpus 的防退化守门
- **更细的 lowering 经验、历史 live blocker 链路与已完成轮次见 archive**：主文档只保留当前仍影响决策的流程性经验
- **Metal IR 的 shader 类型信息出现在三个位置，需要按优先级回退**：① `!air.vertex` / `!air.fragment` / `!air.kernel` 顶层 metadata（最可靠）② `attributes #N = { "air.fragment" ... }` 声明（某些合成/裁剪后的 IR 只有这个）③ 函数名/`inferShaderType` 启发式（最不可靠）。`inferShaderType` 会把 `void` 返回误判为 kernel，必须在前两步都无法确定时才使用
- **孤立 metadata arg 节点可以通过 `air.arg_name` 做 fallback 匹配**：某些 IR 中 `air.texture` / `air.sampler` 的 metadata arg 节点存在但未被函数的 args 列表引用；按 IR 参数名与 `air.arg_name` 做 name-based lookup 可以恢复 texture/sampler 类型
- **fragment shader 的无 attribute value 参数必须带 `[[color(N)]]`**：Metal 编译器会拒绝 "implicit color input declarations"。当 fragment 返回非 void 标量/向量类型时，隐式输出占用 `[[color(0)]]`，输入 value 参数的 color index 应从 1 开始
- **texture access qualifier 不能一刀切删除**：IR metadata 的 `air.arg_type_name` 可能携带 `texture2d<float, write>` 或 `texture2d<float, read>`；`cleanTextureTypeName` 必须保留 `access::write`/`access::read`/`access::read_write`，仅省略默认的 `access::sample`，否则 `write()`/`read()` 方法调用会因缺少 access qualifier 而编译失败
- **AIR 的 `write_texture_*` 参数顺序与 Metal 不同**：AIR 格式为 `(texture_ptr, coord, color, mip_level, ...)`，Metal 的 `texture.write()` 签名为 `write(color, coord)`，需要交换 coord 和 color 的顺序
- **`___metal_fast_*` 和 `air.fast_*` 的 MSL 映射必须统一去掉 `fast_` 前缀**：Metal 标准库不提供 `fast_sin` 等无前缀顶级函数；fast-math 语义由编译器选项（`-ffast-math`）控制，不应体现在生成的 MSL 函数名中。`air.*` 系统从设计上就做了 `air.fast_sin` → `sin` 的映射，`___metal_*` 系统也应保持一致
- **LLVM IR 的 `i32` 无 signedness，但 MSL 的 `int4`/`uint4` 是不同类型**：opaque pointer 模式下，`load <4 x i32>` 从 `device uint4*` 加载时，IR 的 `i32` 被 `irScalarTypeToMSL` 默认映射为 `int`（有符号），但指针的实际元素类型可能是 `uint`（无符号）。标量 signed/unsigned 可隐式转换，但向量类型不行。解决方案：在 `SSAContext` 中追踪 `pointerElementTypes`（从参数 metadata `air.arg_type_name` 获取，通过 GEP 传播），在 `translateLoad`/`translateStore` 中检测 signedness mismatch 并插入 `as_type<>()` bitcast

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 历史归档：live blocker 时间线 / 已完成轮次 | `00-Dashboard-Archive.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL / corpus 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| 离线 replay / batch compile / diff 工具链 | `E-005-OfflineReplayBatchCompileDiff.md` |
| Library API 入口与覆盖优先级 | `E-002-MTLDevice-Library-API.md` |
| swizzle 骨架与 hook 覆盖面 | `E-003-LibrarySwizzleSkeleton.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
