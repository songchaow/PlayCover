## E-006e：`QQ飞车` 在 `metal capture + shader replacement` 同开时启动崩溃

## 状态：TODO（已降为第三优先级；默认在 `E-006g` / `E-006f` 收敛后，或 `QQ飞车` fresh `D=true/true` 再次稳定复现 crash 时恢复优先级，并从 `E-006e2` 继续）

> ⚠️ `QQ飞车` 历史上已经证明“纯截帧路径”可走通，因此这里的问题不是“PlayCover 完全不能在它上面 capture”，而是 **Road E 的 shader replacement 主线与 metal capture 并存后，启动阶段出现了新的兼容性崩溃**。该问题仍然有效，但在 `恋与深空` 三开关启动崩溃与 `原神 31-4302` 之前，**不再是默认最高优先级入口**。

## 问题定义

当前待解问题是：

- app：`QQ飞车`
- bundleId：`com.tencent.tmgp.speedmobile`
- 当前安装版本：`1.56.037138`
- 现象：当 `metalCaptureEnabled=true` 且 `shaderSourceReplacementEnabled=true` 时，app 在启动阶段崩溃

这条线仍然重要，因为它直接关系到“**在真实 app 上同时保留截帧能力与源码替换能力**”能否稳定落地。

## 已知事实

### 1. 纯截帧能力曾在 `QQ飞车` 上走通

同仓库的 Render Capture 文档已经明确记录：

- `QQ飞车` 可以稳定 `create_session -> ready`
- `.gputrace` 曾成功落盘
- 它曾是最早的稳定真实 app capture 样本之一

因此这里的 blocker **不是**“`QQ飞车` 天生不支持截帧”，而是更具体的**并存副作用问题**。

### 2. 当前 runtime 会在启动很早期同时碰到 capture 与 replacement 两条链路

当前 `PlayCover.launch()` 的关键时序是：

1. `MetalCaptureService.initialize()`
2. 若 `metalCaptureEnabled && shaderSourceReplacementEnabled`，调用 `prepareForLibrarySourceAttributionIfNeeded()`
3. 安装 `LibrarySourceInjectionService.shared.installIfNeeded()`
4. 后续真实 `makeLibrary(...)` 命中时进入 replacement 尝试

这意味着当前的怀疑面至少包括：

- **capture 库早期预加载** 的副作用
- **makeLibrary swizzle 安装** 与 app 启动期 shader 加载的相互作用
- **首次 `makeLibrary(source:)` replacement 编译** 对启动链路的扰动

### 3. `shaderSourceReplacementEnabled=false` 时，hook 仍会安装，但会直接返回原始 library

`LibrarySourceInjectionSwizzles` 当前行为是：

- swizzle 仍安装
- 但当 `shaderSourceReplacementEnabled=false` 时，replacement 逻辑直接返回原始 library

这对当前问题很重要，因为它允许我们把实验面先拆成：

- hook 在，但不 replacement
- hook 在，且 replacement 真正执行

## 当前优先假设（按排查顺序）

1. **最优先假设：capture preload + replacement 并存时序导致启动期崩溃**（⚠️ `E-006e1` 当前 fresh 四象限未复现；该假设尚未被证实，后续需重点解释“历史 crash 为何出现、当前为何不复现”）
   - `QQ飞车` 纯 capture 曾正常
   - 当前新增变量是“为保证源码 attribution 而在更早期加载 GPUToolsCapture，再叠加 replacement”
2. **第二假设：首个 replacement 编译发生得过早，触发 app 启动关键路径不兼容**
   - 例如 app 还处于引擎冷启动阶段，就触发了 `makeLibrary(source:)` / 编译 / 替换
3. **第三假设：崩溃与具体 selector / metallib payload / 单个 module 有关**
   - 并不一定是“所有 replacement 都会崩”
   - 也可能是首个命中的某类 library path 与 capture 同时存在时出问题

## 推荐的最小自动化验证路径

> 目标：**不依赖人工操作**，先把崩溃位置钉死在启动时序中的哪一段。

### 固定前提

- 必须使用标准脚本构建 / 安装：

```bash
./BuildScripts/build_and_install.sh
```

- 不要手写 `xcodebuild`
- 不要手工复制 `.app`

### 四象限对照矩阵

按下面四种设置分别做 fresh launch，对比启动结果和 breadcrumb：

| Case | `metalCaptureEnabled` | `shaderSourceReplacementEnabled` | 目的 |
|---|---|---|---|
| A | false | false | 纯基线 |
| B | true | false | 只开 capture |
| C | false | true | 只开 replacement |
| D | true | true | 当前问题态 |

**默认优先比较 `B` vs `D`**：这能最快判断问题是不是 capture 与 replacement 的并存副作用。

### 每轮自动化采集内容

每轮至少固化以下证据：

