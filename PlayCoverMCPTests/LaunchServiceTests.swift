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
            headlessLLDBRunner: { executable, _, timeoutSeconds in
                XCTAssertEqual(executable.lastPathComponent, "LLDBApp")
                XCTAssertEqual(timeoutSeconds, 2.5, accuracy: 0.001)
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
