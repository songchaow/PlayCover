## E-005：离线 replay / batch compile / diff 工具链

## 状态：✅ DONE

> ⚠️ **E-005 已作为稳定参考能力收敛。** 当前 Road E 的最高优先级不是继续扩离线工具，而是使用这些工具完成 `E-006d` 的稳定对照与归因；本文档保留为 offline replay / compile / diff 能力说明。

当前进度：

- `E-005a` **已完成**：`Scripts/corpus_replay_runner.py` 的稳定 replay 入口
- `E-005b` **已完成**：batch compile / preflight / 失败聚类报告
- `E-005c` **已完成**：新旧转换结果 diff / 回归基线

## 目标

E-005 的职责，是把 `ShaderCorpus/` 真正变成日常回归入口，而不是“只是把样本存下来”：

```text
ShaderCorpus/*.ll
  ↓
IRToMSLConverter.convert(...)
  ↓
新的 .metal
  ↓
（已完成）Metal 编译 / 失败聚类 / preflight
  ↓
（已完成）baseline snapshot / 新旧输出 diff / 回归判定
```

也就是说，E-004 负责**沉淀真实输入**，E-005 负责**稳定消费这些输入**。

**注意**：E-005 的稳定保证只覆盖**已经进入 `ShaderCorpus/` 或被手工补成 `.ll` 的样本**。对于仅存在于 `ShaderSourceDiagnostics/` 的 `compile_failed` live 样本，仍需依赖 E-004 / E-006 的 re-capture / 导出闭环把它们带入离线主路径。

## E-005a：corpus replay runner

### 已落地能力

新增脚本：`Scripts/corpus_replay_runner.py`

它当前支持两类输入：

1. **真实 corpus 模式**
   - 输入：`ShaderCorpus/<bundleId>/modules/<moduleKey>/module.ll`
   - 元数据：读取相邻 `module.meta.json`
   - 目录发现：优先读取 `manifest.jsonl`，再补扫 `modules/*/module.meta.json`
   - 输出：稳定写入新的 replay `.metal` 与 JSON 报告

2. **显式 `.ll` 模式**
   - 输入：任意单个或多个 `.ll`
   - 用途：最小样本 smoke / `test-data/` 回放 / 单点 lowering 验证
   - 向后兼容：`Scripts/ir_to_msl_smoketest.sh` 已收口为对该 runner 的 wrapper

### 为什么必须读取 `module.meta.json`

runtime 主路径调用：

- `IRToMSLConverter.convert(irText:functionNames:functionTypes:)`

其中：

- `functionNames`
- `functionTypes`

来自 `MetallibParser` / corpus metadata，而不是单靠 `.ll` 文本恢复。

因此 replay runner 不能只做“把 `.ll` 喂给 converter”，而必须尽量把这些 metadata 一并带上，才能更贴近真实链路。

### 当前输出

默认批量输出目录：

```text
build/shader-corpus-replay/<timestamp>/
  replay-summary.json
  <bundleId>/
    modules/
      <moduleKey>/
        replayed.generated.metal
```

`replay-summary.json` 当前会记录：

- 输入路径 / 输出路径
- `bundleId` / `moduleKey`
- `functionNames` / `functionTypes`
- replay 是否成功
- 转换耗时 / `conversionSummary`
- 生成函数名 / 类型
- conversion stats
- 若存在 baseline，则记录是否与 `module.generated.metal` 在忽略波动头注释（如 `Generated at`）后保持一致

### 用法

#### 1. 回放整个 corpus 根目录

```bash
python3 Scripts/corpus_replay_runner.py \
  --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus
```

#### 2. 只回放某个 bundle / 限制样本数

```bash
python3 Scripts/corpus_replay_runner.py \
  --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus \
  --bundle-id com.miHoYo.Yuanshen \
  --limit 10
```

#### 3. 单个 `.ll` smoke

```bash
python3 Scripts/corpus_replay_runner.py \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
  --output-file build/test_addrspace.generated.metal
```

#### 4. 保持旧入口

```bash
Scripts/ir_to_msl_smoketest.sh \
  LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
  build/test_addrspace.generated.metal
```

## E-005b：batch compile / preflight / failure report

### 已落地能力

`Scripts/corpus_replay_runner.py` 现已直接支持在 replay 后继续执行 batch compile：

