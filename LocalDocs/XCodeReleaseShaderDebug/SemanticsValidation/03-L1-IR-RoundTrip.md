## L1：IR Round-trip

## 文档职责

本文只记录 L1 的**目标、输入接口、产物结构、报告字段与实现边界**。

**任务状态、进展、优先级、TODO、完成判定与默认执行顺序统一只在 `00-Dashboard.md` 维护。** 本页不重复动态控制面信息。

## 目标

建立一条完全离线、自动化优先的最小闭环：

```text
module.ll
  ↓
IRToMSLConverter
  ↓
generated.metal
  ↓
metal -c
  ↓
generated.air
  ↓
llvm-dis
  ↓
regenerated.ll
```

L1 主要回答：

- 哪些样本可以成功完成 round-trip
- 哪些样本卡在生成 MSL、Metal 编译或反汇编阶段
- 如何为 L2 提供成对输入

## 为什么需要 L1

L1 具备以下特点：

- 成本最低
- 不依赖 live 场景
- 不依赖用户操作
- 可以直接复用固定测试样本、本地 corpus 与 diagnostics 导出物
- 可以把失败精确定位到链路中的具体阶段

因此，L1 更适合作为整套语义验证体系的入口层。

## 工具职责

L1 的主要入口是：

- `Scripts/ir_semantics_roundtrip_runner.py`

它承担的职责包括：

1. 发现输入样本（显式 `.ll`、corpus 批量目录、diagnostics 批量目录等）
2. 复用 `Scripts/corpus_replay_runner.py` 与 `IRToMSLConverter`
3. 生成 `generated.metal`
4. 调用 `xcrun metal -c`
5. 生成 `generated.air`
6. 解析 `llvm-dis`
7. 生成 `regenerated.ll`
8. 写出 L1 报告
9. 为 L2 继续提供比较输入

## 输入模式

### 显式输入

支持：

- `--ll <path>`：单个或多个显式 `.ll`
- `--bundle-id`
- `--module-key`
- `--limit`

适合：

- 单样本 smoke
- blocker 复现
- 精准缩小输入集合

### 批量输入

支持：

- `--corpus-root <path>`：从 `ShaderCorpus` 批量发现样本
- `--diagnostics-root <path>`：从 `ShaderSourceDiagnostics` 批量发现样本

适合：

- 真实样本批量复核
- failure-path 导出物批量复核
- 统一生成结构化报告

### 运行选项

常用选项包括：

- `--allow-failures`
- `--llvm-dis`
- `--skip-preflight`
- `--metal-sdk`
- `--metal-arg`
- `--baseline-report`
- `--save-baseline`
- `--manifest-file`
- `--quiet`

### 预设入口

支持的 preset 包括：

- `test-data-representatives`
- `test-data-batch`
- `local-corpus-representatives`
- `local-diagnostics-batch`
- `daily-default`

这些 preset 的**具体契约、产物要求、事实来源优先级与 source-aware 身份规则**统一见 `08-当前代表集与Gate契约参考.md`。

## 输出目录

推荐目录结构：

```text
build/semantics-validation/roundtrip/
  test-data-representatives/
  test-data-batch/
  local-corpus-representatives/
  local-diagnostics-batch/
  daily-default/
  <timestamp>-<unique-suffix>/
    replay-summary.json
    compile-summary.json
    roundtrip-summary.json
    compare-summary.json
    risk-report.json
    high-risk-samples.json
    gate-summary.json
    preset-manifest.json
    baseline.json              # optional
    generated-sources/
    manual/ 或 <bundleId>/modules/<moduleKey>/
      original.ll
      generated.metal
      generated.air
      regenerated.ll
```

约束：

- 固定 preset 应优先复用稳定目录
- 非 preset / 临时试跑建议使用时间戳 + 唯一后缀，避免并行运行互相覆盖

## 报告字段

### 顶层摘要字段

常见字段包括：

- `jobCount`
- `replaySucceededJobs`
- `compileSucceededJobs`
- `compileFailedJobs`
- `llvmDisSucceededJobs`
- `llvmDisFailedJobs`
- `roundTripSucceededJobs`
- `roundTripFailedJobs`
- `warnings`
- `results`

### 每个 job 的关键字段

常见字段包括：

- `inputPath`
- `bundleId`
- `moduleKey`
- `functionNames`
- `functionTypes`
- `generatedMSLPath`
- `generatedAIRPath`
- `regeneratedIRPath`
- `replayStatus`
- `compileStatus`
- `llvmDisStatus`
- `roundTripStatus`
- `failureStage`
- `errorSummary`

### 契约引用

以下内容已统一收口到其它文档，本页只保留接口说明，不再重复展开：

- `comparisonKey` / `sampleIdentity` / `sampleKey` 等 source-aware 身份规则：见 `08-当前代表集与Gate契约参考.md`
- 当前默认命令顺序、收尾验证要求与完成判定：见 `00-Dashboard.md`
- 环境前置条件与失败止损：见 `08-当前代表集与Gate契约参考.md`

## L1 的非目标

L1 不负责：

- 形式化语义证明
- AST/CFG 等价证明
- 行为 oracle
- live / GUI / `.gputrace` 验证

它的职责是把闭环、失败定位与结构化输入准备好，再把成功样本交给 L2。

## 与下一层的衔接

L1 成功样本进入：

- `04-L2-CanonicalCompareAndRiskGrading.md`

L1 只负责把：

- 样本来源
- round-trip 结果
- 失败阶段
- artifact 路径

稳定地交给 L2 继续消费。
