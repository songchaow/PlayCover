## E-004: 将运行时 metallib 提升为可复用的离线 corpus

## 状态：🔄 IN PROGRESS

## 目标

E-004 的目标已经从“证明可以在运行时做 metallib → IR → MSL”升级为：

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

真正拖慢效率的，不再是“链路能不能跑通”，而是：

- 每次修 `IRToMSLConverter` 都要重装 / 重注入 / 启动原神
- live 覆盖面受地图、场景、加载时机影响，**不稳定且随机**
- 当前只有**失败样本**会落盘，成功路径没有形成可复用 corpus

因此 E-004 这一阶段的主目标是：

**把真实运行中遇到的 shader 系统性导出为离线 corpus，使 `IR -> MSL -> 编译` 成为日常回归主路径。**

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
- 当前改进方式不应再是“看到一个 live blocker 修一个”，而应逐步切到“对 corpus 批量回放，按错误模式聚类修复”

## 当前缺口

### 1. 成功路径持久化已打通，且基础规范已落地

当前已有落盘目录：

- `ShaderSourceDiagnostics/`：**失败的** `.metal + .txt`
- `ShaderPayloadSamples/`：**异常 payload** 的 `.bin + .txt (+ .plist)`
- `ShaderCorpus/`：`attemptLibraryReplacement(...)` 成功路径下导出的稳定 corpus

其中 `ShaderCorpus/` 已收敛为：

- 根目录：`ShaderCorpus/<bundleId>/`
- 模块目录：`modules/<moduleKey>/`
- 总索引：`manifest.jsonl`
- `moduleKey`：`sha256(module.bc)`，作为长期稳定的 module 级去重键
- `cacheKey`：仅保留为 metallib 级上下文，不再承担长期去重职责
- 覆盖策略：`.bc/.ll/.metal` 采用**基线优先**；若后续同一 `moduleKey` 再次出现但产物不同，则**不覆盖已有基线**，只在 `manifest.jsonl` 中记录 `conflict_preserved` 事件

这意味着真实运行中采到的成功样本，已经具备长期可复用的目录、索引和去重约束；后续 replay / diff / 回归可以默认建立在这套稳定 corpus 之上。

### 2. `makeLibrary` 覆盖面还不完整

当前真正进入 bitcode 提取和替换主链路的是：

- `newLibraryWithData:error:`

而这些入口虽然已 hook，但目前主要仍是日志：

- `newLibraryWithURL:error:`
- `newDefaultLibrary`
- `newDefaultLibraryWithBundle:error:`
- `newLibraryWithFile:error:`

若要提升 corpus 覆盖率，需要逐步把这些路径纳入统一的导出逻辑。

### 3. 缺少离线 replay 的稳定输入规范

现在已经存在两类离线输入，但边界还不够明确：

- `test-data/`：手工构造的**最小样本**，用于验证单个 lowering、air builtin 或特定 IR 模式
- `ShaderCorpus/`：真实运行时采集的**真实样本集**，用于批量 replay、diff、失败聚类与回归基线

当前的问题不是“完全没有离线输入”，而是还没有一个统一的**真实 corpus 样本规范**。

后续需要统一约定：

- 目录结构
- 命名规则
- 去重键
- manifest 字段
- 成功 / 失败 / fallback 的状态标记
- `test-data/` 与 `ShaderCorpus/` 的职责边界

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

当前已稳定写入：

- `schemaVersion`
- `bundleId`
- `moduleKey`
- `moduleKeyStrategy`
- `selector`（首个 canonical selector）
- `observedSelectors`
- `cacheKey`（首个 canonical metallib cacheKey）
- `sourceCacheKeys`
- `moduleRelativeOffset`
- `moduleSize`
- `functionNames`
- `functionTypes`
- `generatedFunctionNames`
- `generatedFunctionTypes`
- `timestamp`
- `firstCapturedAt`
- `lastCapturedAt`
- `captureCount`
- `baselineConflictCount`
- `llvmDisStatus`
- `converterStatus`
- `compileStatus`
- `bitcodeBytes`
- `llvmIRBytes`
- `generatedMSLBytes`
- `moduleSummary`
- `irSummary`
- `conversionSummary`
- `corpusRelativeDirectory`
- `artifactPaths`

