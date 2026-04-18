## HOK-004 启动验证与 settle window

### 目标

- 将 `com.tencent.ngr` 的“构建 → 配置 → 启动 → session → launch diagnostics → crash report”收敛成 agent 可独立执行的一键闭环。
- 固定本阶段的 settle window 口径，避免再用“窗口看起来像闪退”这类不稳定信号判断启动结果。

### 自动化入口

- runner：`Scripts/hok004_ngr_startup_runner.py`
- 默认命令：`python3 Scripts/hok004_ngr_startup_runner.py`
- 默认行为：
  - 调用 `BuildScripts/build_and_install.sh`
  - 连接 GUI HTTP MCP（默认 `http://127.0.0.1:19820/mcp`）
  - `reset_app_settings` → `update_app_settings` → `get_app_settings`
  - 固化最小兼容 raw settings：
    - `metalCaptureEnabled=false`
    - `injectMetalCaptureEnvironment=false`
    - `shaderSourceReplacementEnabled=false`
    - `rootWorkDir=false`
    - `playChain=false`
  - `launch_app(com.tencent.ngr)`
  - `create_session(timeout=10)` 并在 `10s` settle window 内轮询 `list_sessions`
  - 对照 `launch-events.jsonl` 与新增 `NGR-*.ips`
  - 输出结构化报告到 `build/hok-004-ngr-startup-report.json`
- runner 退出语义：只有当全部验证条件都通过时返回 `0`；若验证失败或执行异常，都会在写出报告后返回非零。

### settle window 口径

- settle window 固定为 `10s`。
- 通过条件：
  - raw settings 回读与最小兼容档一致；
  - 本轮 `processLaunchId` 命中以下 compat 证据：
    - `playcover_startup_compat_profile_applied`
    - `playcover_input_skipped`
    - `playcover_discord_skipped`
    - `playcover_metal_capture_skipped`
    - `playcover_library_injection_skipped`
    - `playcover_working_directory_preserved`
    - `playcover_launch_complete`
  - 本轮不存在 `playcover_input_initialized`、`playcover_discord_initialized` 与 `playcover_library_injection_installed`；
  - `create_session` 成功；
  - settle window 内 session 至少到过一次 `ready`，且不出现 `disconnected` / `closed`；
  - 同轮没有新增 `NGR-*.ips`。
- 失败条件：以上任一条件不满足即失败；当前阶段无需再依赖人工观察窗口表现。

### 2026-04-18 HOK-004 完成时基线结果（历史快照）

- 说明：本节保留 `HOK-004` 完成时的基线证据；`HOK-005A` 之后新增的 `DiscordIPC` / `PlayInput` 分层最小化 live 结果，以 `LocalDocs/HOKCrash/00-Dashboard.md` 与 `LocalDocs/HOKCrash/HOK-005-深层bootstrap分层最小化.md` 为准。

- 全量首跑命令：`python3 Scripts/hok004_ngr_startup_runner.py`
- 退出语义修正后的复跑命令：`python3 Scripts/hok004_ngr_startup_runner.py --skip-build-install`
- 结构化报告：`build/hok-004-ngr-startup-report.json`
- 最新 fresh `processLaunchId`：`launch-90689-88153fd1-9848-4061-a551-49ff0020e5ad`
- 最新 fresh runtime session：`runtime-90689-d0a5ac51-8aa1-420e-bb02-2067e39be39b`
- raw settings 回读：五个关键开关均为 `false`
- diagnostics 结论：
  - required compat events 全部命中；
  - `playcover_library_injection_installed` 未再出现；
  - 说明 HOK-002 / HOK-003 的最小兼容 gate 已按预期生效。
- session 结论：
  - `create_session` 仍超时；
  - settle window 内未观察到 `ready`；
  - `list_sessions` 很快稳定表现为 `runtime-* = disconnected` + `pending-* = starting`。
- crash 结论：
  - 退出语义修正后的复跑又生成了新的 `NGR-2026-04-18-023125.ips`；
  - 该轮 `procLaunch` 为 `2026-04-18 02:31:24.3114 +0800`，`captureTime` 为 `2026-04-18 02:31:24.7209 +0800`，启动到崩溃约 `0.4s`；
  - 崩溃仍是主线程 `EXC_BAD_ACCESS / SIGSEGV`，`KERN_INVALID_ADDRESS at 0x0`；
  - faulting frame 仍落在 `NGR` image，自身 early initializer 窗口没有明显移动。
- runner 结果：
  - `checks.overallPass=false`
  - `checks.exitCode=1`
  - 说明该脚本现在不仅会写报告，还能把失败结果作为自动化 gate 向上游传播。

### 结论

- `HOK-004` 已完成：自动化闭环、settle window 口径与证据输出路径都已固化。
- 当前阻塞点不再是 settings 自动化或 compat gate 是否命中，而是 app 在更深一层 early bootstrap 之后仍然快速崩溃。
- 下一步应转入 `HOK-005`：分层延迟或禁用 `AKInterface`、`PlayScreen`、`PlayInput`、`DiscordIPC` 等更深一层 bootstrap，并继续复用本 runner 做每轮对照。
