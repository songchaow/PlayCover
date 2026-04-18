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

/// HOK-012-B: a single watchpoint hit captured during a headless LLDB run.
/// Populated when `launch_app_with_lldb` is invoked with a non-empty
/// `watchAddress`; the headless runner does not quit on the first stop but
/// captures each hit, records the backtrace, then `continue`s so subsequent
/// writers can also be observed. A `stopReason` value of e.g.
/// `"watchpoint 1 (new value: 0x12345...)"` and a thread/frame snapshot are
/// the minimum evidence required to classify H1/H2/H3 in the HOK-012 plan.
public struct WatchpointHit: Codable, Equatable, Sendable {
    public let index: Int
    public let stopReason: String?
    public let thread: String?
    public let frame: String?
    public let backtrace: [String]
    public let oldValue: String?
    public let newValue: String?

    public init(
        index: Int,
        stopReason: String?,
        thread: String?,
        frame: String?,
        backtrace: [String],
        oldValue: String?,
        newValue: String?
    ) {
        self.index = index
        self.stopReason = stopReason
        self.thread = thread
        self.frame = frame
        self.backtrace = backtrace
        self.oldValue = oldValue
        self.newValue = newValue
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
    /// HOK-012-B: watchpoint hits observed during the run (empty when no
    /// watchpoint was requested, or no hit occurred before timeout).
    public let watchpointHits: [WatchpointHit]
    /// HOK-012-B: absolute path to the file where the child process's
    /// stderr was redirected (when `dyldInitializersLogPath` was supplied);
    /// `nil` when stderr redirection was not used.
    public let dyldInitializersLogPath: String?
    /// HOK-012-C.3-b.0: blocking modal windows owned by the inferior
    /// process (or any surviving descendants thereof) at the end of the
    /// capture window. `com.tencent.ngr` is known to pop a non-fatal
    /// `QtsFileSystem Create Failed!!` modal `NSAlert` that keeps the
    /// UI thread spinning on `-[NSApplication runModalForWindow:]`
    /// — the watchpoint-mode transcript then looks "healthy" even
    /// though every slot / bp / watchpoint reading is taken while the
    /// app is frozen behind that alert. A non-empty array here means
    /// this run's evidence is contaminated and `overallPass` must be
    /// downgraded accordingly. Empty array = no modal alert detected
    /// (or the inferior already exited before the snapshot).
    public let blockingDialogWindows: [BlockingDialogInfo]
    /// HOK-012-C.3-b.0: PIDs that were still alive at the end of the
    /// capture window and were force-killed (`SIGKILL`) by the runner
    /// to prevent the next run from inheriting a stuck child holding a
    /// modal `NSAlert`. The first entry, when present, is the direct
    /// `process launch` child; additional entries are descendants that
    /// lldb was not tracking (e.g. helpers spawned by the inferior).
    public let residualProcessesKilled: [Int32]

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
        transcriptTail: String,
        watchpointHits: [WatchpointHit] = [],
        dyldInitializersLogPath: String? = nil,
        blockingDialogWindows: [BlockingDialogInfo] = [],
        residualProcessesKilled: [Int32] = []
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
        self.watchpointHits = watchpointHits
        self.dyldInitializersLogPath = dyldInitializersLogPath
        self.blockingDialogWindows = blockingDialogWindows
        self.residualProcessesKilled = residualProcessesKilled
    }
}

