## E-006g 历史归档：`恋与深空` 三开关启动崩溃

## 作用

本文档用于承接从 `E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md` 主体下沉的历史信息：已退出的 startup compile blocker、每轮 fresh `case E` 前移脉络，以及当前不再需要长期占据专项主体的工具补强细节。主文档只保留**当前 latest blocker、当前默认入口、当前 TODO 与仍直接影响决策的约束**。

> ⚠️ **本文档是历史归档，不代表当前默认工作入口。** 当前默认入口以 `E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md` 与 `00-Dashboard.md` 为准。

## 历史 blocker 前移归档

> 这里保留的是“latest blocker 如何逐轮前移”的历史脉络，方便后续回看某个 lowering 缺口是何时退出主线、又是通过什么验证闭环的。

| 时间 / 轮次 | latest blocker | 关键修复 / 结论 |
|---|---|---|
| 2026-04-07 同日早些时候 | `791A306ED1B6648B_4577 / ec0c6f...` | 通过 `translateSelect()` 中的 fast-math flag stripping 修复 `select` lowering；fresh `case E` 后 `791A...` 退出 latest blocker |
| 2026-04-07 同日晚些时候 | `F474... / bbb32d...` 与 `A101... / 82d1...` | 通过 metadata builtin 映射补齐 `air.base_vertex -> [[base_vertex]]`、`air.base_instance -> [[base_instance]]`；fresh `case E` 后两者退出 latest blocker |
| 2026-04-07 深夜第一轮 | `45AE24662B56C487_14497 / 1cdc9318...` | 补齐 `bool3 select`、global-const-array `GEP`、`air.gather_texture_2d` lowering；离线 replay / `xcrun metal -c` 已绿 |
| 2026-04-07 深夜第二轮 | `8ABA7F7B315002A3_11361 / 29b821c6...` | fresh `case E` 复测确认 `45AE... / 1cdc...` 已退出 latest failure surface；主线前移到 `_CameraDepthTexture.sample(__air_sampler_state, t0/t3)` 的 `sample` / sampler lowering 问题 |
| 2026-04-07 深夜第三轮 | `D4CAEB2BF7815C4F_6353 / f567fbc2...` | 通过 `__air_sampler_state -> constexpr sampler` lowering、`air.fast_rint -> rint` 映射与最小回归样本，fresh `case E` 复测确认 `8ABA... / 29b821...` 已退出 latest failure surface；主线前移到 `InputTexture.read(t8)` 的 `read_texture_2d` lowering 问题 |

## 详细轮次记录

### 2026-04-07 同日补充：`791A... / ec0c6f...` 已通过 `select fast` lowering 修复退出 fresh blocker

- 已在 `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` 的 `translateSelect()` 中补齐 fast-math flag stripping，并补了最小回归样本：
  - `test-data/test_fast_math_select.ll`
  - `test-data/test_fast_math_select.metal`
- 离线 replay / compile 已验证：
  - `test_fast_math_select.ll` → replay 成功，`xcrun metal -c` 成功
  - 历史失败模块 `moduleKey=ec0c6f0e72d6fc64daf4d5955cd1ea2cc5e729b0f988b1e857d13bfb54c7f6c3` → replay 成功，`xcrun metal -c` 成功
  - 修复后的重放结果已不再出现 `t44.z = /* select parse error */;`，而是生成 `half t35 = t34 ? 0.495117 : 0.504883;`
- 随后已按标准脚本执行 `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh`，并对 `com.papegames.lysk` 重新执行 fresh `case E`：`launch_app -> create_session -> settle -> finalize-case --replace-existing`
- 新快照结果：`matchedRuns=4`、`ignoredRuns=23`、`latestLastEvent=replacement_compile_failed`
- 当前 latest fresh run（`launch-53410-e5f3ab59-f1dc-4695-85a8-6675b7ff6118`）在 startup replacement 中表现为：
  - `replacement_attempt_skipped=1`（`cacheKey=6BECB97B0B4BCBFD_7123`，`reason=bundle_cachekey_bypass`）
  - `replacement_attempt_started=8`
  - `replacement_compile_started=8`
  - `replacement_compile_failed=2`
  - `replacement_succeeded=6`
  - **本轮未再命中** `cacheKey=791A306ED1B6648B_4577 / moduleKey=ec0c6f0e72d6fc64daf4d5955cd1ea2cc5e729b0f988b1e857d13bfb54c7f6c3`
- 当前 latest / actionable compile blocker 已前移到同一类 vertex builtin lowering 缺口：
  - `cacheKey=F474C54E8C5214F4_4689` → `moduleKey=bbb32dc1261c6c5bb2e8d05d0983d7938cfc68cd9556fed2faed2d0852e04854`
  - `cacheKey=A101E8447FA32563_5169` → `moduleKey=82d1eb85c787b3bb08fcb26d19e2effca177026f43664bec88dd234880d56c21`
  - 两者当前 compiler message 均收敛到：`use of undeclared identifier 'mtl_BaseVertex'`
