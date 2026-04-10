## Semantics Validation Dashboard

> **单一来源规则**：凡是任务状态、进展、优先级、TODO、完成判定与默认执行顺序，只在本文件维护；`01`~`08` 子文档只保留背景、方法、契约与历史归档，不重复记录动态控制面。

## 当前主线

> 当前只做一件事：**把 canonical compare 报告当成唯一任务入口，按 case-by-case 的方式逐个分析高风险差异，反推 `IRToMSLConverter` / round-trip 链路里是否存在真实实现问题；每次只收敛一个明确问题，修复后立即重跑 full-batch canonical compare，看整体风险数量是否下降。**

后续控制面只围绕下面这条流程展开：

1. 从 `compare-summary.json` / `risk-report.json` 里挑一个值得分析的高风险 case
2. 逐项解释 canonical diff 到底在说什么
3. 下钻原始 IR / regenerated IR / generated MSL，判断差异更像：
   - compare 口径问题
   - 编译姿势差异
   - 反编译 / 参数建模 / emission 实现问题
4. 如果判断是实现问题，做一次**最小而定向**的实现修改
5. 先对单 case 验证，再重跑 full-batch canonical compare
6. 只看一个问题：**风险数量有没有下降、有没有新的回归**
7. 若任务过大，就拆成更小的 case 子任务；仍然一次只完成一个

## 当前判断

### 现在真正的核心问题

- full-batch 的主要矛盾已经不是 replay / compile / llvm-dis 主链路失败，而是**canonical compare 里的大量 `L2/L3` 风险到底哪些是真问题，哪些只是表达差异或 compare 口径问题**
- 当前最有价值的推进方式，不是继续扩 live 验证，而是**持续消解 canonical compare 中可解释、可复现、可修正的一类类高风险差异**
- `difference-analysis/` 目录已经证明，这条路径是有效的：从单个 case 入手，能够落到实现改动，并在 full-batch 上看到 `L3` 数量下降

### 当前工作原则

- **canonical compare 是任务入口，不是收尾附属品**
- **一个 case 一个 case 地做，不对着“最终完全等价”死磕**
- **每次实现修改之后，必须重新看 full-batch 风险计数是否下降**
- **没有统计收益的实现，不应轻易继续放大**

### 当前最新状态

- 当前主线最新已完成 `CC-003.6`：围绕 `c6d1420a...`、`82d1eb85...`、`1cdc9318...` 这支高频 `L3` 下钻后，已经确认真正缺口并不在 compare，而在 **`IRToMSLConverter.swift` 对“哪些 constant buffer struct 应保留为引用 `&`”的判定过窄，导致 `_Foo_Type` / `cb_Foo_Type` 一类用户类型被错误发成 `const constant T*`，进而在 regenerated IR 中丢失 `dereferenceable(N)`**
- 实现上这轮继续严格按 converter-first 收敛，只改了生成侧：
  - `IRToMSLConverter.swift` 放宽 `isStructTypeName(...)` 的判定，不再只把“首字母大写”的类型名视为 struct
  - `_ScreenSpaceShadowParams_Type`、`_DirectionalShadowBuffer_Type`、`cb_SSAOBlur_Type`、`cb_TAA_Type` 等用户类型因此重新走 `const constant T&` 路径
  - 同时补了 `Scripts/test_ir_semantics_roundtrip_runner.py` 的最小 replay / round-trip 回归，并新增 `test_underscore_struct_reference.ll` 最小样本
- 单 case 结果已经形成闭环：
  - `cc-003-6-single-c6d142-dereferenceable-reference`：`c6d1420a...` 从 `L3 -> L1`
  - `entryComparison`：`L3 -> L0`
  - `blockedSamples = []`，gate `PASS`
  - 最小样本 `manual-underscore-struct-reference` 中 regenerated IR 保留 `dereferenceable(4)`
- full-batch 已继续出现明确统计收益且无新增 `L3`：
  - diagnostics `cc-003-6-diagnostics-20260410-dereferenceable-reference`：`L1 12 / L2 140 / L3 1`
  - corpus `cc-003-6-corpus-20260410-dereferenceable-reference`：**`L1 186 / L2 197 / L3 54`**
  - 相比 `CC-003.5`，共有 `3` 个 diagnostics 样本、`16` 个 corpus 样本移除了 `entry 参数类型摘要变化`
