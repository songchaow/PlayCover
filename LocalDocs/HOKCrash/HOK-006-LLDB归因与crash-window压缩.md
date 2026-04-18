## HOK-006 LLDB 归因与 crash window 压缩

### 目标

- 在保留 `HOK-004/HOK-005` 已证实生效的最小兼容 baseline 前提下，为 `com.tencent.ngr` 增加 agent 可独立执行的 LLDB 归因入口。
- 让 headless `launch_app_with_lldb` 不再只返回“已启动”，而是能稳定输出适合自动化消费的 transcript / stop reason / faulting frame / faulting instruction / backtrace 证据。

### 自动化入口

- baseline live runner：`Scripts/hok004_ngr_startup_runner.py`
- HOK-006 LLDB runner：`Scripts/hok006_ngr_lldb_runner.py`
- 默认命令：`python3 Scripts/hok006_ngr_lldb_runner.py`
- 默认行为：
  - 调用 `BuildScripts/build_and_install.sh`
  - 连接 GUI HTTP MCP（默认 `http://127.0.0.1:19820/mcp`）
- 复用 `HOK-004` 的最小兼容 raw settings 固化流程：
    - `metalCaptureEnabled=false`
    - `injectMetalCaptureEnvironment=false`
    - `shaderSourceReplacementEnabled=false`
    - `rootWorkDir=false`
    - `playChain=false`
  - 使用 `launch_app_with_lldb(bundleId=com.tencent.ngr, withTerminalWindow=false, timeoutSeconds=...)`
  - 并行保留 `create_session` 与 `list_sessions` settle window 采样，继续记录 session 是否出现 `ready` / `disconnected` / `closed`
  - 回收结构化 LLDB 证据并写入 `build/hok-006-ngr-lldb-report.json`
  - 继续对照 session、`launch-events.jsonl` 与新增 `NGR-*.ips`

### 本轮落地内容

- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`
  - 为 `LaunchResult` 新增可选 `lldb` 结构化字段。
  - 新增 `LLDBLaunchEvidence`，统一承载 `processIdentifier`、`timedOut`、`didStop`、`stopReason`、`faultAddress`、`faultingThread`、`faultingFrame`、`faultingInstruction`、`backtrace`、`transcript` 与 `transcriptTail`。
  - `launchAppWithLLDB` 新增 `timeoutSeconds`，headless 模式下会在超时后主动 interrupt / summarize，避免非崩溃 run 无限挂起。
  - headless LLDB 改为抓取 transcript，并在观察到 stop reason 后自动追加 `thread backtrace all`、`disassemble --pc --count 8`、`register read`。
- `PlayCoverMCP/Tools/Host/LaunchTools.swift`
  - MCP `launch_app_with_lldb` 现在接受 `timeoutSeconds`。
  - tool 文本输出现在会序列化完整 `lldb` 结构化字段，便于 Python runner 直接消费。
- `Scripts/hok006_ngr_lldb_runner.py`
  - 复用 `hok004_ngr_startup_runner.py` 的 MCP HTTP client、build/install、settings、session、diagnostics 与 crash-report helper。
  - 新增 LLDB 证据提取、摘要与 gate 评估逻辑，确保 timeout-safe 行为也会写出结构化结果，而不是直接 hanging。
- `Scripts/hok004_ngr_startup_runner.py`
  - `MCPHTTPClient.call_tool(...)` 现已支持按调用传入 `request_timeout`，避免 `create_session(timeout=10)`、`launch_app_with_lldb(timeoutSeconds=5)` 这类长调用继续被 HTTP 层默认 `5s` 超时提前截断。

### focused tests

- Swift：`PlayCoverMCPTests/LaunchServiceTests.swift`
  - 覆盖 `LaunchResult` + `LLDBLaunchEvidence` 的 codable round-trip。
  - 覆盖 transcript → `stopReason` / `faultAddress` / `faultingInstruction` / `backtrace` 解析。
  - 覆盖 headless runner 返回结构化证据时 `launchAppWithLLDB` 的结果整形。
- Python：`Scripts/test_hok006_ngr_lldb_runner.py`
  - 覆盖 LLDB payload 提取。
  - 覆盖 faulting detail 摘要整形。
  - 覆盖 timeout-safe transcript tail 与 automation gate 行为。

### 最新 live 结果

- fresh live 命令：`python3 Scripts/hok006_ngr_lldb_runner.py`
- 结构化报告：`build/hok-006-ngr-lldb-report.json`
- 本轮 fresh `processLaunchId`：`launch-67589-f362ceda-99b0-479b-a0d7-b2bb104c8113`
- diagnostics 结论：
  - `requiredCompatEventsPresent=true`、`forbiddenCompatEventsAbsent=true` 继续命中，`playcover_akinterface_delayed` 已出现，但仍未观察到对应 launch 的 `playcover_akinterface_initialize_started` / `playcover_akinterface_initialized`；
  - `selectedRunSummary.pid=67589`，`selectedRunEventCount=18`，本轮仍只看到最小兼容 baseline 与 bridge 注册完成、随后 `playcover_launch_complete` 的既有模式；
  - 说明 `HOK-005` 的最小化 baseline 在 LLDB 入口下仍保持稳定，没有因为切到 `launch_app_with_lldb` 而丢失 required compat 证据。
- session 结论：
  - `createSessionSucceeded=false`，错误为 `Session heartbeat timed out: Runtime registered for bundleId 'com.tencent.ngr' but command bridge was not reachable within 10s`；
  - settle window 内继续观察到 `starting -> ready -> disconnected`，对应 runtime session 为 `runtime-67589-ba95861f-90ee-4e76-8494-e0476cf770b9`；
  - 说明 app 在 LLDB 入口下仍会短暂完成 runtime register，但很快失联，和此前主线结论一致。
- LLDB 结论：
  - `launch.lldb.timedOut=true`，但同一轮也同时得到 `didStop=true`、`faultingThreadCaptured=true`、`faultingFrameCaptured=true`、`faultingInstructionCaptured=true` 与 `backtraceCaptured=true`；这里的 `timedOut=true` 代表 `5s` capture 窗口到期后做了 interrupt / summarize，不代表证据缺失；
  - `stopReason=EXC_BAD_ACCESS (code=1, address=0x0)`；
  - `faultingFrame=frame #0: 0x000000010480df08 NGR\`___lldb_unnamed_symbol272374 + 124`；
  - `faultingInstruction=->  0x10480df08 <+124>: ldr    x8, [x19]`；
  - `faultingThread=1`，寄存器快照中 `x19=0x0`，与 `faultAddress=0x0` 对齐，指向 `NGR` 自身 early initializer 路径中的空指针解引用；
  - `backtraceHead` 继续直接落到 `NGR` 自身 unnamed symbol 链，并向上游穿过 `dyld4::Loader::findAndRunAllInitializers(...)`、`dyld4::APIs::runAllInitializersForMain()`，证明 faulting window 仍固定在 app 自身 initializer / dyld loader 路径，而不是 `AKInterface`、`PlayScreen`、`PlayInput`、`DiscordIPC` 或 library injection。
- crash 结论：
  - 本轮新增 `NGR-2026-04-18-133909.ips`；
  - `newCrashReportsDetected=true`，说明 LLDB 入口并没有把问题“绕过去”，而是稳定复现了同一类启动期崩溃窗口；
  - 结合 LLDB 的 `faultingFrame` / `faultingInstruction`，现在已经可以把下一步工作从“继续压低 PlayTools 副作用”切换到“围绕 `NGR` 自身 initializer callsite 做二进制意图分析与最小可逆 patch 设计”。

### 结论 / 下一步 handoff

- `HOK-006` 已完成：自动化入口与 fresh live 归因结论都已齐备，后续不需要再靠手工开 Terminal 或人工截 LLDB 窗口日志，就能稳定把同一轮 crash 的关键证据写进结构化 JSON。
- fresh live 已确认 faulting window 仍固定在 `NGR` 自身 early initializer / dyld loader 路径：`frame #0` 落在 `NGR\`___lldb_unnamed_symbol272374 + 124`，faulting instruction 为 `ldr x8, [x19]`，且 `faultAddress=0x0`。
- 下一步应进入 `HOK-007`：围绕 `0x10480df08` / `___lldb_unnamed_symbol272374 + 124` 这一最小 callsite 做 binary intention analysis、相邻指令/符号归因，以及可逆 patch 设计；后续每轮 patch 仍继续复用 `Scripts/hok004_ngr_startup_runner.py` + `Scripts/hok006_ngr_lldb_runner.py` 双入口做完整闭环验证。
