## 当前代表集与 Gate 契约参考

## 目的

本文件承接 `SemanticsValidation` 当前默认 gate 控制面的细节，包括：

- 固定 preset 的当前事实口径
- `gate-summary.json` / `preset-manifest.json` / baseline snapshot 的当前契约
- 哪些结果属于**当前默认 gate**，哪些只属于**增强入口**或**较早参考快照**

主文档只保留 active task、升级顺序与 stop-loss 规则；本文件只作为工作参考，默认**不必须读取**。

## 当前读取建议

- 若只是理解当前主线：优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`
- 若正在写 `SV-003` / `SV-006`、维护 preset / gate profile / manifest，或排查报告口径漂移：再回到本文件
- 若需要历史样本名单与早期提交脉络：读 `07-首轮基线与历史进展归档.md`
- 本文件回答的是“契约细节 / 报告锚点 / 入口定位”，**不是**“当前下一步最该做什么”；主线优先级始终以 `00-Dashboard.md` 的 TODO 与 `02-总体技术路线.md` 为准

## 当前事实来源优先级

当前文档统一按下面顺序理解事实：

1. **`gate-summary.json`**
2. **`risk-report.json`**
3. **`behavior-summary.json` / `behavior-summary.*.json`**
4. **`roundtrip-summary.json` / baseline diff**
5. **`preset-manifest.json` 的描述文字**

补充说明：

- 当前统一口径应理解为：**`gate-summary.json` > `risk-report.json` > `behavior-summary.json` / `behavior-summary.*.json` > `roundtrip-summary.json` > `preset-manifest.json` 的描述文字**
- `gate-summary.json` 里的 `status`、`activeKnownDebt`、`improvements`、`layeredDecision` 等结构字段优先级最高
- `preset-manifest.json` 与 gate profile 仍有契约价值，但其描述文字可能滞后
- 当前 `test-data-representatives` 的 gate profile 描述已与结构字段重新对齐；若未来某次较早产物或旁路快照仍残留旧描述（例如历史上的 compile blocker / 旧 L2 计数），也不应再直接当成 active debt 口径
- 若描述文字与结构字段不一致，**以结构字段为准**
- 仅有描述文字滞后、而结构字段未变化时，这属于**契约说明漂移**，不应单独把 TODO 拉回旧问题

## 自动化前置条件与失败止损

以下约束只用于保证“日常默认 gate 仍可由 agent 自主执行”；它们属于工作参考，不改变 `00-Dashboard.md` 里的主线优先级。

- 默认 `L1/L2` 离线命令依赖本机可自动使用的 `swiftc` 与 `xcrun`；这属于环境前置条件，不应改写成手工打开 Xcode 或手工拼命令的流程
- 默认 `L3` 行为命令依赖本机可自动使用的 `swift`，并直接执行仓库内 `metal_compute_behavior_runner.swift` / `metal_fragment_behavior_runner.swift`；默认**不需要**人工手工编译 harness
- `roundtrip runner` 会按“PlayCover 容器内已安装工具 → PATH → Homebrew → 系统路径”的顺序自动解析 `llvm-dis`；若仍找不到，应停止并汇报，不要把“用户手工找路径”写成日常步骤
- 若缺少上述工具、固定输出目录产物缺失、或标准脚本失败，正确处理是**停下汇报**；不要手写 `xcodebuild`、手工复制产物、改成 GUI 流程，或把用户协助写回默认验证

## 当前默认 gate 事实

### 1. `test-data-representatives`（跨机器硬默认）

当前最新代表产物位于：

- `build/semantics-validation/roundtrip/test-data-representatives/`

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
- `test_casts` 已退出活跃 `L2` 债务，只保留为定向回归样本
- `baseline.json` 已可被固定目录自动复用；若需要看非回归型变化，应直接回到同目录 `roundtrip-summary.json`

### 2. `behavior-summary.json`（当前默认 L3 证据）

当前默认行为产物位于：

- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.json`

当前事实：

- `status = pass`
- `candidateSampleKeys = [test_fast_math_select, test_intrinsic_vector_icmp_zext]`
- `readySampleCount = 2`
- `executedSampleCount = 2`
- `deferredSampleCount = 0`
- `errorCount = 0`
- 当前默认执行结果：
  - `test_fast_math_select = pass`
  - `test_intrinsic_vector_icmp_zext = pass`

补充说明：

- 当前默认输出目录**不是**单独的 `build/semantics-validation/behavior/...`，而是直接复用 `gate-summary.outputRoot`
- 因此重复执行时，agent 不需要额外人工找路径；只要有固定的 `gate-summary.json` 与 `roundtrip-summary.json`，就能在同目录下继续补行为证据
- 更细的 fragment artifact 与旧 fail 收口经过已下沉到 `07-首轮基线与历史进展归档.md`（历史参考，当前主线推进**不必须读取**）

### 3. `behavior-summary.test-casts-verification.json`（定向复核入口）

当前定向复核产物位于：

- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.test-casts-verification.json`

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

当前最新增强产物位于：

- `build/semantics-validation/roundtrip/daily-default/`

当前事实：

- `jobCount = 13`
- `roundTripSucceededJobs = 13`
- `compileFailedJobs = 0`
- 风险分布：`L0 = 1 / L1 = 3 / L2 = 5 / L3 = 4`
- `gate-summary.json` 当前为 `WARN`
- `minimumExpectedJobCount = 8`
- `expectedJobCount = 13`

补充说明：

- 这条入口的定位是：**脚本层的一键增强入口**，而不是跨机器硬默认 gate
- 即使它当前也能全自动执行，它反映的仍是**本机样本快照**，不应作为全局主线优先级的事实来源
- 当前 `WARN` 不应被简化理解为“稳定无事”；它实际包含本机局部样本形态变化，需要按本机增强证据理解，而不是写回默认代表契约
- 若本机缺少部分 `ShaderCorpus` 代表样本，应降级为 `WARN`，而不是要求用户协助 fresh capture

### 5. `local-corpus-representatives`（本地观察入口）

当前最新本地产物位于：

- `build/semantics-validation/roundtrip/local-corpus-representatives/`

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
- 当前产物里若出现 `manifest.jsonl` 行解析 warning，也不应被解释为需要用户介入的默认前置步骤
- 它更适合解释“本机真实样本当前长什么样”，不适合驱动当前主线“下一步最该做什么”

### 6. `test-data-batch`（参考批量，不是当前默认 gate 契约）

当前仓库里保留的批量目录：

- `build/semantics-validation/roundtrip/test-data-batch/`

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
- 对硬默认 gate，当前最该优先维护的活跃 `L2` 候选 / 默认 `L3` 入口仍是：
  - `test_fast_math_select`
  - `test_intrinsic_vector_icmp_zext`
- `behavior-summary.json` 当前已从“compute-only + deferred fragment”切换为“compute-first + 已准入 render-second”组合证据；其当前状态为 `pass`，默认两条样本结果均为 `pass`
- 当前 `SV-004` 的**默认执行边界**已稳定为：`test_fast_math_select` 进入 compute-first；`test_intrinsic_vector_icmp_zext` 进入已准入的最小 render-second，并在修正 sample oracle 漂移后回到稳定 `pass`
- 当前主线应优先守住样本 oracle 与 `.ll` 的同步性；只有新增候选仍满足单命令、本地、无 UI、无工作区外修改时，才适合继续纳入默认 L3
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

> 说明：默认行为 gate 只允许把报告写回 `gate-summary.outputRoot/behavior-summary.json`；只有像上面这样显式 `--sample-key` 的定向复核，才允许通过 `--report-file` 另存报告，而不反向改写默认控制面。

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
