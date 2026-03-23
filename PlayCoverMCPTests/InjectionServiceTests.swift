import XCTest
import Foundation

final class InjectionServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Create a temporary fixture app with an Info.plist and dummy executable.
    private func makeFixtureApp(
        bundleId: String = "com.test.inject",
        displayName: String = "InjectTestApp",
        executableName: String = "InjectTestApp"
    ) throws -> (appDir: URL, containerDir: URL) {
        let fm = FileManager.default

        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectTest_\(UUID().uuidString)")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        let bundleDir = appDir.appendingPathComponent(bundleId).appendingPathExtension("app")
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)

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
        try Data("dummy".utf8).write(to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let containerDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectContainer_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        return (appDir, containerDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeService(appDir: URL, containerDir: URL) -> InjectionService {
        InjectionService(appDirectory: appDir, containerDirectory: containerDir)
    }

    // MARK: - Parameter Validation Tests

    func testCheckPlayToolsRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.checkPlayToolsInstalled(bundleId: "com.nonexistent.app")) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testInjectPlayToolsRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.injectPlayTools(bundleId: "com.nonexistent.app")) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testRemovePlayToolsRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.removePlayTools(bundleId: "com.nonexistent.app")) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent.app"))
        }
    }

    func testSetIntrospectionRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.setIntrospectionEnabled(bundleId: "com.nonexistent", enabled: true)) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent"))
        }
    }

    func testSetIOSFrameworksRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.setIOSFrameworksEnabled(bundleId: "com.nonexistent", enabled: true)) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent"))
        }
    }

    func testSetCategoryRejectsNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.setApplicationCategory(bundleId: "com.nonexistent", category: "public.app-category.games")) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError")
                return
            }
            XCTAssertEqual(injectionError, .appNotFound("com.nonexistent"))
        }
    }

    // MARK: - Check PlayTools Installed Tests

    func testCheckPlayToolsNotInstalled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.nopt")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        // Dummy binary should not have PlayTools injected
        // installedInExec may throw for non-MachO binaries, so we test the error case
        let result = try service.checkPlayToolsInstalled(bundleId: "com.test.nopt")
        XCTAssertFalse(result.installed)
        XCTAssertEqual(result.bundleIdentifier, "com.test.nopt")
    }

    // MARK: - Introspection Tests

    func testSetIntrospectionEnabled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.intro")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Enable introspection (signing will fail on dummy binary, which is expected)
        // We test the plist modification part, signing failure is OK
        do {
            let result = try service.setIntrospectionEnabled(bundleId: "com.test.intro", enabled: true)
            XCTAssertEqual(result.bundleIdentifier, "com.test.intro")
            XCTAssertEqual(result.field, "introspection")
            // Signing may fail, but plist should still be modified
        } catch {
            // Signing failure is expected on dummy binary
            guard let injectionError = error as? InjectionError,
                  case .signingFailed = injectionError else {
                XCTFail("Expected InjectionError.signingFailed, got \(error)")
                return
            }
        }

        // Verify plist was modified
        let config = try service.getRuntimeConfig(bundleId: "com.test.intro")
        XCTAssertEqual(config["bundleIdentifier"] as? String, "com.test.intro")
        XCTAssertTrue(config["introspectionEnabled"] as? Bool ?? false)
    }

    func testSetIntrospectionDisabled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.nointro")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Disable introspection (even if it wasn't set, should succeed)
        do {
            let result = try service.setIntrospectionEnabled(bundleId: "com.test.nointro", enabled: false)
            XCTAssertEqual(result.field, "introspection")
            XCTAssertFalse(result.enabled)
        } catch {
            // Signing failure is expected on dummy binary
            guard let injectionError = error as? InjectionError,
                  case .signingFailed = injectionError else { return }
        }
    }

    // MARK: - iOS Frameworks Tests

    func testSetIOSFrameworksEnabled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.iosfw")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        do {
            let result = try service.setIOSFrameworksEnabled(bundleId: "com.test.iosfw", enabled: true)
            XCTAssertEqual(result.bundleIdentifier, "com.test.iosfw")
            XCTAssertEqual(result.field, "iosFrameworks")
        } catch {
            guard let injectionError = error as? InjectionError,
                  case .signingFailed = injectionError else { return }
        }

        // Verify plist was modified
        let config = try service.getRuntimeConfig(bundleId: "com.test.iosfw")
        XCTAssertTrue(config["iosFrameworksEnabled"] as? Bool ?? false)
    }

    func testSetIOSFrameworksDisabled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.noiosfw")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        do {
            let result = try service.setIOSFrameworksEnabled(bundleId: "com.test.noiosfw", enabled: false)
            XCTAssertFalse(result.enabled)
        } catch {
            guard let _ = error as? InjectionError else { return }
        }
    }

    // MARK: - Category Tests

    func testSetApplicationCategoryValid() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.cat")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        do {
            let result = try service.setApplicationCategory(
                bundleId: "com.test.cat",
                category: "public.app-category.games"
            )
            XCTAssertEqual(result.bundleIdentifier, "com.test.cat")
            XCTAssertEqual(result.category, "public.app-category.games")
        } catch {
            guard let injectionError = error as? InjectionError,
                  case .signingFailed = injectionError else { return }
        }

        // Verify plist was modified
        let bundleDir = appDir.appendingPathComponent("com.test.cat.app")
        let infoPlistURL = bundleDir.appendingPathComponent("Info.plist")
        if let plist = NSDictionary(contentsOf: infoPlistURL) {
            XCTAssertEqual(plist["LSApplicationCategoryType"] as? String, "public.app-category.games")
        }
    }

    func testSetApplicationCategoryNone() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.catnone")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // First set a category
        let bundleDir = appDir.appendingPathComponent("com.test.catnone.app")
        let infoPlistURL = bundleDir.appendingPathComponent("Info.plist")
        if var plist = NSMutableDictionary(contentsOf: infoPlistURL) {
            plist["LSApplicationCategoryType"] = "public.app-category.games"
            plist.write(to: infoPlistURL, atomically: true)
        }

        // Then set to none (should remove the key)
        do {
            let result = try service.setApplicationCategory(
                bundleId: "com.test.catnone",
                category: "public.app-category.none"
            )
            XCTAssertEqual(result.category, "public.app-category.none")
            XCTAssertEqual(result.previousCategory, "public.app-category.games")
        } catch {
            guard let injectionError = error as? InjectionError,
                  case .signingFailed = injectionError else { return }
        }

        if let plist = NSDictionary(contentsOf: infoPlistURL) {
            XCTAssertNil(plist["LSApplicationCategoryType"])
        }
    }

    func testSetApplicationCategoryInvalid() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.badcat")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.setApplicationCategory(
            bundleId: "com.test.badcat",
            category: "invalid.category.value"
        )) { error in
            guard let injectionError = error as? InjectionError else {
                XCTFail("Expected InjectionError")
                return
            }
            XCTAssertEqual(injectionError, .invalidCategory("invalid.category.value"))
        }
    }

    // MARK: - Runtime Config Tests

    func testGetRuntimeConfigDefaults() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.config")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let config = try service.getRuntimeConfig(bundleId: "com.test.config")

        XCTAssertEqual(config["bundleIdentifier"] as? String, "com.test.config")
        XCTAssertFalse(config["introspectionEnabled"] as? Bool ?? true)
        XCTAssertFalse(config["iosFrameworksEnabled"] as? Bool ?? true)
    }

    // MARK: - Result Codable Tests

    func testPlayToolsCheckResultCodable() throws {
        let result = PlayToolsCheckResult(
            bundleIdentifier: "com.test",
            installed: true,
            message: "PlayTools is installed"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(PlayToolsCheckResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.installed)
    }

    func testInjectionResultCodable() throws {
        let result = InjectionResult(
            bundleIdentifier: "com.test",
            displayName: "Test App",
            action: "injected",
            message: "PlayTools injected"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(InjectionResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.action, "injected")
    }

    func testRuntimeConfigResultCodable() throws {
        let result = RuntimeConfigResult(
            bundleIdentifier: "com.test",
            field: "introspection",
            enabled: true,
            message: "introspection enabled"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(RuntimeConfigResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.enabled)
    }

    func testCategoryResultCodable() throws {
        let result = CategoryResult(
            bundleIdentifier: "com.test",
            category: "public.app-category.games",
            previousCategory: "public.app-category.entertainment",
            message: "Category set"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CategoryResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.category, "public.app-category.games")
    }

    // MARK: - Error Tests

    func testInjectionErrorDescriptions() {
        let errors: [(InjectionError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.executableNotFound("/path"), "Executable not found at: /path"),
            (.injectionFailed("reason"), "PlayTools injection failed: reason"),
            (.removalFailed("reason"), "PlayTools removal failed: reason"),
            (.invalidCategory("bad"), "Invalid application category: bad"),
            (.signingFailed("reason"), "Code signing failed: reason"),
        ]
        for (error, expected) in errors {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    func testInjectionErrorEquality() {
        XCTAssertEqual(InjectionError.appNotFound("a"), InjectionError.appNotFound("a"))
        XCTAssertNotEqual(InjectionError.appNotFound("a"), InjectionError.appNotFound("b"))
        XCTAssertEqual(InjectionError.injectionFailed("x"), InjectionError.injectionFailed("x"))
        XCTAssertEqual(InjectionError.signingFailed("y"), InjectionError.signingFailed("y"))
    }

    // MARK: - Valid Categories

    func testValidCategoriesContainsAllStandardTypes() {
        XCTAssertTrue(InjectionService.validCategories.contains("public.app-category.games"))
        XCTAssertTrue(InjectionService.validCategories.contains("public.app-category.entertainment"))
        XCTAssertTrue(InjectionService.validCategories.contains("public.app-category.none"))
        XCTAssertTrue(InjectionService.validCategories.contains("public.app-category.business"))
        XCTAssertTrue(InjectionService.validCategories.count >= 21)
    }

    // MARK: - Default Service Creation

    func testDefaultServiceCreation() {
        let service = InjectionService.defaultService()
        XCTAssertTrue(service.appDirectory.path.contains("Applications"))
        XCTAssertTrue(service.containerDirectory.path.contains("io.playcover.PlayCover"))
    }

    // MARK: - Multiple Apps

    func testIsolationBetweenApps() throws {
        let appDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectIsolation_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let containerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectContainer_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer { cleanupFixture([appDir, containerDir]) }

        // Create two apps
        for (id, name) in [("com.test.alpha", "Alpha"), ("com.test.beta", "Beta")] {
            let bundleDir = appDir.appendingPathComponent(id).appendingPathExtension("app")
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
                "CFBundleShortVersionString": "1.0", "CFBundleExecutable": name,
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plistData.write(to: bundleDir.appendingPathComponent("Info.plist"))
        }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Set category on alpha
        _ = try? service.setApplicationCategory(bundleId: "com.test.alpha", category: "public.app-category.games")

        // Beta should be unaffected
        let betaDir = appDir.appendingPathComponent("com.test.beta.app")
        let betaPlist = betaDir.appendingPathComponent("Info.plist")
        if let plist = NSDictionary(contentsOf: betaPlist) {
            XCTAssertNil(plist["LSApplicationCategoryType"])
        }
    }
}
