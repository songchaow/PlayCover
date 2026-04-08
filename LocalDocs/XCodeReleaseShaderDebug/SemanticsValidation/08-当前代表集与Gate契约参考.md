## 当前代表集与 Gate 契约参考

## 目的

本文件承接 `SemanticsValidation` 当前默认 gate 控制面的细节，包括：

- 固定 preset 的当前事实口径
- `gate-summary.json` / `preset-manifest.json` / baseline snapshot 的当前契约
- 哪些结果属于**当前默认 gate**，哪些只属于**增强入口**或**较早参考快照**

主文档只保留 active task、升级顺序与 stop-loss 规则；本文件只作为工作参考，默认**不必须读取**。

## 当前读取建议

- 若只是理解当前主线：优先读 `00-Dashboard.md` 与 `02-总体技术路线.md`
- 若正在写 `SV-006`、维护 preset / gate profile / manifest：再回到本文件
- 若需要历史样本名单与早期提交脉络：读 `07-首轮基线与历史进展归档.md`

## 当前默认 gate 事实

### 1. `test-data-representatives`（跨机器硬默认）

当前最新代表产物来自：

- `build/semantics-validation/roundtrip/test-data-representatives/`
- `generatedAt = 2026-04-08T07:37:53Z`

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

补充说明：

- `test_struct_array_field` 在当前硬默认 gate 中已经不再是 compile failure，而是 **round-trip 成功但 compare 仍 blocked 的样本**
- `baseline.json` 已可被固定目录自动复用；本轮对 baseline 的可见改进除了更早的 `test_struct_array_field` 收敛，还包括 `test_casts` 从活跃 `L2` debt 收敛为已解决样本
- 当前 `preset-manifest.json` 仍沿用“代表集包含历史 compile blocker”的描述文字；工作口径应以 `gate-summary.json` 与最新产物事实为准

### 2. `daily-default`（本机已有样本时的一键增强入口）

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

补充说明：

- 这条入口的定位是：**脚本层的一键增强入口**，而不是跨机器硬默认 gate
- 当前 `WARN` 主要来自合并后的已知 blocked / `L2` debt；只要不出现新增 round-trip / `L3` 回归，就不应阻断
- 若本机缺少部分 `ShaderCorpus` 代表样本，应降级为 `WARN`，而不是要求用户协助 fresh capture

### 3. `local-corpus-representatives`（本地观察入口）

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

### 4. `test-data-batch`（参考批量，不是当前默认 gate 契约）

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
2. `daily-default` = **本机已有样本时的一键增强入口**
3. `local-corpus-representatives` = **更窄的本地观察入口**
4. `test-data-batch` = **参考批量快照，不承担日常阻断职责**

### 对 `SV-006` / `SV-004` 最有用的当前事实

- 当前 `risk-report.json` 已经能把 **`samplesForL3`** 与 **`blockedSamples`** 分开
- 对硬默认 gate，当前最该优先考虑的 `L3` 候选入口是：
  - `test_casts`
  - `test_fast_math_select`
  - `test_intrinsic_vector_icmp_zext`
- 但当前 `SV-004` 的**实际执行边界**仍应保持更窄：`test_casts`、`test_fast_math_select` 进入 compute-first；`test_intrinsic_vector_icmp_zext` 继续作为 render-second deferred，而不是今天就必须跑的默认步骤
- `test_struct_array_field` 当前仍属于 **blocked sample**，默认不应直接进入第一批 `L3` 行为测试

## 当前默认命令参考

### 硬默认 gate

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
python3 Scripts/ir_semantics_roundtrip_runner.py --preset test-data-representatives --allow-failures --enforce-gate
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

- `build/semantics-validation/roundtrip/test-data-representatives/roundtrip-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/risk-report.json`
- `build/semantics-validation/roundtrip/test-data-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-representatives/preset-manifest.json`
- `build/semantics-validation/roundtrip/daily-default/gate-summary.json`
- `build/semantics-validation/roundtrip/local-corpus-representatives/gate-summary.json`
- `build/semantics-validation/roundtrip/test-data-batch/risk-report.json`
- `07-首轮基线与历史进展归档.md`
