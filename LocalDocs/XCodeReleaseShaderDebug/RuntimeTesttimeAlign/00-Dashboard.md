## Runtime / Test-time Align Dashboard

> **单一来源规则**：本目录中，凡是 runtime 与 test-time 行为统一工作的任务状态、进展、优先级、TODO、默认验证方法与经验，只在本文维护。更细节的分析、设计、验证记录与历史归档下沉到子文档；主文档保持简洁，不重复流水账。

## 最终目标

- 让 runtime shader 重编译链路与离线 replay / round-trip / semantics 验证链路在**同一组输入语义**下尽可能共享**同一份决策与规则**，避免“离线通过但 runtime 失败”或“runtime 成功但离线误报”。
- 当前优先统一三层：
  - compile posture / compile request 决策
  - compile preflight 规则
  - 多模块 aggregate 形态
- 默认只推进 agent 可自主完成的链路；若某一步必须依赖用户授权、GUI 操作、登录态或工作区外高风险动作，必须**先得到用户确认**，再继续落地方案。

## 主线任务

- **当前主线**：继续推进 `RTA-004`：把“从 `original IR` 推导 generated MSL 编译请求”的整条链收口成**单一实现**。`RTA-004.3`、`RTA-004.4` 与新增的 `RTA-004.5.1` 已完成；当前子任务转为 `RTA-004.5.2`：继续补 shared planner 的 cross-backend compile summary 断言矩阵，重点放在 aggregate `xcrun` 入口与更完整 CLI 覆盖。方案见 `02-原始IR到CompileRequest共享方案.md`。
- 当前只保留几条最关键的控制面事实：
  - runtime 真实路径是 `bitcode -> LLVMDisassembler -> IRToMSLConverter -> 多模块 aggregate -> newLibraryWithSource(..., options: MTLCompileOptions?)`
  - 离线仍保留两条路径：`module.ll -> IRToMSLConverter -> xcrun metal -c -> llvm-dis -> canonical compare`，以及 `aggregate.generated.metal -> MTLDevice.newLibraryWithSource(...)` 的最小 harness compile
  - 已完成的共享层主要是：shared manifest（`fast-math` token / preflight rule）、shared compile planner contract、runtime / `mtl-device` harness 直连 planner，以及 Python `xcrun` backend 通过 `Scripts/shared_compile_planner_harness.swift` 消费 planner JSON plan；差异边界见 `01-差异边界分类.md`
  - **当前最大的剩余共享缺口**：compile posture / arg inference 已基本只剩一份 Swift planner 实现；single-module / aggregate 的 compile summary 已补齐 `usesExplicitCompileOptions`、`compileOptionsFastMathEnabled` 与 `explicitOverrideSource` 契约，下一步主要继续补 aggregate `xcrun` 入口与更完整 CLI 级 cross-backend 断言矩阵
  - **默认判断**：不要把 `xcrun metal -c` 结果直接当作 runtime 真值；若目标是贴近 runtime compile 结论，应优先使用 `Scripts/aggregate_replay_runner.py --compile-backend mtl-device`

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
  - 若改动涉及 `SharedCompilePlanner.swift` / `metal_aggregate_compile_harness.swift` / aggregate compile decision，共享层回归优先补跑：
    - `python3 Scripts/test_shared_compile_planner.py`
    - `python3 Scripts/test_aggregate_replay_runner.py`
  - 若同时改了 round-trip 逻辑，继续补跑：
    - `python3 Scripts/test_ir_semantics_roundtrip_runner.py`
    - `python3 Scripts/test_ir_canonical_compare.py`
- **改动了工程文件**：
  - `./BuildScripts/lint_pbxproj.sh`

### 对齐工作默认验证顺序