/// HOK-012-C.3-b.0: structured description of a single blocking modal
/// window observed via `CGWindowListCopyWindowInfo`. All fields are
/// Codable/Equatable/Sendable so the evidence can round-trip through
/// MCP JSON without any extra glue.
public struct BlockingDialogInfo: Codable, Equatable, Sendable {
    /// PID of the process that owns the window. Matches the inferior
    /// (or one of its descendants) when the dialog is blocking it.
    public let ownerPID: Int32
    /// Process name as reported by CoreGraphics (`kCGWindowOwnerName`).
    public let ownerName: String?
    /// Window title (may be empty for `NSAlert`; some apps do not set
    /// it). `kCGWindowName` — requires screen-recording permission on
    /// macOS 10.15+ for full content, but empty/nil is still a useful
    /// signal when combined with `ownerPID`.
    public let windowName: String?
    /// `kCGWindowLayer`. Modal `NSAlert` typically runs at
    /// `NSModalPanelWindowLevel` (8) or higher; normal app windows
    /// run at 0. This is the single most reliable modal discriminator.
    public let windowLayer: Int
    /// `kCGWindowAlpha`. Fully transparent windows (alpha ≈ 0) are
    /// typically layout helpers and should not count as "blocking".
    public let alpha: Double
    /// `kCGWindowIsOnscreen`. True when the window is actually
    /// visible on-screen (as opposed to off-screen caches).
    public let isOnscreen: Bool
    /// Bounding box in screen coordinates.
    public let boundsX: Double
    public let boundsY: Double
    public let boundsWidth: Double
    public let boundsHeight: Double

    public init(
        ownerPID: Int32,
        ownerName: String?,
        windowName: String?,
        windowLayer: Int,
        alpha: Double,
        isOnscreen: Bool,
        boundsX: Double,
        boundsY: Double,
        boundsWidth: Double,
        boundsHeight: Double
    ) {
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowName = windowName
        self.windowLayer = windowLayer
        self.alpha = alpha
        self.isOnscreen = isOnscreen
        self.boundsX = boundsX
        self.boundsY = boundsY
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight
    }
}

/// HOK-012-B: headless LLDB run options that control watchpoint capture and
/// stderr redirection. A fully-default-initialized value reproduces the
/// pre-HOK-012-B behaviour (stop on the first `stop reason =`, collect
/// backtrace, then `quit`); setting any of the new fields switches the
/// runner into the HOK-012-B flow.
public struct LLDBRunOptions: Equatable, Sendable {
    /// Optional watchpoint target address (hex string like `0x10e2146f8` or
    /// decimal). When non-empty, the runner installs a watchpoint with
    /// `watchpoint set expression -s <size> -- <addr>` before `run` and
    /// `continue`s on each hit instead of quitting.
    public let watchAddress: String?
    /// Watchpoint byte size; defaults to 8 (a single 64-bit pointer slot).
    /// Ignored when `watchAddress` is nil.
    public let watchSize: Int
    /// Extra LLDB commands executed once the target is loaded but before
    /// `run`. Useful for additional `breakpoint set` / `settings set`
    /// commands; each entry becomes one LLDB command line.
    public let preRunCommands: [String]
    /// When non-nil, the child process's stderr is redirected to this file
    /// via `process launch -e <path>` so dyld output (e.g.
    /// `DYLD_PRINT_INITIALIZERS=1`) can be correlated with watchpoint hits
    /// captured on the LLDB transcript. The file is created/truncated by
    /// LLDB; the runner only records the path and ensures the parent
    /// directory exists.
    public let dyldInitializersLogPath: String?
    /// HOK-012-C: when `true`, the runner will NOT auto-emit
    /// `watchpoint set expression …` before `run`. Watchpoint-mode
    /// plumbing (stop→continue loop, `parseWatchpointHits`,
    /// `watchpointHits` in the evidence) still engages as long as
    /// `watchAddress` is set, but installing the watchpoint itself becomes
    /// the caller's responsibility — typically via a `preRunCommands`
    /// entry like `breakpoint set --address 0x… -C "watchpoint set expression -s 8 -- 0x…" -C "continue" --auto-continue true --one-shot true`.
    /// This lets HOK-012-C push the watchpoint's "armed" moment from
    /// "before `run`" (where it may miss early framework / `+load` stores
    /// on macOS in practice) to "after a chosen breakpoint fires", while
    /// leaving the legacy HOK-012-B behaviour completely intact for
    /// callers that don't opt in.
    public let deferWatchpointInstall: Bool
    /// HOK-012-C.3-b.2: how long (in seconds) the headless runner waits
    /// for the LLDB child to complete its teardown script (`process
    /// interrupt\nthread backtrace all\n…\nquit\n`) after the outer
    /// capture window elapses. Historically hard-coded to `2.0`, which
    /// was fine for legacy quick-crash runs but not enough for the
    /// SIGABRT-intercept path introduced by HOK-012-C.3-b: abort-style
    /// stops need several extra commands (`memory read`, `breakpoint
    /// list`, `watchpoint list`) and a full all-thread backtrace that
    /// routinely exceed the 2s window. Callers probing abort stops
    /// should raise this to 5–10s; legacy callers keep the pre-HOK-012
    /// value.
    public let teardownTimeoutSeconds: TimeInterval

