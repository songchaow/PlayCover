## E-006d：原神同一界面重复启动时的随机渲染异常调查

## 状态：TODO

> ⚠️ **本文档是 `E-006d` 当前主线的详细执行说明。** `00-Dashboard.md` 负责记录当前最高优先级、最新基线与全局 TODO；本文档只展开 `E-006d` 自身的判断顺序、交付标准与技术备注。

## 现象

- 用 PlayCover 打开原神，按 Road E 流程执行 `metal IR 提取 -> 反编译为 MSL -> makeLibrary(source:) 重编译替换`
- 停留在**同一个界面**，多次启动后画面表现不完全一样
- **mesh 没有变化**，但局部渲染结果会随机异常
- 由于原神是延迟管线，异常也可能出现在后处理、着色阶段，或更上层的 render pipeline 顺序 / 配置
- **当前最保守结论**：最稳定的复现口径是比较**进行了反编译/重编译替换**与**完全不做替换**两种运行方式；但根据当前九轮快照矩阵，**跨模式稳定不同尚未被 corpus / trace 级证据坐实**

## 目标

回答以下四个问题：

1. **"替换"与"不替换"时，最终效果差异是否稳定存在？**
2. **同一界面重复启动时，进入 shader 链路的输入是否相同？**
3. **若输入相同，生成出的单模块 MSL / 聚合 MSL / compile 结果是否完全一致？**
4. **若生成结果也相同，运行时是否稳定使用了替换后的 library，还是问题出在更后续的着色 / 后处理 / render pipeline 阶段？**

其中第 4 问不能只停留在"shader 是否被替换"。如果 corpus / aggregate / trace 证据还不足以稳定解释差异，就必须继续比较 **draw call 数、Render Encoder 结构、Pipeline State 分组、关键 pass summary**。

## 当前最该做的事

`E-006d8` 已从"缺工具、缺证据"前移为四条具体 blocker。每条都应保持 agent 可独立推进（详见下表）。

| # | blocker | 现状 | 推进方式 | agent 可独立完成？ |
|---|---|---|---|---|
| 1 | **capture bridge reachability** | `on-run9` 后已明确：针对 `list_sessions` 中的 ready session，`get_capture_status` / `capture_metal_frame` 可立即成功；但 `create_session(bundleId)` 仍可能超时。runtime launch diagnostics 继续显示 registration 主链完整。详细演进见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | 对照 `list_sessions` 现成 session 与 `create_session(bundleId)` 的选取 / probe 行为差异 | ✅ 是（构建 + 安装 + 注入 + launch + session） |
| 2 | **capture 输出路径** | 容器内 custom path 已验证可用；容器外权限边界未明。短期可继续用默认容器路径 + `--latest-gputrace` | 长期再单独验证容器外路径沙盒权限 | ✅ 是（`--latest-gputrace` 已自动化） |
| 3 | **trace 合法 MSL 覆盖偏低** | 最近 fresh trace 自动检查为 `~3/12` 合法 MSL，覆盖率 `~1.4%`。详细数据见 [00-Dashboard-Archive](00-Dashboard-Archive.md) | 新 fresh capture 后继续用 `check_gputrace_sources.py` 检查并归因 | ✅ 是（fresh trace 已可获得，但仍需继续提高覆盖） |
| 4 | **绘制内容差异未正式产出** | `e006d_render_diff.py` 入口就绪，GUI 自动化环境未验证 | 在 Xcode GUI / Accessibility / `cliclick` 可用时，跑 `off-run1` vs `on-run5` 结构化 diff | ⚠️ 需 GUI 自动化环境 |

**本轮推进标准**：至少把当前问题明确收敛到以下之一：
1. 输入集合不稳定
2. 输入稳定但输出/聚合结果不稳定
3. 输出稳定但 replacement / `llvm-dis` 闭环只部分命中
4. capture 导出 / trace 可见性仍不稳定
5. 替换链路稳定，但差异落在更后续 render pipeline / post-processing

**当前最新收敛（2026-04-06）**：host 侧 session / capture 基础设施修复已全部落地 + 测试覆盖。`on-run8` / `on-run9` 确认：直接命中已有 ready session 时，status / capture 命令可立即成功，但 bundle 级 `create_session` 仍可能误报 bridge not reachable。custom `output_path` 在 app 默认容器内可成功。详细演进见 [00-Dashboard-Archive](00-Dashboard-Archive.md)。后续排查面：
1. **host 侧 ready-session 复用 / reachability probe 路径**：为什么 `create_session(bundleId)` 仍会失败，而 `list_sessions` 返回的同一 ready session 却可以直接执行命令
2. **trace 覆盖与归因路径**：fresh trace 已能稳定产出，但 `valid_msl` 仍偏低，下一步应优先解释已有合法 MSL 对应的 replacement / draw call 归属

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
| host split-brain 修复 | stale cleanup 时主动断开 registration channel | ✅ DONE + 测试覆盖 |
| host session ready 收口 | `SessionService.createSession(...)` 改为返回前额外要求 command bridge `ping` 成功；补充 `PlayCoverMCPTests` 覆盖"bridge 延迟可达 / 已注册但不可达" | ✅ DONE + 测试覆盖 |

