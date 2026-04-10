## Runtime / Test-time Align Dashboard

> **单一来源规则**：本目录中，凡是 runtime 与 test-time 行为统一工作的任务状态、进展、优先级、TODO、默认验证方法与经验，只在本文维护。更细节的分析、设计、验证记录与历史归档下沉到本目录子文档或引用文档；主文档保持简洁，不重复流水账。

## 最终目标

- 让 runtime shader 重编译链路与离线 replay / round-trip / semantics 验证链路在**同一组输入语义**下尽可能共享**同一份决策与规则**，避免“离线通过但 runtime 失败”或“runtime 成功但离线误报”。
- 当前优先统一三层：
  - compile posture 决策（尤其 `fast-math`）
  - compile preflight 规则
  - 多模块 aggregate 形态
- 默认只推进 agent 可自主完成的链路；若某一步必须依赖用户授权、GUI 操作、登录态或工作区外高风险动作，必须**先得到用户确认**，再继续落地方案。

## 主线任务

- **当前主线**：`RTA-002` 已完成，差异边界已收口到 `01-差异边界分类.md`：必须继续对齐的是 shared manifest 规则来源、`fast-math` compile posture、aggregate 的真实模块顺序与去重语义、compile preflight yes/no 决策，以及跨 backend compile summary 语义；有意保留的是 backend-specific 执行宿主、产物形态、diagnostics / failure clustering 与 `target triple / data layout` 等观察字段。当前最高优先级切到 `RTA-003`：恢复推进上游 `SemanticsValidation` 里剩余的 `entry 参数` 高风险 family（`CC-003.9`）。
- 当前已确认的关键事实：
  - runtime 真实路径是 `bitcode -> LLVMDisassembler -> IRToMSLConverter -> 多模块 aggregate -> newLibraryWithSource(..., options: MTLCompileOptions?)`
  - 离线默认路径仍有两条：`module.ll -> IRToMSLConverter -> xcrun metal -c -> llvm-dis -> canonical compare`，以及 `aggregate.generated.metal -> MTLDevice.newLibraryWithSource(...)` 的最小 harness compile
  - `RTA-001.1` 已完成：runtime 已能依据 original IR 中可判定且全模块一致的 `fast-math` posture，显式设置 `MTLCompileOptions.fastMathEnabled`
  - `RTA-001.2` 已完成：compile preflight 规则与 `fast-math` enable/disable option token 已收口到 `LibrarySourceInjectionSwizzles.swift` 内嵌 shared manifest；Swift runtime 直接使用，Python 离线脚本从同一源读取
  - `RTA-001.3` 已完成：`Scripts/aggregate_replay_runner.py` 现在既能保留 `xcrun` backend 做 AIR / CLI 诊断，也能通过 `Scripts/metal_aggregate_compile_harness.swift` 走 `MTLDevice.newLibraryWithSource(...)`，离线复现 runtime 特有的 aggregate / dedupe / preflight / fast-math compile decision
  - `RTA-001.4.1` 已完成：当 backend 是 `mtl-device` 时，Python 不再手工决定 `MTLCompileOptions`；`aggregate_replay_runner.py` 只把 `sourcePath / originalIRPaths / user metal args / manifest source path` 交给 Swift harness，再消费 harness 回写的结构化 JSON compile report
  - `RTA-001.4.2` 已完成：`xcrun` backend 继续由 Python 持有 CLI-specific 逻辑，包括 `fast-math posture -> metal args` 映射、compiler diagnostics 提取、failure clustering、AIR 产物与 baseline diff；这些能力不再被误当成 runtime / harness 必须共用的执行宿主
  - shared contract 当前只统一“规则来源 + compile summary 语义”：`fast-math` token、preflight rule 来自同一份 manifest；`fastMathMode` / `fastMathDecision` / `usesExplicitCompileOptions` / `compileOptionsFastMathEnabled` / `inferredMetalArgs` / `effectiveMetalArgs` 作为跨 backend 对齐字段继续保留；`airPath` 仅属于 `xcrun`，`backendReportPath` 仅属于 `mtl-device`
  - `mtl-device` backend 的 runtime-like compile posture、`MTLCompileOptions` 决策与结构化 compile report 仍留在 Swift runtime / harness；Python 只负责 orchestration 与 summary 归并
