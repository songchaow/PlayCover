// TouchTools.swift
// PlayCoverMCP

import Foundation

/// Registers session input MCP tools on the server.
///
/// Tools registered:
/// - `tap`: Tap at a point on the screen
/// - `long_press`: Long press at a point on the screen
/// - `swipe`: Swipe from one point to another
/// - `drag`: Drag from one point to another with a hold phase
public enum TouchTools {

    /// Register all touch tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        registerTap(on: server, touchService: touchService)
        registerLongPress(on: server, touchService: touchService)
        registerSwipe(on: server, touchService: touchService)
        registerDrag(on: server, touchService: touchService)
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

    private static func requiredDouble(
        from rawValue: Any?,
        toolName: String,
        parameter: String
    ) throws -> Double {
        switch rawValue {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            if let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            fallthrough
        default:
            throw PlayCoverMCPError(
                code: JSONRPCError.invalidParams,
                message: "\(toolName) requires a numeric '\(parameter)' parameter"
            )
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

            let x = try requiredDouble(from: args["x"], toolName: "tap", parameter: "x")
            let y = try requiredDouble(from: args["y"], toolName: "tap", parameter: "y")

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

            let x = try requiredDouble(from: args["x"], toolName: "long_press", parameter: "x")
            let y = try requiredDouble(from: args["y"], toolName: "long_press", parameter: "y")

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

    // MARK: - swipe

    private static func registerSwipe(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        let tool = Tool(
            name: "swipe",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to send the swipe to"
                    ] as Any),
                    "startX": AnyCodable([
                        "type": "number",
                        "description": "Start X coordinate in points (0 = left edge of app window). Must be non-negative."
                    ] as Any),
                    "startY": AnyCodable([
                        "type": "number",
                        "description": "Start Y coordinate in points (0 = top edge of app window). Must be non-negative."
                    ] as Any),
                    "endX": AnyCodable([
                        "type": "number",
                        "description": "End X coordinate in points. Must be non-negative."
                    ] as Any),
                    "endY": AnyCodable([
                        "type": "number",
                        "description": "End Y coordinate in points. Must be non-negative."
                    ] as Any),
                    "durationMs": AnyCodable([
                        "type": "integer",
                        "description": "Duration of the swipe in milliseconds (default: 300, max: 60000). Must be positive."
                    ] as Any),
                    "steps": AnyCodable([
                        "type": "integer",
                        "description": "Number of intermediate touch-move steps (default: 10, min: 2, max: 100)."
                    ] as Any),
                ],
                required: ["sessionId", "startX", "startY", "endX", "endY"]
            ),
            description: "Swipe from one point to another on the app screen. A swipe performs a touch-down at the start point, interpolates touch-move events along a straight line, and lifts up at the end point. Coordinates are in the app window's point coordinate system where (0,0) is the top-left corner.",
            title: "Swipe"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "swipe") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "swipe requires a non-empty 'sessionId' parameter"
                )
            }

            let startX = try requiredDouble(from: args["startX"], toolName: "swipe", parameter: "startX")
            let startY = try requiredDouble(from: args["startY"], toolName: "swipe", parameter: "startY")
            let endX = try requiredDouble(from: args["endX"], toolName: "swipe", parameter: "endX")
            let endY = try requiredDouble(from: args["endY"], toolName: "swipe", parameter: "endY")

            let durationMs: Int
            if let d = args["durationMs"] as? Int {
                durationMs = d
            } else if let d = args["durationMs"] as? Double {
                durationMs = Int(d)
            } else {
                durationMs = 300 // default
            }

            let steps: Int
            if let s = args["steps"] as? Int {
                steps = s
            } else if let s = args["steps"] as? Double {
                steps = Int(s)
            } else {
                steps = 10 // default
            }

            let params = SwipeParams(startX: startX, startY: startY, endX: endX, endY: endY,
                                     durationMs: durationMs, steps: steps)
            let result = try runAsync {
                try await touchService.swipe(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - drag

    private static func registerDrag(
        on server: MCPServer,
        touchService: TouchServiceProtocol
    ) {
        let tool = Tool(
            name: "drag",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to send the drag to"
                    ] as Any),
                    "startX": AnyCodable([
                        "type": "number",
                        "description": "Start X coordinate in points (0 = left edge of app window). Must be non-negative."
                    ] as Any),
                    "startY": AnyCodable([
                        "type": "number",
                        "description": "Start Y coordinate in points (0 = top edge of app window). Must be non-negative."
                    ] as Any),
                    "endX": AnyCodable([
                        "type": "number",
                        "description": "End X coordinate in points. Must be non-negative."
                    ] as Any),
                    "endY": AnyCodable([
                        "type": "number",
                        "description": "End Y coordinate in points. Must be non-negative."
                    ] as Any),
                    "durationMs": AnyCodable([
                        "type": "integer",
                        "description": "Duration of the drag movement in milliseconds (default: 500, max: 60000). Must be positive."
                    ] as Any),
                    "holdDelayMs": AnyCodable([
                        "type": "integer",
                        "description": "Hold time at the start point before moving, in milliseconds (default: 100, max: 60000). Must be positive."
                    ] as Any),
                    "steps": AnyCodable([
                        "type": "integer",
                        "description": "Number of intermediate touch-move steps (default: 10, min: 2, max: 100)."
                    ] as Any),
                ],
                required: ["sessionId", "startX", "startY", "endX", "endY"]
            ),
            description: "Drag from one point to another on the app screen with an initial hold phase. A drag begins with a touch-down and holds at the start point for holdDelayMs, then interpolates touch-move events along a straight line to the end point, and lifts up. This is useful for drag-and-drop interactions. Coordinates are in the app window's point coordinate system where (0,0) is the top-left corner.",
            title: "Drag"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "drag") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "drag requires a non-empty 'sessionId' parameter"
                )
            }

            let startX = try requiredDouble(from: args["startX"], toolName: "drag", parameter: "startX")
            let startY = try requiredDouble(from: args["startY"], toolName: "drag", parameter: "startY")
            let endX = try requiredDouble(from: args["endX"], toolName: "drag", parameter: "endX")
            let endY = try requiredDouble(from: args["endY"], toolName: "drag", parameter: "endY")

            let durationMs: Int
            if let d = args["durationMs"] as? Int {
                durationMs = d
            } else if let d = args["durationMs"] as? Double {
                durationMs = Int(d)
            } else {
                durationMs = 500 // default
            }

            let holdDelayMs: Int
            if let h = args["holdDelayMs"] as? Int {
                holdDelayMs = h
            } else if let h = args["holdDelayMs"] as? Double {
                holdDelayMs = Int(h)
            } else {
                holdDelayMs = 100 // default
            }

            let steps: Int
            if let s = args["steps"] as? Int {
                steps = s
            } else if let s = args["steps"] as? Double {
                steps = Int(s)
            } else {
                steps = 10 // default
            }

            let params = DragParams(startX: startX, startY: startY, endX: endX, endY: endY,
                                    durationMs: durationMs, holdDelayMs: holdDelayMs, steps: steps)
            let result = try runAsync {
                try await touchService.drag(sessionId: sessionId, params: params)
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