- 因此当前最新状态可以概括为：**`constant struct reference / dereferenceable` 这支高频 blocked family 已通过 converter-first 从源头收敛；下一步应优先回到最新 canonical compare 报告，继续下钻剩余 `L3` 中的 `entry 输出语义摘要变化`、`模块级 addrspace 分布变化 + air intrinsic 使用变化`，以及 `entry 参数个数变化` family。**


## 当前默认流程

### Step 1：从 canonical compare 报告选下一个 case

默认优先级：

1. **先看 `L3` 样本**
2. 优先选择：
   - 差异模式在多个样本中重复出现的
   - 能映射到同一类参数 / resource / addrspace / builtin 语义的
   - 有希望通过一处实现改动同时改善多个样本的
3. 暂不优先：
   - 明显只是 target triple / data layout 记录项的
   - 需要 live / 行为测试才能判断、但当前还没有低层证据的

推荐输入：

- `build/semantics-validation/roundtrip/*/compare-summary.json`
- `build/semantics-validation/roundtrip/*/risk-report.json`
- `build/semantics-validation/roundtrip/*/high-risk-samples.json`

### Step 2：先做 case 分析，再决定是否改实现

每个 case 至少回答下面几个问题：

- 差异是发生在：
  - entry 参数类型摘要
  - entry 参数语义摘要
  - resource / builtin 摘要
  - addrspace
  - CFG / instruction family
  - fast-math / module metadata
- 这是“表达方式变化”还是“更像真实语义变化”
- 这个差异更像来自：
  - Apple 编译姿势
  - emitted MSL 写法
  - metadata 建模不足
  - 参数映射错误
  - compare canonicalization 不对称
- 如果修复，应该改哪一层最合适：
  - `IRToMSLConverter`
  - `ir_canonical_compare.py`
  - round-trip runner / compile posture

- **必须严格优先尝试修改 `IRToMSLConverter`实现来解决差异**。只有当反复尝试过修改IRToMSLConverter发现效果不好，才考虑修改 `ir_canonical_compare.py`

若这一步还没有明确判断，**不要急着改实现**。

### Step 3：只做最小实现改动

一旦判断某类差异确实值得修，默认策略是：

- 只修一个清晰问题
- 只引入一个清晰机制
- 尽量保持 diff 小、影响面可控

例如：

- 参数级 `noalias -> __restrict` 回放
- compare 中某一类 alias / metadata 归一化
- 参数建模里补一项 previously-missing 的 first-class 语义

禁止一次混入多条彼此无关的修正。

### Step 4：每次实现后都要做两层验证

#### 4.1 单 case 验证

目的：先确认本轮改动确实命中了目标差异。

典型动作：

- replay 单个 `.ll`
- 编译生成的 `.metal`
- 反汇编回 `.ll`
- 对目标 case 重跑 canonical compare

要求回答：

- 原来的那条差异是否消失 / 降级
- 是否引入新的更坏差异

#### 4.2 full-batch 验证

目的：确认这不是单 case 偶然改善，而是对整体风险分布有统计收益。

当前默认要看两条 full-batch：

- `ShaderCorpus`
- `ShaderSourceDiagnostics`

必须回答：

- `L3` 数量是否下降
- `L2` / `L3` 的共有样本口径下，是否真的改善
- 是否出现新的 `L3` 回归

### Step 5：把结果写回控制面

每次任务结束后，必须把下面内容回写到文档：

- 当前分析的是哪一类差异
- 该类差异的当前结论是什么
- 是否已经落到实现改动
- full-batch 风险数量变化如何
- 下一步最值得继续分析的 case 是什么

## TODO