- 当前默认判断：**不要把 `xcrun metal -c` 结果直接当作 runtime 真值**；若目标是贴近 runtime compile 结论，应优先使用 `Scripts/aggregate_replay_runner.py --compile-backend mtl-device`，而 `xcrun` backend 继续作为 AIR / CLI 诊断补充入口。

## 构建与验证的方法

### 默认原则

- **构建、重建、安装必须优先使用 `BuildScripts/` 的标准脚本**；不要手写 `xcodebuild` 替代，也不要手工复制 `.app` 或拼装安装步骤。
- 默认只采用 agent 可独立完成的命令链路；不把 GUI 点选、人工登录、人工安装、人工准备环境写入日常流程。
- 若需要用户介入，必须先说明原因并得到用户确认；未确认前立即停止，不得擅自继续该路径。

### 日常默认验证

- **纯文档 / 方案拆解 / 路线梳理改动**：更新文档并自检，无需额外构建。
- **Python 脚本、compare、round-trip 相关改动**：
  - `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
  - `python3 Scripts/test_ir_canonical_compare.py`
- **Swift runtime / PlayTools / host bridge / compile decision 相关改动**：
  - `./BuildScripts/build_and_install.sh`
  - 若同时改了 round-trip 逻辑，继续补跑：
    - `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
    - `python3 Scripts/test_ir_canonical_compare.py`
- **改动了工程文件**：
  - `./BuildScripts/lint_pbxproj.sh`

### 对齐工作默认验证顺序

1. **最小样本验证**：先验证单个 representative case 是否命中新改动的目标差异
2. **离线脚本回归**：确保已有 round-trip / compare 测试不回退
3. **runtime 形态贴近验证**：优先用自动化脚本或最小 harness；当前仓库已提供 `Scripts/aggregate_replay_runner.py` 作为 aggregate 形态下的默认自动化入口，应优先使用它
4. **必要时再做更重验证**：只有当离线与最小自动化验证无法回答问题时，才考虑安装、真实 app、capture、GUI 或其它需要用户确认的动作

### 当前不作为默认流程的动作

- 真实 app 安装后的 GUI 点击、登录态验证、覆盖安装后的人工检查
- 工作区外的额外手工改动
- 依赖 GUI 点击、登录态、手工切换系统设置的验证
- 任何需要用户持续在线配合的操作

## agent的工作流程介绍

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格按优先级选取最高优先级的 **一个** 未完成任务执行
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助），立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新任务并追加到 TODO，再只完成其中一个
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**。但文档架构不许改变，不许自己添加新章节
   - a. 过时的信息需要删除
   - b. 新的 TODO，踩坑经验，优先级变更等内容需要添加。若本轮新增了测试脚本或辅助脚本且对后续仍有价值，也应添加。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并添加到文档。
   - c. 审查新加的信息与已有信息，根据其重要性，自主决策该上升主文档和下沉到子文档。主文档保持简洁，**不要只做追加**。TODO 列表的已完成任务需要改为简短概括，不要记录流水账。
7. 复盘工作流；最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

## 所有任务TODO状态

