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
    public let lldb: LLDBLaunchEvidence?

    public init(
        bundleIdentifier: String,
        launched: Bool,
        method: String,
        message: String,
        lldb: LLDBLaunchEvidence? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.launched = launched
        self.method = method
        self.message = message
        self.lldb = lldb
    }
}

public struct LLDBLaunchEvidence: Codable, Equatable, Sendable {
    public let processIdentifier: Int32?
    public let timedOut: Bool
    public let didStop: Bool
    public let terminationStatus: Int32
    public let stopReason: String?
    public let signal: String?
    public let faultAddress: String?
    public let faultingThread: String?
    public let faultingFrame: String?
    public let faultingInstruction: String?
    public let backtrace: [String]
    public let transcript: String
    public let transcriptTail: String

    public init(
        processIdentifier: Int32?,
        timedOut: Bool,
        didStop: Bool,
        terminationStatus: Int32,
        stopReason: String?,
        signal: String?,
        faultAddress: String?,
        faultingThread: String?,
        faultingFrame: String?,
        faultingInstruction: String?,
        backtrace: [String],
        transcript: String,
        transcriptTail: String
    ) {
        self.processIdentifier = processIdentifier
        self.timedOut = timedOut
        self.didStop = didStop
        self.terminationStatus = terminationStatus
        self.stopReason = stopReason
        self.signal = signal
        self.faultAddress = faultAddress
        self.faultingThread = faultingThread
        self.faultingFrame = faultingFrame
        self.faultingInstruction = faultingInstruction
        self.backtrace = backtrace
        self.transcript = transcript
        self.transcriptTail = transcriptTail
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

    private let headlessLLDBRunner: @Sendable (URL, [String: String], TimeInterval) throws -> LLDBLaunchEvidence
    private let terminalLLDBRunner: @Sendable (URL, [String: String]) throws -> Void

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
        "DYLD_INSERT_LIBRARIES": "/usr/lib/libmtlcapture.dylib",
    ]

    private static let minimalStartupCompatBundleIds: Set<String> = ["com.tencent.ngr"]

    /// HOK-012-A: diagnostic environment injected only for bundles in
    /// `minimalStartupCompatBundleIds`. Mirrors
    /// `PlayApp.minimalStartupCompatDiagnosticEnvironment`; both host paths
    /// (GUI `PlayApp` and MCP `LaunchService`) must set the same vars or the
    /// `launch_app` vs `launch_app_with_lldb` launches will diverge.
    ///
    /// `DYLD_PRINT_INITIALIZERS=1` makes dyld log every initializer to stderr;
    /// this is the evidence we need to correlate the writer of a `__common`
    /// slot (currently `0x10e2146f8`) against a concrete image during a
    /// live-trace run. `DYLD_PRINT_APIS=0` is set explicitly to prevent a
    /// parent-shell override from flooding the transcript and hiding the
    /// initializer lines.
    static let minimalStartupCompatDiagnosticEnvironment: [String: String] = [
        "DYLD_PRINT_INITIALIZERS": "1",
        "DYLD_PRINT_APIS": "0",
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
        self.headlessLLDBRunner = { executable, environment, timeoutSeconds in
            try Self.runLLDBHeadless(
                executable: executable,
                environment: environment,
                timeoutSeconds: timeoutSeconds
            )
        }
        self.terminalLLDBRunner = { executable, environment in
            try Self.runLLDBWithTerminal(executable: executable, environment: environment)
        }
    }

