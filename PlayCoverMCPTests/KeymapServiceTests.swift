import XCTest
import Foundation

final class KeymapServiceTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeFixtureApp(
        bundleId: String = "com.test.keymap",
        displayName: String = "KeymapTestApp"
    ) throws -> (appDir: URL, containerDir: URL) {
        let fm = FileManager.default

        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_KeymapTest_\(UUID().uuidString)")
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

        let containerDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Container_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        return (appDir, containerDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeService(appDir: URL, containerDir: URL) -> KeymapService {
        KeymapService(containerDirectory: containerDir, appDirectory: appDir)
    }

    // MARK: - List Keymaps Tests

    func testListKeymapsCreatesDefaultWhenNoneExist() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.list1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.listKeymaps(bundleId: "com.test.list1")

        XCTAssertEqual(result.bundleIdentifier, "com.test.list1")
        XCTAssertEqual(result.defaultKeymap, "default")
        XCTAssertEqual(result.keymaps.count, 1)
        XCTAssertEqual(result.keymaps.first?.name, "default")
        XCTAssertTrue(result.keymaps.first?.isDefault ?? false)
    }

    func testListKeymapsShowsAllCreatedKeymaps() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.list2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.createKeymap(bundleId: "com.test.list2", name: "custom1")
        _ = try service.createKeymap(bundleId: "com.test.list2", name: "custom2")

        let result = try service.listKeymaps(bundleId: "com.test.list2")
        XCTAssertEqual(result.keymaps.count, 3)
        let names = result.keymaps.map(\.name)
        XCTAssertTrue(names.contains("default"))
        XCTAssertTrue(names.contains("custom1"))
        XCTAssertTrue(names.contains("custom2"))
    }

    func testListKeymapsThrowsForNonexistentApp() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.other")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        XCTAssertThrowsError(try service.listKeymaps(bundleId: "com.nonexistent.app")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(keymapError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Get Keymap Tests

    func testGetKeymapReturnsDefaultContent() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.get1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // listKeymaps will auto-create the default
        _ = try service.listKeymaps(bundleId: "com.test.get1")

        let data = try service.getKeymap(bundleId: "com.test.get1", name: "default")
        XCTAssertEqual(data["bundleIdentifier"] as? String, "com.test.get1")
        XCTAssertEqual(data["version"] as? String, "2.0.0")
    }

    func testGetKeymapReturnsEmptyArrays() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.get2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.get2")

        let data = try service.getKeymap(bundleId: "com.test.get2", name: "default")
        let buttons = data["buttonModels"] as? [Any] ?? []
        let joysticks = data["joystickModel"] as? [Any] ?? []
        XCTAssertTrue(buttons.isEmpty)
        XCTAssertTrue(joysticks.isEmpty)
    }

    func testGetKeymapThrowsForNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.get3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.get3")

        XCTAssertThrowsError(try service.getKeymap(bundleId: "com.test.get3", name: "nonexistent")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapNotFound("nonexistent"))
        }
    }

    func testGetKeymapThrowsForInvalidName() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.get4")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.get4")

        XCTAssertThrowsError(try service.getKeymap(bundleId: "com.test.get4", name: "bad/name")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .invalidKeymapName("bad/name"))
        }
    }

    // MARK: - Create Keymap Tests

    func testCreateKeymap() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.create1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        let result = try service.createKeymap(bundleId: "com.test.create1", name: "my-keymap")

        XCTAssertEqual(result.bundleIdentifier, "com.test.create1")
        XCTAssertEqual(result.keymapName, "my-keymap")
        XCTAssertTrue(result.message.contains("created"))

        // Verify it exists
        let list = try service.listKeymaps(bundleId: "com.test.create1")
        XCTAssertTrue(list.keymaps.contains { $0.name == "my-keymap" })
    }

    func testCreateKeymapThrowsForDuplicate() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.create2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.createKeymap(bundleId: "com.test.create2", name: "dup")

        XCTAssertThrowsError(try service.createKeymap(bundleId: "com.test.create2", name: "dup")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapAlreadyExists("dup"))
        }
    }

    func testCreateKeymapThrowsForInvalidName() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.create3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Empty name
        XCTAssertThrowsError(try service.createKeymap(bundleId: "com.test.create3", name: "")) { error in
            XCTAssertTrue(error is KeymapError)
        }

        // Name with slash
        XCTAssertThrowsError(try service.createKeymap(bundleId: "com.test.create3", name: "a/b")) { error in
            XCTAssertTrue(error is KeymapError)
        }

        // Name with dot (would confuse plist extension)
        XCTAssertThrowsError(try service.createKeymap(bundleId: "com.test.create3", name: "a.b")) { error in
            XCTAssertTrue(error is KeymapError)
        }

        // Hidden file name
        XCTAssertThrowsError(try service.createKeymap(bundleId: "com.test.create3", name: ".hidden")) { error in
            XCTAssertTrue(error is KeymapError)
        }
    }

    // MARK: - Rename Keymap Tests

    func testRenameKeymap() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.rename1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.createKeymap(bundleId: "com.test.rename1", name: "old-name")

        let result = try service.renameKeymap(bundleId: "com.test.rename1", oldName: "old-name", newName: "new-name")

        XCTAssertEqual(result.oldName, "old-name")
        XCTAssertEqual(result.newName, "new-name")
        XCTAssertTrue(result.message.contains("renamed"))

        // Verify renamed
        let list = try service.listKeymaps(bundleId: "com.test.rename1")
        XCTAssertTrue(list.keymaps.contains { $0.name == "new-name" })
        XCTAssertFalse(list.keymaps.contains { $0.name == "old-name" })
    }

    func testRenameKeymapThrowsForNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.rename2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        XCTAssertThrowsError(try service.renameKeymap(bundleId: "com.test.rename2", oldName: "ghost", newName: "new")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapNotFound("ghost"))
        }
    }

    func testRenameKeymapThrowsForDuplicateNewName() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.rename3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.createKeymap(bundleId: "com.test.rename3", name: "km1")
        _ = try service.createKeymap(bundleId: "com.test.rename3", name: "km2")

        XCTAssertThrowsError(try service.renameKeymap(bundleId: "com.test.rename3", oldName: "km1", newName: "km2")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapAlreadyExists("km2"))
        }
    }

    // MARK: - Delete Keymap Tests

    func testDeleteKeymap() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.delete1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.createKeymap(bundleId: "com.test.delete1", name: "to-delete")

        let result = try service.deleteKeymap(bundleId: "com.test.delete1", name: "to-delete")

        XCTAssertEqual(result.keymapName, "to-delete")
        XCTAssertTrue(result.message.contains("deleted"))

        let list = try service.listKeymaps(bundleId: "com.test.delete1")
        XCTAssertFalse(list.keymaps.contains { $0.name == "to-delete" })
    }

    func testDeleteKeymapCannotDeleteDefault() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.delete2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.delete2")

        XCTAssertThrowsError(try service.deleteKeymap(bundleId: "com.test.delete2", name: "default")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .defaultKeymapCannotBeDeleted("default"))
        }
    }

    func testDeleteKeymapThrowsForNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.delete3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.delete3")

        XCTAssertThrowsError(try service.deleteKeymap(bundleId: "com.test.delete3", name: "ghost")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapNotFound("ghost"))
        }
    }

    // MARK: - Reset Keymap Tests

    func testResetKeymap() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.reset1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.reset1")

        // First, add some content to the default keymap
        let keymapURL = containerDir
            .appendingPathComponent("Keymapping")
            .appendingPathComponent("com.test.reset1")
            .appendingPathComponent("default.plist")
        var content: [String: Any] = [
            "bundleIdentifier": "com.test.reset1",
            "buttonModels": [["keyCode": 42, "keyName": "Test", "transform": ["size": 10.0, "xCoord": 20.0, "yCoord": 30.0]]],
            "draggableButtonModels": [],
            "joystickModel": [],
            "mouseAreaModel": [],
            "version": "2.0.0"
        ]
        try (content as NSDictionary).write(to: keymapURL)

        // Verify content exists
        let before = try service.getKeymap(bundleId: "com.test.reset1", name: "default")
        let buttons = before["buttonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(buttons.count, 1)

        // Reset
        let result = try service.resetKeymap(bundleId: "com.test.reset1", name: "default")
        XCTAssertEqual(result.keymapName, "default")
        XCTAssertTrue(result.message.contains("reset"))

        // Verify content cleared
        let after = try service.getKeymap(bundleId: "com.test.reset1", name: "default")
        let afterButtons = after["buttonModels"] as? [Any] ?? []
        XCTAssertTrue(afterButtons.isEmpty)
    }

    func testResetKeymapThrowsForNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.reset2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.reset2")

        XCTAssertThrowsError(try service.resetKeymap(bundleId: "com.test.reset2", name: "ghost")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapNotFound("ghost"))
        }
    }

    // MARK: - Result Codable Tests

    func testListKeymapsResultCodable() throws {
        let result = ListKeymapsResult(
            bundleIdentifier: "com.test",
            keymaps: [KeymapInfo(name: "default", isDefault: true, path: "/tmp/default.plist")],
            defaultKeymap: "default"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ListKeymapsResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testCreateKeymapResultCodable() throws {
        let result = CreateKeymapResult(bundleIdentifier: "com.test", keymapName: "km1", message: "created")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testRenameKeymapResultCodable() throws {
        let result = RenameKeymapResult(bundleIdentifier: "com.test", oldName: "a", newName: "b", message: "renamed")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(RenameKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testDeleteKeymapResultCodable() throws {
        let result = DeleteKeymapResult(bundleIdentifier: "com.test", keymapName: "km1", message: "deleted")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DeleteKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testResetKeymapResultCodable() throws {
        let result = ResetKeymapResult(bundleIdentifier: "com.test", keymapName: "km1", message: "reset")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ResetKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - Error Tests

    func testKeymapErrorDescriptions() {
        let errors: [(KeymapError, String)] = [
            (.appNotFound("com.test"), "Application not found: com.test"),
            (.keymapNotFound("missing"), "Keymap not found: missing"),
            (.keymapAlreadyExists("dup"), "Keymap already exists: dup"),
            (.defaultKeymapCannotBeDeleted("default"), "Cannot delete default keymap: default"),
            (.invalidKeymapName("a/b"), "Invalid keymap name: 'a/b'. Name must be non-empty and cannot contain '/' or '.'"),
            (.readFailed("corrupt"), "Failed to read keymap: corrupt"),
            (.writeFailed("disk"), "Failed to write keymap: disk"),
            (.deleteFailed("perm"), "Failed to delete keymap: perm"),
        ]
        for (error, expected) in errors {
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    func testKeymapErrorEquality() {
        XCTAssertEqual(KeymapError.appNotFound("a"), KeymapError.appNotFound("a"))
        XCTAssertNotEqual(KeymapError.appNotFound("a"), KeymapError.appNotFound("b"))
        XCTAssertEqual(KeymapError.keymapNotFound("x"), KeymapError.keymapNotFound("x"))
    }

    // MARK: - Isolation Test

    func testKeymapIsolationBetweenApps() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.isolate1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        // Create a second app
        let fm = FileManager.default
        let bundleDir2 = appDir.appendingPathComponent("com.test.isolate2.app")
        try fm.createDirectory(at: bundleDir2, withIntermediateDirectories: true)
        let info2: [String: String] = [
            "CFBundleIdentifier": "com.test.isolate2",
            "CFBundleName": "App2",
            "CFBundleDisplayName": "App2",
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "App2",
        ]
        let plistData2 = try PropertyListSerialization.data(fromPropertyList: info2, format: .xml, options: 0)
        try plistData2.write(to: bundleDir2.appendingPathComponent("Info.plist"))

        // Create keymap for app1
        _ = try service.createKeymap(bundleId: "com.test.isolate1", name: "only-for-app1")

        // App1 should have 2 keymaps
        let list1 = try service.listKeymaps(bundleId: "com.test.isolate1")
        XCTAssertEqual(list1.keymaps.count, 2)

        // App2 should only have default
        let list2 = try service.listKeymaps(bundleId: "com.test.isolate2")
        XCTAssertEqual(list2.keymaps.count, 1)
        XCTAssertFalse(list2.keymaps.contains { $0.name == "only-for-app1" })
    }
}
