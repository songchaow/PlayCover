// AppResources.swift
// PlayCoverMCP

import Foundation

/// Registers app-related MCP resources and their read handlers.
///
/// Resources registered:
/// - `playcover://apps`: All installed apps as a JSON array
/// - `playcover://apps/{bundleId}`: Single app details as JSON object
public enum AppResources {

    /// Register both app resource metadata and their read handlers on the server.
    public static func register(
        on server: MCPServer,
        appService: AppService
    ) {
        // Collection resource
        server.resourceRegistry.register(Resource(
            uri: "playcover://apps",
            name: "Installed Apps",
            description: "JSON array of all PlayCover-managed iOS applications.",
            mimeType: "application/json"
        ))

        // Template resource for individual app
        server.resourceRegistry.register(Resource(
            uri: "playcover://apps/{bundleId}",
            name: "App Info",
            description: "JSON object with details for a specific installed app. Replace {bundleId} with the app's bundle identifier.",
            mimeType: "application/json"
        ))

        // Resource handler for playcover://apps (exact match)
        server.registerResource(uriTemplate: "playcover://apps") { uri, _ in
            let apps = try appService.listApps()
            let dicts = apps.map { $0.toMCPDictionary() }
            let data = try JSONSerialization.data(
                withJSONObject: dicts,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "[]"

            return ReadResourceResult(
                contents: [.init(uri: uri, mimeType: "application/json", text: text)]
            )
        }

        // Resource handler for playcover://apps/{bundleId} (prefix match)
        server.registerResource(uriTemplate: "playcover://apps/") { uri, _ in
            let bundleId = String(uri.dropFirst("playcover://apps/".count))
            guard !bundleId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "Bundle ID must not be empty"
                )
            }

            let app = try appService.getApp(bundleId: bundleId)
            let dict = app.toMCPDictionary()
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return ReadResourceResult(
                contents: [.init(uri: uri, mimeType: "application/json", text: text)]
            )
        }
    }
}
