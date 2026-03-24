// MCPNotifications.swift
// PlayCoverMCP
//
// Notification names posted by MCP Services after state-changing operations.
// GUI ViewModels observe these to refresh their state automatically.
//
// This file lives in PlayCoverMCP/Common/ so it is compiled by all three targets:
// PlayCover (GUI), PlayCoverMCP (CLI), and PlayCoverMCPTests.
// In CLI mode the notifications are no-ops (no observer registered).

import Foundation

extension Notification.Name {
    /// MCP operation caused the app list to change (install/uninstall/inject/cleanup).
    static let mcpAppsChanged = Notification.Name("io.playcover.mcp.appsChanged")

    /// MCP operation changed an app's settings.
    static let mcpSettingsChanged = Notification.Name("io.playcover.mcp.settingsChanged")

    /// MCP operation changed keymap data for an app.
    static let mcpKeymapsChanged = Notification.Name("io.playcover.mcp.keymapsChanged")
}

/// Convenience helper – posts a notification on the main thread.
/// MCP Services run on background queues, so this ensures
/// GUI observers receive the notification on `DispatchQueue.main`.
enum MCPNotificationPoster {
    static func postAppsChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpAppsChanged, object: nil)
        }
    }

    static func postSettingsChanged(bundleID: String? = nil) {
        DispatchQueue.main.async {
            var userInfo: [String: Any]?
            if let bundleID = bundleID {
                userInfo = ["bundleID": bundleID]
            }
            NotificationCenter.default.post(name: .mcpSettingsChanged, object: nil, userInfo: userInfo)
        }
    }

    static func postKeymapsChanged(bundleID: String? = nil) {
        DispatchQueue.main.async {
            var userInfo: [String: Any]?
            if let bundleID = bundleID {
                userInfo = ["bundleID": bundleID]
            }
            NotificationCenter.default.post(name: .mcpKeymapsChanged, object: nil, userInfo: userInfo)
        }
    }
}
