## E-006g：`恋与深空` 在 `metal capture + startup injection + shader replacement` 同开时启动崩溃

## 状态：IN PROGRESS（`E-006g1` / `E-006g2` 已收敛，当前推进 `E-006g3`）

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
| D | true | false | true | `launch_app -> create_session` 可到 `ready`，但后续 settle window 内会出现 late crash |
| E | true | true | true | `launch_app -> create_session` 可到 `ready`，但后续 settle window 内会出现 late crash |

固化产物位于：

- `build/e006g-launch-matrix/`

当前 fresh baseline 最初回答的是：

- **五个 case 均成功进入 `ready` session**
- `RuntimeLaunchDiagnostics/com.papegames.lysk/launch-events.jsonl` 最新五轮均完整到达 `playcover_launch_complete`
- 也即：fresh launch 本身并不会在 `create_session` 前就稳定失败

因此 `E-006g1` 真正回答的是“当前环境 fresh launch 下哪一个组合会在 runtime 注册前就稳定触发崩溃？”——**答案是：没有任何一个组合在 `create_session` 前稳定失败**。随后 `E-006g2` 通过 settle window 进一步确认：`D/E` 仍会在 launch 完成后数秒内出现 late crash，主线因此继续前移到 `E-006g3` 的命中面收缩。

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
- **自动汇总每个 `processLaunchId` 下的 replacement failure clusters（`event` / `selector` / `cacheKey` / `compilerMessage`）**

而不是引入人工登录、手点 UI、手工看窗口是否闪退之类的 gate。

## 当前优先假设（按排查顺序）

1. **最优先假设：`injectMetalCaptureEnvironment=true` 带来的启动期注入，与 `恋与深空` 启动链路本身不兼容**（❌ `E-006g2` 当前证据已不支持其作为 late crash 主因；`C=true/true/false` 可在 launch 后继续存活，startup injection 不是当前这类崩溃的充分条件）
   - 这条线最靠前、也最可能在 runtime 尚未完成注册前就触发崩溃
2. **第二假设：startup injection 可过，但 `PlayCover.launch()` 早期 preload / swizzle 安装与 app 初始化时序冲突**（⚠️ 目前仍保留为过渡阶段排查项，但优先级已低于 replacement compile / fallback 邻域）
   - 这时通常还能在 `RuntimeLaunchDiagnostics` 中看到部分事件
3. **第三假设：真正触发问题的是首个 replacement 尝试，而不是更早期的 startup injection / swizzle**（✅ `E-006g2` 已部分确认；当前证据更接近“startup 期多个 replacement compile failure / fallback 的集合副作用”）
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

**新增约束（2026-04-07）**：`E-006g` 的 gate 不能只截到 `playcover_launch_complete`。`launch_app -> create_session` 成功后，必须继续保留 app 至少 **10 秒**，再执行 `python3 Scripts/e006g_launch_matrix_runner.py finalize-case ...`，以便把 startup replacement 的 late `replacement_compile_failed` / failure surfaces 一并固化。`finalize-case` 现默认内建 `--settle-seconds 10`；这个窗口来自当前已知 late crash / replacement compile failure 多发生在 launch 后约 **7~8 秒** 的经验基线，日常复测默认直接使用脚本默认值，**不要让 agent 自行改动 settle window**；只有离线测试才应显式传 `--settle-seconds 0`。

## 当前 TODO 拆分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-006g1 | 三开关最小五象限启动矩阵 + diagnostics / crash 证据固化 | ✅ DONE（2026-04-07） | 已新增 `Scripts/e006g_launch_matrix_runner.py`，并对 `com.papegames.lysk` 执行 `A/B/C/D/E` 五象限 fresh launch；五组 settings 均与预期一致，`launch_app -> create_session` 全部成功进入 `ready`，`launch-events.jsonl` 最新 run 全部到达 `playcover_launch_complete` |
| E-006g2 | 系统性汇总 startup 期 `replacement_compile_failed` / fallback failure clusters，确认 late crash 是否由 compile failure 集合触发 | ✅ DONE（2026-04-07，结论已收敛） | 已确认崩溃并不发生在 runtime 注册前；最新 fresh `case E` 已把主 blocker 收敛到 **`cacheKey=791A306ED1B6648B_4577` / `moduleKey=ec0c6f0e72d6fc64daf4d5955cd1ea2cc5e729b0f988b1e857d13bfb54c7f6c3`**，且 `analyze` 已按 compile_failed 优先显示热点 |
| E-006g3 | 把 `compile_failed` 命中面收缩到最小 `cacheKey` / selector / module 集合，为 `E-006g4` 准备最小修复 / 旁路面 | IN PROGRESS（fresh `case E` 已完成；`45AE... / 1cdc...` 已退出 latest failure surface，当前默认入口前移到 `8ABA... / 29b821...`） | `791A306ED1B6648B_4577 / ec0c6f...`、`F474... / bbb32d...`、`A101... / 82d1...` 与 `45AE24662B56C487_14497 / 1cdc9318994d8476d7aba3f917f50630418ed80f749a056ede19285b3e8ca94e` 已先后退出 latest fresh `case E` failure surface；当前 default/actionable blocker 前移到 `cacheKey=8ABA7F7B315002A3_11361 / moduleKey=29b821c6fdea52c3c2e573e94577c93f527cfcf7806dc2f5bfe0b2bf8ad83d2f`，compiler message 主体为 `_CameraDepthTexture.sample(__air_sampler_state, t0/t3)` 触发 `no matching member function for call to 'sample'` |
| E-006g4 | 设计并验证“不牺牲源码可见性目标”的修复方案 | TODO | 最终方案不能退化为“永久关 startup injection”或“永久关 replacement” |

