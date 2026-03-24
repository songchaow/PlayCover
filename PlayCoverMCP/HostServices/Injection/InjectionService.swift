// InjectionService.swift
// PlayCoverMCP

import Foundation

// MARK: - Result Types

/// Result of a PlayTools injection check.
public struct PlayToolsCheckResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let installed: Bool
    public let message: String

    public init(bundleIdentifier: String, installed: Bool, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.installed = installed
        self.message = message
    }
}

/// Result of a PlayTools injection or removal operation.
public struct InjectionResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let action: String
    public let message: String

    public init(bundleIdentifier: String, displayName: String, action: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.action = action
        self.message = message
    }
}

/// Result of a DYLD environment change (introspection / iOS frameworks).
public struct RuntimeConfigResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let field: String
    public let enabled: Bool
    public let message: String

    public init(bundleIdentifier: String, field: String, enabled: Bool, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.field = field
        self.enabled = enabled
        self.message = message
    }
}

/// Result of an application category change.
public struct CategoryResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let category: String
    public let previousCategory: String?
    public let message: String

    public init(bundleIdentifier: String, category: String, previousCategory: String?, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.previousCategory = previousCategory
        self.message = message
    }
}

// MARK: - Error Types

/// Errors specific to injection and runtime config operations.
public enum InjectionError: Error, LocalizedError, Equatable, Sendable {
    case appNotFound(String)
    case executableNotFound(String)
    case injectionFailed(String)
    case removalFailed(String)
    case invalidCategory(String)
    case signingFailed(String)
    case playToolsNotInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .executableNotFound(let path): return "Executable not found at: \(path)"
        case .injectionFailed(let reason): return "PlayTools injection failed: \(reason)"
        case .removalFailed(let reason): return "PlayTools removal failed: \(reason)"
        case .invalidCategory(let cat): return "Invalid application category: \(cat)"
        case .signingFailed(let reason): return "Code signing failed: \(reason)"
        case .playToolsNotInstalled(let reason): return "PlayTools not installed: \(reason)"
        }
    }
}

// MARK: - InjectionService

/// A headless service for PlayTools injection, removal, runtime environment config,
/// and application category management.
///
/// Uses command-line tools (otool, install_name_tool, codesign) to operate on
/// MachO binaries and Info.plist files without depending on the PlayCover module.
public final class InjectionService: Sendable {

    public let appDirectory: URL
    public let containerDirectory: URL

    /// The PlayTools dylib path on the system (matches PlayCover's PlayTools.playCoverContainer).
    private static let playToolsFrameworkURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Frameworks/PlayTools.framework")

    /// The PlayTools dylib binary path within the framework.
    private static let playToolsDylibPath = playToolsFrameworkURL
        .appendingPathComponent("PlayTools")

    /// The AKInterface plugin path (used during injection).
    private static let akInterfacePluginPath = playToolsFrameworkURL
        .appendingPathComponent("PlugIns/AKInterface.bundle")

    /// DYLD_LIBRARY_PATH value for introspection (matches PlayApp.introspection).
    public static let introspectionPath = "/usr/lib/system/introspection"

    /// DYLD_LIBRARY_PATH value for iOS frameworks (matches PlayApp.iosFrameworks).
    public static let iosFrameworksPath = "/System/iOSSupport/System/Library/Frameworks"

    /// All valid LSApplicationCategoryType UTI strings.
    public static let validCategories: Set<String> = [
        "public.app-category.business",
        "public.app-category.developer-tools",
        "public.app-category.education",
        "public.app-category.entertainment",
        "public.app-category.finance",
        "public.app-category.games",
        "public.app-category.graphics-design",
        "public.app-category.healthcare-fitness",
        "public.app-category.lifestyle",
        "public.app-category.medical",
        "public.app-category.music",
        "public.app-category.news",
        "public.app-category.photography",
        "public.app-category.productivity",
        "public.app-category.reference",
        "public.app-category.social-networking",
        "public.app-category.sports",
        "public.app-category.travel",
        "public.app-category.utilities",
        "public.app-category.video",
        "public.app-category.weather",
        "public.app-category.none",
    ]

