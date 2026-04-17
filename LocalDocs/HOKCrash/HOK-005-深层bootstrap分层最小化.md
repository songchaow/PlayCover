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

### 2026-04-18 latest live 结果

- 构建命令：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- live 首跑：`python3 Scripts/hok004_ngr_startup_runner.py`
- 同口径复跑：`python3 Scripts/hok004_ngr_startup_runner.py --skip-build-install`
- 结构化报告：`build/hok-004-ngr-startup-report.json`
- 本轮 fresh `processLaunchId`：
  - 首跑：`launch-590-b0aeb300-ed68-46d9-a244-3eb4fda45871`
  - 复跑：`launch-795-aa4f8063-d573-4c6e-b4ad-9ae8512fc18b`
- diagnostics 结论：
  - 两轮都继续命中 `playcover_startup_compat_profile_applied`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved`、`playcover_launch_complete`；
  - 两轮都新增 `playcover_discord_skipped`，且不再出现对应 launch 的 `playcover_discord_initialized`；
  - 说明 `DiscordIPC` 的 runtime 启动面已经按 `com.tencent.ngr` 精准压低。
- session 结论：
  - 两轮 `create_session` 仍超时；
  - settle window 内仍未观察到 `ready`；
  - `list_sessions` 仍表现为 `runtime-* = disconnected`。
- crash 结论：
  - 首跑新增 `NGR-2026-04-18-024726.ips`，复跑新增 `NGR-2026-04-18-024745.ips`；
  - 最新复跑 `procLaunch` 为 `2026-04-18 02:47:44.5389 +0800`，`captureTime` 为 `2026-04-18 02:47:44.7327 +0800`，约 `0.19s` 内崩溃；
  - 崩溃仍是主线程 `EXC_BAD_ACCESS / SIGSEGV`，`KERN_INVALID_ADDRESS at 0x0`；
  - `instructionByteStream` 与 faulting frame 口径继续落在 `NGR` image 的 early initializer 窗口，没有证据表明根因已从 app 自身初始化路径移走。

### 结论

- `HOK-005A` 已完成：`DiscordIPC` 的 host/runtime 启动面都已被 app-scoped 压低，并且 live diagnostics 能稳定证明这一层已经生效。
- 当前没有证据表明 `DiscordIPC` 是 `com.tencent.ngr` 秒崩的主因；它更像是已排除的一层外部 bootstrap 噪音。
- 下一步进入 `HOK-005B`：继续对 `PlayInput.shared.initialize()` 做同样的 app-scoped 分层最小化，并复用同一套 runner / diagnostics / `.ips` 口径判断 faulting window 是否移动。
