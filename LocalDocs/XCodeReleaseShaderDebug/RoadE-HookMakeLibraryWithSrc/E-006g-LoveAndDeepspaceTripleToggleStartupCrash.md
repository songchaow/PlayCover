## E-006g：`恋与深空` 在 `metal capture + startup injection + shader replacement` 同开时启动崩溃

## 状态：IN PROGRESS（`E-006g1` 已完成，当前推进 `E-006g2`）

> ⚠️ **这是当前最优先收敛的确定性 blocker。** `E-006c` 已经证明“.gputrace 中源码可见”链路本身可以打通；当前更接近最终落地的阻塞，是 **`恋与深空` 在同时启用 `metalCaptureEnabled=true`、`injectMetalCaptureEnvironment=true` 与 `shaderSourceReplacementEnabled=true` 时的启动兼容性**。这条线若不收敛，Road E 仍无法在真实 app 上稳定保住“截帧 + 最早阶段 inject + shader replacement”三者并存。

## 问题定义

当前待解问题是：

- app：`恋与深空`
- bundleId：`com.papegames.lysk`
- 当前安装版本：`5.0.0`
- 现象：当以下三项同时开启时，app 在启动阶段崩溃或无法稳定完成启动：
  1. `metalCaptureEnabled=true`
  2. `injectMetalCaptureEnvironment=true`
  3. `shaderSourceReplacementEnabled=true`

这条线的关键点，不是“单独打开截帧是否可用”，而是 **最终目标所需要的三项能力能否在同一真实 app 上并存**。

## 当前已知事实

### 0. `E-006g1` 已完成：最小五象限 fresh launch 基线已固化（2026-04-07）

已新增自动化脚本：

- `Scripts/e006g_launch_matrix_runner.py`
- `Scripts/test_e006g_launch_matrix_runner.py`

并已对 `com.papegames.lysk` 执行 `A/B/C/D/E` 五象限 fresh launch：

| Case | `metalCaptureEnabled` | `injectMetalCaptureEnvironment` | `shaderSourceReplacementEnabled` | 结果 |
|---|---|---|---|---|
| A | false | false | false | `launch_app -> create_session` 成功，`lastEvent=playcover_launch_complete` |
| B | true | false | false | 成功，`lastEvent=playcover_launch_complete` |
| C | true | true | false | 成功，`lastEvent=playcover_launch_complete` |
| D | true | false | true | 成功，`lastEvent=playcover_launch_complete` |
| E | true | true | true | 成功，`lastEvent=playcover_launch_complete` |

固化产物位于：

- `build/e006g-launch-matrix/`

当前 fresh baseline 下：

- **五个 case 均成功进入 `ready` session**
- `RuntimeLaunchDiagnostics/com.papegames.lysk/launch-events.jsonl` 最新五轮均完整到达 `playcover_launch_complete`
- 当前 fresh run 中**未复现**“三开关同开启动崩溃”

因此 `E-006g1` 已回答“当前环境 fresh launch 下哪一个组合稳定触发崩溃？”——**答案是：这轮五象限里没有任何一个组合触发崩溃**。主线随之切换到 `E-006g2`：解释**为什么历史上存在 blocker 报告，而当前 fresh baseline 不再复现**。

### 1. 这三个开关都已经是仓库中的正式控制面

当前仓库中已经存在并暴露：

- `metalCaptureEnabled`
- `injectMetalCaptureEnvironment`
- `shaderSourceReplacementEnabled`

其中：

- `metalCaptureEnabled`：让 runtime 初始化 `MTLCaptureManager`
- `injectMetalCaptureEnvironment`：让 host 在启动目标 app 时注入额外 Metal capture 环境变量（包括 `DYLD_INSERT_LIBRARIES=/usr/lib/libmtlcapture.dylib`）
- `shaderSourceReplacementEnabled`：允许 `makeLibrary(...)` 路径尝试源码重编译替换

因此这条线不需要再补新的手工控制面，重点是**用已有控制面把问题稳定成自动化矩阵**。

### 2. 当前环境里，`恋与深空` 已经具备“真实 app + 三开关”排查条件

当前环境已确认：

- `bundleId=com.papegames.lysk`
- 版本 `5.0.0`
- 当前安装实例中 `metalCaptureEnabled=true`
- 当前安装实例中 `injectMetalCaptureEnvironment=true`
- 当前安装实例中 `shaderSourceReplacementEnabled=true`

