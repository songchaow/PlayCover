## HOK-005 深层 bootstrap 分层最小化

### 目标

- 在保留 `com.tencent.ngr` 现有最小兼容启动 gate 的前提下，继续按层压低更深一层 early bootstrap 副作用。
- 每次只动一层，并继续复用 `Scripts/hok004_ngr_startup_runner.py` 作为唯一 live 验证入口，判断 session 状态、launch diagnostics 与 crash window 是否发生实质变化。

### 分层顺序

- `HOK-005A`：跳过 `DiscordIPC` 的 host/runtime 启动面。
- `HOK-005B`：跳过 `PlayInput.shared.initialize()`。
- `HOK-005C`：跳过 `PlayScreen.shared.initialize()`。
- `HOK-005D`：在确认上面三层都无效后，再尝试延迟 `AKInterface.initialize()`，避免直接硬禁用导致下游强制解包崩溃。

### HOK-005A 落地内容

- host 侧：`PlayCover/Utils/Extensions/PlayAppExtensions.swift` 现在会对 `com.tencent.ngr` 直接跳过 `loadDiscordIPC()`，不再为该 app 建立 Discord IPC socket symlink。
- host 侧 bundle gate 复用：`PlayCover/Model/PlayApp.swift` 将 `minimalStartupCompatBundleIdentifiers` 提升为同类型可复用，避免在 extension 中再维护一份并行名单。
- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 对 `com.tencent.ngr` 跳过 `DiscordIPC.shared.initialize()`，并新增 `playcover_discord_skipped` 诊断事件；其他 app 仍保持原有 `playcover_discord_initialized` 路径。

### HOK-005B 落地内容

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 现在会对 `com.tencent.ngr` 跳过 `PlayInput.shared.initialize()`，并新增 `playcover_input_skipped` 诊断事件；其他 app 仍保持原有 `playcover_input_initialized` 路径。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 已将 `playcover_input_skipped` 与已落地的 `playcover_discord_skipped` 一并纳入 required compat events，并将 `playcover_input_initialized`、`playcover_discord_initialized` 纳入 forbidden compat events，保证后续每轮 live 都能自动确认当前固定 baseline 是否真实生效。

### HOK-005C 落地内容

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 现在会对 `com.tencent.ngr` 跳过 `PlayScreen.shared.initialize()`，并新增 `playcover_screen_skipped` 诊断事件；其他 app 仍保持原有 `playcover_screen_initialized` 路径。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 已将 `playcover_screen_skipped` 纳入 required compat events，并将 `playcover_screen_initialized` 纳入 forbidden compat events；`Scripts/test_hok004_ngr_startup_runner.py` 也同步覆盖了这组 gate，保证后续每轮 live 都能自动确认 `PlayScreen` 这一层是否真的被压低。

### HOK-005D 落地内容

- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlaySettings.swift` 为 `com.tencent.ngr` 新增唯一一条 `AKInterface` 延迟配置，固定为 `1.0s`，既覆盖当前 `0.20s-0.61s` 的已知 crash window，也保持改动最小且可逆。
- runtime 侧：`Carthage/Checkouts/PlayTools/PlayTools/PlayCover.swift` 现在仅对 `com.tencent.ngr` 将 `AKInterface.initialize()` 改为延迟调度，并新增 `playcover_akinterface_delayed`、`playcover_akinterface_initialize_started`、`playcover_akinterface_initialized` 三个诊断事件，用来区分“已计划延迟”与“实际开始/完成初始化”；其他 bundle 继续走原有即时初始化路径。
- runtime 侧：关闭窗口时若 `com.tencent.ngr` 还处于延迟窗口、`AKInterface.shared` 尚未建立，则不再触发 app-scoped 的强制解包终止路径，而是记录 `playcover_akinterface_terminate_skipped`，避免把新的 pre-init race 误引入 close path。
- 验证侧：`Scripts/hok004_ngr_startup_runner.py` 新增 `diagnostics.akInterface` 摘要，直接把本轮 launch 中 `AKInterface` 的调度/开始/完成状态写进结构化报告；`Scripts/test_hok004_ngr_startup_runner.py` 同步补充离线覆盖。

### 2026-04-18 latest live 结果

- 构建命令：`FORCE_PLAYTOOLS_REBUILD=1 ./BuildScripts/sync_playtools_xcframework.sh`
- live 首跑：`python3 Scripts/hok004_ngr_startup_runner.py`
- 同口径复跑：`python3 Scripts/hok004_ngr_startup_runner.py --skip-build-install`
- 结构化报告：`build/hok-004-ngr-startup-report.json`
- 本轮 fresh `processLaunchId`：
  - 首跑：`launch-24769-e906a6dc-ff3e-4f27-acf3-bed58d8a76dc`
  - 复跑：`launch-24892-73e64973-e85c-4738-b38b-4ff7dce86c75`
- diagnostics 结论：
  - 两轮都继续命中 `playcover_startup_compat_profile_applied`、`playcover_akinterface_delayed`、`playcover_screen_skipped`、`playcover_input_skipped`、`playcover_discord_skipped`、`playcover_metal_capture_skipped`、`playcover_library_injection_skipped`、`playcover_working_directory_preserved`、`playcover_launch_complete`；
  - 两轮都未观察到对应 launch 的 `playcover_akinterface_initialize_started`、`playcover_akinterface_initialized`，也未再出现 `playcover_screen_initialized`、`playcover_input_initialized` 或 `playcover_discord_initialized`；
  - runner 的 required/forbidden compat gate 在最新复跑继续得到 `requiredCompatEventsPresent=true` 与 `forbiddenCompatEventsAbsent=true`；同时结构化报告已新增 `diagnostics.akInterface` 摘要，用于直接对照 `scheduled / initializeStarted / initialized` 三态；
  - 说明 `AKInterface` 的 `1.0s` 延迟调度与既有 `PlayScreen` / `PlayInput` / `DiscordIPC` app-scoped skip 可以同时稳定生效，但 crash window 仍发生在 `AKInterface` 真正开始初始化之前。
- session 结论：
  - 两轮 `create_session` 仍超时；
  - settle window 内仍未观察到 `ready`；
  - `disconnected` 与 `starting` 仍在 settle window 内稳定出现；
  - 最新复跑末尾仍可见 `runtime-24892-6b723a47-ab08-45b9-965d-f2c6df0f31b3 = disconnected`，且没有新 session 转入 `ready`。
- crash 结论：
  - 首跑新增 `NGR-2026-04-18-115518.ips`，复跑新增 `NGR-2026-04-18-115534.ips`；
  - 首跑 `procLaunch` 为 `2026-04-18 11:55:17.0835 +0800`，`captureTime` 为 `2026-04-18 11:55:17.6879 +0800`，约 `0.60s` 内崩溃；
  - 最新复跑 `procLaunch` 为 `2026-04-18 11:55:33.6986 +0800`，`captureTime` 为 `2026-04-18 11:55:33.8651 +0800`，约 `0.17s` 内崩溃；
  - 两轮崩溃仍是主线程 `EXC_BAD_ACCESS / SIGSEGV`，`KERN_INVALID_ADDRESS at 0x0`；
  - 两份新 `.ips` 与上一轮代表样本 `NGR-2026-04-18-104022.ips` 的 `instructionByteStream` 口径完全一致，faulting thread 都是 `0`，说明即便 `AKInterface` 被延后到 crash window 之外，faulting window 仍没有稳定证据表明已从 `NGR` image 的 early initializer 路径实质移走。

### 结论

- `HOK-005D` 已完成：`AKInterface.initialize()` 的 `1.0s` app-scoped 延迟与对应诊断事件已经落地，且 live diagnostics 能稳定证明这层延迟确实被调度。
- 当前没有证据表明 `PlayScreen`、`PlayInput`、`DiscordIPC` 或 `AKInterface` 是 `com.tencent.ngr` 秒崩的首个 faulting mover；其中 `AKInterface` 在最新两轮里甚至还未真正开始初始化，app 就已经复现相同 `.ips` 签名。
- 下一步应进入 `HOK-006`：保持当前 `HOK-005` 的最小化 baseline 不变，用 `launch_app_with_lldb` / faulting instruction / backtrace 直接归因更深一层 `NGR` early initializer 路径。
