// KeymapTools.swift
// PlayCoverMCP

import Foundation

/// Registers keymap management MCP tools on the server.
///
/// Tools registered:
/// - `list_keymaps`: List all keymaps for an app
/// - `get_keymap`: Get keymap content by name
/// - `create_keymap`: Create a new empty keymap
/// - `rename_keymap`: Rename an existing keymap
/// - `delete_keymap`: Delete a keymap (not the default)
/// - `reset_keymap`: Reset a keymap to defaults
public enum KeymapTools {

    public static func register(
        on server: MCPServer,
        keymapService: KeymapService
    ) {
        registerListKeymaps(on: server, keymapService: keymapService)
        registerGetKeymap(on: server, keymapService: keymapService)
        registerCreateKeymap(on: server, keymapService: keymapService)
        registerRenameKeymap(on: server, keymapService: keymapService)
        registerDeleteKeymap(on: server, keymapService: keymapService)
        registerResetKeymap(on: server, keymapService: keymapService)
    }

    // MARK: - list_keymaps

    private static func registerListKeymaps(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "list_keymaps",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "List all keymaps for a PlayCover-managed iOS application. Returns the list of keymap names, which one is the default, and their file paths.",
            title: "List Keymaps"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "list_keymaps") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "list_keymaps requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try keymapService.listKeymaps(bundleId: bundleId)
            let response: [String: Any] = [
                "bundleIdentifier": result.bundleIdentifier,
                "defaultKeymap": result.defaultKeymap,
                "keymaps": result.keymaps.map { [
                    "name": $0.name,
                    "isDefault": $0.isDefault,
                    "path": $0.path
                ]}
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - get_keymap

    private static func registerGetKeymap(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "get_keymap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "name": AnyCodable([
                        "type": "string",
                        "description": "The name of the keymap to retrieve"
                    ] as Any)
                ],
                required: ["bundleId", "name"]
            ),
            description: "Get the content of a specific keymap for an app. Returns the full keymap data including buttons, joysticks, and mouse areas.",
            title: "Get Keymap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "get_keymap") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "get_keymap requires a non-empty 'bundleId' parameter"
                )
            }
            guard let name = args["name"] as? String, !name.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "get_keymap requires a non-empty 'name' parameter"
                )
            }

            let data = try keymapService.getKeymap(bundleId: bundleId, name: name)
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: jsonData, encoding: .utf8) ?? "{}"
            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - create_keymap

    private static func registerCreateKeymap(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "create_keymap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "name": AnyCodable([
                        "type": "string",
                        "description": "The name for the new keymap"
                    ] as Any)
                ],
                required: ["bundleId", "name"]
            ),
            description: "Create a new empty keymap for an app. The keymap starts with no buttons, joysticks, or mouse areas configured.",
            title: "Create Keymap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "create_keymap") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "create_keymap requires a non-empty 'bundleId' parameter"
                )
            }
            guard let name = args["name"] as? String, !name.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "create_keymap requires a non-empty 'name' parameter"
                )
            }

            let result = try keymapService.createKeymap(bundleId: bundleId, name: name)
            return CallToolResult(content: [.text(content: formatResult(result))])
        }
    }

    // MARK: - rename_keymap

    private static func registerRenameKeymap(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "rename_keymap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "name": AnyCodable([
                        "type": "string",
                        "description": "The current name of the keymap"
                    ] as Any),
                    "newName": AnyCodable([
                        "type": "string",
                        "description": "The new name for the keymap"
                    ] as Any)
                ],
                required: ["bundleId", "name", "newName"]
            ),
            description: "Rename an existing keymap. The default keymap can be renamed.",
            title: "Rename Keymap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "rename_keymap") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "rename_keymap requires a non-empty 'bundleId' parameter"
                )
            }
            guard let name = args["name"] as? String, !name.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "rename_keymap requires a non-empty 'name' parameter"
                )
            }
            guard let newName = args["newName"] as? String, !newName.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "rename_keymap requires a non-empty 'newName' parameter"
                )
            }

            let result = try keymapService.renameKeymap(bundleId: bundleId, oldName: name, newName: newName)
            return CallToolResult(content: [.text(content: formatResult(result))])
        }
    }

    // MARK: - delete_keymap

    private static func registerDeleteKeymap(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "delete_keymap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "name": AnyCodable([
                        "type": "string",
                        "description": "The name of the keymap to delete"
                    ] as Any)
                ],
                required: ["bundleId", "name"]
            ),
            description: "Delete a keymap for an app. The default keymap cannot be deleted.",
            title: "Delete Keymap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "delete_keymap") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "delete_keymap requires a non-empty 'bundleId' parameter"
                )
            }
            guard let name = args["name"] as? String, !name.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "delete_keymap requires a non-empty 'name' parameter"
                )
            }

            let result = try keymapService.deleteKeymap(bundleId: bundleId, name: name)
            return CallToolResult(content: [.text(content: formatResult(result))])
        }
    }

    // MARK: - reset_keymap

    private static func registerResetKeymap(on server: MCPServer, keymapService: KeymapService) {
        let tool = Tool(
            name: "reset_keymap",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "name": AnyCodable([
                        "type": "string",
                        "description": "The name of the keymap to reset"
                    ] as Any)
                ],
                required: ["bundleId", "name"]
            ),
            description: "Reset a keymap to its default (empty) state. All buttons, joysticks, and mouse areas are cleared.",
            title: "Reset Keymap"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "reset_keymap") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "reset_keymap requires a non-empty 'bundleId' parameter"
                )
            }
            guard let name = args["name"] as? String, !name.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "reset_keymap requires a non-empty 'name' parameter"
                )
            }

            let result = try keymapService.resetKeymap(bundleId: bundleId, name: name)
            return CallToolResult(content: [.text(content: formatResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatResult<T: Encodable>(_ result: T) -> String {
        let data = try? JSONEncoder().encode(result)
        guard let jsonData = data else { return "{}" }
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }
}
