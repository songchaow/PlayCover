import XCTest
import Foundation

final class CleanupServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a temporary fixture app directory with associated data files.
    private func makeFixtureApp(
        bundleId: String = "com.test.cleanup",
        displayName: String = "CleanupTestApp",
        executableName: String = "CleanupTestApp"
    ) throws -> (appDir: URL, containerDir: URL, libraryDir: URL, playChainDir: URL) {
        let fm = FileManager.default

        // App directory (simulates PlayCover Applications dir)
        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_CleanupTest_\(UUID().uuidString)")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Create .app bundle
        let bundleDir = appDir.appendingPathComponent(bundleId).appendingPathExtension("app")
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)

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

        // Container directory
        let containerDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Container_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        // Create settings file
        let settingsDir = containerDir.appendingPathComponent("App Settings")
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: settingsDir.appendingPathComponent(bundleId).appendingPathExtension("plist"))

        // Create entitlements file
        let entitlementsDir = containerDir.appendingPathComponent("Entitlements")
        try fm.createDirectory(at: entitlementsDir, withIntermediateDirectories: true)
        try Data("entitlements".utf8).write(to: entitlementsDir.appendingPathComponent(bundleId).appendingPathExtension("plist"))

        // Create keymap file
        let keymapDir = containerDir.appendingPathComponent("Keymapping")
        try fm.createDirectory(at: keymapDir, withIntermediateDirectories: true)
        try Data("keymap".utf8).write(to: keymapDir.appendingPathComponent(bundleId).appendingPathExtension("plist"))

        // PlayChain directory
        let playChainDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_PlayChain_\(UUID().uuidString)")
        try fm.createDirectory(at: playChainDir, withIntermediateDirectories: true)
        try Data("playchain".utf8).write(to: playChainDir.appendingPathComponent(bundleId))
        try Data("keycover".utf8).write(to: URL(fileURLWithPath: playChainDir.appendingPathComponent(bundleId).path + ".keyCover"))
        try Data("db".utf8).write(to: URL(fileURLWithPath: playChainDir.appendingPathComponent(bundleId).path + ".db"))

        // Library directory (for cache data)
        let libraryDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Library_\(UUID().uuidString)")
        try fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        // Create cache subdirectories with bundleId-named items
        for subdir in ["Caches", "HTTPStorages", "Containers"] {
            let subDir = libraryDir.appendingPathComponent(subdir)
            try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
            try Data("cache".utf8).write(to: subDir.appendingPathComponent(bundleId))
        }

        return (appDir, containerDir, libraryDir, playChainDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeService(
        appDir: URL,
        containerDir: URL,
        libraryDir: URL,
        playChainDir: URL
    ) -> CleanupService {
        CleanupService(
            appDirectory: appDir,
            containerDirectory: containerDir,
            libraryDirectory: libraryDir,
            playChainDirectory: playChainDir
        )
    }

    // MARK: - Uninstall Error Tests

    func testUninstallAppThrowsForNonexistentApp() throws {
        let service = CleanupService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            containerDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            libraryDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)"),
            playChainDirectory: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")
        )
        XCTAssertThrowsError(try service.uninstallApp(bundleId: "com.nonexistent.app", options: UninstallOptions())) { error in
            guard let cleanupError = error as? CleanupError else {
                XCTFail("Expected CleanupError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(cleanupError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Individual Cleanup Tests

    func testClearAppSettings() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.settings"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        // Verify settings file exists
        let settingsURL = containerDir
            .appendingPathComponent("App Settings")
            .appendingPathComponent("com.test.settings")
            .appendingPathExtension("plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))

        let result = service.clearAppSettings(bundleId: "com.test.settings")
        XCTAssertTrue(result.removed)
        XCTAssertEqual(result.operation, "clear_app_settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    func testClearAppSettingsReturnsFalseForNonexistent() throws {
        let service = CleanupService(
            appDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            containerDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            libraryDirectory: URL(fileURLWithPath: "/tmp/nonexistent"),
            playChainDirectory: URL(fileURLWithPath: "/tmp/nonexistent")
        )

        let result = service.clearAppSettings(bundleId: "com.nonexistent")
        XCTAssertFalse(result.removed)
    }

    func testClearAppEntitlements() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.entitlements"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        let entitlementsURL = containerDir
            .appendingPathComponent("Entitlements")
            .appendingPathComponent("com.test.entitlements")
            .appendingPathExtension("plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: entitlementsURL.path))

        let result = service.clearAppEntitlements(bundleId: "com.test.entitlements")
        XCTAssertTrue(result.removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entitlementsURL.path))
    }

    func testClearAppKeymaps() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.keymaps"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        let keymapURL = containerDir
            .appendingPathComponent("Keymapping")
            .appendingPathComponent("com.test.keymaps")
            .appendingPathExtension("plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keymapURL.path))

        let result = service.clearAppKeymaps(bundleId: "com.test.keymaps")
        XCTAssertTrue(result.removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keymapURL.path))
    }

    func testClearPlayChainData() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.playchain"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        let fm = FileManager.default
        let base = playChainDir.appendingPathComponent("com.test.playchain")
        XCTAssertTrue(fm.fileExists(atPath: base.path))
        XCTAssertTrue(fm.fileExists(atPath: URL(fileURLWithPath: base.path + ".keyCover").path))
        XCTAssertTrue(fm.fileExists(atPath: URL(fileURLWithPath: base.path + ".db").path))

        let result = service.clearPlayChainData(bundleId: "com.test.playchain")
        XCTAssertTrue(result.removed)
        XCTAssertFalse(fm.fileExists(atPath: base.path))
        XCTAssertFalse(fm.fileExists(atPath: URL(fileURLWithPath: base.path + ".keyCover").path))
        XCTAssertFalse(fm.fileExists(atPath: URL(fileURLWithPath: base.path + ".db").path))
    }

    func testClearAllAppData() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.appdata"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        let fm = FileManager.default
        // Verify cache files exist
        XCTAssertTrue(fm.fileExists(atPath: libraryDir.appendingPathComponent("Caches/com.test.appdata").path))
        XCTAssertTrue(fm.fileExists(atPath: libraryDir.appendingPathComponent("HTTPStorages/com.test.appdata").path))
        XCTAssertTrue(fm.fileExists(atPath: libraryDir.appendingPathComponent("Containers/com.test.appdata").path))

        let result = service.clearAllAppData(bundleId: "com.test.appdata")
        XCTAssertTrue(result.removed)
        XCTAssertFalse(fm.fileExists(atPath: libraryDir.appendingPathComponent("Caches/com.test.appdata").path))
        XCTAssertFalse(fm.fileExists(atPath: libraryDir.appendingPathComponent("HTTPStorages/com.test.appdata").path))
        XCTAssertFalse(fm.fileExists(atPath: libraryDir.appendingPathComponent("Containers/com.test.appdata").path))
    }

    // MARK: - Uninstall Combination Tests

    func testUninstallAppWithAllOptions() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.fulluninstall"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)
        let fm = FileManager.default

        let options = UninstallOptions(
            clearAppData: true,
            clearPlayChain: true,
            clearSettings: true,
            clearEntitlements: true,
            clearKeymaps: true
        )

        let result = try service.uninstallApp(bundleId: "com.test.fulluninstall", options: options)

        XCTAssertEqual(result.bundleIdentifier, "com.test.fulluninstall")
        XCTAssertTrue(result.removedItems.contains("appBundle"))
        XCTAssertTrue(result.removedItems.contains("appData"))
        XCTAssertTrue(result.removedItems.contains("playChain"))
        XCTAssertTrue(result.removedItems.contains("settings"))
        XCTAssertTrue(result.removedItems.contains("entitlements"))
        XCTAssertTrue(result.removedItems.contains("keymaps"))

        // Verify app bundle is gone
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("com.test.fulluninstall.app").path))
    }

    func testUninstallAppWithNoCleanupOptions() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.minimal"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)
        let fm = FileManager.default

        let options = UninstallOptions()
        let result = try service.uninstallApp(bundleId: "com.test.minimal", options: options)

        XCTAssertEqual(result.bundleIdentifier, "com.test.minimal")
        XCTAssertTrue(result.removedItems.contains("appBundle"))
        XCTAssertFalse(result.removedItems.contains("settings"))

        // App bundle removed, but settings file still exists
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("com.test.minimal.app").path))
        XCTAssertTrue(fm.fileExists(
            atPath: containerDir.appendingPathComponent("App Settings/com.test.minimal.plist").path
        ))
    }

    func testUninstallAppWithPartialOptions() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.partial"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)
        let fm = FileManager.default

        let options = UninstallOptions(
            clearAppData: true,
            clearKeymaps: true
        )
        let result = try service.uninstallApp(bundleId: "com.test.partial", options: options)

        XCTAssertTrue(result.removedItems.contains("appBundle"))
        XCTAssertTrue(result.removedItems.contains("appData"))
        XCTAssertTrue(result.removedItems.contains("keymaps"))
        XCTAssertFalse(result.removedItems.contains("settings"))
        XCTAssertFalse(result.removedItems.contains("entitlements"))
        XCTAssertFalse(result.removedItems.contains("playChain"))

        // Verify: cache cleared, keymap cleared, settings still present
        XCTAssertFalse(fm.fileExists(atPath: libraryDir.appendingPathComponent("Caches/com.test.partial").path))
        XCTAssertFalse(fm.fileExists(
            atPath: containerDir.appendingPathComponent("Keymapping/com.test.partial.plist").path
        ))
        XCTAssertTrue(fm.fileExists(
            atPath: containerDir.appendingPathComponent("App Settings/com.test.partial.plist").path
        ))
    }

    // MARK: - Result Serialization Tests

    func testUninstallResultCodableRoundTrip() throws {
        let result = UninstallResult(
            bundleIdentifier: "com.test.app",
            displayName: "Test App",
            removedItems: ["appBundle", "settings", "keymaps"],
            message: "Uninstalled Test App"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(UninstallResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.removedItems.count, 3)
    }

    func testCleanupResultCodableRoundTrip() throws {
        let result = CleanupResult(
            bundleIdentifier: "com.test.app",
            operation: "clear_app_settings",
            removed: true,
            message: "Settings cleared"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CleanupResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.removed)
    }

    func testUninstallOptionsCodableRoundTrip() throws {
        let options = UninstallOptions(
            clearAppData: true,
            clearPlayChain: false,
            clearSettings: true,
            clearEntitlements: false,
            clearKeymaps: true
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(UninstallOptions.self, from: data)
        XCTAssertEqual(decoded, options)
    }

    // MARK: - CleanupError Tests

    func testCleanupErrorDescriptions() {
        let errors: [(CleanupError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.cleanupFailed(operation: "clear_settings", reason: "file locked"), "Cleanup failed for clear_settings: file locked"),
        ]

        for (error, expectedDesc) in errors {
            XCTAssertEqual(error.localizedDescription, expectedDesc)
        }
    }

    func testCleanupErrorEquality() {
        XCTAssertEqual(CleanupError.appNotFound("a"), CleanupError.appNotFound("a"))
        XCTAssertNotEqual(CleanupError.appNotFound("a"), CleanupError.appNotFound("b"))
    }

    // MARK: - Default Service Creation

    func testDefaultServiceCreation() {
        let service = CleanupService.defaultService()
        XCTAssertTrue(service.appDirectory.path.contains("Applications"))
        XCTAssertTrue(service.containerDirectory.path.contains("io.playcover.PlayCover"))
    }

    // MARK: - Multiple Apps Isolation

    func testCleanupOnlyAffectsTargetApp() throws {
        let (appDir, containerDir, libraryDir, playChainDir) = try makeFixtureApp(
            bundleId: "com.test.target"
        )
        defer { cleanupFixture([appDir, containerDir, libraryDir, playChainDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir, libraryDir: libraryDir, playChainDir: playChainDir)

        // Create a second app's data in the same directories
        let fm = FileManager.default
        try Data("other-settings".utf8).write(
            to: containerDir.appendingPathComponent("App Settings/com.test.other.plist")
        )

        // Clear settings for target
        let result = service.clearAppSettings(bundleId: "com.test.target")
        XCTAssertTrue(result.removed)

        // Verify other app's settings are untouched
        XCTAssertTrue(fm.fileExists(
            atPath: containerDir.appendingPathComponent("App Settings/com.test.other.plist").path
        ))
    }
}
