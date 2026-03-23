// AppTools.swift
// PlayCoverMCP

import Foundation

/// Registers app-related MCP tools on the server.
///
/// Tools registered:
/// - `list_installed_apps`: List all PlayCover-managed applications
/// - `get_app_info`: Get detailed info for a specific app by bundle ID
public enum AppTools {

    /// Register both app tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        appService: AppService
    ) {
        registerListApps(on: server, appService: appService)
        registerGetAppInfo(on: server, appService: appService)
    }

    // MARK: - list_installed_apps

    private static func registerListApps(
        on server: MCPServer,
        appService: AppService
    ) {
        let tool = Tool(
            name: "list_installed_apps",
            inputSchema: InputSchema(
                type: "object",
                properties: [:],
                required: nil
            ),
            description: "List all PlayCover-managed iOS applications currently installed.",
            title: "List Installed Apps"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "list_installed_apps") { _ in
            let apps = try appService.listApps()
            let appDicts = apps.map { $0.toMCPDictionary() }
            return CallToolResult(
                content: [.text(content: formatAppsList(appDicts))]
            )
        }
    }

    // MARK: - get_app_info

    private static func registerGetAppInfo(
        on server: MCPServer,
        appService: AppService
    ) {
        let tool = Tool(
            name: "get_app_info",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "bundleId": AnyCodable(["type": "string", "description": "The bundle identifier of the app to look up"] as Any)
                ],
                required: ["bundleId"]
            ),
            description: "Get detailed information about a specific installed app by its bundle identifier.",
            title: "Get App Info"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "get_app_info") { arguments in
            guard let bundleId = arguments?.dictionary?["bundleId"] as? String,
                  !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "get_app_info requires a non-empty 'bundleId' parameter"
                )
            }

            let app = try appService.getApp(bundleId: bundleId)
            let dict = app.toMCPDictionary()
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return CallToolResult(
                content: [.text(content: text)]
            )
        }
    }

    // MARK: - Helpers

    private static func formatAppsList(_ apps: [[String: String]]) -> String {
        if apps.isEmpty {
            return "No PlayCover applications found."
        }
        var lines = ["Installed PlayCover Apps (\(apps.count)):", ""]
        for (index, app) in apps.enumerated() {
            let name = app["displayName"] ?? app["bundleName"] ?? "Unknown"
            let bundleId = app["bundleIdentifier"] ?? "?"
            let version = app["version"] ?? "?"
            lines.append("\(index + 1). \(name) (\(bundleId)) v\(version)")
        }
        return lines.joined(separator: "\n")
    }
}
