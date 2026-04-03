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

- **E-004（下一步：`E-004f1` 成功路径全量导出 corpus）**：当前阶段的最高优先级是把真实运行中加载到的 shader **系统性沉淀为离线 corpus**。目标导出物至少包括：`.bc`、`.ll`、`.metal`、manifest（模块偏移 / 大小 / 函数名 / 选择器 / bundleId / 时间戳 / 编译结果）。
- **E-005（下一步：`E-005f1` corpus replay runner）**：建立面向 corpus 的离线回放与批量编译验证工具，让 `IRToMSLConverter` 的日常回归稳定落在“离线 replay + batch compile”。
- **E-006（下一步：`E-006b1` 离线批量 green 后再做最小 live）**：live 保留为**扩覆盖**与**最终真实验证**环节，只在离线结果已经收敛后再投入。

## 最新基线

| 样本 / 基线 | 结论 |
|---|---|
| 流程基线（2026-04-03，offline-first 切换完成） | Road E 的日常迭代主回路已经明确为 **采集 corpus → 离线 replay → 批量编译 → 最小 live 复测 → `.gputrace` 最终确认** |
| 原神 6.4.0（最近一轮 live 基线） | 已确认 `ShaderSourceDiagnostics`、host bridge 与 runtime 注入主路径可用；真实 app 仍是 corpus 的生产来源与最终验证环境 |
| 当前落盘能力 | 失败的 MSL 会进入 `ShaderSourceDiagnostics/`；异常 payload 会进入 `ShaderPayloadSamples/`；**成功路径的 `.bc/.ll/.metal` 目前尚未系统持久化**，这是本阶段最高优先级缺口 |
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

> 当前最高优先级：`E-004f1`（成功路径全量导出 corpus）。历史 live blocker 归因链路见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

| # | 任务 | 状态 | 子文档 |
|---|---|---|---|
| E-001 | **可行性 PoC：`-frecord-sources` 重编译验证** | ✅ DONE | [E-001-PoC](E-001-PoC-frecord-sources.md) |
| E-002 | **调研 `MTLDevice` Library API 入口** | ✅ DONE | [E-002-API](E-002-MTLDevice-Library-API.md) |
| E-003 | **makeLibrary swizzle 骨架** | ✅ DONE | [E-003-Swizzle](E-003-LibrarySwizzleSkeleton.md) |
| E-004 | **metallib → bitcode / IR / MSL 采集与导出** | 🔄 IN PROGRESS | [E-004](E-004-MetallibSourceExtraction.md) |
|  | `E-004a–e` 已完成基础链路；当前主线切换为 **corpus 导出优先** | | |
| E-004f | ↳ 成功路径全量导出 corpus | 🔄 IN PROGRESS | |
| E-004f1 | ↳ 成功路径保存 `.bc/.ll/.metal/.json` | TODO | |
|  | 在 `attemptLibraryReplacement(...)` 成功路径落盘每个 module 的 bitcode、IR、转换后的 MSL 与 manifest；不再只有失败 diagnostics 才有文件可查 | | |
| E-004f2 | ↳ corpus 目录结构、去重键与 manifest 规范 | TODO | |
|  | 以 `bundleId + selector + cacheKey + module(offset,size)` 组织样本，避免重复写入；manifest 至少记录函数名、函数类型、时间戳、编译结果、错误摘要 | | |
| E-004f3 | ↳ 扩展 `makeLibrary(URL/default/file)` 路径的采集覆盖 | TODO | |
|  | 当前只有 `newLibraryWithData:error:` 真正进入 bitcode 提取主路径；需评估是否把 URL / default / file 路径也接入统一 corpus 导出 | | |
| E-005 | **离线 replay / batch compile / diff 工具链** | 🔄 IN PROGRESS | |
| E-005a | ↳ `IR -> MSL` 离线回放 runner | TODO | |
|  | 输入 corpus 中的 `.ll`，稳定输出 `.metal`，用于脱离原神的日常回归 | | |
| E-005b | ↳ 批量 Metal 编译与失败报告 | TODO | |
|  | 对 corpus 批量执行编译，输出按错误模式聚类的报告，替代手工翻 diagnostics | | |
| E-005c | ↳ 新旧转换结果 diff / 回归基线 | TODO | |
|  | 对比不同版本 `IRToMSLConverter` 在同一 corpus 上的输出变化，防止修一个坏两个 | | |
| E-006 | **端到端验证：语义等价 + 可编译 + 截帧可见** | 🔄 IN PROGRESS | |
| E-006a | ↳ 扩展真实 corpus 覆盖面 | TODO | |
|  | 在进入新地图 / 新场景 / 新画质设置时追加采集，逐步逼近“尽量全”的真实 shader 集合 | | |
| E-006b | ↳ 离线批量 green 后做最小 live 复测 | TODO | |
|  | 只在一组 blocker 通过 corpus replay + batch compile 后，再执行 `build_and_install.sh` + 重注入 + 最小 live 验证 | | |
| E-006c | ↳ 最终 `.gputrace` 源码可见确认 | TODO | |
|  | 用 Xcode 打开真实 `.gputrace`，确认关键 Draw Call 的 shader 面板可见源码 | | |
| E-007 | **PlayCover settings / MCP / 工具暴露** | TODO | |
|  | 为 corpus 导出 / replay 增加 UI 或 MCP 能力，使后续采集与回放不依赖手工路径操作 | | |