| 任务 | 状态 | 结束标准 | 详细文档 |
|---|---|---|---|
| `CC-001` 建立 canonical-diff 驱动的新主线 | DOING | `00-Dashboard.md` 已完成重写，后续任务统一改用 case-by-case + full-batch 复跑口径 | 本文档 |
| `CC-002` 收敛 `buffer-noalias` 这类 entry 参数对齐问题 | DONE | 已完成 `noalias -> __restrict` 闭环，并在 full-batch 上确认一批 `L3` 下降且无新增 `L3` | `difference-analysis/buffer-noalias/04-implementation-result.md` / `difference-analysis/buffer-noalias/05-full-batch-compare.md` |
| `CC-003` 归类 `buffer-noalias` 修复后剩余的高频 `L3/L2` 模式 | DOING | 已确认 `entry 参数语义摘要变化` 里有一批是 compare 噪声；接下来需继续统计真正还留在前列的高频残留模式，并明确下一刀优先 case | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/` |
| `CC-003.1` 优先检查 `entry 参数语义摘要变化` 的高频残留模式 | DONE | 已完成 resource metadata `air.address_space` 噪声归一化闭环，并确认一批共有样本 `L2 -> L1` 且无回归 | `difference-analysis/resource-metadata-addrspace/04-implementation-result.md` / `difference-analysis/resource-metadata-addrspace/05-full-batch-compare.md` |
| `CC-003.2` 优先检查 `entry 资源语义摘要变化` 的高频残留模式 | DONE | 已确认残留里有一支是 converter 把 `unity_Builtins0Array_Type` 人为大写化导致的真实实现问题；修复后代表 case `c66b9d4...` 从 `L2 -> L1`，且 diagnostics `L2 3 -> 2`、无新增 `L3` | `difference-analysis/resource-type-name-preservation/04-implementation-result.md` / `difference-analysis/resource-type-name-preservation/05-full-batch-compare.md` |
| `CC-003.3` 优先检查 `模块级 air intrinsic 使用变化 / 指令族统计变化` 的高频残留模式 | DONE | 已先在 converter 侧收敛 vector / half lowering，再把 `747fc286...` 这一处仅剩的极小 instruction-family compare 噪声降回 `L1`；full-batch 复跑后 corpus `L2 109 -> 107`、`L3` 无新增，diagnostics 持平 | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/` |
| `CC-003.4` 优先检查 `模块级 addrspace 分布变化 / air intrinsic 使用变化` 的高频残留模式 | DONE | 已完成 `f26d322...` compare 降噪与 `91c46448...` structured CFG 两轮实现闭环；latest `CC-003.4.5.2` 已将 `91c46448...` 从 `L2 -> L1`，且 full-batch `L2` 继续下降、无新增 `L3` | `04-L2-CanonicalCompareAndRiskGrading.md` / `difference-analysis/` |
| `CC-003.4.1` 先修 `f26d322...` 中 simple diamond `br + phi` 的 CFG 回放缺口 | DONE | `IRToMSLConverter.swift` 已能把 `condbr -> true/false -> common merge` 这类简单 diamond 发射成真实 `if/else`，并有最小 replay 回归覆盖 | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.2` 继续下钻 `f26d322...` / `91c46448...` 里 helper CFG 与 lowering 残留 | DONE | 已确认 `f26d322...` 在 `CC-003.4.1` 之后剩余的 helper `fract / floor / fmin` 漂移更像 compare 噪声；compare 降噪后 diagnostics `L2 2 -> 1`、corpus `L2 106 -> 87`，且无新增 `L3` | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.3` 单独下钻 `91c46448...` 的 residual intrinsic / CFG 漂移 | DONE | 已确认 `91c46448...` 当前 residual 不是 compare 噪声：latest artifact 中 `entryComparison` 已为 `L0`，但 `generated.metal` 仍存在空 `if/else` + 顺序覆盖 phi 的真实 CFG 回放缺口 | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.4` 以 `91c46448...` 为入口修 simple diamond 之外的 structured CFG 回放缺口 | DONE | 已完成 self-loop gated partial structured CFG + entry fallback 边界补齐：`91c46448...` 单 case 获得真实 CFG 收益，`d8ff0527...` 回归已收回，full-batch 达到 `corpus L1 100 / L2 86 / L3 251`、diagnostics 持平 | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.4.1` 对比 `91c46448...` 与 `d8ff0527...` 的 self-loop family 差异 | DONE | 已确认回归根因是 entry 首个 non-structured `condbr` 的 fallback 断流，而不是 self-loop family 本身；修复后 `d8ff0527...` 与 `1fb4a75f...` 均从 `L2 -> L1` | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.5` 在不回退 `CC-003.4.4` 收益的前提下继续下钻 `91c46448...` residual | DONE | 已确认真正缺口是 structured conditional 的 direct-to-merge arm 没有补发 phi edge；修复后 `91c46448...` 从 `L2 -> L1`，diagnostics `L2 1 -> 0`、corpus `L2 86 -> 84`，且无新增 `L3` | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.5.1` 先修 fallback 路径里 final merge / `ret` 被更早前驱提前递归发射的边界缺口 | DONE | `IRToMSLConverter.swift` 已只在 successor 其它前驱齐备时才 eager-emit，并有 `test_late_merge_fallback_order.ll` 回归覆盖；但 `91c46448...` 与 full-batch 均无统计变化 | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.4.5.2` 继续下钻 `91c46448...` 中 `BB821 / BB845 / BB857 / BB1337 / BB1371` 的 nested fallback family | DONE | 已定位真正切口是 structured conditional 的 direct-to-merge arm 未补 phi edge；补齐后 `91c46448...` 从 `L2 -> L1`，nested common merge 最小样本与 full-batch 全部验证通过 | `difference-analysis/phi-diamond-cfg-reconstruction/04-implementation-result.md` |
| `CC-003.5` 优先检查 `entry 返回类型摘要变化` 的高频 `L3` 家族 | DONE | 已确认其中一大支是 converter 把 original IR 的 single-field wrapped return 过早塌成 bare return 的真实实现问题；按 converter-first 修复后 diagnostics `L3 146 -> 4`、corpus `L3 251 -> 70`，且无新增 `L3` | `difference-analysis/single-field-return-wrapper/04-implementation-result.md` / `difference-analysis/single-field-return-wrapper/05-full-batch-compare.md` |
| `CC-003.6` 优先检查 `entry 参数类型摘要变化` 的高频 `L3` 家族 | DONE | 已确认其中一大支不是 compare 噪声，而是 converter 对 constant buffer 用户 struct 的引用判定过窄；修复后 diagnostics `L3 4 -> 1`、corpus `L3 70 -> 54`，且无新增 `L3` | `difference-analysis/constant-struct-reference-dereferenceable/04-implementation-result.md` / `difference-analysis/constant-struct-reference-dereferenceable/05-full-batch-compare.md` |
| `CC-004` 固化新的 case 分析模板 | TODO | 在 `difference-analysis/` 下沉淀一套稳定模板，确保后续每个 case 都按同样结构记录证据、结论与回归数据 | `difference-analysis/` |

## 任务执行规则

### 一次只做一个任务

- 每个 agent / 每次会话默认只完成一个当前最高优先级任务
- 若任务过大，必须先拆出子任务，再只完成其中一个
- 不允许同时并行推进多个主线 case

### 当前选题优先级

从高到低：

1. **能让一批 `L3` 同时下降的差异模式**
2. **已经在 `difference-analysis/` 有初始证据的模式**
3. **单个 case 虽复杂，但明显指向参数建模 / emission 逻辑的问题**
4. **纯 compare 口径问题**（如果它能明显降低误报，也值得做）
5. **需要 live / 行为测试才能推进的问题**（当前不是主优先级）

### 拆任务的规则

若当前任务无法在一次工作中闭环，必须拆开。拆任务时沿下面方式切：

- 按差异类别切：`entry 参数语义` / `resource 语义` / `addrspace` / `CFG` / `fast-math`
- 按机制切：参数建模 / MSL emission / compare 归一化 / compile posture
- 按样本族切：优先切出“重复模式明显”的 case 族

不要按含糊目标切，例如：

- “继续研究 L3”
- “进一步优化 round-trip”

## 当前默认验证

### 改实现前

最低要求：

```bash
python3 Scripts/test_ir_canonical_compare.py
python3 Scripts/test_ir_semantics_roundtrip_runner.py
```

### 单 case 验证

按当前任务需要，组合使用：

```bash
python3 Scripts/corpus_replay_runner.py --ll <sample.ll> --output-file <sample.metal>
xcrun metal -c -emit-llvm <sample.metal> -o <sample.bc>
clang -S -emit-llvm -x ir <sample.bc> -o <sample.ll>
```

### full-batch 验证

只要本轮改动影响 canonical compare、IR 参数建模、MSL emission、resource 语义、地址空间或其它可能改变风险分布的逻辑，收尾时默认执行：

```bash
python3 Scripts/ir_semantics_roundtrip_runner.py --corpus-root ~/Library/Containers/io.playcover.PlayCover/ShaderCorpus --allow-failures
python3 Scripts/ir_semantics_roundtrip_runner.py --diagnostics-root ~/Library/Containers/io.playcover.PlayCover/ShaderSourceDiagnostics --allow-failures
```

当前最重要的不是“有没有跑”，而是：

- 新旧 `risk-report.json` 的 `L3` 数量如何变化
- 共有样本口径下有没有实际改善
- 有没有新增 `L3`

## 当前完成判定

当前每个任务的完成判定统一为：

1. 已选出一个明确 case / 差异模式
2. 已完成足够深入的 canonical diff 分析
3. 已判断它更像 compare 问题还是实现问题
4. 若值得修，已完成一次最小实现修改
5. 已完成单 case 验证
6. 已完成 full-batch canonical compare 复跑
7. 已明确记录风险数量变化与下一步建议

只有满足这 7 条，当前任务才算真正闭环。

## 当前非默认验证

下面这些事项当前不写成默认 TODO 或完工 gate：

- `QQ飞车手游` 启动 smoke
- host bridge registration acknowledgement 稳定性
- `L3` 最小行为测试
- 更重的 live / `.gputrace` 验证

只有当某个具体 case 的证据已经逼近行为层，才再考虑升级到更高层验证。

## Agent 工作流程

1. 读取本文档，先理解 **当前主线** 与 **TODO** 的最新状态
2. 严格选取一个当前最高优先级的未完成任务执行。每次只允许取一个任务执行，严禁对着最终目标死磕。
3. 若最高优先级任务处于阻塞状态（如需人工/外部协助）。立即停止并汇报。严禁执行任何与解决阻塞本身无关的任务。
4. 若任务过大，先拆分出新子任务追加到 TODO，再只完成其中**最关键**的一个。单个TODO不宜过长。
5. 若这次实现了新功能，尽可能靠 skills 或 mcp 做 **实际测试**；若受环境限制，至少做 **模拟性质、离线或最小样本测试**
6. 执行完毕后整理文档：结合已有内容，**深度整理并同步全局信息**，更新优先级、当前主线、TODO、验证与经验；较旧信息可下沉到独立参考文档，主体保持简洁，**不要只做追加**，禁止擅自在主线新增新的章节。
7. 复盘工作流；若本轮新增的测试脚本或辅助脚本对后续仍有价值，也应一并整理并提交。如果当前你手工执行的一些流程在未来预计仍会高频反复用到，考虑使用脚本来完成，并更新到文档参考信息。另外，最重要的：最优方案往往会随着你的探究得到新信息而发生改变。你拥有很大的自主决定权，除了最终目标不能改变，中间的技术路线均可以随时根据实际情况去重新调整。
8. 收尾完成后执行 `git commit`

> 注：`git commit` 不是日常构建/测试/验证闭环的一部分；若当前会话没有明确要求提交，默认停在“变更已落盘且文档已同步”的状态即可。
>
> **每个 agent 默认只完成一个任务，不要并行推进多个主线任务。**

## 踩坑与经验

- **compile green 不等于语义等价**
- **不要把“文本完全一样”误当成“语义一样”**；当前默认应以 canonical summary + 风险分级为主
- **先做离线，再做 live**；在当前阶段，live 不是默认主战场
- **优先把高频手工流程脚本化**；若无法脚本化，也不能默认把用户人工操作写成日常 gate
- **主文档不要直接暴露会漂移的本机快照**：本机增强入口、历史批量快照、manifest 描述文字与局部样本数量都应下沉到参考文档，主文档只保留当前主线真正依赖的控制面事实
- **非 preset 的默认输出目录必须避免碰撞**：当前离线路径允许 agent 近同时发起 corpus / diagnostics 等批量运行；默认输出目录若只按秒命名，会导致报告互相覆盖，因此默认目录需要追加唯一后缀
- **L2 compare 需要主动降噪**；更细的降噪对象与风险口径统一见 `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考，当前主线推进**不必须读取**）
- **resource metadata 的 `air.address_space` 显式化不应重复放大**；当函数参数 `addrspace` 摘要已一致时，这更像 compare 噪声，而不是 entry/resource 语义真的发生变化
- **single-field output 先不要急着改 compare**；当 `outputSemantics` 一致但 `returnSignature` 出现 `wrapped -> bare` 漂移时，应先检查 converter 是否把 original IR 的 single-field wrapped return 过早塌平，只有排除生成侧后才考虑 compare 口径
- **constant buffer struct 的 `&` / `*` 选择会直接影响 `dereferenceable(N)` 是否能 round-trip 保住**；当 `entry 参数类型摘要变化` 表现为 `ptr addrspace(2) dereferenceable(N) -> ptr addrspace(2)` 时，应优先检查 converter 是否把 `_Foo_Type` / `cb_Foo_Type` 这类用户 struct 误降成指针参数

