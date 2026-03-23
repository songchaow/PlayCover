import XCTest
import Foundation

final class AppServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeFixtureApps() throws -> (URL, [String: [String: String]]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let apps: [String: [String: String]] = [
            "TestApp.app": [
                "CFBundleIdentifier": "com.test.myapp",
                "CFBundleName": "TestApp",
                "CFBundleDisplayName": "My Test App",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleExecutable": "TestApp",
            ],
            "GameApp.app": [
                "CFBundleIdentifier": "com.game.example",
                "CFBundleName": "GameApp",
                "CFBundleDisplayName": "Cool Game",
                "CFBundleShortVersionString": "2.0.0",
                "CFBundleExecutable": "GameApp",
            ],
        ]

        for (appName, plist) in apps {
            let appDir = tmp.appendingPathComponent(appName)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let plistURL = appDir.appendingPathComponent("Info.plist")
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL)
        }

        return (tmp, apps)
    }

    private func cleanupFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - listApps

    func testListAppsReturnsAllApps() throws {
        let (tmp, _) = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let service = AppService(appDirectory: tmp)
        let apps = try service.listApps()

        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].displayName, "Cool Game")
        XCTAssertEqual(apps[0].bundleIdentifier, "com.game.example")
        XCTAssertEqual(apps[1].displayName, "My Test App")
        XCTAssertEqual(apps[1].bundleIdentifier, "com.test.myapp")
    }

    func testListAppsReturnsEmptyForNonexistentDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nonexistent_\(UUID().uuidString)")
        defer { cleanupFixture(tmp) }

        let service = AppService(appDirectory: tmp)
        let apps = try service.listApps()
        XCTAssertTrue(apps.isEmpty)
    }

    func testListAppsSkipsNonAppDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { cleanupFixture(tmp) }

        let notApp = tmp.appendingPathComponent("NotAnApp")
        try FileManager.default.createDirectory(at: notApp, withIntermediateDirectories: true)

        let noPlist = tmp.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: noPlist, withIntermediateDirectories: true)

        let validDir = tmp.appendingPathComponent("Valid.app")
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.valid.app",
            "CFBundleName": "Valid",
            "CFBundleDisplayName": "Valid App",
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "Valid",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: validDir.appendingPathComponent("Info.plist"))

        let service = AppService(appDirectory: tmp)
        let apps = try service.listApps()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.bundleIdentifier, "com.valid.app")
    }

    func testListAppsSortsAlphabetically() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { cleanupFixture(tmp) }

        for (name, bundleId) in [("Z.app", "com.z"), ("A.app", "com.a"), ("M.app", "com.m")] {
            let dir = tmp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist: [String: String] = [
                "CFBundleIdentifier": bundleId,
                "CFBundleName": name.replacingOccurrences(of: ".app", with: ""),
                "CFBundleDisplayName": name.replacingOccurrences(of: ".app", with: ""),
                "CFBundleShortVersionString": "1.0",
                "CFBundleExecutable": name.replacingOccurrences(of: ".app", with: ""),
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: dir.appendingPathComponent("Info.plist"))
        }

        let service = AppService(appDirectory: tmp)
        let apps = try service.listApps()
        XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.a", "com.m", "com.z"])
    }

    // MARK: - getApp

    func testGetAppReturnsCorrectApp() throws {
        let (tmp, _) = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let service = AppService(appDirectory: tmp)
        let app = try service.getApp(bundleId: "com.test.myapp")
        XCTAssertEqual(app.displayName, "My Test App")
        XCTAssertEqual(app.version, "1.2.3")
    }

    func testGetAppThrowsForUnknownBundleId() throws {
        let (tmp, _) = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let service = AppService(appDirectory: tmp)
        XCTAssertThrowsError(try service.getApp(bundleId: "com.nonexistent")) { error in
            guard let pce = error as? PlayCoverMCPError else {
                XCTFail("Expected PlayCoverMCPError")
                return
            }
            XCTAssertEqual(pce.code, -32001)
        }
    }

    // MARK: - AppRecord.toMCPDictionary

    func testToMCPDictionaryContainsAllFields() throws {
        let record = AppRecord(
            bundleIdentifier: "com.test.app",
            bundleName: "TestApp",
            displayName: "Test App",
            version: "1.0.0",
            executableName: "TestApp",
            url: URL(fileURLWithPath: "/tmp/TestApp.app")
        )

        let dict = record.toMCPDictionary()
        XCTAssertEqual(dict["bundleIdentifier"] as? String, "com.test.app")
        XCTAssertEqual(dict["bundleName"] as? String, "TestApp")
        XCTAssertEqual(dict["displayName"] as? String, "Test App")
        XCTAssertEqual(dict["version"] as? String, "1.0.0")
        XCTAssertEqual(dict["executableName"] as? String, "TestApp")
        XCTAssertEqual(dict["path"] as? String, "/tmp/TestApp.app")
    }
}
