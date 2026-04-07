## E-004: 将运行时 metallib 提升为可复用的离线 corpus

## 状态：✅ DONE（当前作为参考主文档保留）

> ⚠️ **E-004 已不再是当前最高优先级执行分支。** 相关能力已经成为 Road E 的稳定底座；当前主线与 TODO 以 `00-Dashboard.md` 为准。本文档保留为 corpus / extraction 能力的参考主文档。

## 目标

E-004 的目标已经从"证明可以在运行时做 metallib → IR → MSL"升级为：

1. 在真实 app 里稳定拦截 shader 加载
2. 从 metallib 提取可复用的 **bitcode / IR / MSL**
3. 将这些产物沉淀为宿主机可访问的 **离线 corpus**
4. 让后续大部分 `IRToMSLConverter` 修复都可以脱离原神、直接对 corpus 回放验证

**本阶段仍严格遵守主优先级**：
1. **语义等价**
2. **可编译**
3. **可读性**

## 为什么要转向 corpus 驱动

到目前为止，runtime 主链路已经打通：

```text
app 调 makeLibrary(...)
  ↓
hook 拦截 metallib / payload
  ↓
MetallibParser 提取 BitcodeModule
  ↓
LLVMDisassembler 反汇编为 IR
  ↓
IRToMSLConverter 生成 MSL
  ↓
makeLibrary(source:) 重编译替换
```

真正拖慢效率的，不再是"链路能不能跑通"，而是：

- 每次修 `IRToMSLConverter` 都要重装 / 重注入 / 启动原神
- live 覆盖面受地图、场景、加载时机影响，**不稳定且随机**
- 虽然成功路径已经形成 `ShaderCorpus/`，失败路径在 `E-004f4` 后也已补齐 `.bc/.ll/.metal/.meta.json` 导出，但**新 blocker 仍必须按闭环规则判断**：不能只凭"既有 corpus 已绿"就宣告完成

因此 E-004 这一阶段留下来的核心价值是：

**把真实运行中遇到的 shader 系统性导出为离线 corpus，并把失败样本也转成可回放输入，使 `IR -> MSL -> 编译 / diff` 成为日常回归主路径。**

## 当前已具备的能力

### E-004a：metallib / payload 解析

- `MetallibParser` 已能解析原始 `MTLB`，并支持当前已知 wrapper / archive / payload 恢复
- 已能识别 `SOURCES` section、有无 wrapper、payload 指纹等
- 对异常 payload 已有 `ShaderPayloadSamples/` 落盘机制

### E-004b：bitcode module 提取

- 已能从 metallib 中提取 `BitcodeModule.data`
- 已按 `(offset, size)` 去重，附带函数名与函数类型
- 已具备基础内存缓存能力

### E-004c：宿主 LLVM 工具链

- `LLVMToolManager` 已能下载、安装、校验宿主 `llvm-dis`
- 工具路径已统一到 `~/Library/Containers/io.playcover.PlayCover/llvm-tools/`

### E-004d：bitcode -> IR

- `LLVMDisassembler` 主路径已切到 **runtime → host bridge**
- runtime 侧不再依赖本地 `posix_spawn` 作为主方案
- 宿主机已经可以稳定代跑 `llvm-dis`

### E-004e：IR -> MSL

- `IRToMSLConverter` 已能完成大部分基础 lowering
- 当前改进方式不应再是"看到一个 live blocker 修一个"，而应逐步切到"对 corpus 批量回放，按错误模式聚类修复"

## 当前缺口

> ⚠️ **本节保留的不是"仍待 E-004 继续开发的功能"，而是当前交接时仍必须记住的边界。** E-004 原始缺口已经收敛，真正的当前主线以 `00-Dashboard.md` 为准；`E-006d` 仅作为搁置问题保留进度，不再是默认执行入口。

1. **闭环边界**：blocker 首次来自 `ShaderSourceDiagnostics/` 且样本未进入 `ShaderCorpus/` 时，不能只凭"既有 corpus 已绿"宣告闭环。详见 [E-004-CorpusClosureAndRecapturePolicy](E-004-CorpusClosureAndRecapturePolicy.md)
2. **覆盖边界**：五大 selector 已全部接入统一导出 / 替换链路；剩余边界取决于真实 app 命中情况
3. **输入边界**：`test-data/`（最小 lowering 样本）和 `ShaderCorpus/`（真实 corpus）不能混用

