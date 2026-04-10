## 原始 IR 到 Compile Request 共享方案

## 文档职责

本文只描述一件事：**如何把“从 original IR 推导编译 generated MSL 所需参数 / 选项”的整条决策链收口为单一实现**，供 runtime、`mtl-device` harness 与离线 `xcrun` backend 共同消费。

**任务状态、优先级、TODO 与完成判定统一只在 `00-Dashboard.md` 维护。** 本页只保留稳定方案，不重复动态控制面。

## 问题定义

当前仓库已经做到：

- `fast-math` token 与 compile preflight rule 来自同一份 manifest
- 跨 backend 的 compile summary 字段语义已经对齐
- runtime / harness / Python `xcrun` backend 在 `fast_math_aligned / conflict / partial / unavailable / user_override` 这些 reason code 上大体一致

但仍然存在一个高频维护缺口：

- runtime 在 Swift 里自己从 original IR 推导 `MTLCompileOptions`
- `mtl-device` harness 在 Swift 里又写了一份同类推导
- Python `xcrun` backend 再写一份 `posture -> metal args` 推导

这意味着以后只要 compile 规则继续变化，例如：

- 新增 compile option
- 新增 user override 口径
- 调整“部分可判定 / 冲突 / fallback”的策略
- 把 `fast-math` 之外的 compile posture 纳入共享范围

agent 就必须同时记住修改多处实现，极易发生“语义一致但代码漂移”或“改了 runtime 忘了改测试链路”的问题。

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

把“推导 compile request”的核心逻辑上提为 **Swift 侧单一 planner**，由 runtime / harness / Python 离线脚本共同消费。

之所以优先放在 Swift，而不是 Python：

- runtime 真正执行 compile posture 的宿主本来就在 Swift / PlayTools
- `MTLCompileOptions` 的真实拥有权也在 Swift
- 若把核心逻辑放在 Python，runtime 反而要再消费一层外部翻译，边界会更脆弱

因此最稳的方向是：

- **Swift 持有 compile planner 真正实现**
- Python 不再重写推导逻辑，只消费 planner 输出的 JSON plan

### 目标结构

建议新增一个共享层，例如：

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

`LibrarySourceInjectionSwizzles.swift` 不再自己维护：

- `inferAggregateReplacementFastMathMode(...)`
- `resolveAggregateReplacementCompileDecision(...)`

而是改为调用 `SharedCompilePlanner`，然后把 planner 结果投影为 `MTLCompileOptions?`。

### B. `mtl-device` harness 编译时直接带上 shared planner 源文件

当前 `metal_aggregate_compile_harness.swift` 里还保留了一份独立推导。

建议改为：

- harness 本身只做 CLI 参数解析、调用 Metal API、写 report
- compile decision 的推导完全委托给 `SharedCompilePlanner`
- `aggregate_replay_runner.py` 构建 harness 时，直接把 shared planner Swift 文件与 harness 一起编译

也就是说：

```text
swiftc SharedCompilePlanner.swift metal_aggregate_compile_harness.swift -o <binary>
```

### C. Python `xcrun` backend 改为消费 planner CLI，而不是自己推导

这是本轮共享化的关键。

建议新增一个很小的 CLI wrapper，例如：

- `Scripts/shared_compile_planner_cli.swift`

它本身不持有规则，只负责：

- 接收 original IR path / user metal args / backend kind
- 调用 `SharedCompilePlanner`
- 把结果写成 JSON

然后 Python 的：

- `corpus_replay_runner.py`
- `aggregate_replay_runner.py`

都不再保留：

- `infer_original_ir_fast_math_mode(...)`
- `resolve_compile_metal_args(...)`
- `resolve_aggregate_compile_metal_args(...)`

而是统一改为：

1. 调用 planner CLI
2. 读取 JSON plan
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

## 建议的执行顺序

### 第 1 步：先定义 shared contract，不急着改行为

先把 `SharedCompilePlanner` 的输入 / 输出 contract 定稳：

- 哪些字段属于语义层
- 哪些字段属于 backend 投影层
- 哪些字段必须进入 JSON plan

这一阶段的目标是：**先让 runtime、harness、Python 至少能消费同一种 plan 结构。**

### 第 2 步：把现有 fast-math 推导迁进 shared planner

先只迁现有已经稳定的 `fast-math` 逻辑：

- `user_override`
- `fast_math_aligned`
- `fast_math_conflict`
- `fast_math_partial`
- `fast_math_unavailable`

不要同时引入新 compile option，先把“单一实现”闭环跑通。

### 第 3 步：让 runtime / harness 改为消费 planner

在 Swift 侧先去掉两份重复实现：

- runtime
- harness

这样能先保证真正 runtime path 与 runtime-like offline path 已经物理共用一份 Swift 逻辑。

### 第 4 步：让 Python `xcrun` backend 改为消费 planner CLI

等 Swift planner 稳定后，再删 Python 里的手写 inference。

这一步完成后，才算真正达成：

- **测试时** 与 **运行时** 共用同一份 compile request 推导实现

### 第 5 步：补验证与防回退测试

至少补三类测试：

1. **planner 单元测试**
   - single-module enable / disable
   - multi-module aligned / conflict / partial
   - user override 优先级
2. **harness 集成测试**
   - `mtl-device` backend 消费 planner 输出后，report 字段仍保持一致
3. **Python CLI 集成测试**
   - `xcrun` backend 改为 planner CLI 后，`effectiveMetalArgs` 与当前期望一致

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
