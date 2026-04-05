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

换句话说，E-005 负责的是 **corpus / generated MSL / compile / baseline** 这一层；对于 `.gputrace` 中的 **draw call / Render Encoder / Pipeline State** 结构差异，应转到 `E-006d-GenshinRenderingNondeterminism.md` 与 `E-006d-RenderingPathDiffReference.md`，不要把两层证据混用。

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

当前日常不再依赖早期 `18 / 18` test-data 样本的历史结果；更有价值、也更贴近当前主线的可复用基线已经更新为：

- `test-data/*.ll`（19 个）replay + batch compile **全部成功**
- `ShaderCorpus/com.miHoYo.Yuanshen/modules/` 全部 **91/91** replay + compile **成功**
- preflight rejected `0`
- regression `0`
- `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 通过

这说明 **`E-005b` 已经不只是“能批量跑 metal”，而是能稳定作为当前日常自动化 compile / preflight / 聚类守门路径**；更细的 run 结果以 dashboard 的“最新基线”为准。

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

当前更有价值的不是早期 `18 / 18` 的历史 compare 数字，而是：

- 日常已经可以对 `test-data` 与 `ShaderCorpus` 统一执行 replay + compile + baseline compare
- dashboard 当前基线已确认：`test-data` **19/19**、原神 corpus **91/91**，regression `0`
- `baseline.json + generated-sources/` 已成为稳定 compare 输入；generated MSL 变化会落到 `baseline-diffs/`，回归会直接反映到非 `0` 退出码
- `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 继续作为标准构建守门路径

这说明 **E-005c 已经具备稳定的 baseline snapshot 与自动回归守门能力**；后续重点不再是扩 compare 功能，而是用这套能力支撑 `E-006d` 当前归因主线。

## 下一步

`E-005` 主线已完成；后续优先级回到：

- `E-006d8`：继续使用现有 replay / diff / run-matrix / replacement-attempt 工具，但当前下一步已不再是机械补 run，也不再只是围绕旧的 `llvm-dis` `Operation not permitted` 桶打转；而是优先支撑四条更窄主线：**`session=ready` 之后的 host bridge `Session not registered` 生命周期问题**、**`capture_metal_frame` 自定义 `output_path` 权限问题**、**trace 侧合法 MSL 覆盖偏低**，以及 **代表性 off/on 截帧的 draw call / Render Encoder / Pipeline State 结构对比**。其中前 3 条仍主要依赖 `E-005` 这套 corpus / replay / diff 能力做分层归因，第 4 条则应转到 `E-006d-RenderingPathDiffReference.md` 所定义的 Xcode GUI 自动化路径
- `E-007`：若后续确认人工路径操作已成为效率瓶颈，再把现有离线工具能力经 UI / MCP 暴露出来；前提仍是不能破坏 agent 日常自主执行

也就是说，接下来离线回归能力本身不再是 blocker，重点转为**用这套能力支撑 `E-006d` 当前四条收敛线**；只有当主线再次被操作成本卡住时，才回头推进 `E-007`。
