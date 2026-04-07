## E-006d：原神同一界面重复启动时的随机渲染异常调查

## 状态：搁置（偶现问题，保留进度）

> ⚠️ **本文档是 `E-006d` 的专项执行说明。** `00-Dashboard.md` 负责记录当前最高优先级、最新基线与全局 TODO；本文档只展开 `E-006d` 自身的判断顺序、交付标准与技术备注。

当前说明：`E-006d` 已在 `00-Dashboard.md` 中下调为**搁置（偶现，保留进度）**。除非 dashboard 明确恢复优先级，否则本文档仅作为后续回看与专项恢复时的执行参考，不再构成当前日常默认入口。

## 现象

- 用 PlayCover 打开原神，按 Road E 流程执行 `metal IR 提取 -> 反编译为 MSL -> makeLibrary(source:) 重编译替换`
- 停留在**同一个界面**，多次启动后画面表现不完全一样
- **mesh 没有变化**，但局部渲染结果会随机异常
- 由于原神是延迟管线，异常也可能出现在后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置
- **当前最保守结论**：最稳定的复现口径是比较**进行了反编译/重编译替换**与**完全不做替换**两种运行方式；但根据当前十二轮快照矩阵（`off1/off2/on1~on10`），**跨模式稳定不同尚未被 corpus / trace 级证据坐实**

## 目标

回答以下四个问题：

1. **"替换"与"不替换"时，最终效果差异是否稳定存在？**
2. **同一界面重复启动时，进入 shader 链路的输入是否相同？**
3. **若输入相同，生成出的单模块 MSL / 聚合 MSL / compile 结果是否完全一致？**
4. **若生成结果也相同，运行时是否稳定使用了替换后的 library，还是问题出在更后续的着色 / 后处理 / render pipeline 阶段？**

其中第 4 问不能只停留在"shader 是否被替换"。如果 corpus / aggregate / trace 证据还不足以稳定解释差异，就必须继续比较 **draw call 数、Render Encoder 结构、Pipeline State 分组、关键 pass summary**。

## 当前最该做的事

仅在 `00-Dashboard.md` 明确恢复 `E-006d` 优先级后，才按本节继续推进。

`E-006d8` 已从"缺工具、缺证据"前移为四条具体 blocker。每条都应保持 agent 可独立推进（详见下表）。

| # | blocker | 现状 | 推进方式 | agent 可独立完成？ |
|---|---|---|---|---|
| 1 | **capture bridge reachability** | `on-run10` 确认：`create_session(bundleId)` 首次即返回 ready session，`get_capture_status` 进入 `available=true`，容器内 `capture_metal_frame` 成功；bundle 级 `bridge not reachable` 未复现。一次短暂 `list_sessions` 空窗更像 registry 可见性抖动。详细演进见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | 继续观察 session 可见性偶发不一致，主排查面已下移到 trace 覆盖 | ✅ 是 |
| 2 | **capture 输出路径** | 容器内 custom path 已验证可用；容器外权限边界未明。短期可继续用默认容器路径 + `--latest-gputrace` | 长期再单独验证容器外路径沙盒权限 | ✅ 是（`--latest-gputrace` 已自动化） |
| 3 | **trace 合法 MSL 覆盖偏低** | preload 修复后 `on-run11`：`922 refs = 3 valid + 9 non-MSL + 910 missing`、`visibleMSL=3`。`b3b` 已收敛：两边 raw index 均含 `54` 个 `14/15` 位 short token，但真正额外落盘成 bundle 可见文件的只有 `off-run1=3/54`、`on-run11=2/54`；共享的 2 个 short 文件均为 `bplist`，only-off 额外 1 个是未被 canonical index 引用的 short MSL。`b3c` 进一步确认：同轮 `replacement-on-run12(device)` / `replacement-on-run13(scope)` 都只有 `3 referenced valid + 9 non-MSL`，missing 仅 `1115 -> 1105`，raw short file writes 也都是 `2` | `device` vs `scope` 不是主瓶颈；当前转回 canonical 16 位 referenced hash 的 bundle 写入条件，short token 可见性继续作为旁路证据 | ✅ 是 |
| 4 | **绘制内容差异未正式产出** | `e006d_render_diff.py` 入口就绪，GUI 自动化环境未验证 | 在 Xcode GUI / Accessibility / `cliclick` 可用时，跑 `off-run1` vs `on-run5` 结构化 diff | ⚠️ 需 GUI 自动化环境 |