## 优先排查顺序

### 1. 先固定复现条件

- 固定 app 版本、停留界面、画质设置、注入步骤和启动顺序
- 对原神当前链路，默认以"启动后数十秒自动停在登录界面"为稳定复现面
- 统一入口：`Scripts/e006d_matrix_runner.py prepare-run / finalize-run / analyze`
- 切换模式：`Scripts/set_shader_replacement_mode.py --mode off/on`
- 默认用 `finalize-run --latest-gputrace` 从默认容器回收 `.gputrace`

### 2. 先确认"替换 vs 不替换"差异是否稳定

- 当前矩阵结论：`off-vs-on allPairsDifferent=False`，**尚未形成跨模式稳定不同证据**；`replacement-on-run8` 纳入后，`mode=on missingAttemptWhileEnabledPairs=13`
- 只有当"同模式稳定、跨模式稳定不同"成立后，才继续往更细的 stage / pipeline 归因下钻

### 3. 再比较"输入是否相同"

- 比较每轮 `moduleKey` 集合、`functionNames` / `functionTypes`、`.bc` / `.ll` 哈希
- 当前已证明：`mode=off` 和 `mode=on` 各自 `allInputStable=True`、共享 `moduleKey=91/91`

### 4. 再比较"输出是否相同"

- 对相同 `moduleKey` 比较 `module.generated.metal`、聚合 MSL、compile 结果
- 当前已证明：单模块本体未出现语义级随机漂移
- 但 `mode=on allReplacementAttemptStable=False`、`missingAttemptWhileEnabledPairs=13`

### 5. 最后比较"替换与实际使用"

- 确认 `attemptLibraryReplacement(...)` 是否都进入成功路径
- 若 base pass 接近但最终画面不同，必须进入绘制内容差异检查
- 绘制内容差异方法见 [E-006d-RenderingPathDiffReference](E-006d-RenderingPathDiffReference.md)

## 当前工作假设

- **假设 A：输入并不稳定**（已被矩阵否定：同模式输入稳定）
- **假设 B：`IR -> MSL` 结果不稳定**（已被否定：单模块本体未漂移）
- **假设 C：runtime 替换或 pipeline 实际使用不稳定**（部分证据：`missingAttemptWhileEnabledPairs=13`）
- **假设 D：问题出在更后续的着色 / 后处理 / render pipeline 阶段**（待验证）
- **假设 E：MSL 只是"可编译"而非"语义等价"**（待验证）
- **假设 F：host 把 registration ready 误判成 command-ready**（❌ 已否定：`create_session` 已要求 bridge `ping` 成功 + 单测覆盖；`on-run7` 未再复现 split-brain）
- **假设 G：host 侧 `create_session(bundleId)` 的 ready-session 选择 / reachability probe 仍与 `list_sessions` 暴露出的真实可用 session 不一致**（`on-run9` 新证据：同一轮里 bundle 级 `create_session` 超时，但直接对 ready session 发 `get_capture_status` / `capture_metal_frame` 成功）

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
- **`throw` + 静默 `catch` 回退是 runtime hook 的危险反模式**
- **host 侧 session / capture 基础设施修复已全部落地 + 测试覆盖**：stale cleanup 同步断链、`create_session` 收紧到 bridge `ping`、`get_capture_status` 去 lazy-load + 去 valueOnMainSync——这些都已被 `on-run8`/`on-run9` 验证。剩余问题更像 host 侧 reachability probe / session 选取，而不是 runtime capture 命令整体失效。详细修复历史见 [00-Dashboard-Archive](00-Dashboard-Archive.md)
- **更早的 lowering 细节与已收敛 compile blocker 不再由本文档维护**：见 `E-004-MetallibSourceExtraction.md`、`E-006d-RenderingPathDiffReference.md` 与 archive

## 与其他文档的关系

- 当前主线 / 优先级 / TODO：`00-Dashboard.md`
- 历史 live blocker 时间线与 run 细节：`00-Dashboard-Archive.md`
- 失败样本闭环 / re-capture 策略：`E-004-CorpusClosureAndRecapturePolicy.md`
- corpus replay / batch compile / diff：`E-005-OfflineReplayBatchCompileDiff.md`
- 绘制内容差异（draw call / render pass / pipeline）专项参考：`E-006d-RenderingPathDiffReference.md`
- Xcode GPU GUI 自动化工具说明：`../../XCodeOperation/README.md`
