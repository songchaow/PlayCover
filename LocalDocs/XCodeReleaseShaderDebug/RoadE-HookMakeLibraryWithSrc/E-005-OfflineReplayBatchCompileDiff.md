## E-005：离线 replay / batch compile / diff 工具链

## 状态：🔄 IN PROGRESS

当前进度：

- `E-005a` **已完成**：`Scripts/corpus_replay_runner.py`
- `E-005b` **下一步**：批量 Metal 编译与失败归因
- `E-005c` **后续**：新旧转换结果 diff / 回归基线

## 目标

E-005 的职责，是把 `ShaderCorpus/` 真正变成日常回归入口，而不是“只是把样本存下来”：

```text
ShaderCorpus/*.ll
  ↓
IRToMSLConverter.convert(...)
  ↓
新的 .metal
  ↓
（下一步）Metal 编译 / 失败聚类
  ↓
（后续）新旧输出 diff / 回归基线
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

## 与 E-005b / E-005c 的边界

### 本轮刻意**不**做的事

以下能力仍然归后续子任务：

- `E-005b`：对 replay 输出批量执行 `xcrun metal -c`
- `E-005b`：按编译错误模式聚类、归因、汇总
- `E-005c`：保存多版本 replay 基线
- `E-005c`：输出新旧 `.metal` 的结构化 diff

### 本轮已经为后续预留的接口

当前 runner 已经把后续需要的关键输入稳定化：

- replay 输出路径稳定
- 结构化 JSON summary 稳定
- baseline `module.generated.metal` 可直接比较
- `module.meta.json` 中的函数信息已经被 replay 消费

因此 E-005b / E-005c 可以直接建立在这份 summary 和输出目录之上，无需再反过来修改 E-005a 的输入规范。

## 验证建议

本阶段的最小验证方式：

1. 用 `test-data/` 跑单样本 replay
2. 用小型 corpus fixture 或真实 `ShaderCorpus/` 跑批量 replay
3. 抽样执行：

```bash
xcrun --sdk macosx metal -c <generated.metal> -o <generated.air>
```

注意：第 3 步只是当前阶段的**验证手段**，不等于 `E-005b` 已完成；`E-005b` 的定义是“把这一步做成批量工具和报告”。

## 下一步

当前 E-005 主线已经从“先有 replay 入口”切到：

- `E-005b`：批量 Metal 编译 + 失败报告

只有把 replay 输出系统性编译一遍，离线主回路才算真正闭环。
