## HOK-005 深层 bootstrap 分层最小化

### 目标

- 在保留 `com.tencent.ngr` 现有最小兼容启动 gate 的前提下，继续按层压低更深一层 early bootstrap 副作用。
- 每次只动一层，并继续复用 `Scripts/hok004_ngr_startup_runner.py` 作为唯一 live 验证入口，判断 session 状态、launch diagnostics 与 crash window 是否发生实质变化。

### 分层顺序

- `HOK-005A`：跳过 `DiscordIPC` 的 host/runtime 启动面。
- `HOK-005B`：跳过 `PlayInput.shared.initialize()`。
- `HOK-005C`：跳过 `PlayScreen.shared.initialize()`。
- `HOK-005D`：在确认上面两层都无效后，再尝试延迟 `AKInterface.initialize()`，避免直接硬禁用导致下游强制解包崩溃。

### HOK-005A 落地内容

- host 侧：`PlayCover/Utils/Extensions/PlayAppExtensions.swift` 现在会对 `com.tencent.ngr` 直接跳过 `loadDiscordIPC()`，不再为该 app 建立 Discord IPC socket symlink。
- host 侧 bundle gate 复用：`PlayCover/Model/PlayApp.swift` 将 `minimalStartupCompatBundleIdentifiers` 提升为同类型可复用，避免在 extension 中再维护一份并行名单。
- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 对 `com.tencent.ngr` 跳过 `DiscordIPC.shared.initialize()`，并新增 `playcover_discord_skipped` 诊断事件；其他 app 仍保持原有 `playcover_discord_initialized` 路径。

### HOK-005B 落地内容

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 现在会对 `com.tencent.ngr` 跳过 `PlayInput.shared.initialize()`，并新增 `playcover_input_skipped` 诊断事件；其他 app 仍保持原有 `playcover_input_initialized` 路径。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 已将 `playcover_input_skipped` 与已落地的 `playcover_discord_skipped` 一并纳入 required compat events，并将 `playcover_input_initialized`、`playcover_discord_initialized` 纳入 forbidden compat events，保证后续每轮 live 都能自动确认当前固定 baseline 是否真实生效。

### 2026-04-18 latest live 结果

- 构建命令：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- live 首跑：`python3 Scripts/hok004_ngr_startup_runner.py`
- 同口径复跑：`python3 Scripts/hok004_ngr_startup_runner.py --skip-build-install`
- 结构化报告：`build/hok-004-ngr-startup-report.json`
- 本轮 fresh `processLaunchId`：
  - 首跑：`launch-87270-45a1729e-adb9-4a0c-a879-32dc487be178`
  - 复跑：`launch-89792-988e269b-0720-482d-889c-767bf95b0808`
- diagnostics 结论：
  - 两轮都继续命中 `playcover_startup_compat_profile_applied`、`playcover_input_skipped`、`playcover_discord_skipped`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved`、`playcover_launch_complete`；
  - 两轮都不再出现对应 launch 的 `playcover_input_initialized` 与 `playcover_discord_initialized`；
  - runner 的 required/forbidden compat gate 现在也已把 `DiscordIPC` / `PlayInput` 这两层固定 baseline 纳入强校验，并在最新复跑继续得到 `requiredCompatEventsPresent=true` 与 `forbiddenCompatEventsAbsent=true`；
  - 说明 `PlayInput` 与 `DiscordIPC` 的 runtime 启动面都已经按 `com.tencent.ngr` 精准压低，且自动化 gate 会持续检查这一点。
- session 结论：
  - 两轮 `create_session` 仍超时；
  - settle window 内仍未观察到 `ready`；
  - `disconnected` 仍在 settle window 内稳定出现。
- crash 结论：
  - 首跑新增 `NGR-2026-04-18-103516.ips`，复跑新增 `NGR-2026-04-18-104022.ips`；
  - 首跑 `procLaunch` 为 `2026-04-18 10:35:16.5629 +0800`，`captureTime` 为 `2026-04-18 10:35:16.9340 +0800`，约 `0.37s` 内崩溃；
  - 最新复跑 `procLaunch` 为 `2026-04-18 10:40:21.2396 +0800`，`captureTime` 为 `2026-04-18 10:40:21.4395 +0800`，约 `0.20s` 内崩溃；
  - 两轮崩溃仍是主线程 `EXC_BAD_ACCESS / SIGSEGV`，`KERN_INVALID_ADDRESS at 0x0`；
  - 两份新 `.ips` 的 `instructionByteStream` 完全一致，faulting thread 都是 `0`，没有证据表明 faulting window 已从 `NGR` image 的 early initializer 路径实质移走。

### 结论

- `HOK-005B` 已完成：`PlayInput` 的 runtime 启动面已被 app-scoped 压低，并且 live diagnostics 能稳定证明这一层已经生效。
- 当前没有证据表明 `PlayInput` 是 `com.tencent.ngr` 秒崩的首个 faulting mover；它与 `DiscordIPC` 一样，更像是已经排除的一层外部 bootstrap 噪音。
- 下一步进入 `HOK-005C`：继续对 `PlayScreen.shared.initialize()` 做同样的 app-scoped 分层最小化，并复用同一套 runner / diagnostics / `.ips` 口径判断 faulting window 是否移动。