**本轮推进标准**：至少把当前问题明确收敛到以下之一：
1. 输入集合不稳定
2. 输入稳定但输出/聚合结果不稳定
3. 输出稳定但 replacement / `llvm-dis` 闭环只部分命中
4. capture 导出 / trace 可见性仍不稳定
5. 替换链路稳定，但差异落在更后续 render pipeline / post-processing

**当前最新收敛（2026-04-06）**：host 侧 session / capture 修复已全部落地。`on-run10` 确认 capture bridge reachability 收敛；preload 修复后 `on-run11` scope capture 提升到 **`922 refs = 3 valid + 9 non-MSL + 910 missing`**、`visibleMSL=3`。

**`b3a` 归因**：修正 `gputrace` 归因指纹（忽略尾部 `NUL` 终止符）后，确认 3 个 visible MSL 全部对应当前快照中的 replacement 聚合源码（3 个 `moduleKey` 已确认，详见 `b3a` 产出）。

**`b3b` 收敛（2026-04-06 深夜）**：在 `compare_capture_runs.py` / `check_gputrace_sources.py` 中补上 raw short-hash file writes 摘要后，重新按 canonical 口径对比。`off-run1` 与 `on-run11` 的 raw index 都有 `54` 个 `14/15` 位 short token（`shared=37`），但真正额外落盘成 bundle 可见文件的只有 `off-run1=3/54`、`on-run11=2/54`：共享可见 short 文件为 `53EEDD95681D340`、`76E05038E17F34`（均为 `bplist`），only-off 额外 1 个 `B91673E5592A2B8` 为 short MSL。**这些 short 文件都不进入 canonical 16 位 index 引用集合；即便 `B91673E5592A2B8` 是 MSL，也只是“可见但未被 canonical 引用”的旁路文件，不会减少 `missingReferencedHashes` 或增加 `referencedValidMSLHashes`。**因此，short token 可见性与 canonical missing 基本正交，不能再作为 `910 missing` 的主解释。

**`b3c` 收敛（2026-04-06 深夜）**：本轮在同一 session / 同一 replacement-on 状态下连续执行 `device` 与 `scope` capture，并分别固化为 `replacement-on-run12(device)` / `replacement-on-run13(scope)`。两边的主指标几乎一致：都只有 `3 referenced valid MSL`、`9 referenced non-MSL`、`2` 个未被 canonical index 引用的 short `bplist` 文件；`indexHashReferences` 仅 `1127 -> 1117`，`missingReferencedHashes` 仅 `1115 -> 1105`，`raw short-hash file writes` 也只是 `2/72 -> 2/69`。**结论：`device` vs `scope` capture 不是当前源码写入规模的主瓶颈；它最多带来轻微 missing 波动，没有新增 visible / referenced valid MSL。**

> ⚠️ **历史中间口径（已被 `b3b` / `b3c` 校正取代）**：早期曾误认为 `on-run11` 带来 `0 → 910` missing 的变化，或把 `14/15` 位 short token、`scope` capture 视为 replacement 独有主因。这些结论已被最新基线校正推翻；详情与演进时间线见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。

后续排查面：
1. **✅ `b3a` 已完成：3 个可见 MSL 已归因**
2. **✅ `b3b` 已完成：raw short token 的落盘条件与 canonical missing 的关系已澄清**
3. **✅ `b3c` 已完成：`device` vs `scope` 不是当前源码写入规模主因**
4. **若后续恢复优先级，首要排查方向**：继续归因 canonical 16 位 referenced hash 的 bundle 写入条件
5. **session 可见性抖动**：继续观察，确认只影响 registry 而不影响实际 bridge reachability

## 已完成的子项