### 去重与覆盖策略（已落地）

当前策略分两层：

- **metallib 级缓存**：仍使用快速 `cacheKey` 做运行时内存缓存，避免重复解析同一份 metallib
- **module 级持久化**：使用 `moduleKey = sha256(module.bc)` 做长期去重与目录命名

覆盖策略为：

- 若 canonical artifact 不存在：写入基线文件
- 若已存在且内容相同：复用，不重复覆盖
- 若已存在但内容不同：保持已有基线不变，并在 `manifest.jsonl` 中记录 `conflict_preserved`，避免静默覆写破坏后续 replay / diff 基线

## 现有代码中的最佳插入点

### 插入点 1：`extractAndCacheBitcodeModules(...)`

职责：**最早拿到成功的 `BitcodeModule.data`**

适合新增：
- `.bc` 原始落盘
- metallib / module manifest 的初步记录

优点：
- 拿到的是最原始、最稳定的 bitcode
- 便于后续离线重复 `llvm-dis`

限制：
- 此时还没有 `.ll` / `.metal`

### 插入点 2：`attemptLibraryReplacement(...)`

职责：**最自然的成功路径汇总点**

当前这里已经顺序拿到了：
- `module`
- `irResult.irText`
- `conversion.mslSource`
- `compileError` / success

这是当前最适合先落地的点。建议在这里直接写：
- `module.bc`
- `module.ll`
- `module.generated.metal`
- `module.meta.json`

优点：
- 一次函数调用内拿齐所有关键产物
- 能在同一个 manifest 里记录“提取成功 / 反汇编成功 / 转换成功 / 编译成功或失败”

### 插入点 3：host bridge 命令处理

职责：**在宿主进程保存 `.bc/.ll`**

可作为第二阶段优化：
- 让 `host_disassemble_bitcode` 在返回 `ir_text` 的同时，把 `.bc/.ll` 存到宿主目录
- 这样运行时只负责发命令，不负责文件写入

优点：
- 文件权限与调试体验更好
- 更适合未来 MCP / UI 暴露导出功能

限制：
- 需要 runtime 额外把上下文（bundleId、selector、cacheKey、offset/size）带给宿主

## E-004 新的任务拆分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-004a | metallib / payload 解析器 | ✅ DONE | `MetallibParser` 已稳定支撑当前样本 |
| E-004b | bitcode module 提取与去重 | ✅ DONE | `BitcodeModule` 已具备数据、函数名、类型信息 |
| E-004c | 宿主 LLVM 工具链管理 | ✅ DONE | `LLVMToolManager` 已可下载 / 校验 `llvm-dis` |
| E-004d | runtime→host `llvm-dis` 主路径 | ✅ DONE | host bridge 已成为主路径 |
| E-004e | IR→MSL 转换器 | 🔄 IN PROGRESS | 后续迭代应改为 corpus 驱动 |
| E-004f | 成功路径导出 corpus | 🔄 IN PROGRESS | `E-004f1` 已完成，当前推进到 `E-004f2` |

### E-004f 细分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-004f1 | 成功路径导出 `.bc/.ll/.metal/.json` | ✅ DONE | `attemptLibraryReplacement(...)` 成功时已按 module 落盘真实样本 |
| E-004f2 | corpus 命名 / 去重 / manifest 规范 | ✅ DONE | 已落地 `modules/<moduleKey>`、`manifest.jsonl` 与基线保护策略 |
| E-004f3 | 扩展 `URL/default/file` 路径覆盖 | TODO | 提高采集完整性 |
| E-004f4 | MCP / 脚本化导出接口 | TODO | 降低手工操作成本 |

## 与 E-005 / E-006 的衔接

### E-005：离线回放与批量编译

E-004 的价值不是“把文件存下来”，而是为 E-005 提供真实输入：

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

## 参考

- 当前主线与跨任务 TODO：`00-Dashboard.md`
- E-005 离线 replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
- live blocker 历史归档：`00-Dashboard-Archive.md`
- 早期 E-004 历史细节：`E-004-MetallibSourceExtraction-Archive.md`
- Library API 入口优先级：`E-002-MTLDevice-Library-API.md`
- swizzle 骨架与 hook 角色：`E-003-LibrarySwizzleSkeleton.md`
