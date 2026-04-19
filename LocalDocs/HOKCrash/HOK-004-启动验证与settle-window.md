## HOK-004 启动验证与 settle window

> 本文只沉淀 HOK-004 建立起来的**自动化入口**、**settle window 口径**与**通过/失败判据**。任务状态、主线结论、时间戳快照一律以 `00-Dashboard.md` 为准。
>
> **何时读**：需要改 `Scripts/hok004_ngr_startup_runner.py`、调 compat 事件 required/forbidden 集合、或扩展 settle window 口径时读；日常 HOK-016 系列工作不需要进入。
>
> **相关文档**：
>
> - LLDB 归因入口（HOK-004 的兄弟 runner）：`HOK-006-LLDB归因与crash-window压缩.md`；
> - 深层 bootstrap 分层：`HOK-005-深层bootstrap分层最小化.md`；
> - 兜底链路实现：`HOK-013-slot-preheat.md` / `HOK-014-alert-suppressor.md` / `HOK-015-cmdline-preseed.md`。

### 目标

- 将 `com.tencent.ngr` 的"构建 → 配置 → 启动 → session → launch diagnostics → crash report"收敛成 agent 可独立执行的一键闭环。
- 固定本阶段的 settle window 口径，避免再用"窗口看起来像闪退"这类不稳定信号判断启动结果。

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
    - `rootWorkDir=true`（HOK-010 后的必须状态；让 UE4 的相对路径解析以 `/` 为基准）
    - `playChain=false`
  - `launch_app(com.tencent.ngr)`
  - `create_session(timeout=10)` 并在 `10s` settle window 内轮询 `list_sessions`
  - 对照 `launch-events.jsonl` 与新增 `NGR-*.ips`
  - 输出结构化报告到 `build/hok-004-ngr-startup-report.json`
- runner 退出语义：只有当全部验证条件都通过时返回 `0`；若验证失败或执行异常，都会在写出报告后返回非零。

### settle window 口径

- settle window 固定为 `10s`。
- 通过条件（全部满足）：
  - raw settings 回读与最小兼容档一致；
  - 本轮 `processLaunchId` 命中以下 compat 证据：
    - `playcover_startup_compat_profile_applied`
    - `playcover_input_skipped`
    - `playcover_discord_skipped`
    - `playcover_metal_capture_skipped`
    - `playcover_library_injection_skipped`
    - `playcover_working_directory_changed`（HOK-010 后的正确分支；`_preserved` 是 `rootWorkDir=false` 的旧路径）
    - `playcover_launch_complete`
  - 本轮不存在 `playcover_input_initialized`、`playcover_discord_initialized` 与 `playcover_library_injection_installed`；
  - `create_session` 成功；
  - settle window 内 session 至少到过一次 `ready`，且不出现 `disconnected` / `closed`；
  - 同轮没有新增 `NGR-*.ips`。
- 失败条件：以上任一条件不满足即失败；当前阶段无需再依赖人工观察窗口表现。

### 输出产物

- 结构化报告：`build/hok-004-ngr-startup-report.json`
- 报告消费方：`Scripts/hok006_ngr_lldb_runner.py` 共享 MCP HTTP client / settings / diagnostics / crash-report helper；其他 `hok0xx` 子任务也优先复用本 runner 作为 live baseline。
