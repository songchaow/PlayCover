// InjectionService.swift
// PlayCoverMCP

import Foundation
#if canImport(injection)
import injection
#endif

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
    /// In the GUI target, prefer the same load-dylib injection semantics used by
    /// the long-lived PlayCover UI implementation. CLI builds currently retain a
    /// reduced fallback until install internals are fully shared.
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

#if canImport(injection)
        var didInject = false
        Inject.injectMachO(
            machoPath: executableURL.path,
            cmdType: .loadDylib,
            backup: false,
            injectPath: Self.playToolsDylibPath.path,
            finishHandle: { result in
                didInject = result
            }
        )

        guard didInject else {
            throw InjectionError.injectionFailed(
                "Failed to inject PlayTools dylib load command into \(app.displayName)"
            )
        }

        do {
            try installPlayToolsResources(in: app.url)
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        let message = "PlayTools injected into \(app.displayName) (\(bundleId)). Added dylib load command, installed AKInterface resources, and re-signed the app."
#else
        // Add rpath for the PlayTools framework directory
        let rpath = Self.playToolsFrameworkURL.deletingLastPathComponent().path
        do {
            try MCPShell.run("/usr/bin/install_name_tool", "-add_rpath", rpath, executableURL.path)
        } catch let err as ShellError {
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

        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        let message = "PlayTools injected into \(app.displayName) (\(bundleId)). Added rpath for PlayTools framework, installed AKInterface plugin, and re-signed the app."
#endif

        // Notify GUI that the app state may have changed (injection modifies the binary)
        MCPNotificationPoster.postAppsChanged()

        return InjectionResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            action: "injected",
            message: message
        )
    }

    // MARK: - Remove PlayTools

    /// Remove PlayTools from an app's MachO binary.
    ///
    /// In the GUI target, prefer the same load-dylib removal semantics used by
    /// the original PlayCover UI implementation.
    public func removePlayTools(bundleId: String) throws -> InjectionResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw InjectionError.executableNotFound(executableURL.path)
        }

#if canImport(injection)
        var didRemove = false
        Inject.removeMachO(
            machoPath: executableURL.path,
            cmdType: .loadDylib,
            backup: false,
            injectPath: Self.playToolsDylibPath.path,
            finishHandle: { result in
                didRemove = result
            }
        )

        if !didRemove && isPlayToolsLoaded(in: executableURL) {
            throw InjectionError.removalFailed(
                "Failed to remove PlayTools dylib load command from \(app.displayName)"
            )
        }

        let pluginPath = app.url
            .appendingPathComponent("PlugIns/AKInterface.bundle")
        if FileManager.default.fileExists(atPath: pluginPath.path) {
            try FileManager.default.removeItem(at: pluginPath)
        }

        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        let message = "PlayTools removed from \(app.displayName) (\(bundleId)). Removed dylib load command, deleted AKInterface plugin, and re-signed the app."
#else
        let rpath = Self.playToolsFrameworkURL.deletingLastPathComponent().path
        try? MCPShell.run("/usr/bin/install_name_tool", "-delete_rpath", rpath, executableURL.path)

        let pluginPath = app.url
            .appendingPathComponent("PlugIns/AKInterface.bundle")
        if FileManager.default.fileExists(atPath: pluginPath.path) {
            try FileManager.default.removeItem(at: pluginPath)
        }

        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw InjectionError.signingFailed(error.localizedDescription)
        }

        let message = "PlayTools removed from \(app.displayName) (\(bundleId)). Removed rpath, deleted AKInterface plugin, and re-signed the app."
#endif

        // Notify GUI that the app state may have changed (removal modifies the binary)
        MCPNotificationPoster.postAppsChanged()

        return InjectionResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            action: "removed",
            message: message
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

    /// Check if PlayTools is loaded by inspecting the binary's linked dylibs.
    ///
    /// This intentionally aligns with the GUI behavior: an app only counts as
    /// having PlayTools when the executable contains the actual PlayTools dylib
    /// load command, not merely an auxiliary rpath.
    private func isPlayToolsLoaded(in executable: URL) -> Bool {
        do {
            let output = try MCPShell.run("/usr/bin/otool", "-L", executable.path)
            return output.contains(Self.playToolsDylibPath.path)
                || output.contains("@executable_path/Frameworks/PlayTools.dylib")
        } catch {
            return false
        }
    }

    private func installPlayToolsResources(in payload: URL) throws {
        let sourceFramework = try Self.resolvePlayToolsResourceFramework()
        try Self.copyPlayToolsLocalizations(from: sourceFramework, to: payload)

        let bundleTarget = try Self.copyPlayToolsAsset(
            source: sourceFramework,
            target: payload,
            directoryName: "PlugIns",
            component: "AKInterface",
            pathExtension: "bundle"
        )
        try MCPShell.setExecutable(bundleTarget)
        try MCPShell.signMacho(bundleTarget)
    }

    private static func resolvePlayToolsResourceFramework() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/PlayTools.framework"),
            playToolsFrameworkURL,
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw InjectionError.playToolsNotInstalled(
            "PlayTools framework resources not found in bundled or system locations"
        )
    }

    private static func copyPlayToolsLocalizations(from sourceFramework: URL, to payload: URL) throws {
        let topLevelEntries = try FileManager.default.contentsOfDirectory(
            at: sourceFramework,
            includingPropertiesForKeys: nil
        )

        for localizationDirectory in topLevelEntries where localizationDirectory.pathExtension == "lproj" {
            _ = try copyPlayToolsAsset(
                source: sourceFramework,
                target: payload,
                directoryName: localizationDirectory.lastPathComponent,
                component: "Playtools",
                pathExtension: "strings"
            )
        }

        let resourcesDirectory = sourceFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: resourcesDirectory.path) {
            let resourceEntries = try FileManager.default.contentsOfDirectory(
                at: resourcesDirectory,
                includingPropertiesForKeys: nil
            )
            for localizationDirectory in resourceEntries where localizationDirectory.pathExtension == "lproj" {
                _ = try copyPlayToolsAsset(
                    source: resourcesDirectory,
                    target: payload,
                    directoryName: localizationDirectory.lastPathComponent,
                    component: "Playtools",
                    pathExtension: "strings"
                )
            }
        }
    }

    private static func copyPlayToolsAsset(
        source: URL,
        target: URL,
        directoryName: String,
        component: String,
        pathExtension: String
    ) throws -> URL {
        let directory = target.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceAsset = source
            .appendingPathComponent(directoryName)
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)
        let targetAsset = directory
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)

        if FileManager.default.fileExists(atPath: targetAsset.path) {
            try FileManager.default.removeItem(at: targetAsset)
        }
        try FileManager.default.copyItem(at: sourceAsset, to: targetAsset)
        return targetAsset
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