## `E-006g1` / `E-006g2` 当前结论（2026-04-07）

1. **“`launch_app -> create_session` 成功”不能等价于“启动兼容性已通过”**
   - 之前 `E-006g1` 的五象限 fresh launch 只证明了 runtime 可以进入 `ready`
   - 但用户指出的真实 blocker 是：**session 建立后数秒内 app 仍会崩溃**
2. **当前证据不支持“startup injection 单独导致 late crash”**
   - `B=true/false/false` 与 `C=true/true/false` 均可在 launch 后继续存活（至少 8s）
   - 因此 `injectMetalCaptureEnvironment=true` 不是当前这类 late crash 的充分条件
3. **当前证据支持“late crash 与 replacement 路径强相关”**
   - `D=true/false/true` 与 `E=true/true/true` 都会在 `playcover_launch_complete` 之后约 7~8 秒内崩溃
   - 最新 crash reports：`Unity-iPhone-2026-04-07-165010.ips`（`D`）与 `Unity-iPhone-2026-04-07-165825.ips` / `Unity-iPhone-2026-04-07-170150.ips`（`E`）
4. **崩溃已收敛到 `first replacement compile / fallback` 邻域，而不是 host launch env / preload / bridge 注册阶段**
   - 最新 `RuntimeLaunchDiagnostics` 已新增：
     - `replacement_attempt_started`
     - `replacement_modules_prepared`
     - `replacement_compile_started`
     - `replacement_compile_failed`
     - `replacement_succeeded`
   - 在 `E` 的最新 run（`pid=11539`）里，事件链先完整到达 `playcover_launch_complete`，随后立即进入多次 `newLibraryWithData:error:` replacement
5. **当前已观测到多个 replacement compile blocker，不是单个 cacheKey 即可解释全部崩溃**
   - 已先对 `cacheKey=6BECB97B0B4BCBFD_7123` 加入 targeted bypass 验证；该命中会被 `replacement_attempt_skipped(reason=bundle_cachekey_bypass)` 跳过
   - 但 app 仍继续命中其它 replacement，并出现新的 compile failure，例如：
     - `cacheKey=791A306ED1B6648B_4577`：`expected expression`
     - `cacheKey=F474C54E8C5214F4_4689`：`use of undeclared identifier 'mtl_BaseVertex'`
   - 这说明当前 crash **不是单点 shader**，而是 `恋与深空` 启动早期存在**多个会命中 replacement compile failure 的 shader**
6. **此前关于“`E=true/true/true` 未复现崩溃”的表述需要收窄解释**
   - 更准确的说法应是：`E` 在 launch 早期可到达 `ready`，但**并未通过后续几秒内的稳定性验证**
   - Road E 对 `E-006g` 的 gate 不能只看 `create_session`，必须把 launch 后的短时稳定性也纳入结论

## `E-006g2` 当前最小归因（2026-04-07）

### 已确认

- `B=true/false/false`：可存活，未观察到同类 late crash
- `C=true/true/false`：可存活，未观察到同类 late crash
- `D=true/false/true`：late crash
- `E=true/true/true`：late crash
- 因此当前主因更接近 **replacement enabled**，而不是 startup injection 本身

### 最新 runtime 证据

- `playcover_launch_complete` 现已记录三开关：
  - `metalCaptureEnabled`
  - `injectMetalCaptureEnvironment`
  - `shaderSourceReplacementEnabled`
- `E` 的最新 run（`pid=11539`）显示：
  1. `playcover_capture_library_preload_checked(loaded=true, needed=true)`
  2. `playcover_launch_complete(injectMetalCaptureEnvironment=true, metalCaptureEnabled=true, shaderSourceReplacementEnabled=true)`
  3. 多次 `replacement_attempt_started -> replacement_modules_prepared -> replacement_compile_started`
  4. 部分 cacheKey `replacement_compile_failed`，部分 cacheKey `replacement_succeeded`
  5. 随后 app 仍 crash

