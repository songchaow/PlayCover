// LaunchTools.swift
// PlayCoverMCP

import Foundation

/// Registers app launch MCP tools on the server.
///
/// Tools registered:
/// - `launch_app`: Launch a PlayCover-managed iOS application normally
/// - `launch_app_with_lldb`: Launch a PlayCover-managed iOS application under LLDB
public enum LaunchTools {

    /// Register both launch tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        launchService: LaunchService
    ) {
        registerLaunchApp(on: server, launchService: launchService)
        registerLaunchAppWithLLDB(on: server, launchService: launchService)
    }

    // MARK: - launch_app

    private static func registerLaunchApp(
        on server: MCPServer,
        launchService: LaunchService
    ) {
        let tool = Tool(
            name: "launch_app",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to launch"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Launch a PlayCover-managed iOS application. The app is opened via NSWorkspace in headless mode.",
            title: "Launch App"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "launch_app") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "launch_app requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try launchService.launchApp(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatLaunchResult(result))])
        }
    }

    // MARK: - launch_app_with_lldb

    private static func registerLaunchAppWithLLDB(
        on server: MCPServer,
        launchService: LaunchService
    ) {
        let tool = Tool(
            name: "launch_app_with_lldb",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to launch"
                    ] as Any),
                    "withTerminalWindow": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to open LLDB in a Terminal window (default: false, headless mode)"
                    ] as Any),
                    "timeoutSeconds": AnyCodable([
                        "type": "number",
                        "description": "Headless LLDB timeout before interrupting and summarizing the session (default: 5.0 seconds). Ignored when withTerminalWindow=true"
                    ] as Any),
                    "watchAddress": AnyCodable([
                        "type": "string",
                        "description": "HOK-012-B: optional data watchpoint target address (hex string like `0x10e2146f8`). When supplied, the headless runner installs a watchpoint before `run` and keeps the process alive on each hit, collecting backtrace snapshots until the overall timeout elapses. Ignored when withTerminalWindow=true."
                    ] as Any),
                    "watchSize": AnyCodable([
                        "type": "number",
                        "description": "HOK-012-B: byte size of the watchpoint region (default: 8). Only used when watchAddress is set."
                    ] as Any),
                    "preRunCommands": AnyCodable([
                        "type": "array",
                        "description": "HOK-012-B: optional array of LLDB commands executed once the target is loaded but before the child process is launched (e.g. additional breakpoints). Each array entry becomes one LLDB command line.",
                        "items": ["type": "string"]
                    ] as Any),
                    "dyldInitializersLogPath": AnyCodable([
                        "type": "string",
                        "description": "HOK-012-B: optional absolute path where the child process's stderr should be redirected via `process launch -e <path>`. Intended for capturing DYLD_PRINT_INITIALIZERS output so it can be correlated with watchpoint hits on the transcript. Parent directories are created automatically."
                    ] as Any),
                    "deferWatchpointInstall": AnyCodable([
                        "type": "boolean",
                        "description": "HOK-012-C: when true, the headless runner will NOT auto-emit `watchpoint set expression …` before `run`. Watchpoint-mode plumbing (stop→continue loop, watchpointHits parsing) still engages as long as watchAddress is set, but the caller becomes responsible for installing the watchpoint via a preRunCommands entry (typical pattern: `breakpoint set --address <writer> -C \"watchpoint set expression -s <size> -- <addr>\" -C \"continue\" --auto-continue true --one-shot true`). This shifts the watchpoint's armed moment from \"before run\" to \"after a chosen breakpoint fires\", fixing the HOK-012-C.2 0-hit timing race without altering legacy behaviour."
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Launch a PlayCover-managed iOS application under LLDB for debugging. Can optionally open a Terminal window, and in headless mode can install a data watchpoint / redirect child stderr for HOK-012-B live-trace work.",
            title: "Launch App with LLDB"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "launch_app_with_lldb") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "launch_app_with_lldb requires a non-empty 'bundleId' parameter"
                )
            }

            let withTerminalWindow = args["withTerminalWindow"] as? Bool ?? false
            let timeoutSeconds = args["timeoutSeconds"] as? Double ?? 5.0

            // HOK-012-B: optional watchpoint / preRunCommands / stderr
            // redirection. All fields default to `LLDBRunOptions.default`
            // (legacy stop -> quit behaviour) so callers who do not ask
            // for HOK-012-B features keep the old transcript shape.
            let watchAddress = (args["watchAddress"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            let watchSize: Int = {
                if let intValue = args["watchSize"] as? Int {
                    return intValue
                }
                if let doubleValue = args["watchSize"] as? Double {
                    return Int(doubleValue)
                }
                return 8
            }()
            let preRunCommands: [String] = (args["preRunCommands"] as? [Any])?
                .compactMap { $0 as? String } ?? []
            let dyldInitializersLogPath = (args["dyldInitializersLogPath"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            let deferWatchpointInstall = args["deferWatchpointInstall"] as? Bool ?? false

            let options = LLDBRunOptions(
                watchAddress: (watchAddress?.isEmpty ?? true) ? nil : watchAddress,
                watchSize: watchSize,
                preRunCommands: preRunCommands,
                dyldInitializersLogPath: (dyldInitializersLogPath?.isEmpty ?? true) ? nil : dyldInitializersLogPath,
                deferWatchpointInstall: deferWatchpointInstall
            )

            let result = try launchService.launchAppWithLLDB(
                bundleId: bundleId,
                withTerminalWindow: withTerminalWindow,
                timeoutSeconds: timeoutSeconds,
                options: options
            )
            return CallToolResult(content: [.text(content: formatLaunchResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatLaunchResult(_ result: LaunchResult) -> String {
        var data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "launched": result.launched,
            "method": result.method,
            "message": result.message,
        ]
        if let evidence = result.lldb {
            var lldbData: [String: Any] = [
                "timedOut": evidence.timedOut,
                "didStop": evidence.didStop,
                "terminationStatus": evidence.terminationStatus,
                "backtrace": evidence.backtrace,
                "transcript": evidence.transcript,
                "transcriptTail": evidence.transcriptTail,
            ]
            if let processIdentifier = evidence.processIdentifier {
                lldbData["processIdentifier"] = processIdentifier
            }
            if let stopReason = evidence.stopReason {
                lldbData["stopReason"] = stopReason
            }
            if let signal = evidence.signal {
                lldbData["signal"] = signal
            }
            if let faultAddress = evidence.faultAddress {
                lldbData["faultAddress"] = faultAddress
            }
            if let faultingThread = evidence.faultingThread {
                lldbData["faultingThread"] = faultingThread
            }
            if let faultingFrame = evidence.faultingFrame {
                lldbData["faultingFrame"] = faultingFrame
            }
            if let faultingInstruction = evidence.faultingInstruction {
                lldbData["faultingInstruction"] = faultingInstruction
            }
            // HOK-012-B: surface watchpoint hits and stderr log path so MCP
            // consumers (e.g. `Scripts/hok006_ngr_lldb_runner.py`) can
            // structure watchpoint evidence without re-parsing the
            // transcript.
            if !evidence.watchpointHits.isEmpty {
                lldbData["watchpointHits"] = evidence.watchpointHits.map { hit -> [String: Any] in
                    var entry: [String: Any] = [
                        "index": hit.index,
                        "backtrace": hit.backtrace,
                    ]
                    if let stopReason = hit.stopReason {
                        entry["stopReason"] = stopReason
                    }
                    if let thread = hit.thread {
                        entry["thread"] = thread
                    }
                    if let frame = hit.frame {
                        entry["frame"] = frame
                    }
                    if let oldValue = hit.oldValue {
                        entry["oldValue"] = oldValue
                    }
                    if let newValue = hit.newValue {
                        entry["newValue"] = newValue
                    }
                    return entry
                }
            }
            if let logPath = evidence.dyldInitializersLogPath {
                lldbData["dyldInitializersLogPath"] = logPath
            }
            data["lldb"] = lldbData
        }
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }
}