| 子项 | 内容 | 状态 |
|---|---|---|
| E-006d1 | 输入 diff 工具（`compare_capture_runs.py`） | ✅ DONE |
| E-006d2 | 聚合源码 diff（成功路径落盘 `aggregate.generated.metal`） | ✅ DONE |
| E-006d3 | replacement 开关（`shaderSourceReplacementEnabled` / `set_shader_replacement_mode.py`） | ✅ DONE |
| E-006d4 | run 快照（`snapshot_capture_run.py`） | ✅ DONE |
| E-006d5 | `.gputrace` 固化（快照内含 trace + 源码覆盖摘要） | ✅ DONE |
| E-006d6 | run matrix（`analyze_capture_run_matrix.py` / `e006d_matrix_runner.py`） | ✅ DONE |
| E-006d7 | trace 归因索引（`gputrace-attribution-index.json`） | ✅ DONE |
| E-006d8a | runtime 启动 breadcrumb（`RuntimeLaunchDiagnostics` + summary 脚本） | ✅ DONE |
| E-006d8b1 | 标准化 render-diff runner（`e006d_render_diff.py`） | ✅ DONE |
| host session / capture 基础设施修复 | split-brain、bridge ping、ready-session probe、capture status 去 lazy-load、默认容器回收、GPUToolsCapture 预加载 | ✅ DONE + 测试覆盖 |
| E-006d8-b3-fix1 | GPUToolsCapture 预加载（`PlayCover.launch()` 早期，replacement 前加载 capture 库） | ✅ DONE（`on-run11` 验证生效） |
| E-006d8-b3-fix2 | `compare_capture_runs.py` 对旧 snapshot 的 `gputraceSummary` / `gputraceAttribution` 自动重算，避免旧基线把 `off-run1` 误判为 `0 missing` | ✅ DONE + 测试覆盖 |
| E-006d8-b3b | raw short token 可见性摘要：输出 `raw short-hash file writes`，确认 `off-run1=3/54`、`on-run11=2/54`，且这些 short 文件与 canonical missing 基本正交 | ✅ DONE + 测试覆盖 |

## 优先排查顺序

### 1. 先固定复现条件

- 固定 app 版本、停留界面、画质设置、注入步骤和启动顺序
- 对原神当前链路，默认以"启动后数十秒自动停在登录界面"为稳定复现面
- 统一入口：`Scripts/e006d_matrix_runner.py prepare-run / finalize-run / analyze`（`b3c` 之后对 live trace 建议显式带 `--capture-target`，把 capture 策略写入 snapshot 元数据）
- 切换模式：`Scripts/set_shader_replacement_mode.py --mode off/on`
- 默认用 `finalize-run --latest-gputrace` 从默认容器回收 `.gputrace`

### 2. 先确认"替换 vs 不替换"差异是否稳定

- 当前矩阵结论：`off-vs-on allPairsDifferent=False`，**尚未形成跨模式稳定不同证据**；`replacement-on-run10` 纳入后，`mode=on missingAttemptWhileEnabledPairs=17`
- 只有当"同模式稳定、跨模式稳定不同"成立后，才继续往更细的 stage / pipeline 归因下钻

### 3. 再比较"输入是否相同"

- 比较每轮 `moduleKey` 集合、`functionNames` / `functionTypes`、`.bc` / `.ll` 哈希
- 当前已证明：`mode=off` 和 `mode=on` 各自 `allInputStable=True`、共享 `moduleKey=91/91`

### 4. 再比较"输出是否相同"

- 对相同 `moduleKey` 比较 `module.generated.metal`、聚合 MSL、compile 结果
- 当前已证明：单模块本体未出现语义级随机漂移
- 但 `mode=on allReplacementAttemptStable=False`、`missingAttemptWhileEnabledPairs=17`

### 5. 最后比较"替换与实际使用"

- 确认 `attemptLibraryReplacement(...)` 是否都进入成功路径
- 若 base pass 接近但最终画面不同，必须进入绘制内容差异检查
- 绘制内容差异方法见 [E-006d-RenderingPathDiffReference](E-006d-RenderingPathDiffReference.md)

## 当前工作假设