    public init(
        watchAddress: String? = nil,
        watchSize: Int = 8,
        preRunCommands: [String] = [],
        dyldInitializersLogPath: String? = nil,
        deferWatchpointInstall: Bool = false,
        teardownTimeoutSeconds: TimeInterval = 2.0
    ) {
        self.watchAddress = watchAddress
        self.watchSize = watchSize
        self.preRunCommands = preRunCommands
        self.dyldInitializersLogPath = dyldInitializersLogPath
        self.deferWatchpointInstall = deferWatchpointInstall
        self.teardownTimeoutSeconds = max(teardownTimeoutSeconds, 0.1)
    }

    public static let `default` = LLDBRunOptions()

    /// Whether any HOK-012-B behaviour is active (watchpoint or stderr
    /// redirection). When `false`, the runner keeps the legacy
    /// "stop -> quit" flow; when `true`, it switches to "stop -> backtrace
    /// -> continue".
    public var isWatchpointMode: Bool {
        let addressSet = (watchAddress?.trimmingCharacters(in: .whitespaces).isEmpty == false)
        return addressSet
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

    private let headlessLLDBRunner: @Sendable (URL, [String: String], TimeInterval, LLDBRunOptions) throws -> LLDBLaunchEvidence
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
        self.headlessLLDBRunner = { executable, environment, timeoutSeconds, options in
            try Self.runLLDBHeadless(
                executable: executable,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                options: options
            )
        }
        self.terminalLLDBRunner = { executable, environment in
            try Self.runLLDBWithTerminal(executable: executable, environment: environment)
        }
    }

    init(
        appDirectory: URL,
        aliasDirectory: URL,
        headlessLLDBRunner: @escaping @Sendable (URL, [String: String], TimeInterval, LLDBRunOptions) throws -> LLDBLaunchEvidence,
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
    ///   - options: HOK-012-B run options (watchpoint + stderr redirection);
    ///     defaults to the legacy "stop -> quit" behaviour.
    /// - Returns: A `LaunchResult` indicating success or failure.
    public func launchAppWithLLDB(
        bundleId: String,
        withTerminalWindow: Bool = false,
        timeoutSeconds: TimeInterval = 5.0,
        options: LLDBRunOptions = .default
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
            lldbEvidence = try headlessLLDBRunner(executableURL, launchEnvironment, normalizedTimeoutSeconds, options)
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
        terminationStatus: Int32,
        watchpointHits: [WatchpointHit] = [],
        dyldInitializersLogPath: String? = nil,
        blockingDialogWindows: [BlockingDialogInfo] = [],
        residualProcessesKilled: [Int32] = []
    ) -> LLDBLaunchEvidence {
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        // HOK-012-B: in watchpoint mode the transcript contains many
        // `stop reason = watchpoint …` occurrences. For backward compatibility
        // with the legacy fault-capture consumers, prefer the first non-
        // watchpoint stop (e.g. EXC_BAD_ACCESS); only fall back to the first
        // stop line when no such entry exists.
        let allStopIndices = lines.indices.filter { lines[$0].contains("stop reason =") }
        let stopLineIndex: Int? =
            allStopIndices.first(where: { !lines[$0].contains("watchpoint ") })
            ?? allStopIndices.first
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
            transcriptTail: transcriptTail(transcript),
            watchpointHits: watchpointHits,
            dyldInitializersLogPath: dyldInitializersLogPath,
            blockingDialogWindows: blockingDialogWindows,
            residualProcessesKilled: residualProcessesKilled
        )
    }

