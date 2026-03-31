// LaunchService.swift
// PlayCoverMCP

import AppKit
import Foundation

/// Result of an app launch operation.
public struct LaunchResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let launched: Bool
    public let method: String
    public let message: String

    public init(bundleIdentifier: String, launched: Bool, method: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.launched = launched
        self.method = method
        self.message = message
    }
}

/// Errors specific to app launch operations.
public enum LaunchError: Error, LocalizedError, Equatable {
    case appNotFound(String)
    case executableNotFound(String)
    case aliasNotFound(String)
    case prohibited(String)
    case lldbFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .executableNotFound(let path): return "Executable not found at: \(path)"
        case .aliasNotFound(let id): return "Application alias not found for: \(id)"
        case .prohibited(let id): return "Application is prohibited from launching: \(id)"
        case .lldbFailed(let msg): return "LLDB launch failed: \(msg)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        }
    }
}

/// A headless service for launching PlayCover-managed iOS applications.
///
/// Provides two launch modes:
/// - **Normal launch**: Opens the app via `NSWorkspace` (headless, no UI alert).
/// - **LLDB launch**: Starts the app under `lldb` for debugging.
///
/// Both modes perform pre-flight checks (app exists, alias exists, executable exists)
/// and construct a sanitized child-process environment before launching. When the
/// per-app `injectMetalCaptureEnvironment` setting is enabled, the launch path will
/// additionally inject an experimental Metal capture environment profile.
public final class LaunchService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// The alias directory where PlayCover creates .app aliases.
    public let aliasDirectory: URL

    private static let metalEnvKeys = [
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_LAYER",
        "MTL_DEBUG_LAYER",
        "METAL_API_VALIDATION",
        "METAL_SHADER_VALIDATION",
        "METAL_SHADER_VALIDATION_OPTIONS",
        "METAL_CAPTURE_ENABLED",
        "METAL_CAPTURE_OUTPUT_FILE",
        "METAL_CAPTURE_TYPE",
        "METAL_FORCE_LAZY_COMPILATION",
        "METAL_FRAME_CAPTURE_ENABLED",
        "METAL_ERROR_MODE",
        "MTLCaptureEnabled"
    ]

    private static let injectedMetalCaptureEnvironment: [String: String] = [
        "METAL_DEVICE_WRAPPER_TYPE": "1",
        "METAL_CAPTURE_ENABLED": "1",
        "METAL_FRAME_CAPTURE_ENABLED": "1",
        "MTLCaptureEnabled": "1",
    ]

    /// The system library that enables `MTLCaptureManager.supportsDestination(.gpuTraceDocument)`.
    /// Xcode injects this automatically during GPU Frame Capture debug sessions.
    /// Without it, `supportsDestination(.gpuTraceDocument)` always returns `false`,
    /// making programmatic `.gputrace` export impossible.
    private static let gpuToolsCaptureLibrary = "/usr/lib/libmtlcapture.dylib"

    /// Create a LaunchService with custom paths (useful for testing).
    public init(appDirectory: URL, aliasDirectory: URL) {
        self.appDirectory = appDirectory
        self.aliasDirectory = aliasDirectory
    }

    /// Create a LaunchService pointing to default PlayCover paths.
    public static func defaultService() -> LaunchService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        let appDir = container.appendingPathComponent("Applications")
        let aliasDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent("PlayCover")
        return LaunchService(appDirectory: appDir, aliasDirectory: aliasDir)
    }

    // MARK: - Launch

    /// Launch a PlayCover-managed app by bundle ID.
    ///
    /// - Parameter bundleId: The bundle identifier of the app to launch.
    /// - Returns: A `LaunchResult` indicating success or failure.
    public func launchApp(bundleId: String) throws -> LaunchResult {
        let appRecord = try resolveApp(bundleId: bundleId)
        try preflightChecks(app: appRecord)
        let launchEnvironment = effectiveLaunchEnvironment(bundleId: bundleId)

        let aliasURL = aliasDirectory
            .appendingPathComponent(appRecord.displayName)
            .appendingPathExtension("app")

        guard FileManager.default.fileExists(atPath: aliasURL.path) else {
            throw LaunchError.aliasNotFound(bundleId)
        }

        // Launch via NSWorkspace so that environment (including DYLD_INSERT_LIBRARIES)
        // is correctly propagated to the target app process.
        let config = NSWorkspace.OpenConfiguration()
        config.environment = launchEnvironment

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(
            at: aliasURL,
            configuration: config
        ) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = launchError {
            throw LaunchError.launchFailed(error.localizedDescription)
        }

        return LaunchResult(
            bundleIdentifier: bundleId,
            launched: true,
            method: "normal",
            message: "App \(appRecord.displayName) (\(bundleId)) launched successfully."
        )
    }

    /// Launch a PlayCover-managed app under LLDB.
    ///
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the app to launch.
    ///   - withTerminalWindow: Whether to open a Terminal window for LLDB output.
    /// - Returns: A `LaunchResult` indicating success or failure.
    public func launchAppWithLLDB(bundleId: String, withTerminalWindow: Bool = false) throws -> LaunchResult {
        let appRecord = try resolveApp(bundleId: bundleId)
        try preflightChecks(app: appRecord)
        let launchEnvironment = effectiveLaunchEnvironment(bundleId: bundleId)

        let executableURL = appRecord.url
            .appendingPathComponent(appRecord.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LaunchError.executableNotFound(executableURL.path)
        }

        if withTerminalWindow {
            try lldbWithTerminal(executable: executableURL, environment: launchEnvironment)
        } else {
            try lldbHeadless(executable: executableURL, environment: launchEnvironment)
        }

        return LaunchResult(
            bundleIdentifier: bundleId,
            launched: true,
            method: withTerminalWindow ? "lldb-terminal" : "lldb-headless",
            message: "App \(appRecord.displayName) (\(bundleId)) launched with LLDB (terminal: \(withTerminalWindow))."
        )
    }

    // MARK: - Preflight

    /// Resolve a bundle ID to an app record by scanning the Applications directory.
    public func resolveApp(bundleId: String) throws -> AppRecord {
        let fm = FileManager.default

        guard fm.fileExists(atPath: appDirectory.path) else {
            throw LaunchError.appNotFound(bundleId)
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

        throw LaunchError.appNotFound(bundleId)
    }

    /// Perform pre-flight checks before launching.
    private func preflightChecks(app: AppRecord) throws {
        // Check if the app bundle still exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.url.path) else {
            throw LaunchError.appNotFound(app.bundleIdentifier)
        }

        // Check if the executable exists
        let execURL = app.url.appendingPathComponent(app.executableName)
        guard fm.fileExists(atPath: execURL.path) else {
            throw LaunchError.executableNotFound(execURL.path)
        }
    }

    // MARK: - Environment

    private func effectiveLaunchEnvironment(bundleId: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for key in Array(environment.keys) where key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        for key in Self.metalEnvKeys {
            environment.removeValue(forKey: key)
        }

        if isMetalCaptureEnabled(bundleId: bundleId),
           FileManager.default.fileExists(atPath: Self.gpuToolsCaptureLibrary) {
            environment["DYLD_INSERT_LIBRARIES"] = Self.gpuToolsCaptureLibrary
        }

        if shouldInjectMetalCaptureEnvironment(bundleId: bundleId) {
            for (key, value) in Self.injectedMetalCaptureEnvironment {
                environment[key] = value
            }
        }

        return environment
    }

    private func isMetalCaptureEnabled(bundleId: String) -> Bool {
        let settingsURL = appDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")

        guard let data = try? Data(contentsOf: settingsURL),
              let rawPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = rawPlist as? [String: Any] else {
            return false
        }
        return plist["metalCaptureEnabled"] as? Bool ?? false
    }

    private func shouldInjectMetalCaptureEnvironment(bundleId: String) -> Bool {
        let settingsURL = appDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")

        guard let data = try? Data(contentsOf: settingsURL),
              let rawPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = rawPlist as? [String: Any] else {
            return false
        }
        return plist["injectMetalCaptureEnvironment"] as? Bool ?? false
    }

    // MARK: - LLDB Helpers

    /// Launch an executable under LLDB in headless mode (output to stdout/stderr).
    private func lldbHeadless(executable: URL, environment: [String: String]) throws {
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
            process.arguments = ["-o", "run", executable.path, "-o", "exit"]
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = environment
            try process.run()
            _ = try pipe.fileHandleForReading.readToEnd()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw LaunchError.lldbFailed("lldb exited with status \(process.terminationStatus)")
            }
        } catch let error as LaunchError {
            throw error
        } catch {
            throw LaunchError.lldbFailed(error.localizedDescription)
        }
    }

    /// Launch an executable under LLDB in a Terminal window via osascript.
    private func lldbWithTerminal(executable: URL, environment: [String: String]) throws {
        let escapedPath = executable.path.replacingOccurrences(of: "\"", with: "\\\"")
        let envPrefix = environment
            .filter { Self.injectedMetalCaptureEnvironment.keys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let commandPrefix = envPrefix.isEmpty ? "" : "/usr/bin/env \(envPrefix) "
        let appleScript = """
            tell application "Terminal"
                reopen
                activate
                do script "\(commandPrefix)/usr/bin/lldb -o run \"\(escapedPath)\" -o exit"
            end tell
        """
        do {
            _ = try MCPShell.run("/usr/bin/osascript", "-e", appleScript)
        } catch {
            throw LaunchError.lldbFailed(error.localizedDescription)
        }
    }
}
