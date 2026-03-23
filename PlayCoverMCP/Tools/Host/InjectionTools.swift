// InjectionTools.swift
// PlayCoverMCP

import Foundation

/// Registers PlayTools injection, runtime config, and category MCP tools on the server.
///
/// Tools registered:
/// - `inject_playtools`: Inject PlayTools into an app binary
/// - `remove_playtools`: Remove PlayTools from an app binary
/// - `check_playtools_installed`: Check if PlayTools is installed in an app
/// - `set_introspection_enabled`: Enable/disable introspection DYLD path
/// - `set_ios_frameworks_enabled`: Enable/disable iOS frameworks DYLD path
/// - `set_application_category`: Set the app's LSApplicationCategoryType
public enum InjectionTools {

    /// Register all injection tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        registerInjectPlayTools(on: server, injectionService: injectionService)
        registerRemovePlayTools(on: server, injectionService: injectionService)
        registerCheckPlayToolsInstalled(on: server, injectionService: injectionService)
        registerSetIntrospectionEnabled(on: server, injectionService: injectionService)
        registerSetIOSFrameworksEnabled(on: server, injectionService: injectionService)
        registerSetApplicationCategory(on: server, injectionService: injectionService)
    }

    // MARK: - inject_playtools

    private static func registerInjectPlayTools(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "inject_playtools",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to inject PlayTools into"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Inject PlayTools into a PlayCover-managed iOS application. This modifies the MachO binary to load the PlayTools framework, installs the AKInterface plugin, and re-signs the app. This is a destructive operation.",
            title: "Inject PlayTools"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "inject_playtools") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "inject_playtools requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try injectionService.injectPlayTools(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatInjectionResult(result))])
        }
    }

    // MARK: - remove_playtools

    private static func registerRemovePlayTools(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "remove_playtools",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to remove PlayTools from"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Remove PlayTools from a PlayCover-managed iOS application. This removes the load command from the MachO binary, deletes the AKInterface plugin, and re-signs the app. This is a destructive operation.",
            title: "Remove PlayTools"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "remove_playtools") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "remove_playtools requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try injectionService.removePlayTools(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatInjectionResult(result))])
        }
    }

    // MARK: - check_playtools_installed

    private static func registerCheckPlayToolsInstalled(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "check_playtools_installed",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to check"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Check whether PlayTools is currently injected into a PlayCover-managed iOS application's binary. Returns a boolean indicating the injection status.",
            title: "Check PlayTools Installed"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "check_playtools_installed") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "check_playtools_installed requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try injectionService.checkPlayToolsInstalled(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatCheckResult(result))])
        }
    }

    // MARK: - set_introspection_enabled

    private static func registerSetIntrospectionEnabled(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "set_introspection_enabled",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "enabled": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to enable introspection libraries in DYLD_LIBRARY_PATH"
                    ] as Any)
                ],
                required: ["bundleId", "enabled"]
            ),
            description: "Enable or disable system introspection libraries for a PlayCover-managed iOS application. When enabled, adds /usr/lib/system/introspection to DYLD_LIBRARY_PATH in Info.plist. The app is re-signed after modification.",
            title: "Set Introspection Enabled"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "set_introspection_enabled") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_introspection_enabled requires a non-empty 'bundleId' parameter"
                )
            }

            guard let enabled = args["enabled"] as? Bool else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_introspection_enabled requires a boolean 'enabled' parameter"
                )
            }

            let result = try injectionService.setIntrospectionEnabled(bundleId: bundleId, enabled: enabled)
            return CallToolResult(content: [.text(content: formatRuntimeConfigResult(result))])
        }
    }

    // MARK: - set_ios_frameworks_enabled

    private static func registerSetIOSFrameworksEnabled(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "set_ios_frameworks_enabled",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "enabled": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to enable iOS frameworks in DYLD_LIBRARY_PATH"
                    ] as Any)
                ],
                required: ["bundleId", "enabled"]
            ),
            description: "Enable or disable iOS frameworks for a PlayCover-managed iOS application. When enabled, adds /System/iOSSupport/System/Library/Frameworks to DYLD_LIBRARY_PATH in Info.plist. The app is re-signed after modification.",
            title: "Set iOS Frameworks Enabled"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "set_ios_frameworks_enabled") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_ios_frameworks_enabled requires a non-empty 'bundleId' parameter"
                )
            }

            guard let enabled = args["enabled"] as? Bool else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_ios_frameworks_enabled requires a boolean 'enabled' parameter"
                )
            }

            let result = try injectionService.setIOSFrameworksEnabled(bundleId: bundleId, enabled: enabled)
            return CallToolResult(content: [.text(content: formatRuntimeConfigResult(result))])
        }
    }

    // MARK: - set_application_category

    private static func registerSetApplicationCategory(
        on server: MCPServer,
        injectionService: InjectionService
    ) {
        let tool = Tool(
            name: "set_application_category",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app"
                    ] as Any),
                    "category": AnyCodable([
                        "type": "string",
                        "description": "The LSApplicationCategoryType UTI string (e.g. 'public.app-category.games', 'public.app-category.entertainment', 'public.app-category.none' to remove)"
                    ] as Any)
                ],
                required: ["bundleId", "category"]
            ),
            description: "Set the application category type (LSApplicationCategoryType) for a PlayCover-managed iOS application. Valid categories include: business, developer-tools, education, entertainment, finance, games, graphics-design, healthcare-fitness, lifestyle, medical, music, news, photography, productivity, reference, social-networking, sports, travel, utilities, video, weather, none. The app is re-signed after modification.",
            title: "Set Application Category"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "set_application_category") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_application_category requires a non-empty 'bundleId' parameter"
                )
            }

            guard let category = args["category"] as? String, !category.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "set_application_category requires a non-empty 'category' parameter"
                )
            }

            let result = try injectionService.setApplicationCategory(bundleId: bundleId, category: category)
            return CallToolResult(content: [.text(content: formatCategoryResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatCheckResult(_ result: PlayToolsCheckResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "installed": result.installed,
            "message": result.message,
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }

    private static func formatInjectionResult(_ result: InjectionResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "displayName": result.displayName,
            "action": result.action,
            "message": result.message,
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }

    private static func formatRuntimeConfigResult(_ result: RuntimeConfigResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "field": result.field,
            "enabled": result.enabled,
            "message": result.message,
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }

    private static func formatCategoryResult(_ result: CategoryResult) -> String {
        var data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "category": result.category,
            "message": result.message,
        ]
        if let previous = result.previousCategory {
            data["previousCategory"] = previous
        }
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else {
            return result.message
        }
        return String(data: jsonData, encoding: .utf8) ?? result.message
    }
}
