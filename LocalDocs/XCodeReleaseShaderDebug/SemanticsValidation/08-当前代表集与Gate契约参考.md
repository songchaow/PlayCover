## 当前代表集与 Gate 契约参考

## 目的

本文件承接 `SemanticsValidation` 当前默认 gate 控制面的细节，包括：

- 固定 preset 的当前事实口径
- `gate-summary.json` / `preset-manifest.json` / baseline snapshot 的当前契约
- 哪些结果属于**当前默认 gate**，哪些只属于**增强入口**或**较早参考快照**

主文档只保留 active task、升级顺序与 stop-loss 规则；本文件只作为工作参考，默认**不必须读取**。

## 当前读取建议

- 若只是理解当前主线：优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`
- 若正在写 `SV-003` / `SV-006`、维护 preset / gate profile / manifest：再回到本文件
- 若需要历史样本名单与早期提交脉络：读 `07-首轮基线与历史进展归档.md`

## 当前事实来源优先级

当前文档统一按下面顺序理解事实：

1. **`gate-summary.json`**：当前 gate 状态、活跃 debt、已解决 debt、`layeredDecision`
2. **`risk-report.json`**：当前 `samplesForL3` / `blockedSamples` 与风险分布
3. **`behavior-summary.json` / `behavior-summary.*.json`**：当前 L3 最小行为证据
4. **`roundtrip-summary.json` / baseline diff**：round-trip 成功率、改进与回放差异
5. **`preset-manifest.json`**：preset 期望样本、匹配情况、报告锚点、baseline 锚点

补充说明：

- `preset-manifest.json` 依然有重要价值，但它的**描述文字**可能落后于当前事实
- 当前 `test-data-representatives/preset-manifest.json` 仍写着“compile blocker / 3 个已知 L2”，这不应再直接当成 active debt 口径
- 若出现描述文字与 `gate-summary.json` / `risk-report.json` 不一致，**以 `gate-summary.json` / `risk-report.json` 为准**

## 当前默认 gate 事实

### 1. `test-data-representatives`（跨机器硬默认）

当前最新代表产物来自：

- `build/semantics-validation/roundtrip/test-data-representatives/`
- `gate-summary.generatedAt = 2026-04-08T09:49:06Z`

当前事实：

- `jobCount = 8`
- `roundTripSucceededJobs = 8`
- `compileFailedJobs = 0`
- 风险分布：`L0 = 2 / L1 = 3 / L2 = 2 / L3 = 1`
- `gate-summary.json` 当前为 `WARN`
- 当前 active known debt：
  - blocked sample：`test_struct_array_field`
  - `L2` samples：`test_fast_math_select`、`test_intrinsic_vector_icmp_zext`
- 当前 improvements：
  - `resolvedL2SampleKeys`：`test_casts`
- `layeredDecision.overallDecision = promote_l2_candidates_to_l3`
- `l3Plan.candidateSampleKeys` 当前为：`test_fast_math_select`、`test_intrinsic_vector_icmp_zext`

补充说明：

- `test_struct_array_field` 在当前硬默认 gate 中已经不再是 compile failure，而是 **round-trip 成功但 compare 仍 blocked 的样本**
- `test_casts` 的收敛是当前默认 gate 中最重要的已知改进之一；它已经退出活跃 `L2` 债务，只保留为定向回归样本
- `baseline.json` 已可被固定目录自动复用；当前能直接从 `roundtrip-summary.json` 看到 `test_casts` 与 `test_struct_array_field` 的非回归型变化

### 2. `behavior-summary.json`（当前默认 L3 证据）

当前默认行为产物来自：

- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.json`
- `generatedAt = 2026-04-08T11:53:15Z`

当前事实：

- `status = fail`
- `candidateSampleKeys = [test_fast_math_select, test_intrinsic_vector_icmp_zext]`
- `readySampleCount = 2`
- `executedSampleCount = 2`
- `deferredSampleCount = 0`
- `errorCount = 0`
- 当前默认执行结果：
  - `test_fast_math_select = pass`
  - `test_intrinsic_vector_icmp_zext = fail`

补充说明：

- 当前默认输出目录**不是**单独的 `build/semantics-validation/behavior/...`，而是直接复用 `gate-summary.outputRoot`
- 因此重复执行时，agent 不需要额外人工找路径；只要有固定的 `gate-summary.json` 与 `roundtrip-summary.json`，就能在同目录下继续补行为证据
- 这里的 `fail` 表示 **reference-vs-generated 行为未对齐**，不是 harness 没跑起来；当前默认控制面已把最小 render-second 视为正式执行面的一部分，而不再把它停在 deferred

### 3. `behavior-summary.test-casts-verification.json`（定向复核入口）

当前定向复核产物来自：

- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.test-casts-verification.json`
- `generatedAt = 2026-04-08T09:49:38Z`

当前事实：

- `status = pass`
- `candidateSampleKeys = [test_casts]`
- `executedSampleCount = 1`
- `deferredSampleCount = 0`
- `errorCount = 0`
- `swiftResult.summary = passed 2 / 2 compute cases`

补充说明：

- 这份报告只用于验证 `test_casts` 修复是否真正消除了历史 fail evidence
- 它**不是**当前默认自动执行面的一部分
- 只有在怀疑转换语义回归时，才需要显式 `--sample-key test_casts` 重跑

### 4. `daily-default`（本机已有样本时的一键增强入口）

当前最新增强产物来自：

- `build/semantics-validation/roundtrip/daily-default/`
- `generatedAt = 2026-04-08T07:37:53Z`

当前事实：

- `jobCount = 13`
- `roundTripSucceededJobs = 13`
- `compileFailedJobs = 0`
- 风险分布：`L0 = 1 / L1 = 3 / L2 = 5 / L3 = 4`
- `gate-summary.json` 当前为 `WARN`
- `minimumExpectedJobCount = 8`
- `expectedJobCount = 13`
- 当前 `summary = new L2 sample bundle:com.papegames.lysk::module:6c08f93015cda305e6c675457bab3acfcf7febab294577d27cbe76317e2b1f45`

补充说明：

- 这条入口的定位是：**脚本层的一键增强入口**，而不是跨机器硬默认 gate
- 即使它当前也能全自动执行，它反映的仍是**本机样本快照**，不应作为全局主线优先级的事实来源
- 当前 `WARN` 不应被简化理解为“稳定无事”；它实际包含本机局部样本形态变化，需要按本机增强证据理解，而不是写回默认代表契约
- 若本机缺少部分 `ShaderCorpus` 代表样本，应降级为 `WARN`，而不是要求用户协助 fresh capture

### 5. `local-corpus-representatives`（本地观察入口）

当前最新本地产物来自：

- `build/semantics-validation/roundtrip/local-corpus-representatives/`
- `generatedAt = 2026-04-08T06:06:52Z`

当前事实：

- `jobCount = 5`
- `roundTripSucceededJobs = 5`
- `compileFailedJobs = 0`
- 风险分布：`L0 = 0 / L1 = 0 / L2 = 1 / L3 = 4`
- `gate-summary.json` 当前为 `WARN`
- `minimumExpectedJobCount = 0`
- `expectedJobCount = 5`

补充说明：

- 该入口只复用**当前机器上已经存在**的本地 `ShaderCorpus` 样本
- 它的价值在于补充真实样本证据，而不是把用户准备环境重新带回默认流程
- 当前产物里包含若干 `manifest.jsonl` 行解析 warning；这些 warning 不应被解释为需要用户介入的默认前置步骤
- 它更适合解释“本机真实样本当前长什么样”，不适合驱动当前主线“下一步最该做什么”

### 6. `test-data-batch`（参考批量，不是当前默认 gate 契约）

当前仓库里保留的批量目录：

- `build/semantics-validation/roundtrip/test-data-batch/`
- `generatedAt = 2026-04-08T06:33:20Z`

当前保留的是一份**较早批量参考快照**：

- `jobCount = 27`
- `roundTripSucceededJobs = 26`
- `compileFailedJobs = 1`
- 风险分布：`L0 = 1 / L1 = 3 / L2 = 3 / L3 = 20`
- 其中 `test_struct_array_field` 仍被记为 compile failure

补充说明：

- 这份快照早于 `test-data-representatives` 最新代表产物
- 因此它**不能**再被用来描述当前默认 gate 的 active 口径
- 它只适合作为批量参考基线、失败聚类背景和历史对照

## 当前建议口径

### 默认应统一这样理解

1. `test-data-representatives` = **跨机器硬默认 gate**
2. `behavior-summary.json` = **当前默认 L3 证据**
3. `behavior-summary.test-casts-verification.json` = **定向复核入口，不是默认执行面**
4. `daily-default` = **本机已有样本时的一键增强入口**
5. `local-corpus-representatives` = **更窄的本地观察入口**
6. `test-data-batch` = **参考批量快照，不承担日常阻断职责**

### 对 `SV-003` / `SV-004` / `SV-006` 最有用的当前事实

- 当前 `gate-summary.json` / `risk-report.json` 已经能把 **活跃 L2 候选**、**blocked sample**、**已解决 L2 debt** 明确拆开
- 对硬默认 gate，当前最该优先考虑的活跃 `L3` 候选入口是：
  - `test_fast_math_select`
  - `test_intrinsic_vector_icmp_zext`
- `behavior-summary.json` 当前已从“compute-only + deferred fragment”切换为“compute-first + 已准入 render-second”组合证据；其当前状态为 `fail`，对应 `test_intrinsic_vector_icmp_zext` 的稳定 mismatch
- 当前 `SV-004` 的**默认执行边界**已稳定为：`test_fast_math_select` 进入 compute-first；`test_intrinsic_vector_icmp_zext` 进入已准入的最小 render-second，并稳定产出 `fail` evidence
- `test_casts` 已退出活跃 `L2` debt；它仍可作为定向转换语义回归样本保留，但不再属于默认自动执行面
- `test_struct_array_field` 当前仍属于 **blocked sample**，默认不应直接进入第一批 `L3` 行为测试
- `daily-default` / `local-corpus-representatives` 现在更适合回答“本机有没有额外线索”，不适合替代主文档里的跨机器控制面

## 当前默认命令参考

### 硬默认 gate

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

### 默认行为证据

```bash
python3 Scripts/test_ir_semantics_behavior_runner.py
python3 Scripts/ir_semantics_behavior_runner.py --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json
```

### `test_casts` 定向复核

```bash
python3 Scripts/ir_semantics_behavior_runner.py \
  --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json \
  --sample-key test_casts \
  --report-file build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.test-casts-verification.json
```

### 本机增强入口

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset daily-default --allow-failures --enforce-gate
```

### 本地观察入口

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset local-corpus-representatives --allow-failures
```

### 参考批量入口

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-batch --allow-failures
```

## 参考锚点

- `build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/risk-report.json`
- `build/semantics-validation/roundtrip/test-data-representatives/roundtrip-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.test-casts-verification.json`
- `build/semantics-validation/roundtrip/test-data-representatives/preset-manifest.json`
- `build/semantics-validation/roundtrip/daily-default/gate-summary.json`
- `build/semantics-validation/roundtrip/local-corpus-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-batch/risk-report.json`
- `07-首轮基线与历史进展归档.md`