    public init(appDirectory: URL, containerDirectory: URL) {
        self.appDirectory = appDirectory
        self.containerDirectory = containerDirectory
    }

    /// Create an InjectionService pointing to default PlayCover directories.
    public static func defaultService() -> InjectionService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        return InjectionService(
            appDirectory: container.appendingPathComponent("Applications"),
            containerDirectory: container
        )
    }

    // MARK: - App Resolution

    /// Resolve a bundle ID to an app record by scanning the Applications directory.
    private func resolveApp(bundleId: String) throws -> AppRecord {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appDirectory.path) else {
            throw InjectionError.appNotFound(bundleId)
        }

        let contents = try fm.contentsOfDirectory(
            at: appDirectory, includingPropertiesForKeys: nil, options: []
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

        throw InjectionError.appNotFound(bundleId)
    }

    // MARK: - Check PlayTools Installed

    /// Check whether PlayTools is injected into a specific app's binary.
    ///
    /// Uses `otool -L` to check if the PlayTools load command exists.
    public func checkPlayToolsInstalled(bundleId: String) throws -> PlayToolsCheckResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw InjectionError.executableNotFound(executableURL.path)
        }

        let installed = isPlayToolsLoaded(in: executableURL)

        return PlayToolsCheckResult(
            bundleIdentifier: bundleId,
            installed: installed,
            message: installed
                ? "PlayTools is installed in \(app.displayName) (\(bundleId))."
                : "PlayTools is not installed in \(app.displayName) (\(bundleId))."
        )
    }

    // MARK: - Inject PlayTools

    /// Inject PlayTools into an app's MachO binary.
    ///
    /// Uses `install_name_tool -add_rpath` to add the PlayTools framework's
    /// parent directory as a runtime search path, then copies the AKInterface
    /// plugin and re-signs the app.
    public func injectPlayTools(bundleId: String) throws -> InjectionResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw InjectionError.executableNotFound(executableURL.path)
        }

        // Check that PlayTools is installed on the system
        guard FileManager.default.fileExists(atPath: Self.playToolsDylibPath.path) else {
            throw InjectionError.playToolsNotInstalled(
                "PlayTools.framework not found at \(Self.playToolsFrameworkURL.path)"
            )
        }

        // Add rpath for the PlayTools framework directory
        let rpath = Self.playToolsFrameworkURL.deletingLastPathComponent().path
        do {
            try MCPShell.run("/usr/bin/install_name_tool", "-add_rpath", rpath, executableURL.path)
        } catch let err as ShellError {
            // install_name_tool may fail if the rpath already exists; check for that
            if err.output.contains("already in") || err.output.contains("duplicate") {
                // Rpath already exists, proceed
            } else {
                throw InjectionError.injectionFailed(
                    "Failed to add rpath: \(err.output)"
                )
            }
        } catch {
            throw InjectionError.injectionFailed(error.localizedDescription)
        }

        // Copy AKInterface plugin to the app's PlugIns directory
        if FileManager.default.fileExists(atPath: Self.akInterfacePluginPath.path) {
            let pluginsDir = app.url.appendingPathComponent("PlugIns")
            try FileManager.default.createDirectory(
                at: pluginsDir, withIntermediateDirectories: true
            )
            let destPlugin = pluginsDir.appendingPathComponent("AKInterface.bundle")
            if FileManager.default.fileExists(atPath: destPlugin.path) {
                try FileManager.default.removeItem(at: destPlugin)
            }
            try FileManager.default.copyItem(at: Self.akInterfacePluginPath, to: destPlugin)
            try MCPShell.setExecutable(destPlugin)
        }

        // Re-sign the app
        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        return InjectionResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            action: "injected",
            message: "PlayTools injected into \(app.displayName) (\(bundleId)). Added rpath for PlayTools framework, installed AKInterface plugin, and re-signed the app."
        )
    }

    // MARK: - Remove PlayTools

    /// Remove PlayTools from an app's MachO binary.
    ///
    /// Removes the PlayTools rpath, deletes the AKInterface plugin,
    /// and re-signs the app.
    public func removePlayTools(bundleId: String) throws -> InjectionResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw InjectionError.executableNotFound(executableURL.path)
        }

        // Remove the PlayTools rpath
        let rpath = Self.playToolsFrameworkURL.deletingLastPathComponent().path
        // Try to delete the rpath; ignore errors if it doesn't exist
        try? MCPShell.run("/usr/bin/install_name_tool", "-delete_rpath", rpath, executableURL.path)

        // Remove AKInterface plugin if it exists
        let pluginPath = app.url
            .appendingPathComponent("PlugIns/AKInterface.bundle")
        if FileManager.default.fileExists(atPath: pluginPath.path) {
            try FileManager.default.removeItem(at: pluginPath)
        }

        // Re-sign the app
        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        return InjectionResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            action: "removed",
            message: "PlayTools removed from \(app.displayName) (\(bundleId)). Removed rpath, deleted AKInterface plugin, and re-signed the app."
        )
    }

    // MARK: - Set Introspection Enabled

    /// Enable or disable the introspection DYLD_LIBRARY_PATH entry in Info.plist.
    ///
    /// When enabled, adds `/usr/lib/system/introspection` to `DYLD_LIBRARY_PATH`
    /// in `LSEnvironment`. Re-signs the app after modification.
    public func setIntrospectionEnabled(bundleId: String, enabled: Bool) throws -> RuntimeConfigResult {
        try modifyDyldLibraryPath(
            bundleId: bundleId,
            path: Self.introspectionPath,
            set: enabled,
            field: "introspection"
        )
    }

    // MARK: - Set iOS Frameworks Enabled

    /// Enable or disable the iOS frameworks DYLD_LIBRARY_PATH entry in Info.plist.
    ///
    /// When enabled, adds `/System/iOSSupport/System/Library/Frameworks` to
    /// `DYLD_LIBRARY_PATH` in `LSEnvironment`. Re-signs the app after modification.
    public func setIOSFrameworksEnabled(bundleId: String, enabled: Bool) throws -> RuntimeConfigResult {
        try modifyDyldLibraryPath(
            bundleId: bundleId,
            path: Self.iosFrameworksPath,
            set: enabled,
            field: "iosFrameworks"
        )
    }

    // MARK: - Set Application Category

    /// Set the LSApplicationCategoryType for an app in its Info.plist.
    ///
    /// Valid categories are standard Apple UTI strings (e.g.
    /// `public.app-category.games`, `public.app-category.entertainment`).
    /// Use `public.app-category.none` to remove the category.
    /// Re-signs the app after modification.
    public func setApplicationCategory(bundleId: String, category: String) throws -> CategoryResult {
        let app = try resolveApp(bundleId: bundleId)
        let infoPlistURL = app.url.appendingPathComponent("Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw InjectionError.executableNotFound(infoPlistURL.path)
        }

        guard Self.validCategories.contains(category) else {
            throw InjectionError.invalidCategory(category)
        }

        guard let plist = NSMutableDictionary(contentsOf: infoPlistURL) else {
            throw InjectionError.signingFailed("Failed to read Info.plist")
        }

        let previousCategory = plist["LSApplicationCategoryType"] as? String

        if category == "public.app-category.none" {
            plist.removeObject(forKey: "LSApplicationCategoryType")
        } else {
            plist["LSApplicationCategoryType"] = category
        }

        plist.write(to: infoPlistURL, atomically: true)

        // Re-sign after plist modification
        let executableURL = app.url.appendingPathComponent(app.executableName)
        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        return CategoryResult(
            bundleIdentifier: bundleId,
            category: category,
            previousCategory: previousCategory,
            message: "Application category set to '\(category)' for \(app.displayName) (\(bundleId))."
        )
    }

    // MARK: - Get Runtime Config (for testing / resource use)

    /// Read the current introspection and iOS frameworks state from Info.plist.
    public func getRuntimeConfig(bundleId: String) throws -> [String: Any] {
        let app = try resolveApp(bundleId: bundleId)
        let infoPlistURL = app.url.appendingPathComponent("Info.plist")

        guard let plist = NSDictionary(contentsOf: infoPlistURL) else {
            return [
                "bundleIdentifier": bundleId,
                "introspectionEnabled": false,
                "iosFrameworksEnabled": false,
            ]
        }

        let dyldPath = (plist["LSEnvironment"] as? [String: String])?["DYLD_LIBRARY_PATH"] ?? ""

        return [
            "bundleIdentifier": bundleId,
            "introspectionEnabled": dyldPath.contains(Self.introspectionPath),
            "iosFrameworksEnabled": dyldPath.contains(Self.iosFrameworksPath),
        ]
    }

    // MARK: - Private Helpers

    /// Check if PlayTools is loaded by inspecting the binary's load commands.
    ///
    /// Uses `otool -L` to list shared libraries; looks for the PlayTools path
    /// or uses `otool -l` to check rpaths pointing to the PlayTools framework.
    private func isPlayToolsLoaded(in executable: URL) -> Bool {
        // Check rpaths for PlayTools framework directory
        do {
            let output = try MCPShell.run("/usr/bin/otool", "-l", executable.path)
            // Look for LC_RPATH entries that point to the PlayTools framework parent
            let rpathMarker = "path \(Self.playToolsFrameworkURL.deletingLastPathComponent().path)"
            if output.contains(rpathMarker) {
                return true
            }
        } catch {
            return false
        }

        // Also check loaded libraries via otool -L
        do {
            let output = try MCPShell.run("/usr/bin/otool", "-L", executable.path)
            if output.contains("PlayTools") {
                return true
            }
        } catch {
            // Ignore
        }

        return false
    }

    /// Modify the DYLD_LIBRARY_PATH in Info.plist LSEnvironment.
    ///
    /// - Parameters:
    ///   - bundleId: The app bundle identifier.
    ///   - path: The path to add or remove from DYLD_LIBRARY_PATH.
    ///   - set: `true` to add the path, `false` to remove it.
    ///   - field: Human-readable field name for the result.
    private func modifyDyldLibraryPath(
        bundleId: String, path: String, set: Bool, field: String
    ) throws -> RuntimeConfigResult {
        let app = try resolveApp(bundleId: bundleId)
        let infoPlistURL = app.url.appendingPathComponent("Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw InjectionError.executableNotFound(infoPlistURL.path)
        }

        guard let plist = NSMutableDictionary(contentsOf: infoPlistURL) else {
            throw InjectionError.signingFailed("Failed to read Info.plist")
        }

        // Ensure LSEnvironment exists
        if plist["LSEnvironment"] == nil {
            plist["LSEnvironment"] = NSMutableDictionary(dictionary: [String: String]())
        }
        guard let lsEnv = plist["LSEnvironment"] as? NSMutableDictionary else {
            throw InjectionError.signingFailed("Failed to access LSEnvironment in Info.plist")
        }

        var currentPath = lsEnv["DYLD_LIBRARY_PATH"] as? String ?? ""

        if set {
            if !currentPath.contains(path) {
                // Add colon-separated path entry
                if !currentPath.isEmpty && !currentPath.hasSuffix(":") {
                    currentPath += ":"
                }
                currentPath += path + ":"
            }
        } else {
            currentPath = currentPath.replacingOccurrences(of: path + ":", with: "")
            currentPath = currentPath.replacingOccurrences(of: ":" + path, with: "")
            currentPath = currentPath.replacingOccurrences(of: path, with: "")
        }

        // Remove empty DYLD_LIBRARY_PATH
        if currentPath.trimmingCharacters(in: CharacterSet(charactersIn: ":")).isEmpty {
            lsEnv.removeObject(forKey: "DYLD_LIBRARY_PATH")
        } else {
            lsEnv["DYLD_LIBRARY_PATH"] = currentPath
        }

        plist.write(to: infoPlistURL, atomically: true)

        // Re-sign after plist modification
        let executableURL = app.url.appendingPathComponent(app.executableName)
        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        let enabled = currentPath.contains(path)
        return RuntimeConfigResult(
            bundleIdentifier: bundleId,
            field: field,
            enabled: enabled,
            message: "\(field) \(set ? "enabled" : "disabled") for \(app.displayName) (\(bundleId))."
        )
    }
}
