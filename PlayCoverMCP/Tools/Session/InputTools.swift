// InputTools.swift
// PlayCoverMCP

import Foundation

/// Registers session input MCP tools for keyboard, text, and debug overlay on the server.
///
/// Tools registered:
/// - `press_key`: Press a key (with optional modifiers) on the running app
/// - `type_text`: Type a text string into the running app
/// - `toggle_debug_overlay`: Toggle the debug overlay on the running app
public enum InputTools {

    /// Register all input tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        inputService: InputServiceProtocol
    ) {
        registerPressKey(on: server, inputService: inputService)
        registerTypeText(on: server, inputService: inputService)
        registerToggleDebugOverlay(on: server, inputService: inputService)
    }

    // MARK: - Synchronous bridge helper

    /// Run an async block synchronously using a semaphore.
    /// ToolHandler is synchronous, so we need to bridge to async input service calls.
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

    // MARK: - press_key

    private static func registerPressKey(
        on server: MCPServer,
        inputService: InputServiceProtocol
    ) {
        let tool = Tool(
            name: "press_key",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to send the key press to"
                    ] as Any),
                    "key": AnyCodable([
                        "type": "string",
                        "description": "The key to press. Can be a single character (e.g. 'a', '1') or a named key ('enter', 'escape', 'tab', 'backspace', 'delete', 'space', 'up', 'down', 'left', 'right', 'f1'-'f12', 'shift', 'control', 'option', 'command', 'home', 'end', 'pageup', 'pagedown')."
                    ] as Any),
                    "modifiers": AnyCodable([
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional modifier keys held during the press (e.g. ['shift', 'command']). Valid modifiers: shift, control, option, command, alt."
                    ] as Any),
                ],
                required: ["sessionId", "key"]
            ),
            description: "Press a key on the app's virtual keyboard. Supports single characters and named keys (enter, escape, arrows, function keys, etc.) with optional modifier keys.",
            title: "Press Key"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "press_key") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "press_key requires a non-empty 'sessionId' parameter"
                )
            }

            guard let key = args["key"] as? String,
                  !key.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "press_key requires a non-empty 'key' parameter"
                )
            }

            var modifiers: [String]?
            if let mods = args["modifiers"] as? [String] {
                modifiers = mods
            } else if let mods = args["modifiers"] as? [Any] {
                modifiers = mods.compactMap { $0 as? String }
            }

            let params = KeyPressParams(key: key, modifiers: modifiers)
            let result = try runAsync {
                try await inputService.pressKey(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - type_text

    private static func registerTypeText(
        on server: MCPServer,
        inputService: InputServiceProtocol
    ) {
        let tool = Tool(
            name: "type_text",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to type text into"
                    ] as Any),
                    "text": AnyCodable([
                        "type": "string",
                        "description": "The text string to type. Maximum 10000 characters."
                    ] as Any),
                ],
                required: ["sessionId", "text"]
            ),
            description: "Type a text string into the app. Each character is sent as a sequential key press. This is suitable for filling text fields. Note: complex IME / input method scenarios are not supported; only direct character input is guaranteed to work.",
            title: "Type Text"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "type_text") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "type_text requires a non-empty 'sessionId' parameter"
                )
            }

            guard let text = args["text"] as? String,
                  !text.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "type_text requires a non-empty 'text' parameter"
                )
            }

            let params = TypeTextParams(text: text)
            let result = try runAsync {
                try await inputService.typeText(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let resultText = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: resultText)])
        }
    }

    // MARK: - toggle_debug_overlay

    private static func registerToggleDebugOverlay(
        on server: MCPServer,
        inputService: InputServiceProtocol
    ) {
        let tool = Tool(
            name: "toggle_debug_overlay",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to toggle the debug overlay on"
                    ] as Any),
                ],
                required: ["sessionId"]
            ),
            description: "Toggle the debug overlay on the running app. The debug overlay shows touch points and their states, useful for debugging input automation. Equivalent to pressing Cmd+D in the app.",
            title: "Toggle Debug Overlay"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "toggle_debug_overlay") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "toggle_debug_overlay requires a non-empty 'sessionId' parameter"
                )
            }

            let result = try runAsync {
                try await inputService.toggleDebugOverlay(sessionId: sessionId)
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