| 任务 | 状态 | 结束标准 | 备注 |
|---|---|---|---|
| `RTA-001` 统一 runtime 与离线 compile decision 层 | DONE | runtime 与离线不再各自维护独立的 compile posture 决策；至少 `fast-math` 已共用同一套判断逻辑，并能分别映射到 `MTLCompileOptions` 与离线 metal args | 已完成 `RTA-001.1` / `RTA-001.2` / `RTA-001.3` / `RTA-001.4.1` / `RTA-001.4.2`，且 `RTA-002` 已把“必须对齐 / 有意保留”的边界收口落盘 |
| `RTA-001.1` runtime 显式接入 `fast-math` compile posture 对齐 | DONE | runtime 不再固定 `options: nil`；对于 original IR 中可判定的 `fast-math` posture，能显式设置对应编译选项 | 已接入 `MTLCompileOptions.fastMathEnabled`；仅在全模块都可判定且结论一致时显式设置；当前默认验证脚本已切换为 `./BuildScripts/build_and_install.sh` |
| `RTA-001.2` 提取 compile preflight 规则的单一来源 | DONE | Swift runtime 与 Python 离线脚本不再各自维护一份手写规则；新增规则时只需改一处 | shared manifest 已落在 `LibrarySourceInjectionSwizzles.swift`；Swift runtime 直接使用，Python 通过解析同一源文件加载；`fast-math` enable/disable token 也已并入同一处 |
| `RTA-001.3` 为离线补一条贴近 runtime 的“多模块 aggregate + compile”验证入口 | DONE | agent 可在不依赖人工操作的前提下，验证 aggregate 形态下的 compile 结果；至少能覆盖 runtime 特有的 aggregate / dedupe / preflight 风险 | `Scripts/aggregate_replay_runner.py` 已支持 `xcrun` / `mtl-device` 双 backend；默认把 `mtl-device` 作为更贴近 runtime 的补充真值入口 |
| `RTA-001.4` 明确 Swift 与 Python 的共用边界 | DONE | 形成稳定约定：哪些逻辑留在 Swift，哪些只做 orchestration，哪些通过 JSON / manifest / harness 共享 | `mtl-device` request/report 边界与 `xcrun` backend 保留边界都已文档化；shared contract 只保留规则来源与跨 backend summary 语义 |
| `RTA-001.4.1` 收口 `mtl-device` backend 的 request/report 边界 | DONE | Python 不再为 harness 手工翻译 `MTLCompileOptions`；harness 能基于 shared manifest + original IR 自行做 fast-math decision，并回写结构化 compile report | `metal_aggregate_compile_harness.swift` 现在直接接收 `source / manifest source / original IR / user metal args`；`aggregate_replay_runner.py` 只做 orchestration |
| `RTA-001.4.2` 明确 `xcrun` backend 与 shared contract 的保留边界 | DONE | 文档里能稳定回答：哪些 compile decision 仍由 Python 为 CLI backend 持有，哪些必须继续留在 Swift runtime / harness，哪些字段需要两边统一落盘 | 已明确：Python 保留 CLI arg translation / diagnostics / failure clustering / AIR 与 baseline diff；Swift 保留 runtime-like compile posture 与 structured report；共享层只保留 manifest 与 compile summary 字段 |
| `RTA-002` 明确“必须对齐”和“有意保留”的差异边界 | DONE | 文档中能稳定回答：哪些差异必须继续收口，哪些属于 backend / 输入形态天然不同、无需强行统一 | 已整理到 `01-差异边界分类.md`；明确了 aggregate 顺序 / dedupe / preflight decision / compile summary 语义属于必须对齐，而 backend-specific 宿主 / 产物 / diagnostics 属于有意保留 |
| `RTA-003` 在链路对齐后恢复上游高风险 case 推进 | TODO | 在已收稳的边界之上，继续推进 `SemanticsValidation` 中剩余 `entry 参数` family 的 case-by-case 收敛 | 当前直接对应上游 `CC-003.9`：剩余 `7` 个 corpus `L3` 已收敛成 `entry 参数个数变化 + entry 参数类型摘要变化 + entry 参数语义摘要变化` |

## 踩坑与经验

