## L1：IR Round-trip

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

这层的目标不是“直接证明语义相等”，而是先回答：

- 哪些样本可以成功完成 round-trip
- 哪些样本卡在生成 MSL、Metal 编译或反汇编阶段
- 为 L2 compare 提供成对输入

## 为什么它必须先做

- 成本最低
- 不依赖 live
- 不依赖用户操作
- 可以直接复用 `test-data/` 与 `ShaderCorpus`
- 是 L2/L3/L4 的输入基础

## 已落地的工具

本轮已新增：

- `Scripts/ir_semantics_roundtrip_runner.py`

当前职责：

1. 发现输入样本（显式多 `--ll` / `ShaderCorpus`）
2. 复用现有 `corpus_replay_runner.py` 与 `IRToMSLConverter`
3. 生成 `generated.metal`
4. 调用 `xcrun metal -c`
5. 生成 `generated.air`
6. 按 `LLVMToolManager` 同口径优先解析 PlayCover 容器内的 `llvm-dis`
7. 生成 `regenerated.ll`
8. 写 `roundtrip-summary.json`，并明确 `replay / compile / llvm-dis` 三段状态

### 输入模式

建议支持：

- `--ll <path>`：单个或多个显式 `.ll`
- `--corpus-root <path>`：对 `ShaderCorpus/` 批量发现
- `--bundle-id`
- `--module-key`
- `--limit`

### 输出目录

建议：

```text
build/semantics-validation/roundtrip/<timestamp>/
  roundtrip-summary.json
  manual/ 或 <bundleId>/modules/<moduleKey>/
    original.ll
    generated.metal
    generated.air
    regenerated.ll
```

## 实现路线

### Phase 1：直接复用现有 replay 能力

优先不要重写 `IR -> MSL` 链路。

建议：

- 复用 `Scripts/corpus_replay_runner.py` 的 Swift harness / 调用方式
- 让 round-trip runner 只负责“在 replay 成功后继续往后走”

这样能减少重复逻辑与结果漂移。

### Phase 2：把 Metal 编译物保留下来

当前已有 replay/compile 工具主要关注：

- `.metal`
- compile 成功/失败
- 失败聚类

L1 需要额外保留：

- `generated.air`
- `regenerated.ll`

这是后续 compare 的基础产物。

### Phase 3：统一 `llvm-dis` 解析路径

round-trip runner 需要稳定解决 `llvm-dis` 路径问题。

建议优先级：

1. 优先复用 PlayCover 已下载好的 `llvm-dis`
2. 若有显式参数，允许覆盖路径
3. 必要时再考虑兼容 fallback

原则：

- 默认路径必须 agent 可自动使用
- 不要引入需要用户手工找工具路径的流程

## 报告建议

### 顶层字段

建议报告包含：

- `jobCount`
- `roundTripSucceededJobs`
- `roundTripFailedJobs`
- `compileFailedJobs`
- `llvmDisFailedJobs`
- `results`

### 每个 job 建议字段

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
- `failureStage`
- `errorSummary`

## 验证顺序

### 第一轮

先只跑：

- `test-data/` 中 5~10 个代表样本

目标：

- 把主链路打通
- 明确第一批失败样本分类

### 第二轮

再跑：

- 全部 `test-data/`

目标：

- 形成基础批量能力
- 找出 round-trip 成功率与主要失败类别

### 第三轮

再试：

- 少量 `ShaderCorpus` 代表样本

目标：

- 验证真实样本是否可进入同一主链路
- 为 L2 compare 提供真实数据

## 当前不建议做的事

在 L1 内默认不要：

- 直接引入 AST 级 IR 比较
- 在第一版就支持大量 live capture
- 试图一步到位做行为测试
- 把 GUI / `.gputrace` 校验混进 L1

L1 只做一件事：**把 round-trip 链路本身做稳定。**

## 当前落地结果

本轮验证结果：

- 显式单样本 smoke：`build/semantics-validation/roundtrip/explicit-smoke/`
- `test-data/` 首轮批量报告：`build/semantics-validation/roundtrip/test-data-batch/roundtrip-summary.json`
- 批量统计：`27` 个样本中 `26` 个 round-trip 成功，`1` 个 compile 失败，`0` 个 llvm-dis 失败
- 当前首个 compile-stage blocker：`test_struct_array_field`

## 完成标准

满足以下条件后，可认为 `SV-001` 基本完成：

1. 已有脚本可以对显式 `.ll` 做 round-trip
2. `test-data/` 可以批量执行并产出结构化报告
3. 报告能明确区分失败阶段（replay / compile / llvm-dis）
4. 产物会稳定保留 `original.ll`、`generated.metal`、`generated.air`、`regenerated.ll`
5. 至少有一组结果能供 L2 compare 直接消费

> 当前以上 5 条均已满足，因此 `SV-001` 可视为完成，后续重点转入 `SV-002`。

## 后续衔接

- L1 成功样本 → 进入 `04-L2-CanonicalCompareAndRiskGrading.md`
- L1 高价值/高风险样本 → 后续可进入 `05-L3-最小行为测试.md`
