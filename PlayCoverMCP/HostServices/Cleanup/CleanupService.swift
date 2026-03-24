// CleanupService.swift
// PlayCoverMCP

import Foundation

/// Result of an uninstall operation.
public struct UninstallResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let removedItems: [String]
    public let message: String

    public init(bundleIdentifier: String, displayName: String, removedItems: [String], message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.removedItems = removedItems
        self.message = message
    }
}

/// Result of a single cleanup operation.
public struct CleanupResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let operation: String
    public let removed: Bool
    public let message: String

    public init(bundleIdentifier: String, operation: String, removed: Bool, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.operation = operation
        self.removed = removed
        self.message = message
    }
}

/// Options for the `uninstall_app` tool.
public struct UninstallOptions: Codable, Equatable, Sendable {
    public let clearAppData: Bool
    public let clearPlayChain: Bool
    public let clearSettings: Bool
    public let clearEntitlements: Bool
    public let clearKeymaps: Bool

    public init(
        clearAppData: Bool = false,
        clearPlayChain: Bool = false,
        clearSettings: Bool = false,
        clearEntitlements: Bool = false,
        clearKeymaps: Bool = false
    ) {
        self.clearAppData = clearAppData
        self.clearPlayChain = clearPlayChain
        self.clearSettings = clearSettings
        self.clearEntitlements = clearEntitlements
        self.clearKeymaps = clearKeymaps
    }
}

/// Errors specific to cleanup operations.
public enum CleanupError: Error, LocalizedError, Equatable {
    case appNotFound(String)
    case cleanupFailed(operation: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .cleanupFailed(let op, let reason): return "Cleanup failed for \(op): \(reason)"
        }
    }
}