## 参考信息

### 本目录主文档

- `01-现状调研与缺口.md`（需要理解“当前手头的证据链覆盖到哪里、还差什么”时再读，当前日常推进**不必须读取**）
- `02-总体技术路线.md`（**建议读取**；分层模型与止损边界的背景参考）
- `03-L1-IR-RoundTrip.md`（**建议读取**；round-trip 入口与脚本参考）
- `04-L2-CanonicalCompareAndRiskGrading.md`（工作参考；保留 compare / risk / gate 报告语义说明）
- `05-L3-最小行为测试.md`（资料参考，当前**不纳入默认规划**）
- `06-L4-真实场景验证.md`（资料参考；仅在需要更重 live / `.gputrace` 验证时再读）
- `07-首轮基线与历史进展归档.md`（历史归档与样本名单参考，**不必须读取**）
- `08-当前代表集与Gate契约参考.md`（维护 preset / gate / manifest 细节，或排查 `gate-summary.json` / `preset-manifest.json` 口径不一致时再读）

### 当前重点分析目录

- `difference-analysis/buffer-noalias/00-progress.md`
- `difference-analysis/buffer-noalias/04-implementation-result.md`
- `difference-analysis/buffer-noalias/05-full-batch-compare.md`
- `difference-analysis/resource-metadata-addrspace/04-implementation-result.md`
- `difference-analysis/resource-metadata-addrspace/05-full-batch-compare.md`
- `difference-analysis/resource-type-name-preservation/04-implementation-result.md`
- `difference-analysis/resource-type-name-preservation/05-full-batch-compare.md`
- `difference-analysis/single-field-return-wrapper/04-implementation-result.md`
- `difference-analysis/single-field-return-wrapper/05-full-batch-compare.md`
- `difference-analysis/constant-struct-reference-dereferenceable/04-implementation-result.md`
- `difference-analysis/constant-struct-reference-dereferenceable/05-full-batch-compare.md`

### 相关实现与工具

- `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LLVMDisassembler.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetallibParser.swift`
- `Scripts/corpus_replay_runner.py`
- `Scripts/ir_semantics_roundtrip_runner.py`
- `Scripts/ir_canonical_compare.py`
- `Scripts/test_ir_canonical_compare.py`
- `Scripts/test_ir_semantics_roundtrip_runner.py`
- `Scripts/ir_semantics_behavior_runner.py`
- `Scripts/test_ir_semantics_behavior_runner.py`
- `Scripts/metal_compute_behavior_runner.swift`
- `Scripts/check_gputrace_sources.py`
- `Scripts/compare_capture_runs.py`
- `Scripts/e006d_render_diff.py`
- `Scripts/runtime_launch_diagnostics_summary.py`
