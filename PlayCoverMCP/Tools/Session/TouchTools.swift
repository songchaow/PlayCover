// TouchTools.swift
// PlayCoverMCP

import Foundation

/// Registers session input MCP tools on the server.
///
/// Tools registered:
/// - `tap`: Tap at a point on the screen
/// - `long_press`: Long press at a point on the screen
public enum TouchTools {

    /// Register all touch tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        registerTap(on: server, touchService: touchService)
        registerLongPress(on: server, touchService: touchService)
    }

    // MARK: - Synchronous bridge helper

    /// Run an async block synchronously using a semaphore.
    /// ToolHandler is synchronous, so we need to bridge to async touch service calls.
    private static func runAsync<T>(_ block: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                let value = try await block()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()

        switch result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: - tap

    private static func registerTap(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        let tool = Tool(
            name: "tap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to send the tap to"
                    ] as Any),
                    "x": AnyCodable([
                        "type": "number",
                        "description": "X coordinate in points (0 = left edge of app window). Must be non-negative."
                    ] as Any),
                    "y": AnyCodable([
                        "type": "number",
                        "description": "Y coordinate in points (0 = top edge of app window). Must be non-negative."
                    ] as Any),
                ],
                required: ["sessionId", "x", "y"]
            ),
            description: "Tap at a specific point on the app screen. Coordinates are in the app window's point coordinate system where (0,0) is the top-left corner. A tap is a quick touch-down and touch-up at the same point.",
            title: "Tap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "tap") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "tap requires a non-empty 'sessionId' parameter"
                )
            }

            guard let x = args["x"] as? Double else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "tap requires a numeric 'x' parameter"
                )
            }

            guard let y = args["y"] as? Double else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "tap requires a numeric 'y' parameter"
                )
            }

            let params = TapParams(x: x, y: y)
            let result = try runAsync {
                try await touchService.tap(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - long_press

    private static func registerLongPress(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        let tool = Tool(
            name: "long_press",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to send the long press to"
                    ] as Any),
                    "x": AnyCodable([
                        "type": "number",
                        "description": "X coordinate in points (0 = left edge of app window). Must be non-negative."
                    ] as Any),
                    "y": AnyCodable([
                        "type": "number",
                        "description": "Y coordinate in points (0 = top edge of app window). Must be non-negative."
                    ] as Any),
                    "durationMs": AnyCodable([
                        "type": "integer",
                        "description": "Duration of the press in milliseconds (default: 500, max: 60000). Must be positive."
                    ] as Any),
                ],
                required: ["sessionId", "x", "y"]
            ),
            description: "Long press at a specific point on the app screen. Coordinates are in the app window's point coordinate system where (0,0) is the top-left corner. A long press holds the touch for the specified duration before releasing.",
            title: "Long Press"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "long_press") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "long_press requires a non-empty 'sessionId' parameter"
                )
            }

            guard let x = args["x"] as? Double else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "long_press requires a numeric 'x' parameter"
                )
            }

            guard let y = args["y"] as? Double else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "long_press requires a numeric 'y' parameter"
                )
            }

            let durationMs: Int
            if let d = args["durationMs"] as? Int {
                durationMs = d
            } else if let d = args["durationMs"] as? Double {
                durationMs = Int(d)
            } else {
                durationMs = 500 // default
            }

            let params = LongPressParams(x: x, y: y, durationMs: durationMs)
            let result = try runAsync {
                try await touchService.longPress(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }
}