1. fresh build/install 是否完成
2. 当前 app settings（capture / replacement 开关）
3. `launch_app(bundleId=com.tencent.tmgp.speedmobile)`
4. 是否成功 `create_session`
5. `RuntimeLaunchDiagnostics/com.tencent.tmgp.speedmobile/launch-events.jsonl`
6. `python3 Scripts/runtime_launch_diagnostics_summary.py --bundle-id com.tencent.tmgp.speedmobile --limit 5`
7. 是否产生新的 crash log / 是否在 launch diagnostics 中提前中断

## 当前 TODO 拆分

| # | 子任务 | 状态 | 说明 |
|---|---|---|---|
| E-006e1 | 四象限启动矩阵 + launch diagnostics 固化 | ✅ DONE（2026-04-07） | 新增 `Scripts/e006e_launch_matrix_runner.py`，并已对 `QQ飞车` 执行 `A/B/C/D` 四象限 fresh launch + `create_session` + diagnostics 固化；结果显示四象限均到达 `playcover_launch_complete`，本轮未复现启动崩溃 |
| E-006e2 | 定位崩溃发生在 preload / swizzle / first replacement 的哪一段 | TODO（若优先级恢复，先做） | 用 `Scripts/e006e_launch_matrix_runner.py` 与 `Scripts/runtime_launch_diagnostics_summary.py` 对照历史 crash 轮次和当前 no-crash 基线，明确差异首先落在 `playcover_capture_library_preload_checked`、`playcover_library_injection_installed` 还是首个 replacement 事件；只有形成可自动比较的 event 差异后才算完成 |
| E-006e3 | 验证是否与特定 selector / metallib payload / module 命中有关 | TODO（保留） | 若 `D` 中只在某条 shader 路径崩，应进一步最小化到单次 replacement 尝试 |
| E-006e4 | 设计“不牺牲源码可见性目标”的修复 | TODO（保留） | 最终方案不能退化为“永久关闭 replacement”或“永久关闭 capture” |

## `E-006e1` 当前产物（2026-04-07）

- 新脚本：`Scripts/e006e_launch_matrix_runner.py`
- 固化目录：`build/e006e-launch-matrix/`
- 汇总报告：`build/e006e-launch-matrix/report.json`
- 当前 live 结论：
  - `A=false/false`：`create_session` 成功，最新 run 到达 `playcover_launch_complete`
  - `B=true/false`：`create_session` 成功，最新 run 到达 `playcover_launch_complete`
  - `C=false/true`：`create_session` 成功，最新 run 到达 `playcover_launch_complete`
  - `D=true/true`：`create_session` 成功，最新 run 到达 `playcover_launch_complete`
- 因此本轮没有证据支持“当前环境下 `D` 稳定必现崩溃”；更合理的下一步不是盲修，而是把这条线保留为自动化参考基线，并在优先级恢复时从 `E-006e2` 补齐当初 crash 发生时的 build / settings / diagnostics 差异。

## 候选解决方向

### 方向 A：延后 attribution preload 的触发时机

思路：

- 不在 `PlayCover.launch()` 一开始就无条件 preload
- 改为在更靠近实际 capture / attribution 需要时再加载

适用前提：

- 若四象限矩阵证明崩溃发生在 **preload 之后、首次 replacement 之前**，这条线优先级最高

风险：

- 需要确保不会重新引入“replacement library 无法写入 `.gputrace` bundle”的旧问题

### 方向 B：让 replacement 在启动关键阶段先保守退让

思路：

- 对 app 冷启动早期的首批 library 先返回 original library
- 待 runtime 稳定后再恢复 replacement

适用前提：

- 若问题集中在 app 启动最早一批 shader / selector

风险：

- 可能会牺牲一部分最早期 shader 的源码 attribution，需要明确是否可接受

### 方向 C：bundle / selector / module 级选择性旁路

思路：

- 对 `QQ飞车` 或特定 selector / module key 做细粒度 bypass
- 保持大部分 replacement 仍然有效

适用前提：

- 若问题集中在单个 selector、单类 payload 或少量 module

风险：

- 会引入特例逻辑；只能作为收敛后的工程化方案，不能替代根因判断

## 关单标准

满足以下条件后，`E-006e` 才可视为完成：

1. `QQ飞车` 在 `metalCaptureEnabled=true` 且 `shaderSourceReplacementEnabled=true` 时可稳定启动
2. 启动后不会立即 crash，也不会让 session / runtime 注册链路异常退化
3. 修复方案**不以永久关闭 capture 或 replacement 为代价**
4. 日常复测流程仍可由 agent 独立完成，不引入人工登录、点按钮或手动 GUI 操作
5. 若后续必须升级到工作区外静态分析或其它需人工确认的路径，该路径也只能作为专项升级分支，得到用户确认后才能执行，不能写回日常 gate

## 参考锚点

- `Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/MetalCaptureService.swift`
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift`
- `Scripts/runtime_launch_diagnostics_summary.py`
- `00-Dashboard.md`
