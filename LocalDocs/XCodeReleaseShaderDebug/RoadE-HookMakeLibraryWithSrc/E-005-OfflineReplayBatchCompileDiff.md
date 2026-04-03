## E-005：离线 replay / batch compile / diff 工具链

## 状态：🔄 IN PROGRESS

当前进度：

- `E-005a` **已完成**：`Scripts/corpus_replay_runner.py` 的稳定 replay 入口
- `E-005b` **已完成**：batch compile / preflight / 失败聚类报告
- `E-005c` **下一步**：新旧转换结果 diff / 回归基线

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
（下一步）新旧输出 diff / 回归基线
```

也就是说，E-004 负责**沉淀真实输入**，E-005 负责**稳定消费这些输入**。

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

- replay：`17 / 17` 成功
- Metal compile：`10 / 17` 成功，`7 / 17` 失败
- failure clusters：共 `6` 类，当前最显著为：
  - `undeclared_identifier`：`2` 个样本（如 `uv` / `param2` 未定义）
  - `invalid_conversion`
  - `missing_member`
  - `overload_resolution`

这说明 **`E-005b` 已经把“手工抽样编译”收口成“可批量运行、可落盘、可聚类归因”的稳定工具**，离线主回路已经真正闭环到“可编译性”层面。

## 与 E-005c 的边界

### 本轮刻意**不**做的事

以下能力仍然归后续子任务：

- `E-005c`：保存多版本 replay 基线
- `E-005c`：输出新旧 `.metal` 的结构化 diff
- `E-005c`：把 compile 结果与历史基线做回归对比

### `E-005c` 的直接输入

当前 runner 已经把下一步 diff / baseline 所需的输入稳定化：

- replay 输出路径稳定
- `compile-summary.json` 稳定
- 每个失败样本的 `primaryDiagnostic / sourceContext / clusterKey` 已稳定化
- baseline `module.generated.metal` 仍可直接比较

因此 `E-005c` 可以直接建立在 replay + compile 两份 summary 之上，无需回头调整 `E-005a / E-005b` 的输入协议。

## 下一步

当前 E-005 主线已经从“先有 replay 入口”推进到：

- `E-005c`：新旧转换结果 diff / 回归基线

只有在同一 corpus 上稳定比较“改前 vs 改后”的 replay / compile 结果，离线主回路才真正具备回归防退化能力。
