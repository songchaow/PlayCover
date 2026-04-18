## HOK-006 LLDB 归因与 crash window 压缩

> 本文只沉淀 HOK-006 引入的 **LLDB 自动化入口**、**结构化 LLDB 证据 schema**、**transcript 解析口径**与**automation gate 定义**。任务状态、某轮 live 结论以 `LocalDocs/HOKCrash/00-Dashboard.md` 为准；watchpoint / stderr 重定向等 HOK-012-B 增量扩展见 `LocalDocs/HOKCrash/HOK-011-静态初始化链分析.md` 的方法论小节。

### 目标

- 在保留 `HOK-004/HOK-005` 已证实生效的最小兼容 baseline 前提下，为 `com.tencent.ngr` 增加 agent 可独立执行的 LLDB 归因入口。
- 让 headless `launch_app_with_lldb` 不再只返回"已启动"，而是能稳定输出适合自动化消费的 transcript / stop reason / faulting frame / faulting instruction / backtrace 证据。

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
  - 调用 `launch_app_with_lldb(bundleId=com.tencent.ngr, withTerminalWindow=false, timeoutSeconds=...)`
  - 并行保留 `create_session` 与 `list_sessions` settle window 采样
  - 回收结构化 LLDB 证据写入 `build/hok-006-ngr-lldb-report.json`
  - 对照 session、`launch-events.jsonl` 与新增 `NGR-*.ips`

### 代码落点

- `PlayCoverMCP/HostServices/Launch/LaunchService.swift`
  - 为 `LaunchResult` 新增可选 `lldb` 字段。
  - 新增 `LLDBLaunchEvidence`，承载 `processIdentifier`、`timedOut`、`didStop`、`stopReason`、`faultAddress`、`faultingThread`、`faultingFrame`、`faultingInstruction`、`backtrace`、`transcript`、`transcriptTail`。
  - `launchAppWithLLDB` 支持 `timeoutSeconds`，headless 模式下超时后主动 interrupt / summarize，避免非崩溃 run 无限挂起。
  - headless LLDB 抓取 transcript，观察到 `stop reason =` 后自动追加 `thread backtrace all` / `disassemble --pc --count 8` / `register read`。
- `PlayCoverMCP/Tools/Host/LaunchTools.swift`
  - MCP `launch_app_with_lldb` 接受 `timeoutSeconds` 并把完整 `lldb` 结构化字段序列化到工具文本输出。
- `Scripts/hok006_ngr_lldb_runner.py`
  - 复用 `hok004_ngr_startup_runner.py` 的 MCP HTTP client / build-install / settings / session / diagnostics / crash-report helper。
  - 新增 LLDB 证据提取、摘要与 gate 评估，确保 timeout-safe 行为也会写出结构化结果。
- `Scripts/hok004_ngr_startup_runner.py`
  - `MCPHTTPClient.call_tool(...)` 接受按调用传入的 `request_timeout`，避免 `create_session(timeout=10)`、`launch_app_with_lldb(timeoutSeconds=5)` 被 HTTP 层默认 `5s` 超时提前截断。

### LLDB 证据 schema

- `processIdentifier`：从 transcript 的 `Process N launched` 行解出；`N/A` 时为空。
- `timedOut`：`true` 表示 capture window 到期后做了 interrupt/summarize；**不等于证据缺失**。
- `didStop`：是否观察到至少一条 `stop reason =`。
- `stopReason` / `signal` / `faultAddress` / `faultingThread`：均从**第一条非 watchpoint 的** `stop reason =` 行解析；watchpoint 模式下的扩展语义见 `HOK-011-静态初始化链分析.md`。
- `faultingFrame` / `faultingInstruction`：从 stop line 之后首个 `frame #0:` 行与首个 `->` 开头的 disassembly 行解析。
- `backtrace`：transcript 中所有 `frame #` 行，按出现顺序收集。
- `transcript` / `transcriptTail`：全量与尾部 `4000` 字符，后者用于报告直接嵌入。

### automation gate

- `lldbEvidencePresent`：`didStop` 为真即视为证据已捕获。
- `lldbAutomationReady`：`didStop && faultingFrame && faultingInstruction && backtraceDepth > 0`。
- `lldbTimedOut=true` **不**降级 `lldbAutomationReady`；两个字段独立判断。

### focused tests

- Swift：`PlayCoverMCPTests/LaunchServiceTests.swift`
  - `LaunchResult` + `LLDBLaunchEvidence` 的 codable round-trip。
  - transcript → `stopReason` / `faultAddress` / `faultingInstruction` / `backtrace` 解析。
  - headless runner 返回结构化证据时 `launchAppWithLLDB` 的结果整形。
- Python：`Scripts/test_hok006_ngr_lldb_runner.py`
  - LLDB payload 提取。
  - faulting detail 摘要整形。
  - timeout-safe transcript tail 与 automation gate 行为。

### 口径说明

- `launch_app_with_lldb` 的 `timedOut=true` + `didStop=true` 是**正常捕获形态**：窗口到期的 interrupt 会完整 flush transcript，不代表本轮未抓到崩溃。
- `.ips` 的 `usedImage.base`、triggered thread `frames[0].imageOffset`、LLDB `faultPc` 三者一致时才可进入 HOK-007A 的 file-offset 映射流程；不一致则说明本轮 image base 漂移，需先复位。
