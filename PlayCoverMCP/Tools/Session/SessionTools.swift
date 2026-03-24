// SessionTools.swift
// PlayCoverMCP

import Foundation

/// Registers session lifecycle MCP tools on the server.
///
/// Tools registered:
/// - `create_session`: Wait for a runtime session for a given bundleId
/// - `list_sessions`: List all active sessions
/// - `close_session`: Close a session by ID
public enum SessionTools {

    /// Register all session tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        sessionService: SessionService
    ) {
        registerCreateSession(on: server, sessionService: sessionService)
        registerListSessions(on: server, sessionService: sessionService)
        registerCloseSession(on: server, sessionService: sessionService)
    }

    // MARK: - create_session

    private static func registerCreateSession(
        on server: MCPServer,
        sessionService: SessionService
    ) {
        let tool = Tool(
            name: "create_session",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to create a session for"
                    ] as Any),
                    "timeout": AnyCodable([
                        "type": "number",
                        "description": "Maximum time in seconds to wait for runtime registration (default: 10)"
                    ] as Any),
                ],
                required: ["bundleId"]
            ),
            description: "Create a session for an iOS app. Waits for the PlayTools runtime to register. If the app is already running with an active session, returns it immediately. The app should be launched (via launch_app) before calling this tool.",
            title: "Create Session"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "create_session") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "create_session requires a non-empty 'bundleId' parameter"
                )
            }

            let timeout = args["timeout"] as? Double ?? 10.0

            let sessionInfo = try sessionService.createSession(
                bundleId: bundleId,
                timeout: timeout
            )

            let data = try JSONSerialization.data(
                withJSONObject: sessionInfo.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - list_sessions

    private static func registerListSessions(
        on server: MCPServer,
        sessionService: SessionService
    ) {
        let tool = Tool(
            name: "list_sessions",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "Optional bundle identifier to filter sessions by app"
                    ] as Any),
                ]
            ),
            description: "List all active runtime sessions. Optionally filter by bundleId. Each session shows its status (starting, ready, disconnected, closed).",
            title: "List Sessions"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "list_sessions") { arguments in
            let bundleId = arguments?.dictionary?["bundleId"] as? String
            let sessions = sessionService.listSessions(bundleId: bundleId)

            let dicts = sessions.map { $0.toDictionary() }
            let data = try JSONSerialization.data(
                withJSONObject: dicts,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "[]"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - close_session

    private static func registerCloseSession(
        on server: MCPServer,
        sessionService: SessionService
    ) {
        let tool = Tool(
            name: "close_session",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID to close"
                    ] as Any),
                ],
                required: ["sessionId"]
            ),
            description: "Close a runtime session by its session ID. Unregisters the session from the host. The runtime connection will be cleaned up.",
            title: "Close Session"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "close_session") { arguments in
            guard let sessionId = arguments?.dictionary?["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "close_session requires a non-empty 'sessionId' parameter"
                )
            }

            let closedInfo = try sessionService.closeSession(sessionId: sessionId)

            let data = try JSONSerialization.data(
                withJSONObject: closedInfo.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }
}