1. **最小样本验证**：先验证单个 representative case 是否命中新改动的目标差异
2. **离线脚本回归**：确保已有 round-trip / compare 测试不回退
3. **runtime 形态贴近验证**：优先用自动化脚本或最小 harness；aggregate 相关问题默认优先使用 `Scripts/aggregate_replay_runner.py`
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
| `RTA-001` 统一 runtime 与离线 compile decision 层 | DONE | runtime 与离线不再各自维护独立的 compile posture 决策；至少 `fast-math` 已共用同一套判断逻辑，并能分别映射到 `MTLCompileOptions` 与离线 metal args | 已完成 shared manifest、aggregate 验证入口、`mtl-device` / `xcrun` 边界收口 |
| `RTA-002` 明确“必须对齐”和“有意保留”的差异边界 | DONE | 文档中能稳定回答：哪些差异必须继续收口，哪些属于 backend / 输入形态天然不同、无需强行统一 | 结论已整理到 `01-差异边界分类.md` |
| `RTA-004` 收口 `original IR -> compile request` 的单一实现 | DOING | runtime、`mtl-device` harness 与 Python `xcrun` backend 不再各写一份 posture / arg inference；compile 规则修改时默认只需改一处 shared planner | 规则实现已基本收口，当前主线转为补 `RTA-004.5` 回归覆盖 |
| `RTA-004.1` 定义 shared compile planner contract 与迁移路线 | DONE | 文档能稳定回答：单一实现放哪、输入输出是什么、Python 如何消费、哪些逻辑仍留在 backend-specific 宿主 | 已整理到 `02-原始IR到CompileRequest共享方案.md` |
| `RTA-004.2` 抽出 Swift 侧 shared compile planner | DONE | 新增独立 shared planner 源文件；manifest、semantic decision 与 backend projection contract 在同一处维护 | 已落地 `SharedCompilePlanner.swift`，并把 shared manifest 单一来源切到该文件 |
| `RTA-004.3` 让 runtime 与 `mtl-device` harness 共同消费 shared planner | DONE | `LibrarySourceInjectionSwizzles.swift` 与 `metal_aggregate_compile_harness.swift` 不再各自维护 posture 推导，统一改为调用 shared planner | runtime 主路径与 `mtl-device` harness 已直连 `SharedCompilePlanner.swift`；harness 构建也已联编 shared planner 源文件 |
| `RTA-004.4` 让 Python `xcrun` backend 改为消费 planner 输出 | DONE | `corpus_replay_runner.py` / `aggregate_replay_runner.py` 不再维护 `resolve_compile_metal_args(...)` / `resolve_aggregate_compile_metal_args(...)` 一类推导逻辑，只消费 planner JSON plan | 已新增 `Scripts/shared_compile_planner_harness.swift`；single-module、aggregate 与 `ir_semantics_roundtrip_runner.py` 上层入口都改为预构建 harness 并消费 planner 输出 |
| `RTA-004.5` 补 shared planner 回归与跨 backend 一致性测试 | DOING | single-module / multi-module / user override / `xcrun` / `mtl-device` 的 plan 输出与 compile summary 字段都能稳定对齐 | 已补 `Scripts/test_shared_compile_planner.py`、`Scripts/test_ir_semantics_roundtrip_runner.py` 与 `Scripts/test_aggregate_replay_runner.py` 的基础回归；当前剩余重点是 aggregate `xcrun` 入口与更完整 CLI 级 cross-backend 断言矩阵 |
| `RTA-004.5.1` 补 `mtl-device` harness compile summary reason-code 实际回归 | DONE | `metal_aggregate_compile_harness.swift` 对 `fast_math_aligned / conflict / partial / unavailable / user_override` 的报告字段都有真实回归覆盖 | 已在 `Scripts/test_aggregate_replay_runner.py` 新增实际 harness matrix，锁定 `fastMathMode` / `fastMathDecision` / `usesExplicitCompileOptions` / `fastMathEnabled` / `explicitOverrideSource` / metal args 契约 |
| `RTA-004.5.2` 补 aggregate `xcrun` 入口与 CLI 级 cross-backend compile summary 断言矩阵 | DOING | aggregate `xcrun` compile summary 与 `mtl-device` 在 conflict / partial / unavailable / override 上都有更直接的端到端断言 | 这轮先完成 `mtl-device` 实际 harness 覆盖；后续继续补 `compile_aggregate_source(...)` 与 CLI summary 的对照断言 |
| `RTA-003` 在链路对齐后恢复上游高风险 case 推进 | BLOCKED | 在 `RTA-004` 完成后，再继续推进 `SemanticsValidation` 中剩余 `entry 参数` family 的 case-by-case 收敛 | 当前对应上游 `CC-003.9` |

