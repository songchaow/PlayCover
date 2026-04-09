## 当前代表集与 Gate 契约参考

## 目的

本文件承接 `SemanticsValidation` 当前默认 gate 控制面的细节，包括：

- 固定 preset 的当前事实口径
- `gate-summary.json` / `preset-manifest.json` / baseline snapshot 的当前契约
- 哪些结果属于**当前默认 gate**，哪些只属于**增强入口**、**补充输入**或**较早参考快照**

主文档只保留 active task、升级顺序与 stop-loss 规则；本文件只作为工作参考，默认**不必须读取**。

## 当前读取建议

- 若只是理解当前主线：优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`
- 若正在写当前 L1/L2 主线、维护 preset / gate profile / manifest，或排查报告口径漂移：再回到本文件
- 若需要历史样本名单与早期提交脉络：读 `07-首轮基线与历史进展归档.md`
- 本文件回答的是“契约细节 / 报告锚点 / 入口定位”，**不是**“当前下一步最该做什么”；主线优先级始终以 `00-Dashboard.md` 的 TODO 为准

## 当前事实来源优先级

当前文档统一按下面顺序理解事实：

1. **`gate-summary.json`**
2. **`risk-report.json`**
3. **`roundtrip-summary.json` / baseline diff**
4. **`preset-manifest.json` 的结构字段**
5. **`preset-manifest.json` 的描述文字**

补充说明：

- 当前统一口径应理解为：**`gate-summary.json` > `risk-report.json` > `roundtrip-summary.json` > `preset-manifest.json`**
- `gate-summary.json` 里的 `status`、`activeKnownDebt`、`improvements`、`layeredDecision` 等结构字段优先级最高
- `preset-manifest.json` 与 gate profile 仍有契约价值，但其描述文字可能滞后
- 若描述文字与结构字段不一致，**以结构字段为准**
- 仅有描述文字滞后、而结构字段未变化时，这属于**契约说明漂移**，不应单独把 TODO 拉回旧问题

## 自动化前置条件与失败止损

以下约束只用于保证“日常默认 gate 仍可由 agent 自主执行”；它们属于工作参考，不改变 `00-Dashboard.md` 里的主线优先级。

- 默认 `L1/L2` 离线命令依赖本机可自动使用的 `swiftc` 与 `xcrun`；这属于环境前置条件，不应改写成手工打开 Xcode 或手工拼命令的流程
- `roundtrip runner` 会按“PlayCover 容器内已安装工具 → PATH → Homebrew → 系统路径”的顺序自动解析 `llvm-dis`；若仍找不到，应停止并汇报，不要把“用户手工找路径”写成日常步骤
- 若缺少上述工具、固定输出目录产物缺失、或标准脚本失败，正确处理是**停下汇报**；不要手写 `xcodebuild`、手工复制产物、改成 GUI 流程，或把用户协助写回默认验证
- 日常构建、调试、测试、验证默认必须仍可由 agent 自主自动完成；若未来某个路径需要用户介入，必须先得到确认，且不能回流为默认 gate

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

补充说明：

- `test_struct_array_field` 在当前硬默认 gate 中已经不再是 compile failure，而是 **round-trip 成功但 compare 仍 blocked 的样本**
- `baseline.json` 已可被固定目录自动复用；若需要看非回归型变化，应直接回到同目录 `roundtrip-summary.json`

### 2. `ShaderCorpus` 全量批量入口（success-path 主入口）

当前最高优先级入口命令为：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

当前事实：

- `gate-summary.json` 当前为 **`FAIL`**
- `jobCount = 372`
- `roundTripSucceededJobs = 365`
- `roundTripFailedJobs = 7`
- 风险分布：`L0 = 0 / L1 = 4 / L2 = 104 / L3 = 264`

当前契约：

- 这条入口的定位是：**当前 success-path 的批量主入口**
- 它的职责是让已采集成功路径样本进入统一的 `roundtrip / compare / risk / gate` 语义，并持续清理 full-batch blocker
- 它不是固定 preset 契约，但它仍是当前主线里最优先要维持稳定的批量入口
- 若本机缺少现成 `ShaderCorpus`，正确处理是退回跨机器硬默认 gate，而不是要求用户协助 fresh capture

### 3. `ShaderSourceDiagnostics`（failure-path 批量补充入口）

当前批量补充入口命令为：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

当前事实：

- `gate-summary.json` 当前为 **`FAIL`**
- `jobCount = 152`
- `roundTripSucceededJobs = 149`
- `roundTripFailedJobs = 3`
- 风险分布：`L0 = 0 / L1 = 0 / L2 = 4 / L3 = 148`

当前契约：

- 这条入口继续承担 **failure-path 补充输入** 角色，不替代默认 gate
- 当前已支持直接批量发现 `module.ll / module.generated.metal / module.meta.json`
- 虽然它不是默认 gate，但它当前批量结果里已经暴露出来的 compile / compare / gate 错误，已经进入当前主线待修范围
- 当 `ShaderCorpus` 与 `ShaderSourceDiagnostics` 命中相同 `bundleId + moduleKey` 时，`comparisonKey / sampleKey` 必须继续保留来源区分，避免 failure-path 结果污染 success-path 事实
- 若未来某种 diagnostics 用法仍要求人工批量整理路径，就不应并入默认流程

### 4. `behavior-summary.json`（后置 L3 参考）

当前默认行为产物位于：

- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.json`