/// A headless service for uninstalling apps and cleaning up associated data.
///
/// Provides fine-grained control over what gets cleaned:
/// - App data (cache directories)
/// - PlayChain data
/// - App settings
/// - Entitlements
/// - Keymaps
public final class CleanupService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// The PlayCover container directory (holds settings, entitlements, keymaps, etc.).
    public let containerDirectory: URL

    /// The user's home Library directory (for cache cleanup).
    public let libraryDirectory: URL

    /// PlayChain path (for PlayChain data cleanup).
    public let playChainDirectory: URL

    /// Create a CleanupService with custom paths (useful for testing).
    public init(
        appDirectory: URL,
        containerDirectory: URL,
        libraryDirectory: URL,
        playChainDirectory: URL
    ) {
        self.appDirectory = appDirectory
        self.containerDirectory = containerDirectory
        self.libraryDirectory = libraryDirectory
        self.playChainDirectory = playChainDirectory
    }

    /// Create a CleanupService pointing to default PlayCover paths.
    public static func defaultService() -> CleanupService {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let container = library
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        let appDir = container.appendingPathComponent("Applications")
        let playChainDir = container.appendingPathComponent("PlayChain")
        return CleanupService(
            appDirectory: appDir,
            containerDirectory: container,
            libraryDirectory: library,
            playChainDirectory: playChainDir
        )
    }

    // MARK: - Path Resolution

    /// Cache directories to search for app data.
    private var cacheDirectories: [URL] {
        [
            libraryDirectory.appendingPathComponent("Containers"),
            libraryDirectory.appendingPathComponent("Application Scripts"),
            libraryDirectory.appendingPathComponent("Caches"),
            libraryDirectory.appendingPathComponent("HTTPStorages"),
            libraryDirectory.appendingPathComponent("Saved Application State"),
        ]
    }

    private func settingsURL(for bundleId: String) -> URL {
        containerDirectory.appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId).appendingPathExtension("plist")
    }

    private func entitlementsURL(for bundleId: String) -> URL {
        containerDirectory.appendingPathComponent("Entitlements")
            .appendingPathComponent(bundleId).appendingPathExtension("plist")
    }

    private func keymapURL(for bundleId: String) -> URL {
        containerDirectory.appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleId).appendingPathExtension("plist")
    }

    private func playChainURL(for bundleId: String) -> URL {
        playChainDirectory.appendingPathComponent(bundleId)
    }

    /// Resolve a bundle ID to an app record by scanning the Applications directory.
    private func resolveApp(bundleId: String) throws -> AppRecord {
        let fm = FileManager.default

        guard fm.fileExists(atPath: appDirectory.path) else {
            throw CleanupError.appNotFound(bundleId)
        }

        let contents = try fm.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for url in contents where url.hasDirectoryPath {
            guard url.pathExtension.contains("app") else { continue }

            let infoPlistURL = url.appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: infoPlistURL.path) else { continue }

            if let info = NSDictionary(contentsOf: infoPlistURL),
               let id = info["CFBundleIdentifier"] as? String,
               id == bundleId {

                return AppRecord(
                    bundleIdentifier: id,
                    bundleName: info["CFBundleName"] as? String
                        ?? (info["CFBundleDisplayName"] as? String ?? ""),
                    displayName: info["CFBundleDisplayName"] as? String
                        ?? (info["CFBundleName"] as? String ?? ""),
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    executableName: info["CFBundleExecutable"] as? String ?? "",
                    url: url
                )
            }
        }

        throw CleanupError.appNotFound(bundleId)
    }

    // MARK: - Uninstall

    /// Uninstall an app with the specified options.
    ///
    /// This is the primary entry point for the `uninstall_app` tool.
    public func uninstallApp(bundleId: String, options: UninstallOptions) throws -> UninstallResult {
        let app = try resolveApp(bundleId: bundleId)
        var removedItems: [String] = []

        if options.clearAppData {
            clearAppData(bundleId: bundleId)
            removedItems.append("appData")
        }

        if options.clearPlayChain {
            clearPlayChain(bundleId: bundleId)
            removedItems.append("playChain")
        }

        if options.clearSettings {
            let removed = removeFile(at: settingsURL(for: bundleId))
            if removed { removedItems.append("settings") }
        }

        if options.clearEntitlements {
            let removed = removeFile(at: entitlementsURL(for: bundleId))
            if removed { removedItems.append("entitlements")
            }
        }

        if options.clearKeymaps {
            let removed = removeFile(at: keymapURL(for: bundleId))
            if removed { removedItems.append("keymaps") }
        }

        // Remove the app bundle itself
        removeDirectory(at: app.url)
        removedItems.append("appBundle")

        let message = "Uninstalled \(app.displayName) (\(bundleId)). Removed: \(removedItems.joined(separator: ", "))"

        // Notify GUI that the app list has changed
        MCPNotificationPoster.postAppsChanged()

        return UninstallResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            removedItems: removedItems,
            message: message
        )
    }

    // MARK: - Individual Cleanup Operations

    /// Clear all cached app data (containers, caches, etc.) for the given bundle ID.
    public func clearAppData(bundleId: String) {
        let fm = FileManager.default
        for cacheDir in cacheDirectories {
            guard fm.fileExists(atPath: cacheDir.path) else { continue }
            if let enumerator = fm.enumerator(
                at: cacheDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.path.contains(bundleId) {
                        try? fm.removeItem(at: fileURL)
                    }
                }
            }
        }
    }

    /// Clear PlayChain data for the given bundle ID.
    public func clearPlayChain(bundleId: String) {
        let fm = FileManager.default
        let base = playChainURL(for: bundleId)
        for suffix in ["", ".keyCover", ".db"] {
            let targetURL = suffix.isEmpty ? base : URL(fileURLWithPath: base.path + suffix)
            try? fm.removeItem(at: targetURL)
        }
    }

    /// Clear app settings for the given bundle ID.
    public func clearAppSettings(bundleId: String) -> CleanupResult {
        let url = settingsURL(for: bundleId)
        let removed = removeFile(at: url)
        return CleanupResult(
            bundleIdentifier: bundleId,
            operation: "clear_app_settings",
            removed: removed,
            message: removed
                ? "Settings cleared for \(bundleId)"
                : "No settings file found for \(bundleId)"
        )
    }

    /// Clear entitlements for the given bundle ID.
    public func clearAppEntitlements(bundleId: String) -> CleanupResult {
        let url = entitlementsURL(for: bundleId)
        let removed = removeFile(at: url)
        return CleanupResult(
            bundleIdentifier: bundleId,
            operation: "clear_app_entitlements",
            removed: removed,
            message: removed
                ? "Entitlements cleared for \(bundleId)"
                : "No entitlements file found for \(bundleId)"
        )
    }

    /// Clear keymaps for the given bundle ID.
    public func clearAppKeymaps(bundleId: String) -> CleanupResult {
        let url = keymapURL(for: bundleId)
        let removed = removeFile(at: url)
        return CleanupResult(
            bundleIdentifier: bundleId,
            operation: "clear_app_keymaps",
            removed: removed,
            message: removed
                ? "Keymaps cleared for \(bundleId)"
                : "No keymap file found for \(bundleId)"
        )
    }

    /// Clear PlayChain data for the given bundle ID, returning a structured result.
    public func clearPlayChainData(bundleId: String) -> CleanupResult {
        let fm = FileManager.default
        let base = playChainURL(for: bundleId)
        var removed = false

        for suffix in ["", ".keyCover", ".db"] {
            let targetURL: URL
            if suffix.isEmpty {
                targetURL = base
            } else {
                targetURL = URL(fileURLWithPath: base.path + suffix)
            }
            if fm.fileExists(atPath: targetURL.path) {
                try? fm.removeItem(at: targetURL)
                removed = true
            }
        }

        return CleanupResult(
            bundleIdentifier: bundleId,
            operation: "clear_playchain_data",
            removed: removed,
            message: removed
                ? "PlayChain data cleared for \(bundleId)"
                : "No PlayChain data found for \(bundleId)"
        )
    }

    /// Clear all app data (cache directories) for the given bundle ID, returning a structured result.
    public func clearAllAppData(bundleId: String) -> CleanupResult {
        let fm = FileManager.default
        var removed = false

        for cacheDir in cacheDirectories {
            guard fm.fileExists(atPath: cacheDir.path) else { continue }
            if let enumerator = fm.enumerator(
                at: cacheDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.path.contains(bundleId) {
                        try? fm.removeItem(at: fileURL)
                        removed = true
                    }
                }
            }
        }

        return CleanupResult(
            bundleIdentifier: bundleId,
            operation: "clear_app_data",
            removed: removed,
            message: removed
                ? "App data cleared for \(bundleId)"
                : "No app data found for \(bundleId)"
        )
    }

    // MARK: - File System Helpers

    /// Remove a single file, returning whether it existed.
    private func removeFile(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        try? fm.removeItem(at: url)
        return true
    }

    /// Remove a directory, returning whether it existed.
    private func removeDirectory(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        try? fm.removeItem(at: url)
        return true
    }
}
