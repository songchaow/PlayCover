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

若只是理解当前主线优先级，优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`；本文件更偏向 L1 接口、产物与边界的工作参考，当前日常推进**不必须读取**。

## 为什么它必须先做

- 成本最低
- 不依赖 live
- 不依赖用户操作
- 可以直接复用 `test-data/` 与 `ShaderCorpus`
- 是当前“全量 corpus 的 L1/L2 测试”的入口基础

## 已落地的工具

本轮已新增：

- `Scripts/ir_semantics_roundtrip_runner.py`

当前职责：

1. 发现输入样本（显式 `.ll` / `ShaderCorpus` / `ShaderSourceDiagnostics` failure-path）
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
- `--diagnostics-root <path>`：对 `ShaderSourceDiagnostics/` 批量发现
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
- `--preset local-diagnostics-batch`
- `--preset daily-default`

补充说明：

- `test-data-representatives` 继续只承担**跨机器硬默认 gate** 角色
- `ShaderCorpus` 继续是**当前最高优先级的批量主入口**
- `ShaderSourceDiagnostics` 继续只承担**failure-path 补充输入**角色，不反向定义当前默认 gate；当前既可显式使用 `--diagnostics-root`，也可在标准本机路径下通过 `--preset local-diagnostics-batch` 复用同一批量入口
- `local-corpus-representatives`、`daily-default` 与 `test-data-batch` 继续只承担**增强入口 / 观察入口 / 历史参考**角色，不反向定义当前主线优先级
- 若 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 在同一次运行里命中相同 `bundleId + moduleKey`，L1 报告中的 `comparisonKey / sampleIdentity` 必须保留来源区分，避免 diagnostics 样本覆盖 success-path 的 corpus 事实
- 当前更细的 preset contract、样本计数、active known debt 与 manifest 摘要已统一下沉到 `08-当前代表集与Gate契约参考.md`（工作参考，当前日常推进**不必须读取**）

### 输出目录

当前实际形态分成两类：

```text
build/semantics-validation/roundtrip/
  test-data-representatives/
  test-data-batch/
  local-corpus-representatives/
  daily-default/
  <timestamp>-<unique-suffix>/ # 非 preset / 临时试跑；默认追加唯一后缀，避免并行运行互相覆盖
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

补充说明：

- 当前 `test-data-representatives` 的同一输出目录仍会被后置 L3 参考路径复用，但这**不改变**当前 L1/L2 主线目标
- 对当前阶段而言，最重要的是稳定产出 `roundtrip / compare / risk / gate` 这组 L1/L2 报告

## 实现路线

### Phase 1：直接复用现有 replay 能力

这一阶段已经完成；当前只继续维护一条原则：不重写 `IR -> MSL` 主链路，继续复用 `Scripts/corpus_replay_runner.py` 的既有调用方式，让 L1 只承担“把 replay 之后的 round-trip 链路做稳定”的职责。

### Phase 2：把 Metal 编译物保留下来

这一阶段也已经完成；当前只要求固定 preset 继续稳定保留 `generated.metal`、`generated.air`、`regenerated.ll` 以及对应 summary / compare / risk / gate / manifest 报告，避免结果退回一次性试验。

### Phase 3：统一 `llvm-dis` 解析路径

这一阶段的首版也已完成；当前仍需维持的约束是：

1. 默认优先复用 PlayCover 已下载好的 `llvm-dis`
2. 显式参数允许覆盖路径
3. 若缺少 `llvm-dis` 等必要工具，agent 应停止并汇报，不应尝试把“用户手工找工具路径”写成默认步骤

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

- `python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures`

目标：

- 让 **`ShaderCorpus` 全量已采集样本** 尽可能进入同一套 L1/L2 离线路径
- 优先扩大真实样本覆盖，而不是继续把执行面停在代表集或后置验证
- 继续保持“单命令、本地、无人工介入”的自动化边界；若本机没有现成样本，应退回第一轮，而不是把 fresh capture 写成默认依赖

### 第三轮

最后再按需跑：

- `python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures`
- 或 `python3 Scripts/ir_semantics_roundtrip_runner.py --ll <path_to_failure_module.ll> --allow-failures`

目标：

- 先通过 `--diagnostics-root` 对已导出的 failure-path 样本做**批量补充复核**；必要时再回退到显式 `--ll` 处理单个 blocker
- 继续保持“默认脚本化入口优先”；即使当前已具备批量入口，也不要把人工批量整理 `ShaderSourceDiagnostics` 样本写回默认流程

## 当前不建议做的事

在 L1 内默认不要：

- 直接引入 AST 级 IR 比较
- 在第一版就支持大量 live capture
- 试图一步到位做行为测试
- 把 GUI / `.gputrace` 校验混进 L1

L1 当前只做一件事：**把全量 corpus 的 round-trip 链路本身做稳定。**

## 当前落地结果

本页当前只保留 L1 仍需记住的角色划分：

- `test-data-representatives` 继续是 **跨机器硬默认入口**；当前详细事实、active debt 与固定命令统一见 `08-当前代表集与Gate契约参考.md`（工作参考，当前主线推进**不必须读取**）
- `ShaderCorpus` 继续是 **当前最高优先级的真实样本主入口**；它应尽可能复用同一套 `roundtrip / compare / risk` 报告，而不是另起一套平行控制面
- `ShaderSourceDiagnostics` 当前已可通过 `--diagnostics-root` 作为 failure-path 批量补充输入；显式 `--ll` 继续保留给单样本复核，但这条路径仍不应冒充默认 gate
- `daily-default`、`local-corpus-representatives` 与 `test-data-batch` 的更细定位统一下沉到 `08-当前代表集与Gate契约参考.md` 与 `07-首轮基线与历史进展归档.md`（均为参考，当前主线推进**不必须读取**）
- 若缺少 `swiftc` / `xcrun` / 自动可解析的 `llvm-dis`，应视为环境前置条件未满足并停止汇报；不要把用户手工找路径或手工拼命令写回默认流程

## 完成标准

`SV-001` 已完成；原定的 5 条完成标准（显式 `.ll` round-trip、`test-data/` 批量执行、失败阶段区分、关键产物保留、L2 可直接消费）当前均已满足。

> L1 当前的工作重心已从“把 runner 做出来”转为“把它接入更稳定的日常 gate，并让更多已采集 corpus 样本稳定进入同一套 L1/L2 路径”；更细的首轮完成过程与历史结果已下沉到 `07-首轮基线与历史进展归档.md`（历史参考，**不必须读取**）。

## 后续衔接

- L1 成功样本 → 进入 `04-L2-CanonicalCompareAndRiskGrading.md`
- L1 当前最直接的后续任务 → `SV-003F`（让全量已采集 corpus 样本尽可能进入统一的 L1/L2 离线路径）
- L3 / L4 继续只保留为后置参考，不改变当前阶段目标