## 推荐的新主路径

### 采集层（runtime / host）

```text
makeLibrary(...) hook
  ↓
提取 BitcodeModule
  ↓
为每个 module 生成稳定 key
  ↓
保存 .bc
  ↓
host llvm-dis
  ↓
保存 .ll
  ↓
IRToMSLConverter
  ↓
保存 .metal
  ↓
记录 manifest（模块信息、编译信息、错误摘要、时间戳）
```

### 回放层（offline replay）

```text
读 corpus 中的 .ll
  ↓
IRToMSLConverter.convert(...)
  ↓
输出新的 .metal
  ↓
Metal 编译
  ↓
汇总错误 / diff / 回归结果
```

### 最终验证层（minimal live）

```text
当一批 corpus 在离线回放中已通过
  ↓
build_and_install.sh
  ↓
重注入 app
  ↓
最小 live 复测
  ↓
真实 .gputrace 查看源码是否可见
```

## 导出物与目录结构（已落地）

当前成功样本在 PlayCover 容器目录下采用如下结构：

```text
~/Library/Containers/io.playcover.PlayCover/ShaderCorpus/<bundleId>/
  manifest.jsonl
  modules/
    <moduleKey>/
      module.bc
      module.ll
      module.generated.metal
      module.meta.json
```

其中：

- `moduleKey = sha256(module.bc)`
- `manifest.jsonl` 按 **一行一个 capture 事件** 追加，记录 selector / cacheKey / moduleKey / artifact 状态
- `module.meta.json` 保存 **module 级稳定元数据**，包括首捕获时间、最近捕获时间、累计捕获次数、`observedSelectors`、`sourceCacheKeys` 与 canonical artifact 路径

### `module.meta.json` 当前核心字段

当前字段已经稳定，日常主要按下面四类理解即可：

- **标识与去重**：`schemaVersion`、`bundleId`、`moduleKey`、`moduleKeyStrategy`、`selector`、`observedSelectors`、`cacheKey`、`sourceCacheKeys`
- **模块与函数信息**：`moduleRelativeOffset`、`moduleSize`、`functionNames`、`functionTypes`、`generatedFunctionNames`、`generatedFunctionTypes`
- **采集与状态**：`timestamp`、`firstCapturedAt`、`lastCapturedAt`、`captureCount`、`baselineConflictCount`、`llvmDisStatus`、`converterStatus`、`compileStatus`
- **摘要与路径**：`bitcodeBytes`、`llvmIRBytes`、`generatedMSLBytes`、`moduleSummary`、`irSummary`、`conversionSummary`、`corpusRelativeDirectory`、`artifactPaths`

若需要逐字段追查历史含义，应优先回看对应代码或 archive；当前主文档只保留"如何使用这些字段做闭环和回归"的层次。

### 去重与覆盖策略（已落地）

当前策略分两层：

- **metallib 级缓存**：仍使用快速 `cacheKey` 做运行时内存缓存，避免重复解析同一份 metallib
- **module 级持久化**：使用 `moduleKey = sha256(module.bc)` 做长期去重与目录命名

覆盖策略为：

- 若 canonical artifact 不存在：写入基线文件
- 若已存在且内容相同：复用，不重复覆盖
- 若已存在但内容不同：保持已有基线不变，并在 `manifest.jsonl` 中记录 `conflict_preserved`，避免静默覆写破坏后续 replay / diff 基线

## 现有代码中的最佳插入点

> ⚠️ **这一节现在只保留给回看实现时参考，不再代表当前待办。** 更细的设计取舍已下沉到 `E-004-MetallibSourceExtraction-Archive.md`。

- **`extractAndCacheBitcodeModules(...)`**：最早拿到稳定 `BitcodeModule.data` 的位置，适合回看原始 `.bc` 提取链路
- **`attemptLibraryReplacement(...)`**：当前成功路径的 canonical 汇总点，`module.bc` / `module.ll` / `module.generated.metal` / `module.meta.json` 都以这里为主线组织
- **host bridge 命令处理**：若未来需要把文件保存、MCP 暴露或宿主侧诊断继续前移，这里仍是自然扩展点