## 踩坑与经验

- **核心原则：优先沉淀成功样本，再去扩 lowering**：失败的 `.metal` 已经会写入 `ShaderSourceDiagnostics/`，异常 payload 已有 `ShaderPayloadSamples/`，但成功路径还没有统一的 `.bc/.ll/.metal/.json` corpus；在这个缺口补上之前，继续靠 live 追新 blocker 的收益会持续偏低
- **最终目标不变，但日常主回路必须切到离线**：live 负责采集和最终验证，不适合作为日常 blocker 归因与回归主路径
- **`test-data/` 和 `ShaderCorpus/` 不能混用**：`test-data/` 是手工构造的最小样本，适合验证单个 lowering；`ShaderCorpus/` 是真实运行时样本，适合批量 replay、diff 与回归基线
- **`newLibraryWithData:error:` 是当前最可靠的真实采集入口**：其他 `URL/default/file` 路径已 hook 但目前主要是日志；若要提高 corpus 覆盖率，需要把这些路径逐步纳入统一导出逻辑
- **`build_and_install.sh` 是更新运行时 framework 的唯一可靠路径**：`sync_playtools_xcframework.sh` 只更新构建产物；涉及 live 时必须 `build_and_install.sh`，否则注入的还是旧 framework
- **多 module 聚合仍要坚持“全成全退”**：所有 module 都能完成 `llvm-dis + IRToMSLConverter` 且聚合后无重名时才重编译；否则整体 fallback，避免部分替换把问题混淆
- **离线 replay 可以替代大部分回归，但不能替代最终真实渲染验证**：`IR -> MSL -> Metal 编译` 只能证明“更接近正确”，不能替代真实 GPU 渲染、时序与 `.gputrace` 可见性的最终确认
- **IR metadata 仍是精确类型信息的主要来源**：opaque pointer 模式下，很多参数/返回类型只能从 `!air.vertex` / `!air.fragment` / `!air.kernel` metadata 恢复
- **已知坏 MSL 不要继续盲编译**：preflight、batch compile 和 diagnostics 的价值，是把问题从“运行时崩溃”前移到“可离线定位的源码问题”
- **更细的 lowering 经验、历史 live blocker 链路与已完成轮次见 archive**：主文档只保留当前仍影响决策的流程性经验

## 参考信息

| 主题 | 位置 |
|---|---|
| dashboard 历史归档：live blocker 时间线 / 已完成轮次 | `00-Dashboard-Archive.md` |
| `-frecord-sources` PoC 与关键否定结论 | `E-001-PoC-frecord-sources.md` |
| metallib / bitcode / llvm-dis / IR→MSL / corpus 主实现记录 | `E-004-MetallibSourceExtraction.md` |
| Library API 入口与覆盖优先级 | `E-002-MTLDevice-Library-API.md` |
| swizzle 骨架与 hook 覆盖面 | `E-003-LibrarySwizzleSkeleton.md` |
| Metal 编译流水线 | `../Research/03-Metal-Shader编译流水线.md` |
| `.gputrace` 内部结构 | `../Research/02-gputrace内部结构分析.md` |
| PlayCover 组件安装目录 | `~/Library/Containers/io.playcover.PlayCover/` |
