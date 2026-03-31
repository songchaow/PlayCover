import XCTest
import Foundation

final class SettingsServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a temporary fixture app directory with settings.
    private func makeFixtureApp(
        bundleId: String = "com.test.settings",
        displayName: String = "SettingsTestApp"
    ) throws -> (appDir: URL, containerDir: URL) {
        let fm = FileManager.default

        // App directory
        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SettingsTest_\(UUID().uuidString)")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        let bundleDir = appDir.appendingPathComponent(bundleId).appendingPathExtension("app")
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let info: [String: String] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleExecutable": displayName,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try plistData.write(to: bundleDir.appendingPathComponent("Info.plist"))

        // Container directory
        let containerDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Container_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let settingsDir = containerDir.appendingPathComponent("App Settings")
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        return (appDir, containerDir)
    }

    /// Create a settings plist file with default values for the given bundleId.
    private func createDefaultSettings(containerDir: URL, bundleId: String) throws {
        let defaults: [String: Any] = [
            "bundleIdentifier": bundleId,
            "keymapping": true,
            "sensitivity": Float(50),
            "disableTimeout": false,
            "iosDeviceModel": "iPad13,8",
            "windowWidth": 1920,
            "windowHeight": 1080,
            "customScaler": 2.0,
            "resolution": 1,
            "aspectRatio": 1,
            "notch": false,
            "bypass": false,
            "discordActivity": [
                "enable": true,
                "applicationID": "",
                "details": "",
                "state": "",
                "image": "",
            ],
            "version": "3.0.0",
            "playChain": true,
            "playChainDebugging": false,
            "inverseScreenValues": false,
            "metalHUD": false,
            "windowFixMethod": 0,
            "injectIntrospection": false,
            "rootWorkDir": true,
            "noKMOnInput": true,
            "enableScrollWheel": true,
            "hideTitleBar": false,
            "floatingWindow": false,
            "checkMicPermissionSync": false,
            "limitMotionUpdateFrequency": false,
            "disableBuiltinMouse": false,
            "resizableAspectRatioType": 0,
            "resizableAspectRatioWidth": 0,
            "resizableAspectRatioHeight": 0,
            "blockSleepSpamming": false,
            "metalCaptureEnabled": false,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: defaults, format: .xml, options: 0
        )
        let url = containerDir
            .appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
        try data.write(to: url)
    }

    /// Create a settings plist with custom values.
    private func createCustomSettings(
        containerDir: URL,
        bundleId: String,
        keymapping: Bool = false,
        sensitivity: Float = 75
    ) throws {
        var defaults: [String: Any] = [
            "bundleIdentifier": bundleId,
            "keymapping": true,
            "sensitivity": Float(50),
            "disableTimeout": false,
            "iosDeviceModel": "iPad13,8",
            "windowWidth": 1920,
            "windowHeight": 1080,
            "customScaler": 2.0,
            "resolution": 1,
            "aspectRatio": 1,
            "notch": false,
            "bypass": false,
            "discordActivity": [
                "enable": true, "applicationID": "", "details": "", "state": "", "image": "",
            ],
            "version": "3.0.0",
            "playChain": true,
            "playChainDebugging": false,
            "inverseScreenValues": false,
            "metalHUD": false,
            "windowFixMethod": 0,
            "injectIntrospection": false,
            "rootWorkDir": true,
            "noKMOnInput": true,
            "enableScrollWheel": true,
            "hideTitleBar": false,
            "floatingWindow": false,
            "checkMicPermissionSync": false,
            "limitMotionUpdateFrequency": false,
            "disableBuiltinMouse": false,
            "resizableAspectRatioType": 0,
            "resizableAspectRatioWidth": 0,
            "resizableAspectRatioHeight": 0,
            "blockSleepSpamming": false,
            "metalCaptureEnabled": false,
            "injectMetalCaptureEnvironment": false,
        ]
        defaults["keymapping"] = keymapping
        defaults["sensitivity"] = sensitivity
        let data = try PropertyListSerialization.data(
            fromPropertyList: defaults, format: .xml, options: 0
        )
        let url = containerDir
            .appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
        try data.write(to: url)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeService(appDir: URL, containerDir: URL) -> SettingsService {
        SettingsService(appDirectory: appDir, containerDirectory: containerDir)
    }

    // MARK: - Get Settings Tests

    func testGetSettingsReturnsDefaultsWhenNoFile() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.nodefaults")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let settings = try service.getSettings(bundleId: "com.test.nodefaults")

        // Should return default values
        XCTAssertEqual(settings["keymapping"] as? Bool, true)
        XCTAssertEqual(settings["sensitivity"] as? Float, 50)
        XCTAssertEqual(settings["bundleIdentifier"] as? String, "com.test.nodefaults")
        XCTAssertEqual(settings["windowWidth"] as? Int, 1920)
        XCTAssertEqual(settings["windowHeight"] as? Int, 1080)
    }

    func testGetSettingsReadsExistingFile() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.existing")
        defer { cleanupFixture([appDir, containerDir]) }
        try createCustomSettings(containerDir: containerDir, bundleId: "com.test.existing", keymapping: false, sensitivity: 75)

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let settings = try service.getSettings(bundleId: "com.test.existing")

        XCTAssertEqual(settings["keymapping"] as? Bool, false)
        // sensitivity is Float, may be represented as Double after JSON round-trip
        XCTAssertEqual(settings["sensitivity"] as? Double, 75.0)
    }

    func testGetSettingsThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.other")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.getSettings(bundleId: "com.nonexistent.app")) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(settingsError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Update Settings Tests

    func testUpdateSettingsPatchSingleField() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.patch1")
        defer { cleanupFixture([appDir, containerDir]) }
        try createDefaultSettings(containerDir: containerDir, bundleId: "com.test.patch1")

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.updateSettings(
            bundleId: "com.test.patch1",
            changes: ["keymapping": false]
        )

        XCTAssertEqual(result.bundleIdentifier, "com.test.patch1")
        XCTAssertEqual(result.updatedFields, ["keymapping"])
        XCTAssertTrue(result.message.contains("keymapping"))

        // Verify persisted
        let settings = try service.getSettings(bundleId: "com.test.patch1")
        XCTAssertEqual(settings["keymapping"] as? Bool, false)
        // Other fields preserved
        XCTAssertEqual(settings["sensitivity"] as? Double, 50.0)
    }

    func testUpdateSettingsPatchMultipleFields() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.patchmulti")
        defer { cleanupFixture([appDir, containerDir]) }
        try createDefaultSettings(containerDir: containerDir, bundleId: "com.test.patchmulti")

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.updateSettings(
            bundleId: "com.test.patchmulti",
            changes: [
                "keymapping": false,
                "disableTimeout": true,
                "windowWidth": 2560,
                "sensitivity": 80,
            ]
        )

        XCTAssertEqual(result.bundleIdentifier, "com.test.patchmulti")
        XCTAssertTrue(result.updatedFields.contains("keymapping"))
        XCTAssertTrue(result.updatedFields.contains("disableTimeout"))
        XCTAssertTrue(result.updatedFields.contains("windowWidth"))
        XCTAssertTrue(result.updatedFields.contains("sensitivity"))
        XCTAssertEqual(result.updatedFields.count, 4)

        // Verify persisted
        let settings = try service.getSettings(bundleId: "com.test.patchmulti")
        XCTAssertEqual(settings["keymapping"] as? Bool, false)
        XCTAssertEqual(settings["disableTimeout"] as? Bool, true)
        XCTAssertEqual(settings["windowWidth"] as? Int, 2560)
    }

    func testUpdateSettingsCreatesNewFileWhenMissing() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.newsettings")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.updateSettings(
            bundleId: "com.test.newsettings",
            changes: ["bypass": true]
        )

        XCTAssertEqual(result.updatedFields, ["bypass"])

        // Verify file was created and defaults preserved
        let settings = try service.getSettings(bundleId: "com.test.newsettings")
        XCTAssertEqual(settings["bypass"] as? Bool, true)
        XCTAssertEqual(settings["keymapping"] as? Bool, true) // default preserved
    }

    func testUpdateSettingsRejectsInvalidField() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.invalid")
        defer { cleanupFixture([appDir, containerDir]) }
        try createDefaultSettings(containerDir: containerDir, bundleId: "com.test.invalid")

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.updateSettings(
            bundleId: "com.test.invalid",
            changes: ["nonexistent_field": true]
        )) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(settingsError, .invalidField("'nonexistent_field' is not a recognized patchable settings field"))
        }
    }

    func testUpdateSettingsRejectsProtectedFields() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.protected")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // bundleIdentifier should be rejected
        XCTAssertThrowsError(try service.updateSettings(
            bundleId: "com.test.protected",
            changes: ["bundleIdentifier": "hacked"]
        )) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError")
                return
            }
            XCTAssertTrue(settingsError.localizedDescription.contains("bundleIdentifier"))
        }
    }

    func testUpdateSettingsRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.something")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.updateSettings(
            bundleId: "com.nonexistent",
            changes: ["keymapping": false]
        )) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError")
                return
            }
            XCTAssertEqual(settingsError, .appNotFound("com.nonexistent"))
        }
    }

    func testUpdateSettingsRejectsEmptyChanges() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.emptychanges")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Empty changes dict — service should handle it but return empty updatedFields
        let result = try service.updateSettings(
            bundleId: "com.test.emptychanges",
            changes: [:]
        )
        XCTAssertTrue(result.updatedFields.isEmpty)
    }

    func testUpdateSettingsBoolFieldRejectsWrongType() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.wrongtype")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Passing a string to a bool field should be rejected
        XCTAssertThrowsError(try service.updateSettings(
            bundleId: "com.test.wrongtype",
            changes: ["keymapping": "yes please"]
        )) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError")
                return
            }
            XCTAssertEqual(settingsError, .invalidField("'keymapping' is not a recognized patchable settings field"))
        }
    }

    func testUpdateSettingsAllBoolFields() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.allbools")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let allBoolFields = [
            "keymapping": false,
            "disableTimeout": true,
            "notch": false,
            "bypass": true,
            "playChain": false,
            "playChainDebugging": true,
            "inverseScreenValues": true,
            "metalHUD": false,
            "injectIntrospection": true,
            "rootWorkDir": false,
            "noKMOnInput": false,
            "enableScrollWheel": false,
            "hideTitleBar": true,
            "floatingWindow": true,
            "checkMicPermissionSync": false,
            "limitMotionUpdateFrequency": true,
            "disableBuiltinMouse": true,
            "blockSleepSpamming": false,
            "metalCaptureEnabled": true,
            "injectMetalCaptureEnvironment": true,
        ]

        let result = try service.updateSettings(
            bundleId: "com.test.allbools",
            changes: allBoolFields
        )

        XCTAssertEqual(result.updatedFields.count, allBoolFields.count)

        // Verify all persisted
        let settings = try service.getSettings(bundleId: "com.test.allbools")
        XCTAssertEqual(settings["keymapping"] as? Bool, false)
        XCTAssertEqual(settings["disableTimeout"] as? Bool, true)
        XCTAssertEqual(settings["bypass"] as? Bool, true)
        XCTAssertEqual(settings["floatingWindow"] as? Bool, true)
    }

    // MARK: - Reset Settings Tests

    func testResetSettings() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.reset")
        defer { cleanupFixture([appDir, containerDir]) }
        try createCustomSettings(containerDir: containerDir, bundleId: "com.test.reset", keymapping: false, sensitivity: 75)

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Verify non-default values
        let before = try service.getSettings(bundleId: "com.test.reset")
        XCTAssertEqual(before["keymapping"] as? Bool, false)

        // Reset
        let result = try service.resetSettings(bundleId: "com.test.reset")
        XCTAssertEqual(result.bundleIdentifier, "com.test.reset")
        XCTAssertTrue(result.message.contains("reset to defaults"))

        // Verify defaults restored
        let after = try service.getSettings(bundleId: "com.test.reset")
        XCTAssertEqual(after["keymapping"] as? Bool, true)
        XCTAssertEqual(after["sensitivity"] as? Double, 50.0)
    }

    func testResetSettingsForNewApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.resetnew")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.resetSettings(bundleId: "com.test.resetnew")
        XCTAssertEqual(result.bundleIdentifier, "com.test.resetnew")

        // File should now exist with defaults
        let settings = try service.getSettings(bundleId: "com.test.resetnew")
        XCTAssertEqual(settings["keymapping"] as? Bool, true)
    }

    func testResetSettingsThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.other2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.resetSettings(bundleId: "com.nonexistent")) { error in
            guard let settingsError = error as? SettingsError else {
                XCTFail("Expected SettingsError")
                return
            }
            XCTAssertEqual(settingsError, .appNotFound("com.nonexistent"))
        }
    }

    // MARK: - Result Codable Tests

    func testSettingsUpdateResultCodable() throws {
        let result = SettingsUpdateResult(
            bundleIdentifier: "com.test",
            updatedFields: ["keymapping", "sensitivity"],
            message: "Updated 2 setting(s)"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SettingsUpdateResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.updatedFields.count, 2)
    }

    func testSettingsResetResultCodable() throws {
        let result = SettingsResetResult(
            bundleIdentifier: "com.test",
            message: "Settings reset to defaults"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SettingsResetResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - Error Tests

    func testSettingsErrorDescriptions() {
        let errors: [(SettingsError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.settingsNotFound("com.test"), "Settings not found for: com.test"),
            (.invalidField("bad_field"), "Invalid settings field: bad_field"),
            (.encodingFailed("disk full"), "Failed to encode settings: disk full"),
            (.decodingFailed("corrupt"), "Failed to decode settings: corrupt"),
        ]
        for (error, expected) in errors {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    func testSettingsErrorEquality() {
        XCTAssertEqual(SettingsError.appNotFound("a"), SettingsError.appNotFound("a"))
        XCTAssertNotEqual(SettingsError.appNotFound("a"), SettingsError.appNotFound("b"))
        XCTAssertEqual(SettingsError.invalidField("x"), SettingsError.invalidField("x"))
    }

    // MARK: - Default Service

    func testDefaultServiceCreation() {
        let service = SettingsService.defaultService()
        XCTAssertTrue(service.appDirectory.path.contains("Applications"))
        XCTAssertTrue(service.containerDirectory.path.contains("io.playcover.PlayCover"))
    }

    // MARK: - Isolation Test

    func testUpdateOnlyAffectsTargetApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.target")
        defer { cleanupFixture([appDir, containerDir]) }

        // Create another app's settings
        try createCustomSettings(containerDir: containerDir, bundleId: "com.test.target", keymapping: false, sensitivity: 75)

        // Create a second app
        let fm = FileManager.default
        let bundleDir2 = appDir.appendingPathComponent("com.test.other.app")
        try fm.createDirectory(at: bundleDir2, withIntermediateDirectories: true)
        let info2: [String: String] = [
            "CFBundleIdentifier": "com.test.other",
            "CFBundleName": "Other",
            "CFBundleDisplayName": "Other App",
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "Other",
        ]
        let plistData2 = try PropertyListSerialization.data(fromPropertyList: info2, format: .xml, options: 0)
        try plistData2.write(to: bundleDir2.appendingPathComponent("Info.plist"))

        // Create settings for the other app
        var otherDefaults: [String: Any] = [
            "bundleIdentifier": "com.test.other",
            "keymapping": true,
            "sensitivity": Float(99),
            "disableTimeout": false,
            "iosDeviceModel": "iPad13,8",
            "windowWidth": 1920,
            "windowHeight": 1080,
            "customScaler": 2.0,
            "resolution": 1,
            "aspectRatio": 1,
            "notch": false,
            "bypass": false,
            "discordActivity": [
                "enable": true, "applicationID": "", "details": "", "state": "", "image": "",
            ],
            "version": "3.0.0",
            "playChain": true,
            "playChainDebugging": false,
            "inverseScreenValues": false,
            "metalHUD": false,
            "windowFixMethod": 0,
            "injectIntrospection": false,
            "rootWorkDir": true,
            "noKMOnInput": true,
            "enableScrollWheel": true,
            "hideTitleBar": false,
            "floatingWindow": false,
            "checkMicPermissionSync": false,
            "limitMotionUpdateFrequency": false,
            "disableBuiltinMouse": false,
            "resizableAspectRatioType": 0,
            "resizableAspectRatioWidth": 0,
            "resizableAspectRatioHeight": 0,
            "blockSleepSpamming": false,
            "metalCaptureEnabled": false,
        ]
        let otherData = try PropertyListSerialization.data(
            fromPropertyList: otherDefaults, format: .xml, options: 0
        )
        let otherUrl = containerDir.appendingPathComponent("App Settings/com.test.other.plist")
        try otherData.write(to: otherUrl)

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Update target app
        _ = try service.updateSettings(bundleId: "com.test.target", changes: ["keymapping": true])

        // Target should be updated
        let targetSettings = try service.getSettings(bundleId: "com.test.target")
        XCTAssertEqual(targetSettings["keymapping"] as? Bool, true)

        // Other should be unchanged
        let otherSettings = try service.getSettings(bundleId: "com.test.other")
        XCTAssertEqual(otherSettings["sensitivity"] as? Double, 99.0)
    }
}