当前日常推进不再围绕"把插入点接上"展开，而是围绕已落地的 corpus / replay / live 闭环能力做归因。

## E-004 新的任务拆分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-004a | metallib / payload 解析器 | ✅ DONE | `MetallibParser` 已稳定支撑当前样本 |
| E-004b | bitcode module 提取与去重 | ✅ DONE | `BitcodeModule` 已具备数据、函数名、类型信息 |
| E-004c | 宿主 LLVM 工具链管理 | ✅ DONE | `LLVMToolManager` 已可下载 / 校验 `llvm-dis` |
| E-004d | runtime→host `llvm-dis` 主路径 | ✅ DONE | host bridge 已成为主路径 |
| E-004e | IR→MSL 转换器 | ✅ DONE（基础能力） | 当前作为稳定底座保留；后续具体收敛工作已转入 `E-006d` / 离线回归主线 |
| E-004f | corpus 导出与闭环策略 | ✅ DONE | 成功路径已稳定，`E-004f4` 已实现失败路径导出闭环 |

### E-004f 细分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-004f1 | 成功路径导出 `.bc/.ll/.metal/.json` | ✅ DONE | `attemptLibraryReplacement(...)` 成功时已按 module 落盘真实样本 |
| E-004f2 | corpus 命名 / 去重 / manifest 规范 | ✅ DONE | 已落地 `modules/<moduleKey>`、`manifest.jsonl` 与基线保护策略 |
| E-004f3 | 扩展 `URL/default/file` 路径覆盖 | ✅ DONE | 相关 selector 已在代码路径上复用统一导出 / 替换逻辑；default 路径增加了 bundle `.metallib` 保守定位策略 |
| E-004f4 | 失败样本闭环 / re-capture 策略 | ✅ DONE | 失败路径在 `ShaderSourceDiagnostics/<baseName>_modules/` 导出 `.bc/.ll/.metal/.meta.json`；异常路径导出所有模块 `.bc` 及已准备模块的 `.ll`/`.metal` |
| E-004f5 | MCP / 脚本化导出接口 | 已并入 `E-007` | 该能力不再单独作为 E-004 未完成项维护，后续统一由 dashboard 中的跨任务 `E-007` 收敛 |

## 与 E-005 / E-006 的衔接

### E-005：离线回放与批量编译

E-004 的价值不是"把文件存下来"，而是为 E-005 提供真实输入：

- `module.ll` 已成为 `Scripts/corpus_replay_runner.py` 的稳定输入
- `module.generated.metal` 成为后续新旧输出 diff 的基线
- `module.meta.json` 已被 replay runner 消费，并继续作为错误聚类和回归报告的数据源

### E-006：live 只做必要工作

E-004 完成后，E-006 的职责应明显收缩：

- **做覆盖扩充**：采更多真实 shader
- **做最终验证**：真实 `.gputrace` 是否可见源码

而不是继续用 live 当成日常 blocker 分析器。

## 本阶段完成标准

E-004 这一阶段完成，不等于最终 `.gputrace` 目标完成；它的完成标准是：

1. **真实运行中加载到的 shader 能稳定导出为 corpus**
2. corpus 中每个 module 至少具备 `.bc/.ll/.metal/.json`
3. 后续 `IRToMSLConverter` 修复能对 corpus 做离线 replay（当前已由 `Scripts/corpus_replay_runner.py` 落地）
4. 新 blocker 的首轮归因，默认优先在 corpus 上完成，而不是回到原神里反复试错
5. 若 blocker 首次只出现在 `ShaderSourceDiagnostics/`、尚未进入 `ShaderCorpus/`，则必须通过 post-fix fresh capture 或失败路径 `.bc/.ll` 导出补齐闭环，而不能只凭"现有 corpus 已绿"宣布完成

## 参考

- 当前主线与跨任务 TODO：`00-Dashboard.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- E-005 离线 replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
- live blocker 历史归档：`00-Dashboard-Archive.md`
- 早期 E-004 历史细节：`E-004-MetallibSourceExtraction-Archive.md`
- Library API 入口优先级：`E-002-MTLDevice-Library-API.md`
- swizzle 骨架与 hook 角色：`E-003-LibrarySwizzleSkeleton.md`