## 踩坑与经验

- **离线 `xcrun metal -c` 成功，不等于 runtime `newLibraryWithSource` 一定成功。**
- **backend 不同可以保留，但 compile decision 不能长期分叉**；真正要统一的是决策层，不是强行把 runtime 和离线都改成同一个执行 backend。
- **如果 compile 规则预期会频繁变更，就不能长期停留在“manifest 共享、推导逻辑多份实现”。** 真正高成本的是 `original IR -> compile request` 的推导过程，而不是 token 常量本身。
- **aggregate 的真实模块顺序不能只看 `replacement.meta.json` 的 `moduleKeys`**；runtime 落盘时这个字段会做稳定排序，更接近身份归档而不是拼源顺序；离线要贴近 runtime source shape，必须优先恢复 `manifest.jsonl` 中的 capture 顺序。
- **preflight 需要统一的是“是否拒绝继续 compile”的决策，不是 reject 之后的宿主行为**；runtime 返回 original library、写 launch diagnostics，离线落结构化 JSON 报告，都可以保留差异。
- **涉及 PlayCover 构建、重建、安装时，一律优先使用 `BuildScripts/`**；不要回退到手写 `xcodebuild`。
- **Swift harness 一旦改成和 shared planner 多文件联编，入口要用 `@main` 或其它显式 main 形式。** 单文件脚本式顶层 `do/catch` 在联编场景下会直接编译失败。
- **如果上层 orchestrator 还会再次封装 compile 流程（例如 `ir_semantics_roundtrip_runner.py`），也必须显式预构建并传递 shared planner harness binary。** 只在底层 `corpus_replay_runner.py` 切到 planner 还不够，否则真实 CLI 主入口仍会在 compile 阶段报 `shared compile planner binary is missing`。

## 参考信息

### 必须读取

- `RuntimeTesttimeAlign/00-Dashboard.md`（本文）

### 按需读取

- `01-差异边界分类.md`：稳定边界结论；判断某类 residual 属于“必须继续对齐”还是“有意保留”时优先读取
- `02-原始IR到CompileRequest共享方案.md`：shared compile planner 方案；实现 `RTA-004` 时优先读取
- `SemanticsValidation/00-Dashboard.md`：上游风险主线、case 优先级与当前 residual 背景
- `SemanticsValidation/02-总体技术路线.md`：分层模型、止损边界与自动化优先原则
- `Carthage/Checkouts/PlayTools/PlayTools/SharedCompilePlanner.swift`：shared compile planner contract、shared manifest 与 fast-math 语义 / projection 单一实现
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`：runtime shader 替换 / aggregate / compile 主路径
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`：runtime bitcode -> IR 反汇编路径与 host bridge 边界
- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`：runtime / offline 已共用的核心转换器
- `Scripts/corpus_replay_runner.py`：离线 replay + compile posture 决策现状
- `Scripts/aggregate_replay_runner.py`：aggregate 形态下的默认离线验证入口
- `Scripts/shared_compile_planner_harness.swift`：Python `xcrun` backend 消费 shared planner JSON plan 的标准 Swift harness
- `Scripts/metal_aggregate_compile_harness.swift`：最小 runtime-like aggregate compile harness
- `Scripts/test_aggregate_replay_runner.py`：aggregate 入口的单元 / CLI 集成回归
- `Scripts/ir_semantics_roundtrip_runner.py`：当前 round-trip / canonical compare 主入口
- `BuildScripts/README.md`：标准构建与测试脚本说明

### 暂不需读取

- 除 `01-差异边界分类.md`、`02-原始IR到CompileRequest共享方案.md` 外，本目录其余子文档当前留空；后续若新增设计稿、问题列表、验证记录，再按“必须读取 / 按需读取 / 暂不需读取”继续归类维护
