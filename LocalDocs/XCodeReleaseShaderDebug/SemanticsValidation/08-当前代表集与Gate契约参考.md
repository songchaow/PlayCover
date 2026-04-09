## 当前代表集与 Gate 契约参考

## 文档职责

本文件只维护 `SemanticsValidation` 的**preset / gate / manifest / 报告契约**，包括：

- 各类入口的角色定义
- 报告之间的事实优先级
- source-aware 身份规则
- 自动化前置条件与失败止损

**本页不记录任务状态、进展、优先级，也不记录会随运行漂移的当前计数、当前 PASS/WARN/FAIL、当前 blocker 名单。** 这些动态事实统一写在 `00-Dashboard.md`。

## 阅读建议

- 看动态控制面：`00-Dashboard.md`
- 看分层路线：`02-总体技术路线.md`
- 看 L1 / L2 具体接口：`03-L1-IR-RoundTrip.md`、`04-L2-CanonicalCompareAndRiskGrading.md`
- 看历史基线与旧样本背景：`07-首轮基线与历史进展归档.md`

## 事实来源优先级

当多个报告同时存在时，统一按下面顺序理解事实：

1. `gate-summary.json`
2. `risk-report.json`
3. `roundtrip-summary.json` / baseline diff
4. `preset-manifest.json` 的结构字段
5. `preset-manifest.json` 的描述文字

补充规则：

- `gate-summary.json` 中的 `status`、`activeKnownDebt`、`improvements`、`layeredDecision` 等结构字段优先级最高
- `preset-manifest.json` 适合表达发现范围、artifact 锚点与输入构成，不适合单独充当动态 debt 事实来源
- 若描述文字与结构字段不一致，应以结构字段为准

## 自动化前置条件与失败止损

以下约束用于保证默认入口仍可由 agent 自主执行：

- L1/L2 离线命令依赖本机可自动使用的 `swiftc` 与 `xcrun`
- `roundtrip runner` 应按“PlayCover 容器内已安装工具 → PATH → Homebrew → 系统路径”的顺序自动解析 `llvm-dis`
- 若缺少必要工具、固定输出目录产物缺失、或标准脚本失败，正确处理是**停下汇报**
- 不要手写 `xcodebuild`、手工复制产物、改成 GUI 流程，或把用户协助写回默认验证

## 入口契约

### 1. `test-data-representatives`

性质：

- 固定 preset
- 跨机器可复用的稳定入口
- 适合承载最小闭环与固定目录报告

契约重点：

- 目录与输入集合应保持稳定
- 应持续产出 `roundtrip / compare / risk / gate / manifest` 这组报告
- 如启用了 L3，行为报告也应能与同目录 artifact 建立明确对应关系

### 2. `ShaderCorpus` 批量入口

入口形式：`--corpus-root <path>`

性质：

- success-path 样本批量入口
- 真实样本来源之一
- 不依赖固定 preset 名称，也应保持稳定报告语义

契约重点：

- 应进入同一套 `roundtrip / compare / risk / gate` 报告语义
- 若本机缺少现成 corpus，应退回固定代表集或其它更低成本入口，而不是要求 fresh capture
- 报告身份字段必须能与其它来源区分开

### 3. `ShaderSourceDiagnostics` 批量入口

入口形式：`--diagnostics-root <path>`

性质：

- failure-path 导出物批量入口
- 与 corpus 并列进入同一套报告语义
- 不应依赖人工批量枚举 `.ll` 路径

契约重点：

- 批量发现规则应围绕 `module.ll / module.generated.metal / module.meta.json`
- 不同来源命中相同 `bundleId + moduleKey` 时，身份字段必须继续保留来源信息
- 若某种 diagnostics 用法仍要求大量人工整理路径，就不应视为契约稳定

### 4. `behavior-summary.json`

性质：

- L3 行为层的补充证据
- 与同一轮 L1/L2 artifact 建立引用关系

契约重点：

- 应能标出输入样本、比较策略、结果状态与 artifact 锚点
- 不应单独替代 L1/L2 报告成为事实主源

### 5. `daily-default` / `local-corpus-representatives`

性质：

- 本机增强或观察入口
- 可用于补充本机线索

契约重点：

- 适合回答“本机还有没有额外信息”
- 不适合作为唯一事实源替代固定代表集或批量主入口

### 6. `test-data-batch`

性质：

- 早期参考批量快照
- 历史对照入口

契约重点：

- 适合保留噪声面、聚类背景与历史对照
- 不应用作动态控制面的事实主源

## source-aware 身份规则

当 `ShaderCorpus`、`ShaderSourceDiagnostics`、显式 `--ll` 等不同来源命中相同 `bundleId + moduleKey` 时，以下字段必须继续保留来源区分：

- `comparisonKey`
- `sampleKey`
- `sampleIdentity`

目标是避免：

- failure-path 结果覆盖 success-path 事实
- 不同入口的 artifact 被误认为同一来源
- 动态 gate 判断被来源混淆污染

## 报告与 artifact 关系

建议理解为：

- `roundtrip-summary.json`：描述链路执行结果与失败阶段
- `compare-summary.json`：描述逐样本的结构化差异
- `risk-report.json`：描述批量风险分布与升级候选
- `gate-summary.json`：描述整体判定与 layered decision
- `preset-manifest.json`：描述发现范围、输入集合与 artifact 锚点
- `behavior-summary.json`：描述行为层的附加证据

## 命令归属

- 当前默认验证顺序、收尾命令与“哪些命令必须执行”的动态要求统一见 `00-Dashboard.md`
- 本页只解释这些入口各自的契约、角色和事实优先级，不重复展开命令列表

## 参考锚点

- `build/semantics-validation/roundtrip/test-data-representatives/`
- `build/semantics-validation/roundtrip/daily-default/`
- `build/semantics-validation/roundtrip/local-corpus-representatives/`
- `build/semantics-validation/roundtrip/test-data-batch/`
- `07-首轮基线与历史进展归档.md`
