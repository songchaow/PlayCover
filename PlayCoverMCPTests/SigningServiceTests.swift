import XCTest
import Foundation

final class SigningServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a temporary app directory with a fake .app bundle for testing.
    private func makeFixtureApp(
        bundleId: String = "com.test.signapp",
        displayName: String = "Sign Test App",
        executableName: String = "SignTestApp"
    ) throws -> (URL, URL) {
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SigningTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let bundleDir = appDir.appendingPathComponent(bundleId).appendingPathExtension("app")
        try FileManager.default.createDirectory(
            at: bundleDir.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )

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

        // Create a dummy executable (just needs to exist, doesn't need to be a real MachO for path tests)
        let execURL = bundleDir.appendingPathComponent(executableName)
        try Data("dummy".utf8).write(to: execURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: execURL.path
        )

        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SigningContainer_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        return (appDir, containerDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Parameter Validation Tests

    func testPreviewEntitlementsRejectsEmptyBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.previewEntitlements(bundleId: "")) { error in
            XCTAssertTrue(
                error is SigningServiceError,
                "Expected SigningServiceError, got \(type(of: error))"
            )
        }
    }

    func testPreviewEntitlementsThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.previewEntitlements(bundleId: "com.nonexistent.app")) { error in
            guard let signingError = error as? SigningServiceError else {
                XCTFail("Expected SigningServiceError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(signingError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testValidateSigningRejectsEmptyBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.validateSigning(bundleId: "")) { error in
            XCTAssertTrue(
                error is SigningServiceError,
                "Expected SigningServiceError, got \(type(of: error))"
            )
        }
    }

    func testValidateSigningThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.validateSigning(bundleId: "com.nonexistent.app")) { error in
            guard let signingError = error as? SigningServiceError else {
                XCTFail("Expected SigningServiceError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(signingError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testResignAppRejectsEmptyBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.resignApp(bundleId: "")) { error in
            XCTAssertTrue(
                error is SigningServiceError,
                "Expected SigningServiceError, got \(type(of: error))"
            )
        }
    }

    func testResignAppThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.resignApp(bundleId: "com.nonexistent.app")) { error in
            guard let signingError = error as? SigningServiceError else {
                XCTFail("Expected SigningServiceError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(signingError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Preview Entitlements Tests

    func testPreviewEntitlementsForUnsignedApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(
            bundleId: "com.test.unsigned",
            displayName: "UnsignedApp"
        )
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        let result = try service.previewEntitlements(bundleId: "com.test.unsigned")

        XCTAssertEqual(result.bundleIdentifier, "com.test.unsigned")
        XCTAssertTrue(result.currentEntitlements.isEmpty)
        XCTAssertFalse(result.appSandbox)
        XCTAssertFalse(result.hasNetworkClient)
        XCTAssertFalse(result.hasCamera)
        XCTAssertEqual(result.sandboxProfileRules, 0)
    }

    // MARK: - Validate Signing Tests

    func testValidateSigningForUnsignedApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(
            bundleId: "com.test.unvalidated",
            displayName: "UnvalidatedApp"
        )
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        let result = try service.validateSigning(bundleId: "com.test.unvalidated")

        XCTAssertEqual(result.bundleIdentifier, "com.test.unvalidated")
        // Dummy binary is not a valid MachO, so codesign will fail
        XCTAssertFalse(result.signed)
        XCTAssertFalse(result.infoPlistSigned)
        XCTAssertFalse(result.entitlementsMatch)
        XCTAssertFalse(result.valid)
    }

    // MARK: - Resign App Tests

    func testResignAppFailsForDummyBinary() throws {
        // A dummy binary (not a real MachO) cannot be signed
        let (appDir, containerDir) = try makeFixtureApp(
            bundleId: "com.test.resign.fail",
            displayName: "ResignFail"
        )
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        XCTAssertThrowsError(try service.resignApp(bundleId: "com.test.resign.fail")) { error in
            guard let signingError = error as? SigningServiceError else {
                XCTFail("Expected SigningServiceError, got \(type(of: error))")
                return
            }
            if case .resignFailed = signingError {
                // Expected: dummy binary cannot be signed
            } else {
                XCTFail("Expected .resignFailed, got \(signingError)")
            }
        }
    }

    // MARK: - Resign App with TaskManager

    func testResignAppWithTaskForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        let taskManager = TaskManager()

        let result = service.resignAppWithTask(
            bundleId: "com.nonexistent.app",
            taskManager: taskManager
        )

        // Task should have failed
        XCTAssertFalse(result.resigned)
        XCTAssertNotNil(result.taskId)

        let status = taskManager.getTask(result.taskId!)
        XCTAssertEqual(status?.state, .failed)
    }

    func testResignAppWithTaskCreatesTaskEntry() throws {
        let (appDir, containerDir) = try makeFixtureApp(
            bundleId: "com.test.task",
            displayName: "TaskApp"
        )
        defer { cleanupFixture([appDir, containerDir]) }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        let taskManager = TaskManager()

        let result = service.resignAppWithTask(
            bundleId: "com.test.task",
            taskManager: taskManager
        )

        XCTAssertNotNil(result.taskId)
        XCTAssertNotNil(taskManager.getTask(result.taskId!))
    }

    // MARK: - Result Type Codable Round-trip Tests

    func testSigningValidationResultCodableRoundTrip() throws {
        let result = SigningValidationResult(
            bundleIdentifier: "com.test.app",
            valid: true,
            signed: true,
            infoPlistSigned: true,
            entitlementsMatch: true,
            message: "All checks passed."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SigningValidationResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.valid, true)
    }

    func testSigningValidationResultInvalidCodableRoundTrip() throws {
        let result = SigningValidationResult(
            bundleIdentifier: "com.test.app",
            valid: false,
            signed: false,
            infoPlistSigned: true,
            entitlementsMatch: false,
            message: "Binary is not signed, no entitlements found."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SigningValidationResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.valid, false)
        XCTAssertEqual(decoded.signed, false)
    }

    func testEntitlementsPreviewResultCodableRoundTrip() throws {
        let result = EntitlementsPreviewResult(
            bundleIdentifier: "com.test.app",
            currentEntitlements: [:],
            message: "No entitlements."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EntitlementsPreviewResult.self, from: data)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.appSandbox, false)
        XCTAssertEqual(decoded.sandboxProfileRules, 0)
        XCTAssertEqual(decoded.message, "No entitlements.")
    }

    func testEntitlementsPreviewResultWithCapsCodableRoundTrip() throws {
        let result = EntitlementsPreviewResult(
            bundleIdentifier: "com.test.app",
            currentEntitlements: [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.network.client": true,
            ],
            message: "2 keys."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EntitlementsPreviewResult.self, from: data)
        XCTAssertEqual(decoded.appSandbox, true)
        XCTAssertEqual(decoded.hasNetworkClient, true)
        XCTAssertEqual(decoded.hasCamera, false)
    }

    func testResignResultCodableRoundTrip() throws {
        let result = ResignResult(
            bundleIdentifier: "com.test.app",
            displayName: "Test App",
            resigned: true,
            taskId: "task-1",
            message: "Re-signed successfully."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ResignResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.resigned, true)
        XCTAssertEqual(decoded.taskId, "task-1")
    }

    func testResignResultWithoutTaskCodableRoundTrip() throws {
        let result = ResignResult(
            bundleIdentifier: "com.test.app",
            displayName: "Test App",
            resigned: true,
            message: "Re-signed successfully."
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ResignResult.self, from: data)
        XCTAssertEqual(decoded.resigned, true)
        XCTAssertNil(decoded.taskId)
    }

    // MARK: - Error Tests

    func testSigningServiceErrorDescriptions() {
        let errors: [(SigningServiceError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.executableNotFound("/path/to/exec"), "Executable not found at: /path/to/exec"),
            (.signingFailed("reason"), "Code signing failed: reason"),
            (.entitlementsDumpFailed("reason"), "Failed to dump entitlements: reason"),
            (.resignFailed("reason"), "Re-signing failed: reason"),
        ]

        for (error, expectedDesc) in errors {
            XCTAssertEqual(error.localizedDescription, expectedDesc)
        }
    }

    func testSigningServiceErrorEquality() {
        XCTAssertEqual(SigningServiceError.appNotFound("a"), SigningServiceError.appNotFound("a"))
        XCTAssertNotEqual(SigningServiceError.appNotFound("a"), SigningServiceError.appNotFound("b"))
        XCTAssertEqual(SigningServiceError.signingFailed("x"), SigningServiceError.signingFailed("x"))
        XCTAssertEqual(SigningServiceError.resignFailed("y"), SigningServiceError.resignFailed("y"))
    }

    // MARK: - Default Service Creation

    func testDefaultServiceCreation() {
        let service = SigningService.defaultService()
        XCTAssertTrue(service.appDirectory.path.contains("Applications"))
        XCTAssertTrue(service.containerDirectory.path.contains("io.playcover.PlayCover"))
    }

    // MARK: - Multiple Apps

    func testResolveAppAmongMultipleApps() throws {
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SigningMulti_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SigningContainer_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer { cleanupFixture([appDir, containerDir]) }

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
            try Data("dummy".utf8).write(to: execURL)
        }

        let service = SigningService(appDirectory: appDir, containerDirectory: containerDir)
        let result = try service.previewEntitlements(bundleId: "com.test.alpha")
        XCTAssertEqual(result.bundleIdentifier, "com.test.alpha")

        let betaResult = try service.previewEntitlements(bundleId: "com.test.beta")
        XCTAssertEqual(betaResult.bundleIdentifier, "com.test.beta")
    }

    func testNonexistentAppDirectory() throws {
        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SigningContainer_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer { cleanupFixture([containerDir]) }

        let service = SigningService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            containerDirectory: containerDir
        )
        XCTAssertThrowsError(try service.validateSigning(bundleId: "com.any.app")) { error in
            guard let signingError = error as? SigningServiceError else {
                XCTFail("Expected SigningServiceError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(signingError, .appNotFound("com.any.app"))
        }
    }
}
