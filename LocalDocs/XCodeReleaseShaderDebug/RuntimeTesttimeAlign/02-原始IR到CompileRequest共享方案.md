## 原始 IR 到 Compile Request 共享方案

## 文档职责

本文只描述一件事：**如何把“从 original IR 推导编译 generated MSL 所需参数 / 选项”的整条决策链收口为单一实现**，供 runtime、`mtl-device` harness 与离线 `xcrun` backend 共同消费。

**任务状态、优先级、TODO 与完成判定统一只在 `00-Dashboard.md` 维护。** 本页只保留稳定方案，不重复动态控制面。

## 问题定义

当前仓库已经做到：

- `fast-math` token 与 compile preflight rule 来自同一份 manifest
- 跨 backend 的 compile summary 字段语义已经对齐
- runtime / harness / Python `xcrun` backend 在 `fast_math_aligned / conflict / partial / unavailable / user_override` 这些 reason code 上大体一致

当前这条共享链已经完成主体收口：

- runtime 直接调用 `SharedCompilePlanner.swift` 生成 `MTLCompileOptions` 决策
- `mtl-device` harness 在编译时联编 `SharedCompilePlanner.swift`，不再维护独立 posture 推导
- Python `xcrun` backend 通过 `Scripts/shared_compile_planner_harness.swift` 消费 planner JSON plan，只保留 orchestration 与 CLI 执行层

因此当前剩下的高频维护点已经不再是“多份实现如何同步”，而是：

- 新增 compile option
- 新增 user override 口径
- 调整“部分可判定 / 冲突 / fallback”的策略
- 把 `fast-math` 之外的 compile posture 纳入共享范围

真正需要防的是：shared planner 虽然已经成为单一实现，但如果回归覆盖跟不上，仍可能出现“规则本身改对了，single-module / aggregate / `xcrun` / `mtl-device` 的断言矩阵没有同步补齐”的隐性回退。

## 目标

把下面这件事收口为**单一实现**：

```text
original IR 集合 + user override + backend target
-> compile request / compile plan
-> backend-specific projection
```

这里的核心不是只共享 manifest，而是共享**完整推导过程**：

1. 读取 original IR 中可用的 compile posture 证据
2. 合并用户显式 override
3. 产出统一的 reason / mode / explicitness 判断
4. 再按 backend 投影为：
   - `MTLCompileOptions?`
   - `xcrun metal` CLI args
   - 结构化 JSON report 字段

## 非目标

当前这轮不把下面内容一起并入“单一实现”范围：

- compiler diagnostics 提取
- failure clustering
- AIR 产物与 baseline diff
- preflight reject 之后的 runtime / offline side effect
- `llvm-dis` / host bridge 的执行宿主差异

这些仍可保留为 backend-specific 宿主逻辑。

## 推荐方案

### 总体思路

把“推导 compile request”的核心逻辑上提为 **Swift 侧单一 planner**，由 runtime / harness / Python 离线脚本共同消费。这一方向现已落地，当前文档记录的是这套稳定形态，而不是待实施草案。

之所以优先放在 Swift，而不是 Python：

- runtime 真正执行 compile posture 的宿主本来就在 Swift / PlayTools
- `MTLCompileOptions` 的真实拥有权也在 Swift
- 若把核心逻辑放在 Python，runtime 反而要再消费一层外部翻译，边界会更脆弱

因此最稳的方向是：

- **Swift 持有 compile planner 真正实现**
- Python 不再重写推导逻辑，只消费 planner 输出的 JSON plan

### 目标结构

当前共享层位于：

- `Carthage/Checkouts/PlayTools/PlayTools/SharedCompilePlanner.swift`

其中只放**纯规则推导**，不直接依赖 runtime replacement 流程，也不直接耦合 Python orchestration。

### 核心数据结构

建议抽象为三层：

#### 1. 输入层：`SharedCompilePlannerInput`

最小字段建议包含：

- `originalIRTexts` 或 `originalIRPaths`
- `userMetalArgs`
- `requestedBackend`
  - `mtl-device`
  - `xcrun`
- 后续可扩：
  - target SDK
  - feature flags
  - extra compile hints

#### 2. 语义层：`SharedCompileDecision`

这是**真正要共享的核心结果**，不依赖具体 backend：

- `fastMathMode`
- `fastMathDecision`
- `usesExplicitCompileOptions`
- `compileOptionsFastMathEnabled`
- `explicitOverrideSource`
- `reason`
- 后续可扩展的 compile posture 字段

#### 3. 投影层：`SharedCompilePlan`

在语义层之上，附带 backend-specific projection：

- `inferredMetalArgs`
- `effectiveMetalArgs`
- `mtlCompileOptionsPayload`
  - 如 `fastMathEnabled: Bool?`
  - 后续若加入更多 compile option，可继续扩

关键点是：

- **语义判断只做一遍**
- `CLI args` 与 `MTLCompileOptions` 只是同一个语义结果的两种投影

## 推荐落地方式

### A. runtime 直接调用 shared planner

这一步已经完成：`LibrarySourceInjectionSwizzles.swift` 不再自己维护 aggregate fast-math posture 推导，而是直接调用 `SharedCompilePlanner`，再把 planner 结果投影为 `MTLCompileOptions?`。

