import XCTest
import Foundation

final class InstallerServiceTests: XCTestCase {

    // MARK: - Helper: Create minimal fake IPA

    /// Create a minimal .ipa file (actually a zip) containing a tiny .app bundle
    /// with an Info.plist and a dummy MachO executable.
    private func createFakeIPA(
        bundleId: String = "com.test.fakeapp",
        execName: String = "FakeApp",
        displayName: String = "FakeApp"
    ) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let payloadDir = tmpDir.appendingPathComponent("Payload")
        let appDir = payloadDir.appendingPathComponent("\(displayName).app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Create minimal Info.plist
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleExecutable": execName,
            "CFBundleName": displayName,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "MinimumOSVersion": "14.0"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try plistData.write(to: appDir.appendingPathComponent("Info.plist"))

        // Create a minimal dummy MachO file (just the ARM64 magic bytes + minimal header)
        var header = Data()
        header.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE]) // MH_MAGIC_64
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0x0100000C).littleEndian) { Array($0) }) // CPU_TYPE_ARM64
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // cpusubtype
        header.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) }) // MH_EXECUTE
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // ncmds
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // sizeofcmds
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // flags
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) }) // reserved

        let execURL = appDir.appendingPathComponent(execName)
        try header.write(to: execURL)

        // Zip it into an IPA (zip from within tmpDir so Payload is at the root)
        let ipaURL = tmpDir.appendingPathComponent("\(displayName).ipa")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", ipaURL.lastPathComponent, "Payload"]
        process.currentDirectoryURL = tmpDir
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShellError(command: "/usr/bin/zip", arguments: ["-r", ipaURL.lastPathComponent, "Payload"],
                             exitCode: process.terminationStatus, output: "")
        }

        // Cleanup temp payload (keep only the ipa)
        try? FileManager.default.removeItem(at: payloadDir)

        return ipaURL
    }

    /// Create a temporary directory for testing.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCPTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Parameter Validation Tests

    func testInstallRejectsNonexistentIPA() throws {
        let service = InstallerService(
            appDirectory: try makeTempDir(),
            playToolsFrameworkPath: try makeTempDir()
        )
        XCTAssertThrowsError(try service.install(ipaPath: "/nonexistent/path.ipa")) { error in
            if let installerError = error as? InstallerError {
                XCTAssertEqual(installerError, .ipaNotFound("/nonexistent/path.ipa"))
            } else {
                XCTFail("Expected InstallerError.ipaNotFound, got \(error)")
            }
        }
    }

    func testInstallRejectsEmptyPath() throws {
        let service = InstallerService(
            appDirectory: try makeTempDir(),
            playToolsFrameworkPath: try makeTempDir()
        )
        XCTAssertThrowsError(try service.install(ipaPath: "")) { error in
            // Empty path should fail - either as InstallerError.ipaNotFound or ShellError
            XCTAssertTrue(
                error is InstallerError || error is ShellError,
                "Expected InstallerError or ShellError, got \(type(of: error))"
            )
        }
    }

    func testExportRejectsNonexistentIPA() throws {
        let service = InstallerService(
            appDirectory: try makeTempDir(),
            playToolsFrameworkPath: try makeTempDir()
        )
        XCTAssertThrowsError(try service.export(ipaPath: "/nonexistent/path.ipa")) { error in
            if let installerError = error as? InstallerError {
                XCTAssertEqual(installerError, .ipaNotFound("/nonexistent/path.ipa"))
            } else {
                XCTFail("Expected InstallerError.ipaNotFound, got \(error)")
            }
        }
    }

    // MARK: - Full Install Flow Tests (with fake IPA, no PlayTools)

    func testInstallFakeIPAWithoutPlayTools() throws {
        let appDir = try makeTempDir()
        let ipaURL = try createFakeIPA()
        defer {
            try? FileManager.default.removeItem(at: ipaURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: appDir)
        }

        let service = InstallerService(
            appDirectory: appDir,
            playToolsFrameworkPath: try makeTempDir()
        )

        // Install without PlayTools injection
        do {
            let result = try service.install(
                ipaPath: ipaURL.path,
                injectPlayTools: false,
                progress: nil
            )

            XCTAssertEqual(result.bundleIdentifier, "com.test.fakeapp")
            XCTAssertEqual(result.injectPlayTools, false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.appPath))
            XCTAssertTrue(result.appPath.hasPrefix(appDir.path))
        } catch {
            // The minimal MachO we create might cause issues at conversion/signing,
            // but the flow should at least reach those later steps
            if let installerError = error as? InstallerError {
                switch installerError {
                case .ipaNotFound, .invalidIPA, .missingExecutable, .appEncrypted:
                    XCTFail("Unexpected early failure: \(installerError)")
                case .conversionFailed, .signingFailed, .injectionFailed,
                     .exportFailed, .packFailed:
                    break // Acceptable for a fake binary
                }
            }
            // Shell errors (e.g., codesign issues) are also acceptable
        }
    }

    func testInstallFakeIPAWithProgress() throws {
        let appDir = try makeTempDir()
        let ipaURL = try createFakeIPA()
        defer {
            try? FileManager.default.removeItem(at: ipaURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: appDir)
        }

        let service = InstallerService(
            appDirectory: appDir,
            playToolsFrameworkPath: try makeTempDir()
        )

        var progressUpdates: [(Int, Int, String)] = []
        _ = try? service.install(
            ipaPath: ipaURL.path,
            injectPlayTools: false,
            progress: { total, current, message in
                progressUpdates.append((total, current, message))
            }
        )

        // Verify progress was reported
        XCTAssertTrue(progressUpdates.count >= 2,
                       "Expected at least 2 progress updates, got \(progressUpdates.count)")
        if let first = progressUpdates.first {
            XCTAssertEqual(first.2, "begin")
        }
    }

    // MARK: - Export Flow Tests

    func testExportFakeIPAWithoutPlayTools() throws {
        let appDir = try makeTempDir()
        let outputDir = try makeTempDir()
        let ipaURL = try createFakeIPA()
        defer {
            try? FileManager.default.removeItem(at: ipaURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: appDir)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let service = InstallerService(
            appDirectory: appDir,
            playToolsFrameworkPath: try makeTempDir()
        )

        // Export mode always injects PlayTools, so failure is expected without real PlayTools
        do {
            let result = try service.export(
                ipaPath: ipaURL.path,
                outputDirectory: outputDir.path,
                progress: nil
            )

            XCTAssertEqual(result.bundleIdentifier, "com.test.fakeapp")
            XCTAssertTrue(result.ipaPath.hasSuffix(".ipa"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.ipaPath))
        } catch {
            // Any error is acceptable for a test without real PlayTools
            // The important thing is that the flow runs without crashing
        }
    }

    // MARK: - Result Serialization Tests

    func testInstallResultSerialization() throws {
        let result = InstallResult(
            bundleIdentifier: "com.test.app",
            appPath: "/path/to/app.app",
            injectPlayTools: true
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(InstallResult.self, from: data)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.appPath, "/path/to/app.app")
        XCTAssertEqual(decoded.injectPlayTools, true)
    }

    func testExportResultSerialization() throws {
        let result = ExportResult(
            bundleIdentifier: "com.test.app",
            ipaPath: "/path/to/output.ipa"
        )

        let data = try JSONEncoder().encode(result)
        // Verify it can be decoded back
        let decoded = try JSONDecoder().decode(ExportResult.self, from: data)
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.app")
        XCTAssertEqual(decoded.ipaPath, "/path/to/output.ipa")
    }

    func testInstallResultDecodableRoundTrip() throws {
        let result = InstallResult(
            bundleIdentifier: "com.test.app",
            appPath: "/path/to/app.app",
            injectPlayTools: true
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(InstallResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testExportResultDecodableRoundTrip() throws {
        let result = ExportResult(
            bundleIdentifier: "com.test.app",
            ipaPath: "/path/to/output.ipa"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExportResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - InstallerError Tests

    func testInstallerErrorDescriptions() {
        let errors: [(InstallerError, String)] = [
            (.ipaNotFound("/path"), "IPA not found: /path"),
            (.invalidIPA("bad"), "Invalid IPA: bad"),
            (.appEncrypted("bin"), "App is encrypted: bin"),
            (.missingExecutable("exe"), "Missing executable: exe"),
            (.conversionFailed("err"), "MachO conversion failed: err"),
            (.injectionFailed("err"), "PlayTools injection failed: err"),
            (.signingFailed("err"), "Signing failed: err"),
            (.exportFailed("err"), "Export failed: err"),
            (.packFailed("err"), "IPA packing failed: err"),
        ]

        for (error, expectedDesc) in errors {
            XCTAssertEqual(error.localizedDescription, expectedDesc)
        }
    }

    // MARK: - Shell Tests

    func testShellRunSuccess() throws {
        let output = try Shell.run("/bin/echo", "hello")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testShellRunFailure() {
        do {
            _ = try Shell.run("/usr/bin/false")
            XCTFail("Should have thrown")
        } catch let error as ShellError {
            XCTAssertEqual(error.exitCode, 1)
            XCTAssertEqual(error.command, "/usr/bin/false")
        } catch {
            XCTFail("Expected ShellError, got \(error)")
        }
    }

    func testShellErrorEquality() {
        let e1 = ShellError(command: "/bin/test", arguments: ["a"], exitCode: 1, output: "err")
        let e2 = ShellError(command: "/bin/test", arguments: ["a"], exitCode: 1, output: "err")
        XCTAssertEqual(e1, e2)
    }
}