- cross-run hotspot 现已前移：`Scripts/e006g_launch_matrix_runner.py analyze` 的 `hotspotSurface` 已不再是 `791A...`，而是 `F474... / bbb32d...`；`A101... / 82d1...` 则是本轮 latest newly surfaced blocker
- 因此，`791A... / ec0c6f...` 现应下调为**已修复、需保回归**的历史 blocker，而不再是 `E-006g3` 的默认工作入口

### 2026-04-07 同日晚补充：vertex draw-offset builtin 映射已完成验证，latest blocker 前移

- 已在 `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` 的 metadata builtin 映射中补齐：
  - `air.base_vertex` → `[[base_vertex]]`
  - `air.base_instance` → `[[base_instance]]`
- 已新增最小回归样本：
  - `test-data/test_vertex_draw_builtins.ll`
  - `test-data/test_vertex_draw_builtins.metal`
- 离线验证已完成并通过：
  - `test_vertex_draw_builtins.ll` → replay 成功，`xcrun metal -c` 成功
  - 历史 failure modules `bbb32d...` 与 `82d1...` → replay 成功，`xcrun metal -c` 成功
- 运行时验证已完成并通过既定脚本闭环：
  - `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 成功
  - `./BuildScripts/build_and_install.sh` 成功
  - fresh `case E` 已重新 `prepare-case -> launch_app -> finalize-case --replace-existing`
- **结论更新**：`F474... / bbb32d...` 与 `A101... / 82d1...` 已退出 latest fresh `case E` failure surface；最新一轮 `processLaunchId=launch-74202-a5fd16bc-18f3-447f-a472-452c316110e9` 的唯一 compile blocker 已前移到：
  - `cacheKey=45AE24662B56C487_14497`
  - `moduleKey=1cdc9318994d8476d7aba3f917f50630418ed80f749a056ede19285b3e8ca94e`
  - 当前 compiler message 主体为 `bool3 select` 类型不匹配、`GEP error` 与多处 `air.gather_texture_2d` placeholder
- **注意区分 latest 与 aggregate**：`Scripts/e006g_launch_matrix_runner.py analyze` 的 `hotspotSurface` 仍显示 `F474...`，是因为它按保留 runs 做 cross-run 聚合；但 `case.meta.json` / `launch-summary.txt` 的 `latestReplacementFailureSurfaces` 已不再包含 `F474...` 或 `A101...`

### 2026-04-07 深夜补充：`45AE... / 1cdc...` 从离线修复推进到 fresh `case E` 验证通过

- 已在 `Carthage/Checkouts/PlayTools/PlayTools/IRToMSLConverter.swift` 落下三类修复：
  - `translateSelect()`：`<N x i1>` 条件的 `select` 改为**逐分量 lowering**，不再直接发射 `boolN ? vecN : vecN`
  - `parseIRType()` / `generateMSL()` / `resolveIROperand()`：补齐**顶层 `[N x T]` 数组类型解析**、**全局常量定义发射**与**非 sampler 全局符号保留**，使 `@_ZL7ImmCB_0` 这类 constant array 的 `GEP + load` 可编译
  - `airBuiltinMappings` / `generateMSLForAirCall()`：补齐 `air.gather_texture_2d -> texture.gather(...)` lowering，默认覆盖当前 `offset=0` / `component=x` 命中面
- 已新增最小回归样本：
  - `test-data/test_vector_select_global_gep.ll`
  - `test-data/test_vector_select_global_gep.metal`
  - `test-data/test_gather_texture_2d.ll`
  - `test-data/test_gather_texture_2d.metal`
- 离线验证已完成并通过：
  - `moduleKey=1cdc9318994d8476d7aba3f917f50630418ed80f749a056ede19285b3e8ca94e` → replay 成功，`xcrun metal -c` 成功
  - `test_vector_select_global_gep.ll` → replay 成功，`xcrun metal -c` 成功
  - `test_gather_texture_2d.ll` → replay 成功，`xcrun metal -c` 成功
  - `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh` 成功
- 随后已按标准脚本完成运行时闭环：
  - `FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/build_and_install.sh` 成功
  - fresh `case E` 已重新执行 `prepare-case -> launch_app -> create_session -> finalize-case --replace-existing`
  - `create_session` 可成功进入 `ready`，但 settle window 后 latest `lastEvent` 仍落到 `replacement_compile_failed`
- **结论更新**：`45AE24662B56C487_14497 / 1cdc9318994d8476d7aba3f917f50630418ed80f749a056ede19285b3e8ca94e` 已退出 latest fresh `case E` failure surface，说明本轮 `bool3 select`、global-const-array `GEP` 与 `air.gather_texture_2d` 三类修复已在真实运行时生效；它现应下调为**已修复、需保回归**的历史 blocker
- 最新一轮 `processLaunchId=launch-17338-799c65bf-470d-45b0-b8ae-8da59a2108ad` 的 actionable compile blocker 已继续前移到：
  - `cacheKey=8ABA7F7B315002A3_11361`
  - `moduleKey=29b821c6fdea52c3c2e573e94577c93f527cfcf7806dc2f5bfe0b2bf8ad83d2f`
  - 当前 compiler message 主体为 `_CameraDepthTexture.sample(__air_sampler_state, t0)` / `_CameraDepthTexture.sample(__air_sampler_state, t3)` 触发 `no matching member function for call to 'sample'`，显示新的缺口已前移到 **texture sample / sampler lowering 邻域**
- failure-path 样本已完成闭环导出：
  - `ShaderSourceDiagnostics/com.papegames.lysk/2026-04-07T14_32_50Z_newLibraryWithData_error__compile_failed_modules/29b821c6fdea52c3c2e573e94577c93f527cfcf7806dc2f5bfe0b2bf8ad83d2f/` 下已落到 `module.bc` / `module.ll` / `module.generated.metal` / `module.meta.json`
  - 该样本目前尚未进入成功路径 `ShaderCorpus/`，因此后续默认入口应先消费 failure-path 样本做离线 replay / 最小样本化，再回到 fresh `case E`

## 工具补强归档（2026-04-07）

> 当前主文档只保留“这些能力已经具备”的结论；这里保留较细的演进记录，便于后续排查为什么某次 matrix snapshot 或 failure surface 摘要会长成这样。

- `Scripts/runtime_launch_diagnostics_summary.py` 现已在每个 `processLaunchId` 摘要里直接输出 replacement 事件计数与 failure clusters
- `Scripts/runtime_launch_diagnostics_summary.py` 现会从 `playcover_launch_complete` 提取并保留 `launchSettings`（三开关状态），即使最后一个事件已变成 late `replacement_compile_failed` 也不会丢失 case 身份
- failure cluster 的聚合键为 `event + selector + cacheKey + compilerMessage`，并保留 `count / firstTimestamp / lastTimestamp`
- `Scripts/runtime_launch_diagnostics_summary.py` 现已额外读取 `ShaderCorpus/<bundleId>/manifest.jsonl` 中的 `replacement_attempt`，把同一启动窗口内的失败尝试相关联为 **failure surfaces**（`selector + cacheKey + reasonCode + moduleKeys`），用于把 `E-006g3` 的命中面直接收缩到最小模块集合
- `Scripts/runtime_launch_diagnostics_summary.py` 现已额外输出 **cross-run replacement hotspots**：把最近若干个 `processLaunchId` 的 failure clusters / failure surfaces 再按 `cacheKey` / `reasonCode` / `moduleKeys` 聚合，直接回答“哪些 startup blocker 在多轮 launch 中反复出现”
- `Carthage/Checkouts/PlayTools/PlayTools/LibrarySourceInjectionSwizzles.swift` 现会在 `replacement_*` runtime diagnostics 里直接写入 `moduleKeys` / `moduleKeyCount`；`Scripts/runtime_launch_diagnostics_summary.py` 在 manifest 没有落到对应 `replacement_attempt` 时，会回退使用 runtime event 直接生成带 `evidenceSources=[runtime_event]` 的 failure surface，避免 `E-006g3` 因单条 compile_failed 缺少模块关联而停住
- `Scripts/e006g_launch_matrix_runner.py finalize-case` 现默认先等待 **10 秒 settle window**，再把 replacement counts / failure clusters 一并写入 `launch-summary.json`、`launch-summary.txt` 与 `case.meta.json`，避免 case 快照只停在 `playcover_launch_complete`
- `Scripts/e006g_launch_matrix_runner.py finalize-case` 现会按 `launchSettings` 过滤 runs，只保留与当前 case 对应的 `processLaunchId`；因此 `case E` 快照不再混入 `C/D` 或更早的 baseline launch
- `Scripts/e006g_launch_matrix_runner.py finalize-case` 现支持 `--replace-existing`，用于在同一路径刷新既有 case snapshot，而不必手工清理 `build/e006g-launch-matrix/`
- `Scripts/e006g_launch_matrix_runner.py finalize-case` 现会同时固化 `latestReplacementFailureSurfaces` / `latestReplacementFailureSurfaceCount`
- `Scripts/e006g_launch_matrix_runner.py finalize-case` 现会额外固化 `aggregatedReplacementFailureClusters` / `aggregatedReplacementFailureSurfaces`，避免只盯住 latest run
- `Scripts/e006g_launch_matrix_runner.py analyze` 会直接打印每个 case 最新一轮的 `replacementCompileFailed` 与 `failureSurfaces` 次数，以及跨保留 runs 的 hotspot surface / cluster，用于快速比较 `C / D / E` 并识别 startup 期最小旁路面

## 参考跳转

- 当前主线 / TODO / 默认入口：`E-006g-LoveAndDeepspaceTripleToggleStartupCrash.md`
- 全局优先级与日常 gate：`00-Dashboard.md`