### B. `mtl-device` harness 编译时直接带上 shared planner 源文件

这一步也已经完成：`metal_aggregate_compile_harness.swift` 只负责 CLI 参数解析、调用 Metal API、写 report，compile decision 完全委托给 `SharedCompilePlanner`；`aggregate_replay_runner.py` 构建 harness 时会直接把 shared planner Swift 文件与 harness 一起编译：

```text
swiftc SharedCompilePlanner.swift metal_aggregate_compile_harness.swift -o <binary>
```

### C. Python `xcrun` backend 消费 planner harness，而不是自己推导

这一步已经以一个很小的 Swift harness 落地：

- `Scripts/shared_compile_planner_harness.swift`

它本身不持有规则，只负责：

- 接收 `SharedCompilePlannerInput` JSON
- 调用 `SharedCompilePlanner`
- 把 `SharedCompilePlannerPlan` 写回 JSON

Python 的：

- `corpus_replay_runner.py`
- `aggregate_replay_runner.py`
- `ir_semantics_roundtrip_runner.py`（上层 compile orchestration 入口）

现在统一改为：

1. 预构建 shared planner harness binary
2. 调用 harness 读取 JSON plan
3. 直接使用其中的 `effectiveMetalArgs` / summary 字段

这样以后 compile 规则修改时：

- Swift planner 改一处
- runtime / harness / Python 离线链路自动跟随

## 为什么不建议继续停留在“共享 manifest + 各自实现”

因为 manifest 只解决了：

- token 名字一致
- preflight rule 来源一致

但它**没有解决推导过程的一致性**：

- 如何处理多模块全量一致
- 如何处理 partial / conflict
- 如何处理用户 override 优先级
- 如何把一个 shared decision 同时投影到 `MTLCompileOptions` 和 CLI args
- 未来新增 compile posture 时，是否会在三个宿主同时补齐

对“compile 规则会频繁变化”的场景来说，真正高成本的不是 token 常量，而是**推导逻辑**。

## 当前迁移状态

### 第 1 步：shared contract 已完成

`SharedCompilePlanner` 的输入 / 输出 contract 已稳定，runtime、harness 与 Python 现在都能消费同一种 plan 结构。

### 第 2 步：fast-math 推导已迁入 shared planner

当前已统一收口的 fast-math 语义包括：

- `user_override`
- `fast_math_aligned`
- `fast_math_conflict`
- `fast_math_partial`
- `fast_math_unavailable`

### 第 3 步：runtime / harness 已切到 planner

Swift 侧的 runtime 主路径与 `mtl-device` harness 已经物理共用同一份 `SharedCompilePlanner.swift` 逻辑。

### 第 4 步：Python `xcrun` backend 已切到 planner harness

Python 不再自己做 compile posture / arg inference，而是通过 `Scripts/shared_compile_planner_harness.swift` 调用 shared planner，再消费返回的 JSON plan。

### 第 5 步：当前重点是补验证与防回退测试

当前仍需持续补强的主要是三类回归：

1. **planner 单元测试**
   - single-module enable / disable
   - multi-module aligned / conflict / partial
   - user override 优先级
2. **harness 集成测试**
   - `mtl-device` backend 消费 planner 输出后，report 字段仍保持一致
3. **Python CLI 集成测试**
   - single-module 与 aggregate 的 `xcrun` backend 在消费 planner 后，`fastMathMode` / `fastMathDecision` / `effectiveMetalArgs` 与当前期望一致

## 完成判定

这条共享化任务完成时，至少应满足：

1. original IR -> compile request 推导只剩**一份真正的规则实现**
2. runtime 不再自己维护一份 posture 推导
3. `mtl-device` harness 不再自己维护一份 posture 推导
4. Python `xcrun` backend 不再自己维护一份 arg inference
5. compile 规则新增或修改时，默认只需要改 shared planner 一处
6. runtime / harness / Python 产出的 `fastMathMode` / `fastMathDecision` / `effectiveMetalArgs` / `compileOptionsFastMathEnabled` 保持一致

## 风险与注意事项

### 1. 不要把“共享 planner”做成“所有 backend 都必须执行同一编译宿主”

共享的是：

- decision 逻辑
- request / plan contract
- backend projection

不是：

- 都改成 `xcrun`
- 或都改成 `MTLDevice`

### 2. Python 最终仍可保留 orchestration，但不能再保留规则推导

Python 继续负责：

- 批量作业发现
- subprocess orchestration
- report 汇总
- diagnostics / baseline diff

但不再负责“根据 IR 规则判断该加什么 compile 参数”。

### 3. 先把 fast-math 迁完，再决定是否扩到更多 compile option

当前最重要的是把**共享实现的骨架**搭起来，而不是一次把全部 compile option 范围放大。否则会让迁移任务失控。

## 总结

**推荐方向不是继续停留在“manifest 共享、推导逻辑三份实现”，而是把 `original IR -> compile request` 收口成 Swift 侧单一 planner，再让 runtime、harness 和 Python `xcrun` backend 全部改为消费同一份 planner 结果。**