换句话说，这条线不是纸面风险，而是**当前环境已具备的真实 blocker**。

### 3. 这条线现在已有专项文档、自动化脚本与 fresh baseline

当前仓库范围内：

- 已有 `恋与深空` 对应的专项文档
- 已有 `Scripts/e006g_launch_matrix_runner.py` / `Scripts/test_e006g_launch_matrix_runner.py`
- 已有 `build/e006g-launch-matrix/` fresh baseline 快照

因此这条线已经完成“先把问题整理成**可重复、可自动化、可归档**的最小验证路径”这一步；后续不能再把问题描述停留在“尚未固化矩阵”，而应转向解释**历史 blocker 与当前基线之间的差异**。

### 4. 这条线的日常验证可以保持 agent 全自动

当前仓库 / 工具链已经具备：

- `build_and_install.sh`
- `get_app_settings` / `update_app_settings`
- `launch_app`
- `create_session`
- `RuntimeLaunchDiagnostics/<bundleId>/launch-events.jsonl`
- `Scripts/runtime_launch_diagnostics_summary.py`

因此这条线的默认推进方式应是：

- **自动切换三开关组合**
- **自动 launch / create_session**
- **自动固化 diagnostics / crash 证据**

而不是引入人工登录、手点 UI、手工看窗口是否闪退之类的 gate。

## 当前优先假设（按排查顺序）

1. **最优先假设：`injectMetalCaptureEnvironment=true` 带来的启动期注入，与 `恋与深空` 启动链路本身不兼容**
   - 这条线最靠前、也最可能在 runtime 尚未完成注册前就触发崩溃
2. **第二假设：startup injection 可过，但 `PlayCover.launch()` 早期 preload / swizzle 安装与 app 初始化时序冲突**
   - 这时通常还能在 `RuntimeLaunchDiagnostics` 中看到部分事件
3. **第三假设：真正触发问题的是首个 replacement 尝试，而不是更早期的 startup injection / swizzle**
   - 需要在“startup injection 开启但 replacement 关闭”的对照下才能确认

## 推荐的最小自动化验证路径

> 目标：先把“哪一个开关组合触发启动崩溃”稳定成 agent 可重复执行的最小矩阵。

### 固定前提

- 必须使用标准脚本构建 / 安装：

```bash
./BuildScripts/build_and_install.sh
```

- 不要手写 `xcodebuild`
- 不要手工复制 `.app`

### 最小五象限对照矩阵

优先使用下面五个 case，而不是一上来就跑完整 `2^3` 八象限：

| Case | `metalCaptureEnabled` | `injectMetalCaptureEnvironment` | `shaderSourceReplacementEnabled` | 目的 |
|---|---|---|---|---|
| A | false | false | false | 纯基线 |
| B | true | false | false | 只开 delayed capture |
| C | true | true | false | 看 startup injection 本身是否足以触发 |
| D | true | false | true | 看 replacement 在 delayed capture 下是否可过 |
| E | true | true | true | 当前问题态 |

**默认优先比较 `C` vs `E`**：这能最快判断“startup injection 本身”与“startup injection + replacement 并存”哪个更接近根因。

### 每轮自动化采集内容

每轮至少固化以下证据：

1. fresh build/install 是否完成
2. 当前 app settings（三个开关的状态）
3. `launch_app(bundleId=com.papegames.lysk)`
4. 是否成功 `create_session`
5. `RuntimeLaunchDiagnostics/com.papegames.lysk/launch-events.jsonl`
6. `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.papegames.lysk --limit 5`
7. 是否出现新的 crash log / 若 diagnostics 缺失，是否说明崩溃早于 `PlayCover.launch()`

**注意**：若 `injectMetalCaptureEnvironment=true` 时 app 在 runtime 尚未注册前就崩溃，那么“没有 runtime diagnostics 文件 / 只有极短链路”本身也是有效证据，而不是流程失败。

