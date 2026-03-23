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
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Launch a PlayCover-managed iOS application under LLDB for debugging. Can optionally open a Terminal window.",
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
            let result = try launchService.launchAppWithLLDB(
                bundleId: bundleId,
                withTerminalWindow: withTerminalWindow
            )
            return CallToolResult(content: [.text(content: formatLaunchResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatLaunchResult(_ result: LaunchResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "launched": result.launched,
            "method": result.method,
            "message": result.message
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }
}