- 新增 `--compile`：对每个 replay 成功样本执行 `xcrun --sdk <sdk> metal -c`
- 新增 `--compile-report-file`：允许自定义 `compile-summary.json` 输出路径
- 新增 `--metal-sdk` / `--metal-arg`：允许透传宿主 Metal 编译参数
- 新增 `--skip-preflight`：必要时可绕过 LLVM token 泄漏预检，强制继续编译

### 预检与失败归因

batch compile 不只是“跑一遍 metal”：

1. **preflight**
   - 复用 runtime 侧 `validateAggregateReplacementSource(...)` 的思路
   - 在真正调用 `xcrun metal` 之前扫描明显的 LLVM token 泄漏：
     - `ptr`
     - `addrspace(...)`
     - `%foo`
     - `i32 / i64`
     - `undef / poison / zeroinitializer`
     - `@symbol`

2. **结构化诊断**
   - 解析 Metal 编译器输出中的 `file:line:column: error:` 记录
   - 为每个失败样本保存：
     - `primaryDiagnostic`
     - 出错行附近的 `sourceContext`
     - 原始 `stdout/stderr`
     - `clusterKey / clusterCategory / clusterTitle`

3. **失败聚类**
   - 按归一化后的主错误消息聚类
   - 当前内建分类包括：
     - `undeclared_identifier`
     - `unknown_type`
     - `missing_member`
     - `address_space`
     - `overload_resolution`
     - `invalid_conversion`
     - `syntax`
     - `redefinition`
     - `unsupported_builtin`

### 当前输出

默认批量输出目录现已变为：

```text
build/shader-corpus-replay/<timestamp>/
  replay-summary.json
  compile-summary.json
  manual/ 或 <bundleId>/modules/<moduleKey>/
    replayed.generated.metal / <name>.generated.metal
    replayed.generated.air   / <name>.generated.air
```

其中：

- `replay-summary.json`
  - 保留 `E-005a` 的 replay 信息
  - 在启用 `--compile` 时，为每个结果追加 `compile` 字段
  - 顶层追加 `compile` 摘要（成功数 / 失败数 / failure clusters / 报告路径）

- `compile-summary.json`
  - 汇总 batch compile 的结构化结果
  - 记录：
    - `compileSucceededJobs`
    - `compileFailedJobs`
    - `preflightRejectedJobs`
    - `failureClusters`
    - 每个 job 的 `primaryDiagnostic / sourceContext / compilerOutput`

### 用法

#### 1. replay + batch compile 整个 corpus

```bash
python3 Scripts/corpus_replay_runner.py \
  --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus \
  --compile
```

#### 2. replay + batch compile 一批显式 `.ll`

```bash
python3 Scripts/corpus_replay_runner.py \
  --compile \
  --allow-failures \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.ll \
  --output-root build/road-e-batch-compile
```

#### 3. 需要额外 Metal 参数时

```bash
python3 Scripts/corpus_replay_runner.py \
  --compile \
  --metal-sdk macosx \
  --metal-arg -std=macos-metal3.1 \
  --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus
```

### 本轮最小验证

本轮已执行：

1. `test-data/*.ll` 的批量 replay + batch compile
2. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`

验证结果：

- replay：`18 / 18` 成功
- Metal compile：`10 / 18` 成功，`8 / 18` 失败
- failure clusters：共 `6` 类，当前最显著为：
  - `undeclared_identifier`：`2` 个样本（如 `uv` / `param2` 未定义）
  - `invalid_conversion`
  - `missing_member`
  - `overload_resolution`

这说明 **`E-005b` 已经把“手工抽样编译”收口成“可批量运行、可落盘、可聚类归因”的稳定工具**，离线主回路已经真正闭环到“可编译性”层面。

## E-005c：新旧转换结果 diff / 回归基线

### 已落地能力

`Scripts/corpus_replay_runner.py` 现已补齐 `E-005c` 所需的三块能力：

1. **保存可复用 baseline snapshot**
   - 新增 `--save-baseline <path>`
   - 输出 `baseline.json` 与相邻 `generated-sources/`
   - `baseline.json` 会记录：
     - 稳定 `comparisonKey`
     - replay 成败 / `conversionSummary` / stats
     - compile 状态 / `clusterKey` / `primaryDiagnostic`
     - 归一化后的 generated MSL hash / 行数
   - `generated-sources/` 保留基线时刻的 `.metal`，供后续真实 diff 使用

2. **对当前结果做结构化 baseline diff**
   - 新增 `--baseline-report <baseline.json>`
   - 会为每个 job 追加 `baselineComparison`
   - 比较维度包括：
     - replay 是否成功 / 是否退化
     - compile `status` / `clusterKey` 是否变化
     - generated MSL 归一化后是否变化
   - 若 generated MSL 发生变化，会在当前输出目录下生成 `baseline-diffs/`

3. **把 regression 变成可自动守门的退出码**
   - 若本轮 replay / compile 失败，维持原有非 0 返回
   - 若和 baseline 比较后出现 replay regression 或 compile regression，也返回非 0
   - `--allow-failures` 仍可用于“先落盘、后分析”的场景

### 当前输出

在 `--save-baseline` 模式下，典型输出为：

```text
build/road-e-baseline/
  baseline.json
  generated-sources/
    manual/ 或 <bundleId>/modules/<moduleKey>/
      *.generated.metal