## 当前 TODO 拆分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-006g1 | 三开关最小五象限启动矩阵 + diagnostics / crash 证据固化 | ✅ DONE（2026-04-07） | 已新增 `Scripts/e006g_launch_matrix_runner.py`，并对 `com.papegames.lysk` 执行 `A/B/C/D/E` 五象限 fresh launch；五组 settings 均与预期一致，`launch_app -> create_session` 全部成功进入 `ready`，`launch-events.jsonl` 最新 run 全部到达 `playcover_launch_complete` |
| E-006g2 | 定位崩溃发生在 host launch env / startup injection / `PlayCover.launch()` / first replacement 的哪一段 | TODO（当前先做） | `E-006g1` 当前未复现历史 blocker；下一步应解释“历史上为何会崩、当前为何不崩”，重点比对 host launch env / preload / injection / first replacement 的时序与环境差异 |
| E-006g3 | 在可进入 runtime 的 case 下，对照 preload / swizzle / first replacement 事件，缩小到最小阶段差异 | TODO | 复用现有 `RuntimeLaunchDiagnostics` 与 `replacement_attempt` 证据链 |
| E-006g4 | 设计并验证“不牺牲源码可见性目标”的修复方案 | TODO | 最终方案不能退化为“永久关 startup injection”或“永久关 replacement” |

## `E-006g1` 本轮结论（2026-04-07）

1. **当前 fresh baseline 不支持“startup injection 单独就会稳定崩”的假设**
   - `C=true/true/false` 已稳定进入 `ready`
2. **当前 fresh baseline 也不支持“startup injection + replacement 并存必崩”的假设**
   - `E=true/true/true` 同样稳定进入 `ready`
3. **问题已从“复现并分离开关”转为“解释历史 crash 与当前基线之间的环境差异”**
   - 当前更像是**时序 / 环境 / deploy 状态差异**问题，而不是单纯的三开关逻辑组合必现
4. **当前证据链仍有一个缺口：runtime diagnostics 的 `lastDetails` 尚未记录 `injectMetalCaptureEnvironment`**
   - 五象限脚本已把三开关 settings 与 per-case snapshot 固化下来，但 `launch-events.jsonl` 末事件当前仅回显 `metalCaptureEnabled` 与 `shaderSourceReplacementEnabled`
   - 因此 `E-006g2` 应优先补强“startup injection 是否真的进入 host launch env / runtime breadcrumb”的时序可见性

## 候选解决方向

### 方向 A：缩小 startup injection 的作用面

思路：

- 先证明 `injectMetalCaptureEnvironment=true` 是否是首要触发因子
- 若是，再研究是否能对 `恋与深空` 缩小启动期注入范围，而不是全量 `DYLD_INSERT_LIBRARIES`

适用前提：

- 若 `C` 就崩，而 `B` 不崩，这条线优先级最高

风险：

- 需要确认不会因此丢失最终 `.gputrace` attribution 所依赖的能力

### 方向 B：保留 startup injection，但让 replacement 在冷启动阶段先保守退让

思路：

- 如果 `C` 可过、`E` 崩，则说明 startup injection 本身不一定是问题
- 此时应优先怀疑首个 replacement 发生过早

适用前提：

- `C` 稳定、`E` 不稳定

风险：

- 可能牺牲一部分启动早期 shader 的源码 attribution，需要明确是否可接受

### 方向 C：bundle / selector / module 级选择性旁路

思路：

- 若问题最终集中在少数 startup shader / selector / module
- 可考虑对 `恋与深空` 做细粒度 bypass，保住大部分 capture + replacement 链路

适用前提：

- 崩溃已能收敛到较小命中面

风险：

- 工程上是折中方案；只能在根因已基本明确后使用

## 关单标准

满足以下条件后，`E-006g` 才可视为完成：

1. `恋与深空` 在 `metalCaptureEnabled=true`、`injectMetalCaptureEnvironment=true`、`shaderSourceReplacementEnabled=true` 时可稳定启动
2. 启动后不会立即 crash，也不会让 session / runtime 注册链路异常退化
3. 解决方案明确回答：到底是 startup injection、preload / swizzle、还是 first replacement 导致的问题
4. 最终方案不以永久关闭 startup injection 或 replacement 为代价
5. 日常复测仍可由 agent 独立完成，不引入人工登录、点按钮或手动 GUI 操作

## 参考锚点

- `README-MCP.md`
- `PlayCover/Model/AppSettings.swift`
- `PlayCover/Views/AppSettingsView.swift`
- `PlayCover/Model/PlayApp.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Scripts/e006g_launch_matrix_runner.py`
- `Scripts/test_e006g_launch_matrix_runner.py`
- `Scripts/runtime_launch_diagnostics_summary.py`
- `E-006e-QQSpeedCaptureReplacementStartupCrash.md`
- `00-Dashboard.md`