- **离线 `xcrun metal -c` 成功，不等于 runtime `newLibraryWithSource` 一定成功**。
- **backend 不同可以保留，但 compile decision 不能长期分叉**；真正要统一的是“决策层”，不是强行把 runtime 和离线都改成同一个执行 backend。
- **多模块 aggregate 是 runtime 的真实形态**；离线若长期只看单模块结果，会系统性漏掉 runtime 特有问题。
- **`fast-math` posture 在 runtime 侧应走保守显式化策略**：只有 original IR 可判定且 aggregate 内所有模块结论一致时，才显式设置 `MTLCompileOptions.fastMathEnabled`；部分可判定、互相冲突或完全不可判定时继续回退默认编译行为。
- **规则表与常量一旦双份维护，迟早会漂**；凡是 preflight / posture / compile metadata 这类高频规则，优先寻找单一来源。对当前仓库而言，把 shared manifest 内嵌在 Swift runtime 源码、再由 Python 解析同一源文件，比额外引入资源打包链路更稳妥。
- **shared manifest 是规则来源，不是所有 backend 的执行宿主**；`xcrun` backend 可以继续把 CLI-specific 逻辑留在 Python（如 `metal args` 映射、diagnostics 提取、failure clustering），但 token / preflight rule 必须继续从同一份 manifest 读取。
- **当 backend 是 `MTLDevice.newLibraryWithSource(...)` 时，不要让 Python 手工翻译 `MTLCompileOptions`**；更稳的边界是 Python 只负责 orchestration，把 `source / original IR / 用户 override / manifest source` 交给 Swift harness，由 Swift 决定 compile posture 并通过 JSON report 回传结果。
- **跨 backend 真正该统一的是 compile summary 语义，不是产物形态**；`fastMathMode` / `fastMathDecision` / `usesExplicitCompileOptions` 可以对齐，但 `airPath` 只属于 `xcrun`、`backendReportPath` 只属于 `mtl-device`，不必强行做成同一类产物。
- **aggregate 的真实模块顺序不能只看 `replacement.meta.json` 的 `moduleKeys`**；runtime 落盘时这个字段会做稳定排序，更接近身份归档而不是拼源顺序；离线若要贴近 runtime source shape，必须优先恢复 `manifest.jsonl` 中的 capture 顺序。
- **preflight 需要统一的是“是否拒绝继续 compile”的决策，不是 reject 之后的宿主行为**；runtime 返回 original library、写 launch diagnostics，离线落结构化 JSON 报告，都可以保留差异。
- **涉及 PlayCover 构建、重建、安装时，一律优先使用 `BuildScripts/`**；不要回退到手写 `xcodebuild`。

## 参考信息

### 必须读取

- `RuntimeTesttimeAlign/00-Dashboard.md`（本文）

### 按需读取

- `01-差异边界分类.md`：`RTA-002` 的稳定结论；需要判断某类 residual 属于“必须继续对齐”还是“有意保留”时优先读取
- `SemanticsValidation/00-Dashboard.md`：上游风险主线、case 优先级与当前 residual 背景
- `SemanticsValidation/02-总体技术路线.md`：分层模型、止损边界与自动化优先原则
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`：runtime shader 替换 / aggregate / compile 主路径
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`：runtime bitcode -> IR 反汇编路径与 host bridge 边界
- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`：runtime / offline 已共用的核心转换器
- `Scripts/corpus_replay_runner.py`：离线 replay + compile posture 决策 + compile preflight 现状
- `Scripts/aggregate_replay_runner.py`：当前 aggregate 形态下的默认离线验证入口
- `Scripts/metal_aggregate_compile_harness.swift`：最小 runtime-like aggregate compile harness，直接调用 `MTLDevice.newLibraryWithSource(...)`
- `Scripts/test_aggregate_replay_runner.py`：aggregate 入口的单元 / CLI 集成回归
- `Scripts/ir_semantics_roundtrip_runner.py`：当前 round-trip / canonical compare 主入口
- `BuildScripts/README.md`：标准构建与测试脚本说明

### 暂不需读取

- 除 `01-差异边界分类.md` 外，本目录其余子文档当前留空；后续若新增设计稿、问题列表、验证记录，再按“必须读取 / 按需读取 / 暂不需读取”继续归类维护
