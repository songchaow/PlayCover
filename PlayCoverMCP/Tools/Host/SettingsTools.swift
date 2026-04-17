// SettingsTools.swift
// PlayCoverMCP

import Foundation

/// Registers app settings MCP tools on the server.
///
/// Tools registered:
/// - `get_app_settings`: Read all settings for an app
/// - `update_app_settings`: Patch-update one or more settings fields
/// - `reset_app_settings`: Reset all settings to defaults
public enum SettingsTools {

    /// Register all settings tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        settingsService: SettingsService
    ) {
        registerGetAppSettings(on: server, settingsService: settingsService)
        registerUpdateAppSettings(on: server, settingsService: settingsService)
        registerResetAppSettings(on: server, settingsService: settingsService)
    }

    // MARK: - get_app_settings

    private static func registerGetAppSettings(
        on server: MCPServer,
        settingsService: SettingsService
    ) {
        let tool = Tool(
            name: "get_app_settings",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose settings to read"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Read all settings for a PlayCover-managed iOS application. Returns a JSON object with all configurable fields (keymapping, sensitivity, window size, display options, etc.).",
            title: "Get App Settings"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "get_app_settings") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "get_app_settings requires a non-empty 'bundleId' parameter"
                )
            }

            let settings = try settingsService.getSettings(bundleId: bundleId)
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - update_app_settings

    private static func registerUpdateAppSettings(
        on server: MCPServer,
        settingsService: SettingsService
    ) {
        let tool = Tool(
            name: "update_app_settings",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to update"
                    ] as Any),
                    "changes": AnyCodable([
                        "type": "object",
                        "description": "A dictionary of setting field names to their new values. Supported fields include: keymapping (bool), sensitivity (number), disableTimeout (bool), iosDeviceModel (string), windowWidth (int), windowHeight (int), customScaler (number), resolution (int), aspectRatio (int), notch (bool), bypass (bool), playChain (bool), playChainDebugging (bool), inverseScreenValues (bool), metalHUD (bool), windowFixMethod (int), injectIntrospection (bool), rootWorkDir (bool), noKMOnInput (bool), enableScrollWheel (bool), hideTitleBar (bool), floatingWindow (bool), checkMicPermissionSync (bool), limitMotionUpdateFrequency (bool), disableBuiltinMouse (bool), resizableAspectRatioType (int), resizableAspectRatioWidth (int), resizableAspectRatioHeight (int), blockSleepSpamming (bool), metalCaptureEnabled (bool), injectMetalCaptureEnvironment (bool), shaderSourceReplacementEnabled (bool)."
                    ] as Any)
                ],
                required: ["bundleId", "changes"]
            ),
            description: "Patch-update one or more settings fields for a PlayCover-managed iOS application. Only the specified fields are modified; all other fields are preserved. Uses patch semantics (not full replacement).",
            title: "Update App Settings"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "update_app_settings") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "update_app_settings requires a non-empty 'bundleId' parameter"
                )
            }

            guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "update_app_settings requires a non-empty 'changes' object"
                )
            }

            let result = try settingsService.updateSettings(bundleId: bundleId, changes: changes)
            return CallToolResult(content: [.text(content: formatUpdateResult(result))])
        }
    }

    // MARK: - reset_app_settings

    private static func registerResetAppSettings(
        on server: MCPServer,
        settingsService: SettingsService
    ) {
        let tool = Tool(
            name: "reset_app_settings",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose settings to reset"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Reset all settings for a PlayCover-managed iOS application to their default values.",
            title: "Reset App Settings"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "reset_app_settings") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "reset_app_settings requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try settingsService.resetSettings(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatResetResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatUpdateResult(_ result: SettingsUpdateResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "updatedFields": result.updatedFields,
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

    private static func formatResetResult(_ result: SettingsResetResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
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