    /// HOK-012-B: split the captured LLDB transcript into watchpoint-hit
    /// segments. Each segment starts at a `stop reason = watchpoint N` line
    /// and ends just before the next stop reason (or the end of the
    /// transcript). Returns a `WatchpointHit` for every segment, carrying
    /// the first `frame #0:` line, the first full `frame #` block, and the
    /// `old value` / `new value` lines immediately under the stop line.
    static func parseWatchpointHits(transcript: String) -> [WatchpointHit] {
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        var hitRanges: [(stopIndex: Int, endExclusive: Int)] = []
        for (index, line) in lines.enumerated() where line.contains("stop reason = watchpoint") {
            hitRanges.append((index, lines.count))
        }
        for i in 0..<hitRanges.count {
            if i + 1 < hitRanges.count {
                hitRanges[i].endExclusive = hitRanges[i + 1].stopIndex
            }
        }
        var hits: [WatchpointHit] = []
        for (hitIndex, range) in hitRanges.enumerated() {
            let slice = Array(lines[range.stopIndex..<range.endExclusive])
            let stopLine = slice.first?.trimmingCharacters(in: .whitespaces)
            let thread = stopLine.flatMap {
                extractFirstMatch(in: $0, pattern: #"thread\s+#(\d+)"#)
            }
            let stopReason = stopLine.flatMap { line -> String? in
                guard let range = line.range(of: "stop reason =") else {
                    return nil
                }
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            let frame0 = slice.first { $0.contains("frame #0:") }?
                .trimmingCharacters(in: .whitespaces)
            // Backtrace for this segment: all `frame #` lines until we hit
            // the next stop or the end of slice.
            let segmentBacktrace = slice
                .filter { $0.contains("frame #") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let oldValue = slice
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("old value:") }?
                .trimmingCharacters(in: .whitespaces)
            let newValue = slice
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("new value:") }?
                .trimmingCharacters(in: .whitespaces)
            hits.append(
                WatchpointHit(
                    index: hitIndex,
                    stopReason: stopReason,
                    thread: thread,
                    frame: frame0,
                    backtrace: segmentBacktrace,
                    oldValue: oldValue,
                    newValue: newValue
                )
            )
        }
        return hits
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

    /// HOK-012-C.3-b.0: enumerate windows owned by `rootPid` or any of
    /// its still-alive descendants via `CGWindowListCopyWindowInfo`. No
    /// special entitlement or TCC permission is required for the filter
    /// fields we use (`kCGWindowOwnerPID`, `kCGWindowLayer`,
    /// `kCGWindowIsOnscreen`, `kCGWindowAlpha`); on macOS 10.15+ the
    /// `kCGWindowName` field may be redacted for non-owned apps without
    /// screen-recording permission, but PID + layer alone is enough to
    /// tell "is a modal dialog blocking the inferior" apart from "no
    /// dialog at all". Only windows that are (a) on-screen, (b) alpha
    /// ≥ 0.05, and (c) layer ≥ 0 (filters out screen-saver / tooltip
    /// off-screen caches) are returned.
    private static func enumerateBlockingDialogs(ownedBy pids: Set<Int32>) -> [BlockingDialogInfo] {
        guard !pids.isEmpty else { return [] }
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var dialogs: [BlockingDialogInfo] = []
        for entry in raw {
            guard let ownerPIDAny = entry[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let ownerPID = Int32(truncating: ownerPIDAny)
            guard pids.contains(ownerPID) else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            // Screen-saver / off-screen caches are filtered by
            // `.optionOnScreenOnly` above; here we still drop fully
            // transparent helper windows to avoid false positives.
            guard alpha >= 0.05 else { continue }
            let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            let windowName = entry[kCGWindowName as String] as? String
            var bx = 0.0, by = 0.0, bw = 0.0, bh = 0.0
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                bx = Double(boundsDict["X"] ?? 0)
                by = Double(boundsDict["Y"] ?? 0)
                bw = Double(boundsDict["Width"] ?? 0)
                bh = Double(boundsDict["Height"] ?? 0)
            } else if let dictRef = entry[kCGWindowBounds as String] {
                // Sometimes CoreGraphics returns a CFDictionary that
                // does not bridge cleanly; fall through with zeros.
                _ = dictRef
            }
            dialogs.append(
                BlockingDialogInfo(
                    ownerPID: ownerPID,
                    ownerName: ownerName,
                    windowName: windowName,
                    windowLayer: layer,
                    alpha: alpha,
                    isOnscreen: isOnscreen,
                    boundsX: bx,
                    boundsY: by,
                    boundsWidth: bw,
                    boundsHeight: bh
                )
            )
        }
        return dialogs
    }

    /// HOK-012-C.3-b.0: find the LLDB child's direct inferior PID (the
    /// `NGR` process, not LLDB itself) plus any surviving descendants,
    /// using `sysctl` via `Process` on `/bin/ps`. Returns a set suitable
    /// for passing to `enumerateBlockingDialogs`.
    ///
    /// We intentionally do NOT parse LLDB's transcript for "Process N
    /// launched" here — the caller already has that pid via
    /// `parseProcessIdentifier`. Instead we walk `ps -axo pid,ppid` and
    /// union the inferior's PID with every process whose parent chain
    /// traces back to it; this also catches helpers (e.g. XPC services)
    /// the inferior spawned.
    private static func descendantPIDs(of rootPID: Int32) -> Set<Int32> {
        guard rootPID > 0 else { return [] }
        // `ps -axo pid=,ppid=` prints one `<pid> <ppid>` pair per line,
        // no header. Stable across every macOS release.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        do {
            try ps.run()
        } catch {
            return [rootPID]
        }
        ps.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        var parentOf: [Int32: Int32] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .filter { !$0.isEmpty }
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else {
                continue
            }
            parentOf[pid] = ppid
        }
        var result: Set<Int32> = [rootPID]
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in parentOf where result.contains(ppid) && !result.contains(pid) {
                result.insert(pid)
                changed = true
            }
        }
        return result
    }

    /// HOK-012-C.3-b.0: force-kill every PID in `pids` with `SIGKILL`.
    /// Used at the end of a headless LLDB run to guarantee the next
    /// run does not inherit a frozen child holding a modal `NSAlert`.
    /// Returns the subset of PIDs that were actually alive (and thus
    /// signaled) right before the kill; PIDs that were already gone
    /// are skipped silently.
    @discardableResult
    private static func forceKillResidualPIDs(_ pids: [Int32]) -> [Int32] {
        var killed: [Int32] = []
        for pid in pids {
            guard pid > 0 else { continue }
            // `kill(pid, 0)` is the POSIX idiom for "is this pid still
            // alive and signalable by us" — returns 0 when yes,
            // -1/ESRCH when the process is gone.
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
                killed.append(pid)
            }
        }
        return killed
    }

    /// Launch an executable under LLDB in headless mode and collect automation-grade evidence.
    private static func runLLDBHeadless(
        executable: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval,
        options: LLDBRunOptions
    ) throws -> LLDBLaunchEvidence {
        do {
            let process = Process()
            let pipe = Pipe()
            let inputPipe = Pipe()
            let transcriptQueue = DispatchQueue(label: "PlayCoverMCP.LLDBTranscript")
            let completion = DispatchSemaphore(value: 0)
            var transcript = ""
            var legacyStopHandled = false
            var lastHandledStopOffset: String.Index?
            let watchpointMode = options.isWatchpointMode
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
            process.arguments = [executable.path]
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = inputPipe
            process.environment = environment
            process.terminationHandler = { _ in
                completion.signal()
            }

            // HOK-012-B: ensure the target directory for any stderr log
            // exists so `process launch -e <path>` below does not fail.
            if let logPath = options.dyldInitializersLogPath,
               !logPath.isEmpty {
                let logURL = URL(fileURLWithPath: logPath)
                try? FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Truncate any prior log to keep runs from blending together.
                FileManager.default.createFile(atPath: logPath, contents: Data(), attributes: nil)
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                transcriptQueue.sync {
                    transcript += chunk
                    if watchpointMode {
                        // Each time a new `stop reason =` shows up (which
                        // in watchpoint mode is expected to be a watchpoint
                        // hit or an unrelated signal), grab a full backtrace
                        // and `continue`. We intentionally do not `quit` —
                        // the outer timeout is the only terminator, so more
                        // hits in the same run can also be recorded.
                        let searchStart = lastHandledStopOffset ?? transcript.startIndex
                        if let stopRange = transcript.range(of: "stop reason =", range: searchStart..<transcript.endIndex) {
                            lastHandledStopOffset = stopRange.upperBound
                            // HOK-012-C.3-b.1: classify the stop. The line
                            // slice from `stopRange.lowerBound` to the next
                            // newline is the actual `stop reason = …` line;
                            // a watchpoint hit contains `watchpoint `
                            // (space-suffixed, since LLDB prints
                            // `watchpoint 1`). Anything else (typically
                            // `signal SIGABRT` once the abort-intercept
                            // preRunCommand is active) gets the richer
                            // evidence script so we can read the slot
                            // value, writer bp hit counts and watchpoint
                            // list in one go. Legacy HOK-012-B behaviour
                            // on watchpoint-hit stops is preserved
                            // verbatim.
                            let lineEnd = transcript.range(
                                of: "\n",
                                range: stopRange.upperBound..<transcript.endIndex
                            )?.lowerBound ?? transcript.endIndex
                            let stopLine = String(transcript[stopRange.lowerBound..<lineEnd])
                            if stopLine.contains("watchpoint ") {
                                sendLLDBCommands(
                                    "thread backtrace\nframe variable\ncontinue\n",
                                    to: inputPipe.fileHandleForWriting
                                )
                            } else {
                                // Abort-style (typically SIGABRT) stop in
                                // watchpoint mode: snapshot every thread,
                                // read the watched slot so its current
                                // value is on transcript regardless of
                                // whether the watchpoint ever fired, then
                                // dump breakpoint/watchpoint hit counts so
                                // the caller can tell "bp hit 0 times"
                                // from "bp never installed". `memory read`
                                // is only emitted when `watchAddress` is
                                // non-empty; otherwise the commands are
                                // independent of the slot address and
                                // safe to send unconditionally.
                                var abortScript = "thread backtrace all\nframe variable\n"
                                if let addr = options.watchAddress?
                                    .trimmingCharacters(in: .whitespaces),
                                    !addr.isEmpty {
                                    // HOK-012-C.3-b.3-redo: explicit `-fx`
                                    // (hex) format is REQUIRED here — the
                                    // default display format `-fb` (bytes
                                    // with ASCII) collides with `-s 8` and
                                    // LLDB rejects the command with
                                    // `display format ... conflicts with
                                    // the specified byte size 8`, which
                                    // silently drops the slot read. Keep
                                    // the format explicit so the slot
                                    // value is always emitted in hex.
                                    abortScript += "memory read -fx -s 8 -c 1 \(addr)\n"
                                }
                                abortScript += "breakpoint list\nwatchpoint list\n"
                                // HOK-012-C.3-b.3-redo: kill the inferior
                                // and quit LLDB instead of `continue`. All
                                // evidence we care about (slot value, bp
                                // hit counts, watchpoint list, every
                                // thread's backtrace) has already been
                                // dumped above; letting the app continue
                                // would allow `-[NSWindow orderFront:]`
                                // to finish ordering the modal dialog
                                // into view, which would (a) pollute
                                // future `CGWindowListCopyWindowInfo`
                                // snapshots and (b) force b.0's dialog
                                // gate to hard-fail the run. `kill` also
                                // avoids depending on the Apple crash
                                // dialog to tear the process down on
                                // SIGABRT paths — we never need the
                                // `.ips` because the LLDB evidence is a
                                // strict superset of what the `.ips`
                                // would carry.
                                abortScript += "kill\nquit\n"
                                sendLLDBCommands(
                                    abortScript,
                                    to: inputPipe.fileHandleForWriting
                                )
                            }
                        }
                    } else {
                        if !legacyStopHandled && transcript.contains("stop reason =") {
                            legacyStopHandled = true
                            sendLLDBCommands(
                                "thread backtrace all\ndisassemble --pc --count 8\nregister read\nquit\n",
                                to: inputPipe.fileHandleForWriting
                            )
                        }
                    }
                }
            }

            try process.run()

            // HOK-012-B: pre-run commands + watchpoint installation happen
            // before `run` / `process launch` so the watchpoint is active
            // from the very first child instruction. LLDB accepts one
            // command per line via stdin.
            var preRunScript = ""
            for command in options.preRunCommands {
                let trimmed = command.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    preRunScript += trimmed + "\n"
                }
            }
            if watchpointMode, !options.deferWatchpointInstall,
               let address = options.watchAddress?.trimmingCharacters(in: .whitespaces),
               !address.isEmpty {
                let size = max(options.watchSize, 1)
                preRunScript += "watchpoint set expression -s \(size) -- \(address)\n"
            }
            if !preRunScript.isEmpty {
                sendLLDBCommands(preRunScript, to: inputPipe.fileHandleForWriting)
            }

            // Pick the launch command. Legacy path uses `run`; watchpoint /
            // stderr-redirection path uses `process launch -e <path>` so
            // the child's stderr is captured into the dyld log file while
            // LLDB's own stdout/stderr still flow through the transcript
            // pipe for parsing.
            if let logPath = options.dyldInitializersLogPath, !logPath.isEmpty {
                let escapedPath = logPath.replacingOccurrences(of: "\"", with: "\\\"")
                // `-e <path>` redirects the child's stderr; `-o <path>`
                // would also redirect stdout but we want the child's stdout
                // inlined into the transcript for later correlation, so
                // only stderr is redirected.
                sendLLDBCommands(
                    "process launch -e \"\(escapedPath)\"\n",
                    to: inputPipe.fileHandleForWriting
                )
            } else {
                sendLLDBCommands("run\n", to: inputPipe.fileHandleForWriting)
            }

            let timedOut = completion.wait(timeout: .now() + timeoutSeconds) == .timedOut
            if timedOut {
                // In watchpoint mode we also need a final backtrace snapshot
                // (not just during `continue`) for the caller to correlate
                // the last in-flight writer; the sequence is the same as
                // the legacy path.
                sendLLDBCommands(
                    "process interrupt\nthread backtrace all\ndisassemble --pc --count 8\nregister read\nquit\n",
                    to: inputPipe.fileHandleForWriting
                )
                // HOK-012-C.3-b.2: the teardown window used to be hard
                // coded to 2.0 seconds. That is enough for legacy fault
                // captures but not for SIGABRT-intercept runs where the
                // stop handler on an abort also sends `memory read` /
                // `breakpoint list` / `watchpoint list`; we now respect
                // the caller-supplied `options.teardownTimeoutSeconds`
                // (default 2.0 to preserve legacy behaviour).
                if completion.wait(timeout: .now() + options.teardownTimeoutSeconds) == .timedOut {
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
            let watchpointHits = watchpointMode
                ? parseWatchpointHits(transcript: capturedTranscript)
                : []

            // HOK-012-C.3-b.0: before we declare the run finished,
            // snapshot any still-visible modal window owned by the
            // inferior (or its descendants), then force-kill the
            // whole subtree. Without this, `com.tencent.ngr`'s
            // non-fatal `NSAlert` keeps blocking the UI thread on
            // `-[NSApplication runModalForWindow:]` while lldb
            // thinks "the process is still running fine" — every
            // `memory read` / `breakpoint list` / `watchpoint list`
            // reading taken in that state is contaminated. The
            // snapshot is taken FIRST so a non-empty result means
            // "this run was contaminated"; the kill then happens
            // unconditionally so the next run starts clean.
            let inferiorPID = parseProcessIdentifier(from: capturedTranscript) ?? 0
            let dialogPIDs = descendantPIDs(of: inferiorPID)
            let blockingDialogs = inferiorPID > 0
                ? enumerateBlockingDialogs(ownedBy: dialogPIDs)
                : []
            let killedPIDs = inferiorPID > 0
                ? forceKillResidualPIDs(Array(dialogPIDs).sorted())
                : []

            let evidence = parseLLDBEvidence(
                transcript: capturedTranscript,
                timedOut: timedOut,
                terminationStatus: process.terminationStatus,
                watchpointHits: watchpointHits,
                dyldInitializersLogPath: options.dyldInitializersLogPath,
                blockingDialogWindows: blockingDialogs,
                residualProcessesKilled: killedPIDs
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
