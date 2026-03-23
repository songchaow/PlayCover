// CleanupTools.swift
// PlayCoverMCP

import Foundation

/// Registers uninstall and cleanup MCP tools on the server.
///
/// Tools registered:
/// - `uninstall_app`: Uninstall an app with configurable cleanup options
/// - `clear_app_data`: Clear cached app data (containers, caches, etc.)
/// - `clear_playchain_data`: Clear PlayChain data for an app
/// - `clear_app_settings`: Clear app settings for an app
/// - `clear_app_entitlements`: Clear entitlements for an app
/// - `clear_app_keymaps`: Clear keymaps for an app
public enum CleanupTools {

    /// Register all cleanup tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        registerUninstallApp(on: server, cleanupService: cleanupService)
        registerClearAppData(on: server, cleanupService: cleanupService)
        registerClearPlayChainData(on: server, cleanupService: cleanupService)
        registerClearAppSettings(on: server, cleanupService: cleanupService)
        registerClearAppEntitlements(on: server, cleanupService: cleanupService)
        registerClearAppKeymaps(on: server, cleanupService: cleanupService)
    }

    // MARK: - uninstall_app

    private static func registerUninstallApp(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "uninstall_app",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to uninstall"
                    ] as Any),
                    "clearAppData": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to clear cached app data (containers, caches, etc.) (default: false)"
                    ] as Any),
                    "clearPlayChain": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to clear PlayChain data (default: false)"
                    ] as Any),
                    "clearSettings": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to clear app settings (default: false)"
                    ] as Any),
                    "clearEntitlements": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to clear entitlements (default: false)"
                    ] as Any),
                    "clearKeymaps": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to clear keymaps (default: false)"
                    ] as Any),
                ],
                required: ["bundleId"]
            ),
            description: "Uninstall a PlayCover-managed iOS application. Optionally clear associated data (app data, PlayChain, settings, entitlements, keymaps). This is a destructive operation.",
            title: "Uninstall App"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "uninstall_app") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "uninstall_app requires a non-empty 'bundleId' parameter"
                )
            }

            let options = UninstallOptions(
                clearAppData: args["clearAppData"] as? Bool ?? false,
                clearPlayChain: args["clearPlayChain"] as? Bool ?? false,
                clearSettings: args["clearSettings"] as? Bool ?? false,
                clearEntitlements: args["clearEntitlements"] as? Bool ?? false,
                clearKeymaps: args["clearKeymaps"] as? Bool ?? false
            )

            let result = try cleanupService.uninstallApp(bundleId: bundleId, options: options)
            return CallToolResult(content: [.text(content: formatUninstallResult(result))])
        }
    }

    // MARK: - clear_app_data

    private static func registerClearAppData(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "clear_app_data",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose data to clear"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Clear cached app data (containers, caches, HTTPStorages, Saved Application State) for a specific app. This is a destructive operation.",
            title: "Clear App Data"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "clear_app_data") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "clear_app_data requires a non-empty 'bundleId' parameter"
                )
            }

            let result = cleanupService.clearAllAppData(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCleanupResult(result))])
        }
    }

    // MARK: - clear_playchain_data

    private static func registerClearPlayChainData(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "clear_playchain_data",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose PlayChain data to clear"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Clear PlayChain data for a specific app. This is a destructive operation.",
            title: "Clear PlayChain Data"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "clear_playchain_data") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "clear_playchain_data requires a non-empty 'bundleId' parameter"
                )
            }

            let result = cleanupService.clearPlayChainData(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCleanupResult(result))])
        }
    }

    // MARK: - clear_app_settings

    private static func registerClearAppSettings(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "clear_app_settings",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose settings to clear"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Clear app settings for a specific app. This is a destructive operation.",
            title: "Clear App Settings"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "clear_app_settings") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "clear_app_settings requires a non-empty 'bundleId' parameter"
                )
            }

            let result = cleanupService.clearAppSettings(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCleanupResult(result))])
        }
    }

    // MARK: - clear_app_entitlements

    private static func registerClearAppEntitlements(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "clear_app_entitlements",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose entitlements to clear"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Clear entitlements for a specific app. This is a destructive operation.",
            title: "Clear App Entitlements"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "clear_app_entitlements") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "clear_app_entitlements requires a non-empty 'bundleId' parameter"
                )
            }

            let result = cleanupService.clearAppEntitlements(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCleanupResult(result))])
        }
    }

    // MARK: - clear_app_keymaps

    private static func registerClearAppKeymaps(
        on server: MCPServer,
        cleanupService: CleanupService
    ) {
        let tool = Tool(
            name: "clear_app_keymaps",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose keymaps to clear"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Clear keymaps for a specific app. This is a destructive operation.",
            title: "Clear App Keymaps"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "clear_app_keymaps") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "clear_app_keymaps requires a non-empty 'bundleId' parameter"
                )
            }

            let result = cleanupService.clearAppKeymaps(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCleanupResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatUninstallResult(_ result: UninstallResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "displayName": result.displayName,
            "removedItems": result.removedItems,
            "message": result.message,
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }

    private static func formatCleanupResult(_ result: CleanupResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "operation": result.operation,
            "removed": result.removed,
            "message": result.message,
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