当前事实：

- `status = pass`
- `candidateSampleKeys = [test_fast_math_select, test_intrinsic_vector_icmp_zext]`
- 当前默认执行结果：
  - `test_fast_math_select = pass`
  - `test_intrinsic_vector_icmp_zext = pass`

补充说明：

- 这份报告继续保留，但它属于**后置参考**，不是当前目标的一部分
- 只有在用户后续明确决定升级到 L3 时，才需要重新把它纳入判断

### 5. `daily-default` / `local-corpus-representatives`（本机增强 / 观察入口）

当前最新增强产物位于：

- `build/semantics-validation/roundtrip/daily-default/`
- `build/semantics-validation/roundtrip/local-corpus-representatives/`

当前契约：

- 这两条入口继续保留，但它们只反映**本机样本快照**
- 它们适合补充“本机是否还有额外线索”，不适合作为全局主线优先级的事实来源
- 即使它们能自动执行，也不应替代跨机器硬默认 gate，更不应替代当前 `ShaderCorpus` 全量批量主线
- 若本机缺少部分样本，应降级为观察层信息，而不是要求用户协助补环境

### 6. `test-data-batch`（参考批量，不是当前默认 gate 契约）

当前仓库里保留的批量目录：

- `build/semantics-validation/roundtrip/test-data-batch/`

当前保留的是一份**较早批量参考快照**：

- `jobCount = 27`
- `roundTripSucceededJobs = 26`
- `compileFailedJobs = 1`
- 风险分布：`L0 = 1 / L1 = 3 / L2 = 3 / L3 = 20`

补充说明：

- 这份快照早于 `test-data-representatives` 最新代表产物
- 它**不能**再被用来描述当前默认 gate 的 active 口径
- 它只适合作为批量参考基线、失败聚类背景和历史对照

## 当前建议口径

### 默认应统一这样理解

1. `test-data-representatives` = **跨机器硬默认 gate**
2. `python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures` = **当前 success-path 主入口，也是最优先的 blocker 清理入口**
3. `python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures` / `--preset local-diagnostics-batch --allow-failures` = **failure-path 批量补充入口；不替代默认 gate，但其当前错误已进入待修范围**
4. `behavior-summary.json` = **后置 L3 参考**
5. `daily-default` / `local-corpus-representatives` = **本机增强 / 观察入口**
6. `test-data-batch` = **参考批量快照，不承担日常阻断职责**

### 对当前 L1/L2 主线最有用的事实

- 当前 `gate-summary.json` / `risk-report.json` 已经能把 **活跃 L2 候选**、**blocked sample**、**已解决 debt** 明确拆开
- 对硬默认 gate，当前最该优先维护的活跃 `L2` 候选仍是：
  - `test_fast_math_select`
  - `test_intrinsic_vector_icmp_zext`
- 当前主线应优先守住 `ShaderCorpus` 全量样本进入同一套 L1/L2 报告语义的能力，并优先清理 success-path 主入口里的 blocker
- 当前主线也应继续守住 success-path 与 failure-path 的身份隔离，避免 `ShaderSourceDiagnostics` 覆盖 corpus 事实；同时，diagnostics 当前批量入口里已经暴露的错误也应继续被计入主线待修范围
- `daily-default` / `local-corpus-representatives` 现在更适合回答“本机有没有额外线索”，不适合替代主文档里的跨机器控制面

## 当前默认命令参考

### 硬默认 gate

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
```

### 当前最高优先级 L1/L2 主线

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
```

### failure-path 批量补充入口

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

### 后置参考入口

```bash
python3 Scripts/ir_semantics_behavior_runner.py --gate-summary build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json
python3 Scripts/ir_semantics_roundtrip_runner.py --preset daily-default --allow-failures --enforce-gate
python3 Scripts/ir_semantics_roundtrip_runner.py --preset local-corpus-representatives --allow-failures
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-batch --allow-failures
```

> 说明：上面这组入口继续保留，但它们不属于当前主线目标；只有在需要补充参考或后续升级时才按需使用。

## 参考锚点

- `build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/risk-report.json`
- `build/semantics-validation/roundtrip/test-data-representatives/roundtrip-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/behavior-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/preset-manifest.json`
- `build/semantics-validation/roundtrip/daily-default/gate-summary.json`
- `build/semantics-validation/roundtrip/local-corpus-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-batch/risk-report.json`
- `07-首轮基线与历史进展归档.md`