### 当前解释

- 当前最合理的解释不是“startup injection 让 app 在 launch 前就崩”，而是：
  - `恋与深空` 启动早期会命中多条 shader replacement
  - 其中已有多条生成的 MSL 会在 `makeLibrary(source:)` 编译阶段失败
  - 单个 compile failure / fallback 或其连锁副作用，足以在 launch 完成后数秒内触发 app abort

### 2026-04-07 同日补充：`791A... / ec0c6f...` 已通过 `select fast` lowering 修复退出 fresh blocker

- 该轮详细修复、离线验证与 fresh `case E` 前移过程已下沉到 `E-006g-Archive.md`
- 当前只保留对主线仍有决策价值的结论：`791A306ED1B6648B_4577 / ec0c6f...` 已退出 latest fresh `case E` blocker，现应作为**离线回归样本**保留，而不再占据默认工作入口

### 2026-04-07 同日晚补充：vertex draw-offset builtin 映射已完成验证，latest blocker 前移

- 该轮 `air.base_vertex` / `air.base_instance` 映射修复、对应最小样本与运行时闭环细节已下沉到 `E-006g-Archive.md`
- 当前只保留结论：`F474... / bbb32d...` 与 `A101... / 82d1...` 已退出 latest fresh `case E` failure surface，现同样只作为**离线回归样本**保留

### 2026-04-07 深夜补充（fresh `case E` 复测已完成）：`45AE... / 1cdc...` 已退出 latest blocker，新的 latest blocker 前移到 `8ABA... / 29b821...`

- 该轮 `bool3 select`、global-const-array `GEP`、`air.gather_texture_2d` 修复的离线验证、fresh `case E` 闭环与 failure-path 导出细节已下沉到 `E-006g-Archive.md`
- 当前只保留本轮结论：`45AE24662B56C487_14497 / 1cdc9318994d8476d7aba3f917f50630418ed80f749a056ede19285b3e8ca94e` 已退出 latest fresh `case E` failure surface；最新 actionable blocker 已前移到：
  - `cacheKey=8ABA7F7B315002A3_11361`
  - `moduleKey=29b821c6fdea52c3c2e573e94577c93f527cfcf7806dc2f5bfe0b2bf8ad83d2f`
  - 当前 compiler message 主体为 `_CameraDepthTexture.sample(__air_sampler_state, t0)` / `_CameraDepthTexture.sample(__air_sampler_state, t3)` 触发 `no matching member function for call to 'sample'`
- 默认下一步已切换为：先消费该 failure-path `module.ll` 做离线 replay / 最小样本化 / `xcrun metal -c`，再回到 fresh `case E`

### 下一步（仅记录，不在本轮展开）

1. 以 `cacheKey=8ABA7F7B315002A3_11361` / `moduleKey=29b821c6fdea52c3c2e573e94577c93f527cfcf7806dc2f5bfe0b2bf8ad83d2f` 为默认入口，先对 failure-path `module.ll` 做离线 replay / `xcrun metal -c`，并把 `sample(...)` / sampler operand 邻域缩成可最小复现的 `test-data` 样本
2. `45AE... / 1cdc...`、`791A... / ec0c6f...`、`F474... / bbb32d...` 与 `A101... / 82d1...` 全部继续保留为回归样本；后续若 fresh `case E` 再次回退，优先用离线 replay + fresh case E 联合报警
3. `cacheKey=6BECB97B0B4BCBFD_7123` 的 targeted bypass 继续保留，直到新的 latest compile blocker 收敛后再评估是否缩回

### 2026-04-07 工具补强

- 具体工具增强细节已下沉到 `E-006g-Archive.md`
- 主文档当前只保留仍会影响决策的结论：`finalize-case + analyze + runtime_launch_diagnostics_summary.py` 已足以支撑 `E-006g3` 的日常工作流；除非出现新的证据缺口，否则**不再把“补新埋点”当作默认任务**

## 候选解决方向

### 方向 A：缩小 startup injection 的作用面

- **当前状态**：`E-006g2` 已证明 `C=true/true/false` 可在 launch 后继续存活；也即 startup injection 不是当前 late crash 的充分条件，因此这条线**已不再是默认优先修复路径**
- 历史展开与当时的适用前提已下沉到 `E-006g-Archive.md`；若后续出现新的“`C` 也开始不稳定”的证据，再恢复该方向的详细排查即可

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
- `E-006g-Archive.md`
- `00-Dashboard.md`
