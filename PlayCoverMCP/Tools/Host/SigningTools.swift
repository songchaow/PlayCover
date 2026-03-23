// SigningTools.swift
// PlayCoverMCP

import Foundation

/// Registers signing and entitlements MCP tools on the server.
///
/// Tools registered:
/// - `preview_entitlements`: Read and preview the current entitlements of an app
/// - `validate_app_signing`: Check the signing state of an app
/// - `resign_app`: Re-sign an app bundle (ad-hoc, deep sign)
public enum SigningTools {

    /// Register all signing tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        signingService: SigningService,
        taskManager: TaskManager? = nil
    ) {
        registerPreviewEntitlements(on: server, signingService: signingService)
        registerValidateAppSigning(on: server, signingService: signingService)
        registerResignApp(on: server, signingService: signingService, taskManager: taskManager)
    }

    // MARK: - preview_entitlements

    private static func registerPreviewEntitlements(
        on server: MCPServer,
        signingService: SigningService
    ) {
        let tool = Tool(
            name: "preview_entitlements",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app whose entitlements to preview"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Preview the current entitlements of a PlayCover-managed iOS application. Returns a structured summary of capability flags (sandbox, network, camera, microphone, etc.) and sandbox profile rules count.",
            title: "Preview Entitlements"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "preview_entitlements") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "preview_entitlements requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try signingService.previewEntitlements(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatEntitlementsPreview(result))])
        }
    }

    // MARK: - validate_app_signing

    private static func registerValidateAppSigning(
        on server: MCPServer,
        signingService: SigningService
    ) {
        let tool = Tool(
            name: "validate_app_signing",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to validate"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Validate the code signing state of a PlayCover-managed iOS application. Checks whether the binary is signed, whether Info.plist is included in the signature, and whether entitlements are present.",
            title: "Validate App Signing"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "validate_app_signing") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "validate_app_signing requires a non-empty 'bundleId' parameter"
                )
            }

            let result = try signingService.validateSigning(bundleId: bundleId)
            return CallToolResult(content: [.text(content: formatValidationResult(result))])
        }
    }

    // MARK: - resign_app

    private static func registerResignApp(
        on server: MCPServer,
        signingService: SigningService,
        taskManager: TaskManager?
    ) {
        let tool = Tool(
            name: "resign_app",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable([
                        "type": "string",
                        "description": "The bundle identifier of the app to re-sign"
                    ] as Any),
                    "useTask": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to track the re-signing as a background task (default: false, runs synchronously)"
                    ] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Re-sign a PlayCover-managed iOS application using ad-hoc signing. Performs a deep re-sign of the app bundle, preserving existing entitlements. Useful when the code signature has become invalid after modification.",
            title: "Resign App"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "resign_app") { arguments in
            guard let args = arguments?.dictionary,
                  let bundleId = args["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "resign_app requires a non-empty 'bundleId' parameter"
                )
            }

            let useTask = args["useTask"] as? Bool ?? false

            let result: ResignResult
            if useTask, let taskManager = taskManager {
                result = signingService.resignAppWithTask(
                    bundleId: bundleId,
                    taskManager: taskManager
                )
            } else {
                result = try signingService.resignApp(bundleId: bundleId)
            }

            return CallToolResult(content: [.text(content: formatResignResult(result))])
        }
    }

    // MARK: - Helpers

    private static func formatEntitlementsPreview(_ result: EntitlementsPreviewResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "appSandbox": result.appSandbox,
            "capabilities": [
                "networkClient": result.hasNetworkClient,
                "networkServer": result.hasNetworkServer,
                "camera": result.hasCamera,
                "microphone": result.hasMicrophone,
                "bluetooth": result.hasBluetooth,
                "usb": result.hasUSB,
                "location": result.hasLocation,
                "contacts": result.hasContacts,
                "calendars": result.hasCalendars,
            ],
            "sandboxProfileRules": result.sandboxProfileRules,
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

    private static func formatValidationResult(_ result: SigningValidationResult) -> String {
        let data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "valid": result.valid,
            "checks": [
                "signed": result.signed,
                "infoPlistSigned": result.infoPlistSigned,
                "entitlementsPresent": result.entitlementsMatch,
            ],
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

    private static func formatResignResult(_ result: ResignResult) -> String {
        var data: [String: Any] = [
            "bundleIdentifier": result.bundleIdentifier,
            "displayName": result.displayName,
            "resigned": result.resigned,
            "message": result.message,
        ]
        if let taskId = result.taskId {
            data["taskId"] = taskId
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
