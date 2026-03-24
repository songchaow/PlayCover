// LaunchService.swift
// PlayCoverMCP

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
/// and clear debug-affecting environment variables before launching.
public final class LaunchService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// The alias directory where PlayCover creates .app aliases.
    public let aliasDirectory: URL

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

        // Clear debug-affecting environment variables
        clearDebugEnvironment()

        let aliasURL = aliasDirectory
            .appendingPathComponent(appRecord.displayName)
            .appendingPathExtension("app")

        guard FileManager.default.fileExists(atPath: aliasURL.path) else {
            throw LaunchError.aliasNotFound(bundleId)
        }

        // Launch via `open` command (non-blocking, headless)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [aliasURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
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

        // Clear debug-affecting environment variables
        clearDebugEnvironment()

        let executableURL = appRecord.url
            .appendingPathComponent(appRecord.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LaunchError.executableNotFound(executableURL.path)
        }

        if withTerminalWindow {
            try lldbWithTerminal(executable: executableURL)
        } else {
            try lldbHeadless(executable: executableURL)
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

    /// Clear environment variables that could affect the launched app's behavior.
    ///
    /// Mirrors `PlayApp.clearDebugAffectingEnvironment()` but without UI dependencies.
    private func clearDebugEnvironment() {
        // Clear DYLD_* variables
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }

        // Clear Metal debug/capture variables
        let metalKeys = [
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
        for key in metalKeys {
            unsetenv(key)
        }
    }

    // MARK: - LLDB Helpers

    /// Launch an executable under LLDB in headless mode (output to stdout/stderr).
    private func lldbHeadless(executable: URL) throws {
        do {
            _ = try MCPShell.run("/usr/bin/lldb", "-o", "run", executable.path, "-o", "exit")
        } catch {
            throw LaunchError.lldbFailed(error.localizedDescription)
        }
    }

    /// Launch an executable under LLDB in a Terminal window via osascript.
    private func lldbWithTerminal(executable: URL) throws {
        let escapedPath = executable.path.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
            tell application "Terminal"
                reopen
                activate
                do script "/usr/bin/lldb -o run \"\(escapedPath)\" -o exit"
            end tell
        """
        do {
            _ = try MCPShell.run("/usr/bin/osascript", "-e", appleScript)
        } catch {
            throw LaunchError.lldbFailed(error.localizedDescription)
        }
    }
}
