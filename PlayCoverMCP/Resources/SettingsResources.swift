// SettingsResources.swift
// PlayCoverMCP

import Foundation

/// Registers app settings MCP resource metadata.
///
/// The actual resource read handler is integrated into `AppResources`
/// to avoid URI prefix handler conflicts in `MCPServer`.
///
/// Resources registered:
/// - `playcover://apps/{bundleId}/settings`: Settings for a specific app as JSON
public enum SettingsResources {

    /// Register the settings resource metadata on the server.
    ///
    /// The read handler for `playcover://apps/{bundleId}/settings` is already
    /// handled by `AppResources` when `settingsService` is provided during
    /// its registration. This method only registers the resource template metadata.
    public static func register(on server: MCPServer) {
        // Template resource for per-app settings
        server.resourceRegistry.register(Resource(
            uri: "playcover://apps/{bundleId}/settings",
            name: "App Settings",
            description: "JSON object with all settings for a specific installed app. Replace {bundleId} with the app's bundle identifier.",
            mimeType: "application/json"
        ))
    }
}