```

在 `--baseline-report` 模式下，典型输出为：

```text
build/shader-corpus-replay/<timestamp>/
  replay-summary.json
  compile-summary.json
  baseline-diffs/
    manual/ 或 <bundleId>/modules/<moduleKey>/
      replayed-vs-baseline.diff
```

其中：

- `replay-summary.json`
  - 顶层新增 `baselineComparison` 摘要
  - 每个 job 新增 `baselineComparison.replay / compile / generatedMSL`
- `baseline.json`
  - 作为后续任意一次 compare 的稳定输入
  - 不依赖运行时 corpus 目录是否仍保留旧输出
- `baseline-diffs/`
  - 仅在 generated MSL 真的变化时写入 unified diff
  - 无变化样本不会生成空 diff 文件

### 用法

#### 1. 为当前一轮 replay + compile 结果保存 baseline

```bash
python3 Scripts/corpus_replay_runner.py \
  --compile \
  --allow-failures \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.ll \
  --output-root build/road-e-baseline-run \
  --save-baseline build/road-e-baseline
```

#### 2. 与既有 baseline 做 compare

```bash
python3 Scripts/corpus_replay_runner.py \
  --compile \
  --allow-failures \
  --output-root build/road-e-compare-run \
  --baseline-report build/road-e-baseline/baseline.json \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_addrspace.ll \
  --ll LocalDocs/XCodeReleaseShaderDebug/RoadE-HookMakeLibraryWithSrc/test-data/test_casts.ll
```

#### 3. CI / 自动守门模式

```bash
python3 Scripts/corpus_replay_runner.py \
  --compile \
  --baseline-report build/road-e-baseline/baseline.json \
  --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus
```

当 compare 发现 replay regression 或 compile regression 时，命令会直接返回非 0。

### 本轮最小验证

本轮已执行：

1. 对 `test-data/*.ll` 执行一轮 replay + batch compile，并用 `--save-baseline` 生成基线快照
2. 对同一批 `test-data/*.ll` 再执行一轮 replay + batch compile，并用 `--baseline-report` 与上一步 baseline 对比
3. `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`

验证结果：

- replay：`18 / 18` 成功
- Metal compile：`10 / 18` 成功，`8 / 18` 失败
- failure clusters：仍为 `6` 类，主要集中在 `invalid_conversion`、`undeclared_identifier`、`missing_member` 与 `overload_resolution`
- baseline compare：matched/new/removed `18 / 0 / 0`
- replay changed：`0`（regression `0`，improvement `0`）
- generated MSL changed：`0`
- compile changed：`0 / 18` compared（regression `0`，improvement `0`）
- BuildScripts 标准构建链路通过

这说明 **E-005 已经不只具备“离线 replay + 编译验证”能力，还具备了稳定的 baseline snapshot 与新旧回归比较能力**。

## 下一步

`E-005` 主线已完成；后续优先级回到：

- `E-006d8`：使用现有 replay / diff / run-matrix 工具，先形成 `replacement=off/on` 多轮稳定矩阵，并输出第一层归因结论
- `E-007`：若后续确认人工路径操作已成为效率瓶颈，再把现有离线工具能力经 UI / MCP 暴露出来

也就是说，接下来离线回归能力本身不再是 blocker，重点转为**用这套能力支撑 `E-006d` 当前归因主线**；只有当主线再次被操作成本卡住时，才回头推进 `E-007`。