- **假设 A：输入并不稳定**（❌ 已否定：同模式输入稳定）
- **假设 B：`IR -> MSL` 结果不稳定**（❌ 已否定：单模块本体未漂移）
- **假设 C：runtime 替换或 pipeline 实际使用不稳定**（⚠️ 部分证据：`missingAttemptWhileEnabledPairs=17`）
- **假设 D：问题出在更后续的着色 / 后处理 / render pipeline 阶段**（待验证）
- **假设 E：MSL 只是"可编译"而非"语义等价"**（待验证）
- **假设 F：host 把 registration ready 误判成 command-ready**（❌ 已否定）
- **假设 G：host 侧 `create_session(bundleId)` reachability 不一致**（❌ 已基本否定：`on-run10`/`on-run11` 未复现）
- **假设 H：GPUToolsCapture 加载时序导致 replacement library 错过观测窗口**（⚠️ 部分确认：preload 修复后 `visibleMSL` 从 `0` 恢复到 `3`，但覆盖率仍极低，说明时序是因素之一但不是唯一瓶颈）
- **假设 I：`device` vs `scope` capture target 是当前覆盖率主因**（❌ 已否定：`replacement-on-run12(device)` / `run13(scope)` 仅 `missingReferencedHashes` 有 `-10` 轻微波动，未带来新增 visible / referenced valid MSL）

## 完成标准

- 至少形成一组**可重复复现**的对照样本
- 至少形成一组**替换 vs 不替换**的稳定对照样本
- 至少形成一组**agent 独立完成**的 live 启动 / 等待 / 截帧 / 快照固化样本
- 能明确将问题归到以下某一层：
  - 替换开启后引入的稳定差异（但根因层级未定）
  - 输入差异
  - `IRToMSLConverter` 非确定性 / 错误 lowering
  - 聚合 MSL / replacement 链路问题
  - runtime 实际使用阶段问题
  - 更后续的着色 / 后处理 / render pipeline 顺序或配置问题
- 若定位到具体 blocker，需要把它转化为可离线 replay / compile / diff 的样本或规则

## 技术备注（从 dashboard 下沉）

- **延迟管线下，base pass 看起来类似并不能排除后续阶段问题**
- **"替换 vs 不替换"必须有明确控制面**：统一使用 `shaderSourceReplacementEnabled` / `Scripts/set_shader_replacement_mode.py`
- **run 快照要在 live 结束后立即固化**：使用 `Scripts/snapshot_capture_run.py` 或 `Scripts/e006d_matrix_runner.py finalize-run`
- **成功路径也要落盘聚合产物**：只保留单模块 `.bc/.ll/.metal` 不足以覆盖聚合顺序、重名去重
- **draw call / Render Encoder / Pipeline State 是独立证据层**：当 shader / trace 侧证据不足时必须补
- **`module.meta.json` 的统计字段要与真实 artifact diff 分开看**：`captureCount`、`sourceCacheKeys` 等变化不等于本体变化
- **GPUToolsCapture 预加载时序直接影响 trace 覆盖率**：但 `b3b` 已确认 `14/15` 位 short token 现象非 replacement 独有；在 `off-run1` / `on-run11` 中它们大多只停留在 raw index，真正额外落盘的只有 `3/54` 与 `2/54`，且这些 short 文件不进入 canonical 16 位引用集合，因此不能拿它们直接解释 `missingReferencedHashes`
- **旧 snapshot 的 `gputraceSummary` / `gputraceAttribution` 不可直接信任**：`compare_capture_runs.py` 已改为优先对原始 `.gputrace` 现算，避免 schema 演进导致误判
- **host 侧 session / capture 基础设施已全部修复**：详细修复历史见 [00-Dashboard-Archive](00-Dashboard-Archive.md)
- **更早的 lowering 细节与已收敛 compile blocker 不再由本文档维护**：见 `E-004-MetallibSourceExtraction.md`、`E-006d-RenderingPathDiffReference.md` 与 archive

## 与其他文档的关系

- 当前主线 / 优先级 / TODO：`00-Dashboard.md`
- 历史 live blocker 时间线与 run 细节：`00-Dashboard-Archive.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- corpus replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
- 绘制内容差异（draw call / render pass / pipeline）专项参考：`E-006d-RenderingPathDiffReference.md`
- Xcode GPU GUI 自动化工具说明：`../../XCodeOperation/README.md`
