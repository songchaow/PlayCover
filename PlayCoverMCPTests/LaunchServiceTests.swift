import XCTest
import Foundation

final class LaunchServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a temporary app directory with a fake .app bundle for testing.
    private func makeFixtureApp(
        bundleId: String = "com.test.myapp",
        displayName: String = "My Test App",
        executableName: String = "MyTestApp"
    ) throws -> (URL, URL) {
        // App directory (simulates PlayCover Applications dir)
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Create .app bundle
        let bundleDir = appDir.appendingPathComponent(bundleId).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Create Info.plist
        let info: [String: String] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleExecutable": executableName,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try plistData.write(to: bundleDir.appendingPathComponent("Info.plist"))

        // Create a dummy executable
        let execURL = bundleDir.appendingPathComponent(executableName)
        try Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 28)).write(to: execURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: execURL.path
        )

        // Alias directory
        let aliasDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchAlias_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)

        // Create alias entry
        let aliasURL = aliasDir.appendingPathComponent(displayName).appendingPathExtension("app")
        try FileManager.default.createDirectory(at: aliasURL, withIntermediateDirectories: true)

        return (appDir, aliasDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Parameter Validation Tests

    func testLaunchAppRejectsEmptyBundleId() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias")
        )
        XCTAssertThrowsError(try service.launchApp(bundleId: "")) { error in
            XCTAssertTrue(
                error is LaunchError,
                "Expected LaunchError, got \(type(of: error))"
            )
        }
    }

    func testLaunchAppThrowsForNonexistentApp() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias_\(UUID().uuidString)")
        )
        XCTAssertThrowsError(try service.launchApp(bundleId: "com.nonexistent.app")) { error in
            guard let launchError = error as? LaunchError else {
                XCTFail("Expected LaunchError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(launchError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testLaunchWithLLDBRejectsEmptyBundleId() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias")
        )
        XCTAssertThrowsError(try service.launchAppWithLLDB(bundleId: "")) { error in
            XCTAssertTrue(
                error is LaunchError,
                "Expected LaunchError, got \(type(of: error))"
            )
        }
    }

    func testLaunchWithLLDBThrowsForNonexistentApp() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias_\(UUID().uuidString)")
        )
        XCTAssertThrowsError(try service.launchAppWithLLDB(bundleId: "com.nonexistent.app")) { error in
            guard let launchError = error as? LaunchError else {
                XCTFail("Expected LaunchError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(launchError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Resolve App Tests

    func testResolveAppFindsCorrectApp() throws {
        let (appDir, aliasDir) = try makeFixtureApp(
            bundleId: "com.test.resolve",
            displayName: "ResolveApp",
            executableName: "ResolveApp"
        )
        defer { cleanupFixture([appDir, aliasDir]) }

        let service = LaunchService(appDirectory: appDir, aliasDirectory: aliasDir)
        let record = try service.resolveApp(bundleId: "com.test.resolve")

        XCTAssertEqual(record.bundleIdentifier, "com.test.resolve")
        XCTAssertEqual(record.displayName, "ResolveApp")
        XCTAssertEqual(record.executableName, "ResolveApp")
    }

    func testResolveAppThrowsForUnknownBundleId() throws {
        let (appDir, aliasDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, aliasDir]) }

        let service = LaunchService(appDirectory: appDir, aliasDirectory: aliasDir)
        XCTAssertThrowsError(try service.resolveApp(bundleId: "com.unknown.app")) { error in
            guard let launchError = error as? LaunchError else {
                XCTFail("Expected LaunchError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(launchError, .appNotFound("com.unknown.app"))
        }
    }

    func testResolveAppThrowsForNonexistentDirectory() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias_\(UUID().uuidString)")
        )
        XCTAssertThrowsError(try service.resolveApp(bundleId: "com.any.app")) { error in
            guard let launchError = error as? LaunchError else {
                XCTFail("Expected LaunchError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(launchError, .appNotFound("com.any.app"))
        }
    }

    // MARK: - Preflight Tests

    func testLaunchAppThrowsForMissingExecutable() throws {
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let aliasDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchAlias_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        defer { cleanupFixture([appDir, aliasDir]) }

        // Create .app bundle without executable
        let bundleDir = appDir.appendingPathComponent("com.test.noexec.app")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let info: [String: String] = [
            "CFBundleIdentifier": "com.test.noexec",
            "CFBundleName": "NoExec",
            "CFBundleDisplayName": "NoExec",
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "MissingExec",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try plistData.write(to: bundleDir.appendingPathComponent("Info.plist"))

        let service = LaunchService(appDirectory: appDir, aliasDirectory: aliasDir)
        XCTAssertThrowsError(try service.launchApp(bundleId: "com.test.noexec")) { error in
            guard let launchError = error as? LaunchError else {
                XCTFail("Expected LaunchError, got \(type(of: error))")
                return
            }
            if case .executableNotFound = launchError {
                // Expected
            } else {
                XCTFail("Expected .executableNotFound, got \(launchError)")
            }
        }
    }

    // MARK: - LaunchResult Serialization Tests

    func testLaunchResultCodableRoundTrip() throws {
        let result = LaunchResult(
            bundleIdentifier: "com.test.app",
            launched: true,
            method: "normal",
            message: "Launched successfully."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LaunchResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.launched, true)
        XCTAssertEqual(decoded.method, "normal")
    }

    func testLaunchResultLLDBCodableRoundTrip() throws {
        let result = LaunchResult(
            bundleIdentifier: "com.test.app",
            launched: true,
            method: "lldb-terminal",
            message: "Launched with LLDB in terminal.",
            lldb: LLDBLaunchEvidence(
                processIdentifier: 42,
                timedOut: false,
                didStop: true,
                terminationStatus: 0,
                stopReason: "signal SIGSEGV",
                signal: "SIGSEGV",
                faultAddress: "0x0",
                faultingThread: "1",
                faultingFrame: "frame #0: 0x1 App`main + 0",
                faultingInstruction: "->  0x1 <+0>: brk #0x1",
                backtrace: ["frame #0: 0x1 App`main + 0"],
                transcript: "Process 42 launched",
                transcriptTail: "Process 42 launched"
            )
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LaunchResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.method, "lldb-terminal")
        XCTAssertEqual(decoded.lldb?.signal, "SIGSEGV")
    }

    func testParseLLDBEvidenceExtractsStopReasonFaultAndBacktrace() {
        let transcript = """
        (lldb) target create /Applications/NGR.app/NGR
        Current executable set to '/Applications/NGR.app/NGR' (arm64).
        (lldb) run
        Process 24769 launched: '/Applications/NGR.app/NGR' (arm64)
        Process 24769 stopped
        * thread #1, queue = 'com.apple.main-thread', stop reason = EXC_BAD_ACCESS (code=1, address=0x0)
            frame #0: 0x0000000101234567 NGR`foo + 12
        NGR`foo:
        ->  0x0000000101234567 <+12>: ldr    x8, [x0]
            0x000000010123456b <+16>: ret
        (lldb) thread backtrace all
        * thread #1, queue = 'com.apple.main-thread', stop reason = EXC_BAD_ACCESS (code=1, address=0x0)
          * frame #0: 0x0000000101234567 NGR`foo + 12
            frame #1: 0x0000000107654321 NGR`bar + 44
        """

        let evidence = LaunchService.parseLLDBEvidence(
            transcript: transcript,
            timedOut: false,
            terminationStatus: 0
        )

        XCTAssertEqual(evidence.processIdentifier, 24769)
        XCTAssertTrue(evidence.didStop)
        XCTAssertEqual(evidence.faultAddress, "0x0")
        XCTAssertEqual(evidence.faultingThread, "1")
        XCTAssertEqual(evidence.signal, nil)
        XCTAssertEqual(evidence.faultingFrame, "frame #0: 0x0000000101234567 NGR`foo + 12")
        XCTAssertEqual(evidence.faultingInstruction, "->  0x0000000101234567 <+12>: ldr    x8, [x0]")
        XCTAssertEqual(evidence.backtrace.count, 3)
    }

    func testLaunchWithLLDBHeadlessReturnsStructuredEvidenceFromRunner() throws {
        let (appDir, aliasDir) = try makeFixtureApp(
            bundleId: "com.test.lldb",
            displayName: "LLDBApp",
            executableName: "LLDBApp"
        )
        defer { cleanupFixture([appDir, aliasDir]) }

        let expectedEvidence = LLDBLaunchEvidence(
            processIdentifier: 9,
            timedOut: true,
            didStop: false,
            terminationStatus: 15,
            stopReason: nil,
            signal: nil,
            faultAddress: nil,
            faultingThread: nil,
            faultingFrame: nil,
            faultingInstruction: nil,
            backtrace: [],
            transcript: "Process 9 launched",
            transcriptTail: "Process 9 launched"
        )
        let service = LaunchService(
            appDirectory: appDir,
            aliasDirectory: aliasDir,
            headlessLLDBRunner: { executable, _, timeoutSeconds, options in
                XCTAssertEqual(executable.lastPathComponent, "LLDBApp")
                XCTAssertEqual(timeoutSeconds, 2.5, accuracy: 0.001)
                // Default (legacy) invocation path: no HOK-012-B options.
                XCTAssertEqual(options, LLDBRunOptions.default)
                return expectedEvidence
            },
            terminalLLDBRunner: { _, _ in
                XCTFail("terminal runner should not be used in headless test")
            }
        )

        let result = try service.launchAppWithLLDB(
            bundleId: "com.test.lldb",
            withTerminalWindow: false,
            timeoutSeconds: 2.5
        )

        XCTAssertEqual(result.method, "lldb-headless")
        XCTAssertEqual(result.lldb, expectedEvidence)
        XCTAssertTrue(result.lldb?.timedOut ?? false)
    }

    // MARK: - HOK-012-B: watchpoint / preRunCommands / dyldInitializersLogPath

    /// HOK-012-B: `launchAppWithLLDB` must forward watchpoint options to the
    /// headless runner unchanged; the runner closure is the contract
    /// boundary, so the assertions live on the closure's captured `options`.
    func testLaunchWithLLDBForwardsWatchpointOptionsToRunner() throws {
        let (appDir, aliasDir) = try makeFixtureApp(
            bundleId: "com.test.watch",
            displayName: "WatchApp",
            executableName: "WatchApp"
        )
        defer { cleanupFixture([appDir, aliasDir]) }

        let capturedHit = WatchpointHit(
            index: 0,
            stopReason: "watchpoint 1",
            thread: "1",
            frame: "frame #0: 0x1 App`writer + 0",
            backtrace: ["frame #0: 0x1 App`writer + 0"],
            oldValue: "old value: 0x0",
            newValue: "new value: 0x2000"
        )
        let expectedEvidence = LLDBLaunchEvidence(
            processIdentifier: 7,
            timedOut: true,
            didStop: true,
            terminationStatus: 0,
            stopReason: "watchpoint 1",
            signal: nil,
            faultAddress: nil,
            faultingThread: "1",
            faultingFrame: "frame #0: 0x1 App`writer + 0",
            faultingInstruction: nil,
            backtrace: ["frame #0: 0x1 App`writer + 0"],
            transcript: "Process 7 launched",
            transcriptTail: "Process 7 launched",
            watchpointHits: [capturedHit],
            dyldInitializersLogPath: "/tmp/dyld-init.log"
        )

        let service = LaunchService(
            appDirectory: appDir,
            aliasDirectory: aliasDir,
            headlessLLDBRunner: { _, _, _, options in
                XCTAssertEqual(options.watchAddress, "0x10e2146f8")
                XCTAssertEqual(options.watchSize, 8)
                XCTAssertEqual(options.preRunCommands, ["breakpoint set --name foo"])
                XCTAssertEqual(options.dyldInitializersLogPath, "/tmp/dyld-init.log")
                XCTAssertTrue(options.isWatchpointMode)
                return expectedEvidence
            },
            terminalLLDBRunner: { _, _ in
                XCTFail("terminal runner should not be used in watchpoint test")
            }
        )

        let result = try service.launchAppWithLLDB(
            bundleId: "com.test.watch",
            withTerminalWindow: false,
            timeoutSeconds: 5.0,
            options: LLDBRunOptions(
                watchAddress: "0x10e2146f8",
                watchSize: 8,
                preRunCommands: ["breakpoint set --name foo"],
                dyldInitializersLogPath: "/tmp/dyld-init.log"
            )
        )

        XCTAssertEqual(result.lldb?.watchpointHits.count, 1)
        XCTAssertEqual(result.lldb?.watchpointHits.first, capturedHit)
        XCTAssertEqual(result.lldb?.dyldInitializersLogPath, "/tmp/dyld-init.log")
    }

    /// HOK-012-B: `LLDBRunOptions.default` must preserve legacy semantics —
    /// no watchpoint, no stderr redirection.
    func testLLDBRunOptionsDefaultIsLegacyBehaviour() {
        let options = LLDBRunOptions.default
        XCTAssertNil(options.watchAddress)
        XCTAssertEqual(options.watchSize, 8)
        XCTAssertTrue(options.preRunCommands.isEmpty)
        XCTAssertNil(options.dyldInitializersLogPath)
        XCTAssertFalse(options.isWatchpointMode)
    }

    /// HOK-012-B: watchpoint mode should only engage when a non-empty
    /// `watchAddress` is set; empty / whitespace-only strings fall back to
    /// the legacy flow so accidental empty CLI arguments don't hang the
    /// runner waiting for watchpoint hits that will never arrive.
    func testLLDBRunOptionsWatchpointModeRequiresNonEmptyAddress() {
        XCTAssertFalse(LLDBRunOptions(watchAddress: "").isWatchpointMode)
        XCTAssertFalse(LLDBRunOptions(watchAddress: "   ").isWatchpointMode)
        XCTAssertTrue(LLDBRunOptions(watchAddress: "0x1000").isWatchpointMode)
    }

    /// HOK-012-B: the watchpoint-segment parser must split the transcript
    /// by each `stop reason = watchpoint` line, and attach the first
    /// `frame #0:` / `old value:` / `new value:` lines under each segment.
    func testParseWatchpointHitsSplitsSegmentsAndExtractsValues() {
        let transcript = """
        (lldb) run
        Process 100 launched
        Watchpoint 1 hit:
        old value: 0x0000000000000000
        new value: 0x0000000100000000
        Process 100 stopped
        * thread #3, queue = 'com.example.a', stop reason = watchpoint 1
          * frame #0: 0x0000000100001000 App`writer_a + 0
            frame #1: 0x0000000100002000 App`caller_a + 44
        (lldb) continue
        Watchpoint 1 hit:
        old value: 0x0000000100000000
        new value: 0x0000000200000000
        Process 100 stopped
        * thread #7, queue = 'com.example.b', stop reason = watchpoint 1
          * frame #0: 0x0000000100003000 App`writer_b + 0
            frame #1: 0x0000000100004000 App`caller_b + 12
        """

        let hits = LaunchService.parseWatchpointHits(transcript: transcript)

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].index, 0)
        XCTAssertEqual(hits[0].thread, "3")
        XCTAssertEqual(hits[0].stopReason, "watchpoint 1")
        XCTAssertEqual(hits[0].frame, "* frame #0: 0x0000000100001000 App`writer_a + 0")
        XCTAssertEqual(hits[0].backtrace.count, 2)
        XCTAssertEqual(hits[1].index, 1)
        XCTAssertEqual(hits[1].thread, "7")
        XCTAssertEqual(hits[1].frame, "* frame #0: 0x0000000100003000 App`writer_b + 0")
        XCTAssertEqual(hits[1].backtrace.count, 2)
    }

    /// HOK-012-B: `parseLLDBEvidence` should not be fooled by watchpoint
    /// stop lines into reporting a false "fault". When both watchpoint and
    /// non-watchpoint stops appear, the fault fields must describe the
    /// non-watchpoint stop (i.e. the real crash), not the watchpoint.
    func testParseLLDBEvidencePrefersNonWatchpointStopForFaultFields() {
        let transcript = """
        Process 1 launched
        * thread #2, queue = 'com.example.a', stop reason = watchpoint 1
          * frame #0: 0x1 App`writer + 0
        (lldb) continue
        * thread #3, queue = 'com.example.b', stop reason = EXC_BAD_ACCESS (code=1, address=0x0)
          * frame #0: 0x2 App`crasher + 0
        App`crasher:
        ->  0x2 <+0>: ldr x8, [x0]
        """

        let evidence = LaunchService.parseLLDBEvidence(
            transcript: transcript,
            timedOut: false,
            terminationStatus: 0,
            watchpointHits: LaunchService.parseWatchpointHits(transcript: transcript)
        )

        XCTAssertEqual(evidence.faultingThread, "3")
        XCTAssertEqual(evidence.faultAddress, "0x0")
        XCTAssertTrue(evidence.stopReason?.contains("EXC_BAD_ACCESS") ?? false)
        XCTAssertEqual(evidence.watchpointHits.count, 1)
    }

    // MARK: - LaunchError Tests

    func testLaunchErrorDescriptions() {
        let errors: [(LaunchError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.executableNotFound("/path/to/exec"), "Executable not found at: /path/to/exec"),
            (.aliasNotFound("com.test"), "Application alias not found for: com.test"),
            (.prohibited("com.test"), "Application is prohibited from launching: com.test"),
            (.lldbFailed("err"), "LLDB launch failed: err"),
            (.launchFailed("err"), "Launch failed: err"),
        ]

        for (error, expectedDesc) in errors {
            XCTAssertEqual(error.localizedDescription, expectedDesc)
        }
    }

    func testLaunchErrorEquality() {
        XCTAssertEqual(LaunchError.appNotFound("a"), LaunchError.appNotFound("a"))
        XCTAssertNotEqual(LaunchError.appNotFound("a"), LaunchError.appNotFound("b"))
        XCTAssertEqual(LaunchError.lldbFailed("x"), LaunchError.lldbFailed("x"))
    }

    // MARK: - Default Service Creation

    func testDefaultServiceCreation() {
        let service = LaunchService.defaultService()
        XCTAssertTrue(service.appDirectory.path.contains("Applications"))
        XCTAssertTrue(service.aliasDirectory.path.contains("PlayCover"))
    }

    // MARK: - HOK-012-A: minimalStartupCompat diagnostic env

    /// HOK-012-A: for `com.tencent.ngr` the launch environment must carry
    /// `DYLD_PRINT_INITIALIZERS=1` so dyld's initializer chain is visible in
    /// both `launch_app` and `launch_app_with_lldb` transcripts.
    func testEffectiveLaunchEnvironmentInjectsDyldInitializersForMinimalStartupCompatBundle() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias")
        )
        let env = service.effectiveLaunchEnvironment(bundleId: "com.tencent.ngr")
        XCTAssertEqual(env["DYLD_PRINT_INITIALIZERS"], "1")
        XCTAssertEqual(env["DYLD_PRINT_APIS"], "0")
    }

    /// HOK-012-A: the diagnostic env must NOT leak to unrelated bundles.
    func testEffectiveLaunchEnvironmentDoesNotInjectDyldInitializersForOtherBundles() throws {
        let service = LaunchService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            aliasDirectory: URL(fileURLWithPath: "/tmp/nonexistent_alias")
        )
        let env = service.effectiveLaunchEnvironment(bundleId: "com.example.other")
        XCTAssertNil(env["DYLD_PRINT_INITIALIZERS"])
        XCTAssertNil(env["DYLD_PRINT_APIS"])
    }

    // MARK: - Multiple Apps

    func testResolveAppAmongMultipleApps() throws {
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchMulti_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let aliasDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_LaunchMultiAlias_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        defer { cleanupFixture([appDir, aliasDir]) }

        // Create two apps
        for (id, name) in [("com.test.alpha", "AlphaApp"), ("com.test.beta", "BetaApp")] {
            let bundleDir = appDir.appendingPathComponent(id).appendingPathExtension("app")
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

            let info: [String: String] = [
                "CFBundleIdentifier": id,
                "CFBundleName": name,
                "CFBundleDisplayName": name,
                "CFBundleShortVersionString": "1.0",
                "CFBundleExecutable": name,
            ]
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try plistData.write(to: bundleDir.appendingPathComponent("Info.plist"))

            let execURL = bundleDir.appendingPathComponent(name)
            try Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 28)).write(to: execURL)
        }

        let service = LaunchService(appDirectory: appDir, aliasDirectory: aliasDir)
        let alpha = try service.resolveApp(bundleId: "com.test.alpha")
        XCTAssertEqual(alpha.displayName, "AlphaApp")

        let beta = try service.resolveApp(bundleId: "com.test.beta")
        XCTAssertEqual(beta.displayName, "BetaApp")
    }
}
