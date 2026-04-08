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

若只是理解当前主线优先级，优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`；本文件更偏向 L1 接口、产物与边界的工作参考。

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

1. 发现输入样本（显式 `.ll` / `ShaderCorpus`）
2. 复用现有 `corpus_replay_runner.py` 与 `IRToMSLConverter`
3. 生成 `generated.metal`
4. 调用 `xcrun metal -c`
5. 生成 `generated.air`
6. 按 `LLVMToolManager` 同口径优先解析 PlayCover 容器内的 `llvm-dis`
7. 生成 `regenerated.ll`
8. 写 `replay-summary.json`、`compile-summary.json`、`roundtrip-summary.json`
9. 继续为 L2 自动产出 `compare-summary.json / risk-report.json / high-risk-samples.json`
10. 对固定 preset 继续写 `preset-manifest.json`，并支持 replay baseline snapshot 的保存与复用

### 输入模式

当前实际已支持：

- `--ll <path>`：单个或多个显式 `.ll`
- `--corpus-root <path>`：对 `ShaderCorpus/` 批量发现
- `--bundle-id`
- `--module-key`
- `--limit`
- `--allow-failures`
- `--llvm-dis`
- `--skip-preflight`
- `--metal-sdk`
- `--metal-arg`
- `--baseline-report`
- `--save-baseline`
- `--manifest-file`
- `--quiet`
- `--preset test-data-representatives`
- `--preset test-data-batch`
- `--preset local-corpus-representatives`
- `--preset daily-default`

补充说明：

- `test-data-representatives` 当前固定为 `8` 个样本：`L0 / L1 / 5 个 L2 / compile blocker`
- `local-corpus-representatives` 当前固定为本机已存在的 `5` 个 `ShaderCorpus` 代表模块
- `daily-default` 当前等于：`test-data-representatives + local-corpus-representatives`
- `SV-003` 当前已不再依赖“每次手工挑文件”，而是优先复用上述固定入口

### 输出目录

当前实际形态分成两类：

```text
build/semantics-validation/roundtrip/
  test-data-representatives/
  test-data-batch/
  local-corpus-representatives/
  daily-default/
  <timestamp>/                 # 非 preset / 临时试跑
    replay-summary.json
    compile-summary.json
    roundtrip-summary.json
    compare-summary.json
    risk-report.json
    high-risk-samples.json
    preset-manifest.json
    # 若显式保存 baseline：
    baseline.json
    generated-sources/
    manual/ 或 <bundleId>/modules/<moduleKey>/
      original.ll
      generated.metal
      generated.air
      regenerated.ll
```

其中，固定 preset 应优先复用其稳定目录；只有非 preset 或一次性试验运行，才默认落到时间戳目录。

## 实现路线

### Phase 1：直接复用现有 replay 能力

这一阶段已经完成。当前仍应保持的原则是：

- 不重写 `IR -> MSL` 主链路
- 继续复用 `Scripts/corpus_replay_runner.py` 的既有调用方式
- 让 L1 只承担“把 replay 之后的 round-trip 链路做稳定”的职责

### Phase 2：把 Metal 编译物保留下来

这一阶段也已经完成。当前仍需要维护的，是固定 preset 运行时稳定保留：

- `generated.metal`
- `generated.air`
- `regenerated.ll`
- 对应 summary / compare / risk / gate / manifest 报告

这样 L1 结果才能继续被 L2/L3/L4 消费，而不是退回一次性试验结果。

### Phase 3：统一 `llvm-dis` 解析路径

这一阶段的首版也已完成；当前仍需维持的约束是：

1. 默认优先复用 PlayCover 已下载好的 `llvm-dis`
2. 显式参数允许覆盖路径
3. 缺工具时可以汇报 warning / failure，但不要把“用户手工找工具路径”写成默认步骤

原则仍然不变：默认路径必须 agent 可自动使用。

## 报告建议

### 顶层字段

当前实际重点字段包括：

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

### 每个 job 建议字段

当前每个 job 的关键字段包括：

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

## 验证顺序

### 第一轮

当前默认先跑：

- `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
- `python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate`

目标：

- 保证跨机器硬默认入口仍稳定
- 先确认 L1 的固定 preset / 固定目录 / 固定报告没有漂移

### 第二轮

再按需跑：

- `python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-batch --allow-failures`

目标：

- 看完整 `test-data/` 基线
- 为代表集维护、失败聚类和升级边界提供参考
- 这一步属于参考批量，不属于每次都要执行的硬默认 gate

### 第三轮

最后再按需跑：

- `python3 Scripts/ir_semantics_roundtrip_runner.py --preset local-corpus-representatives --allow-failures`
- 或 `python3 Scripts/ir_semantics_roundtrip_runner.py --preset daily-default --allow-failures --enforce-gate`

目标：

- 在本机已有样本时补充真实样本证据
- 为 L2 compare 提供真实数据
- 若当前机器缺样本，应退回前两轮，而不是把 fresh capture 写成默认依赖

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
- `test-data-representatives` 固定入口：`build/semantics-validation/roundtrip/test-data-representatives/roundtrip-summary.json`
  - `8` 个样本中 `7` 个 round-trip 成功，`1` 个 compile 失败，`0` 个 llvm-dis 失败
  - 风险分布：`L0 = 1 / L1 = 1 / L2 = 5 / L3 = 1`
- `local-corpus-representatives` 固定入口：`build/semantics-validation/roundtrip/local-corpus-representatives/roundtrip-summary.json`
  - 当前固定 `5` 个本地 `ShaderCorpus` 代表模块全部 round-trip 成功
  - 风险分布：`L0 = 0 / L1 = 0 / L2 = 1 / L3 = 4`
- `test-data-batch` 批量统计：`27` 个样本中 `26` 个 round-trip 成功，`1` 个 compile 失败，`0` 个 llvm-dis 失败
- 当前首个 compile-stage blocker：`test_struct_array_field`
- 更细的样本名单、固定代表集与阶段性提交脉络已下沉到 `07-首轮基线与历史进展归档.md`（历史参考，**不必须读取**）

## 完成标准

满足以下条件后，可认为 `SV-001` 基本完成：

1. 已有脚本可以对显式 `.ll` 做 round-trip
2. `test-data/` 可以批量执行并产出结构化报告
3. 报告能明确区分失败阶段（replay / compile / llvm-dis）
4. 产物会稳定保留 `original.ll`、`generated.metal`、`generated.air`、`regenerated.ll`
5. 至少有一组结果能供 L2 compare 直接消费

> 当前以上 5 条均已满足，因此 `SV-001` 可视为完成；L1 当前的工作重心已从“把 runner 做出来”转为“把它接入更稳定的日常 gate”。

## 后续衔接

- L1 成功样本 → 进入 `04-L2-CanonicalCompareAndRiskGrading.md`
- L1 高价值/高风险样本 → 后续可进入 `05-L3-最小行为测试.md`
- L1 当前最直接的后续任务 → `SV-003`（稳定 `test-data` / `ShaderCorpus` 默认入口）