    init(
        appDirectory: URL,
        aliasDirectory: URL,
        headlessLLDBRunner: @escaping @Sendable (URL, [String: String], TimeInterval) throws -> LLDBLaunchEvidence,
        terminalLLDBRunner: @escaping @Sendable (URL, [String: String]) throws -> Void
    ) {
        self.appDirectory = appDirectory
        self.aliasDirectory = aliasDirectory
        self.headlessLLDBRunner = headlessLLDBRunner
        self.terminalLLDBRunner = terminalLLDBRunner
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
    ///   - timeoutSeconds: Headless LLDB wait timeout before the session is interrupted and summarized.
    /// - Returns: A `LaunchResult` indicating success or failure.
    public func launchAppWithLLDB(
        bundleId: String,
        withTerminalWindow: Bool = false,
        timeoutSeconds: TimeInterval = 5.0
    ) throws -> LaunchResult {
        let appRecord = try resolveApp(bundleId: bundleId)
        try preflightChecks(app: appRecord)
        let launchEnvironment = effectiveLaunchEnvironment(bundleId: bundleId)

        let executableURL = appRecord.url
            .appendingPathComponent(appRecord.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LaunchError.executableNotFound(executableURL.path)
        }

        let normalizedTimeoutSeconds = max(timeoutSeconds, 0.1)
        let lldbEvidence: LLDBLaunchEvidence?
        if withTerminalWindow {
            try terminalLLDBRunner(executableURL, launchEnvironment)
            lldbEvidence = nil
        } else {
            lldbEvidence = try headlessLLDBRunner(executableURL, launchEnvironment, normalizedTimeoutSeconds)
        }

        return LaunchResult(
            bundleIdentifier: bundleId,
            launched: true,
            method: withTerminalWindow ? "lldb-terminal" : "lldb-headless",
            message: "App \(appRecord.displayName) (\(bundleId)) launched with LLDB (terminal: \(withTerminalWindow)).",
            lldb: lldbEvidence
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

    /// Build the launch environment applied to every child process that this
    /// service starts. Internal visibility (rather than `private`) is
    /// intentional so that unit tests can validate the environment composition
    /// without having to drive a real child process.
    func effectiveLaunchEnvironment(bundleId: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        let injectCapture = shouldInjectMetalCaptureEnvironment(bundleId: bundleId)
        let isMinimalStartupCompat = Self.minimalStartupCompatBundleIds.contains(bundleId)

        // When metal capture env injection is enabled, do NOT clear DYLD_* keys
        // because we need DYLD_INSERT_LIBRARIES to load libmtlcapture.dylib at
        // dyld time so GPUToolsCapture wraps Metal objects from the very start.
        // RC-014's __attribute__((constructor)) in GuardedCapture.m installs
        // early compat stubs on NSObject before GPUToolsCapture's hooks fire,
        // preventing SIGABRT on apps like Genshin Impact.
        if !injectCapture {
            for key in Array(environment.keys) where key.hasPrefix("DYLD_") {
                environment.removeValue(forKey: key)
            }
        }

        for key in Self.metalEnvKeys {
            environment.removeValue(forKey: key)
        }

        if injectCapture {
            for (key, value) in Self.injectedMetalCaptureEnvironment {
                environment[key] = value
            }
        }

        // HOK-012-A: opt-in dyld initializer logging for minimalStartupCompat
        // bundles. Applied last so it wins over any earlier DYLD_* removal;
        // note that when `injectCapture` is true the parent DYLD_* keys are
        // preserved but the set of minimalStartupCompat bundles and the set
        // of metal-capture bundles is currently disjoint (NGR is excluded
        // from metal capture), so there is no conflict between the two
        // injection paths.
        if isMinimalStartupCompat {
            for (key, value) in Self.minimalStartupCompatDiagnosticEnvironment {
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
        guard !Self.minimalStartupCompatBundleIds.contains(bundleId) else {
            return false
        }

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

    private static func parseProcessIdentifier(from transcript: String) -> Int32? {
        let pattern = #"Process\s+(\d+)\s+launched"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsrange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let match = regex.firstMatch(in: transcript, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: transcript),
              let value = Int32(transcript[range]) else {
            return nil
        }
        return value
    }

    private static func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func transcriptTail(_ transcript: String, maxCharacters: Int = 4000) -> String {
        guard transcript.count > maxCharacters else {
            return transcript
        }
        let start = transcript.index(transcript.endIndex, offsetBy: -maxCharacters)
        return String(transcript[start...])
    }

    static func parseLLDBEvidence(
        transcript: String,
        timedOut: Bool,
        terminationStatus: Int32
    ) -> LLDBLaunchEvidence {
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        let stopLineIndex = lines.firstIndex { $0.contains("stop reason =") }
        let stopLine = stopLineIndex.map { lines[$0].trimmingCharacters(in: .whitespaces) }
        let faultingFrame = stopLineIndex.flatMap { startIndex in
            lines[startIndex...].first { $0.contains("frame #0:") }
        }?.trimmingCharacters(in: .whitespaces)
        let faultingInstruction = stopLineIndex.flatMap { startIndex in
            lines[startIndex...].first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("->") }
        }?.trimmingCharacters(in: .whitespaces)
        let backtrace = lines
            .filter { $0.contains("frame #") }
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let stopReason = stopLine.flatMap { line -> String? in
            guard let range = line.range(of: "stop reason =") else {
                return nil
            }
            return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        let signal = stopReason.flatMap {
            extractFirstMatch(in: $0, pattern: #"(SIG[A-Z0-9]+)"#)
        }
        let faultAddress = stopReason.flatMap {
            extractFirstMatch(in: $0, pattern: #"address\s*=\s*([^,)\s]+)"#)
        }
        let faultingThread = stopLine.flatMap {
            extractFirstMatch(in: $0, pattern: #"thread\s+#(\d+)"#)
        }

        return LLDBLaunchEvidence(
            processIdentifier: parseProcessIdentifier(from: transcript),
            timedOut: timedOut,
            didStop: stopReason != nil,
            terminationStatus: terminationStatus,
            stopReason: stopReason,
            signal: signal,
            faultAddress: faultAddress,
            faultingThread: faultingThread,
            faultingFrame: faultingFrame,
            faultingInstruction: faultingInstruction,
            backtrace: backtrace,
            transcript: transcript,
            transcriptTail: transcriptTail(transcript)
        )
    }

    private static func sendLLDBCommands(_ command: String, to handle: FileHandle) {
        guard let data = command.data(using: .utf8) else {
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    /// Launch an executable under LLDB in headless mode and collect automation-grade evidence.
    private static func runLLDBHeadless(
        executable: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) throws -> LLDBLaunchEvidence {
        do {
            let process = Process()
            let pipe = Pipe()
            let inputPipe = Pipe()
            let transcriptQueue = DispatchQueue(label: "PlayCoverMCP.LLDBTranscript")
            let completion = DispatchSemaphore(value: 0)
            var transcript = ""
            var commandsSentAfterStop = false
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
            process.arguments = [executable.path]
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = inputPipe
            process.environment = environment
            process.terminationHandler = { _ in
                completion.signal()
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                transcriptQueue.sync {
                    transcript += chunk
                    if !commandsSentAfterStop && transcript.contains("stop reason =") {
                        commandsSentAfterStop = true
                        sendLLDBCommands(
                            "thread backtrace all\ndisassemble --pc --count 8\nregister read\nquit\n",
                            to: inputPipe.fileHandleForWriting
                        )
                    }
                }
            }

            try process.run()
            sendLLDBCommands("run\n", to: inputPipe.fileHandleForWriting)

            let timedOut = completion.wait(timeout: .now() + timeoutSeconds) == .timedOut
            if timedOut {
                sendLLDBCommands(
                    "process interrupt\nthread backtrace all\ndisassemble --pc --count 8\nregister read\nquit\n",
                    to: inputPipe.fileHandleForWriting
                )
                if completion.wait(timeout: .now() + 2.0) == .timedOut {
                    process.terminate()
                    _ = completion.wait(timeout: .now() + 1.0)
                }
            }

            pipe.fileHandleForReading.readabilityHandler = nil
            let remainder = try pipe.fileHandleForReading.readToEnd() ?? Data()
            if !remainder.isEmpty {
                let trailingText = String(data: remainder, encoding: .utf8) ?? ""
                transcriptQueue.sync {
                    transcript += trailingText
                }
            }

            let capturedTranscript = transcriptQueue.sync { transcript }
            let evidence = parseLLDBEvidence(
                transcript: capturedTranscript,
                timedOut: timedOut,
                terminationStatus: process.terminationStatus
            )
            if process.terminationStatus != 0,
               evidence.processIdentifier == nil,
               !evidence.didStop {
                throw LaunchError.lldbFailed(
                    "lldb exited with status \(process.terminationStatus): \(evidence.transcriptTail)"
                )
            }
            return evidence
        } catch let error as LaunchError {
            throw error
        } catch {
            throw LaunchError.lldbFailed(error.localizedDescription)
        }
    }

    /// Launch an executable under LLDB in a Terminal window via osascript.
    private static func runLLDBWithTerminal(executable: URL, environment: [String: String]) throws {
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
