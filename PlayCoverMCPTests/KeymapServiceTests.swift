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

    // MARK: - Import Keymap Tests

    private func makeImportSourceKeymap(bundleId: String, extraButtons: Bool = false) throws -> URL {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_ImportSource_\(UUID().uuidString).plist")
        var keymap: [String: Any] = [
            "bundleIdentifier": bundleId,
            "buttonModels": [],
            "draggableButtonModels": [],
            "joystickModel": [],
            "mouseAreaModel": [],
            "version": "2.0.0"
        ]
        if extraButtons {
            keymap["buttonModels"] = [
                ["keyCode": 42, "keyName": "Jump", "transform": ["size": 10.0, "xCoord": 20.0, "yCoord": 30.0]],
                ["keyCode": 88, "keyName": "Fire", "transform": ["size": 15.0, "xCoord": 50.0, "yCoord": 60.0]]
            ]
            keymap["joystickModel"] = [
                ["side": "left", "transform": ["size": 80.0, "xCoord": 100.0, "yCoord": 200.0]]
            ]
        }
        try (keymap as NSDictionary).write(to: sourceURL)
        return sourceURL
    }

    func testImportKeymapSuccess() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import1")

        let sourceURL = try makeImportSourceKeymap(bundleId: "com.test.import1", extraButtons: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let result = try service.importKeymap(bundleId: "com.test.import1", name: "imported-km", filePath: sourceURL.path)

        XCTAssertEqual(result.bundleIdentifier, "com.test.import1")
        XCTAssertEqual(result.keymapName, "imported-km")
        XCTAssertTrue(result.bundleIdMatched)
        XCTAssertTrue(result.message.contains("imported"))

        // Verify the imported keymap has the expected content
        let data = try service.getKeymap(bundleId: "com.test.import1", name: "imported-km")
        let buttons = data["buttonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(buttons.count, 2)
        let joysticks = data["joystickModel"] as? [[String: Any]] ?? []
        XCTAssertEqual(joysticks.count, 1)
    }

    func testImportKeymapOverwritesExisting() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import2")

        // Create a keymap first
        _ = try service.createKeymap(bundleId: "com.test.import2", name: "target-km")

        // Verify it's empty
        let before = try service.getKeymap(bundleId: "com.test.import2", name: "target-km")
        let beforeButtons = before["buttonModels"] as? [Any] ?? []
        XCTAssertTrue(beforeButtons.isEmpty)

        // Import with content (overwrites)
        let sourceURL = try makeImportSourceKeymap(bundleId: "com.test.import2", extraButtons: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let result = try service.importKeymap(bundleId: "com.test.import2", name: "target-km", filePath: sourceURL.path)
        XCTAssertTrue(result.bundleIdMatched)

        // Verify content was overwritten
        let after = try service.getKeymap(bundleId: "com.test.import2", name: "target-km")
        let afterButtons = after["buttonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(afterButtons.count, 2)
    }

    func testImportKeymapBundleIdMismatchThrowsWithoutForce() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import3")

        // Source with different bundleId
        let sourceURL = try makeImportSourceKeymap(bundleId: "com.other.app")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        XCTAssertThrowsError(try service.importKeymap(bundleId: "com.test.import3", name: "mismatch", filePath: sourceURL.path)) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .bundleIdMismatch(sourceBundleId: "com.other.app", targetBundleId: "com.test.import3"))
        }
    }

    func testImportKeymapBundleIdMismatchSucceedsWithForce() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import4")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import4")

        // Source with different bundleId
        let sourceURL = try makeImportSourceKeymap(bundleId: "com.other.app", extraButtons: true)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let result = try service.importKeymap(bundleId: "com.test.import4", name: "forced", filePath: sourceURL.path, force: true)

        XCTAssertFalse(result.bundleIdMatched)
        XCTAssertTrue(result.message.contains("bundleId overwritten"))

        // Verify the bundleId was overwritten
        let data = try service.getKeymap(bundleId: "com.test.import4", name: "forced")
        XCTAssertEqual(data["bundleIdentifier"] as? String, "com.test.import4")
    }

    func testImportKeymapSourceNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import5")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import5")

        XCTAssertThrowsError(try service.importKeymap(bundleId: "com.test.import5", name: "bad", filePath: "/nonexistent/path.plist")) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .importSourceNotFound("/nonexistent/path.plist"))
        }
    }

    func testImportKeymapInvalidFile() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import6")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.import6")

        // Create a non-plist file
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_BadFile_\(UUID().uuidString).plist")
        try "not a plist".data(using: .utf8)!.write(to: badURL)
        defer { try? FileManager.default.removeItem(at: badURL) }

        XCTAssertThrowsError(try service.importKeymap(bundleId: "com.test.import6", name: "bad", filePath: badURL.path)) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            if case .invalidKeymapFile(_) = keymapError {
                // expected
            } else {
                XCTFail("Expected invalidKeymapFile, got \(keymapError)")
            }
        }
    }

    func testImportKeymapAppNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.import7")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        let sourceURL = try makeImportSourceKeymap(bundleId: "com.nonexistent.app")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        XCTAssertThrowsError(try service.importKeymap(bundleId: "com.nonexistent.app", name: "bad", filePath: sourceURL.path)) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .appNotFound("com.nonexistent.app"))
        }
    }

    // MARK: - Export Keymap Tests

    func testExportKeymapSuccess() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.export1")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.export1")

        // Add content to default keymap
        let keymapURL = containerDir
            .appendingPathComponent("Keymapping")
            .appendingPathComponent("com.test.export1")
            .appendingPathComponent("default.plist")
        var content: [String: Any] = [
            "bundleIdentifier": "com.test.export1",
            "buttonModels": [["keyCode": 99]],
            "draggableButtonModels": [],
            "joystickModel": [],
            "mouseAreaModel": [],
            "version": "2.0.0"
        ]
        try (content as NSDictionary).write(to: keymapURL)

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Export_\(UUID().uuidString).plist").path

        let result = try service.exportKeymap(bundleId: "com.test.export1", name: "default", outputPath: outputPath)

        XCTAssertEqual(result.bundleIdentifier, "com.test.export1")
        XCTAssertEqual(result.keymapName, "default")
        XCTAssertTrue(result.message.contains("exported"))

        // Verify the exported file exists and has correct content
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: outputPath))
        defer { try? fm.removeItem(atPath: outputPath) }

        guard let exported = NSDictionary(contentsOfFile: outputPath) as? [String: Any] else {
            XCTFail("Cannot read exported plist")
            return
        }
        XCTAssertEqual(exported["bundleIdentifier"] as? String, "com.test.export1")
        let buttons = exported["buttonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(buttons.count, 1)
    }

    func testExportKeymapRoundTrip() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.export2")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.export2")

        // Create and populate a keymap
        _ = try service.createKeymap(bundleId: "com.test.export2", name: "roundtrip")
        let keymapURL = containerDir
            .appendingPathComponent("Keymapping")
            .appendingPathComponent("com.test.export2")
            .appendingPathComponent("roundtrip.plist")
        var content: [String: Any] = [
            "bundleIdentifier": "com.test.export2",
            "buttonModels": [["keyCode": 1], ["keyCode": 2], ["keyCode": 3]],
            "draggableButtonModels": [["name": "drag1"]],
            "joystickModel": [["side": "left"]],
            "mouseAreaModel": [["name": "area1"]],
            "version": "2.0.0"
        ]
        try (content as NSDictionary).write(to: keymapURL)

        // Export
        let exportPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_RoundTrip_\(UUID().uuidString).plist").path
        _ = try service.exportKeymap(bundleId: "com.test.export2", name: "roundtrip", outputPath: exportPath)
        defer { try? FileManager.default.removeItem(atPath: exportPath) }

        // Delete the original keymap file (but not from config) to test import into fresh location
        try? FileManager.default.removeItem(at: keymapURL)

        // Import into a different name
        let result = try service.importKeymap(bundleId: "com.test.export2", name: "reimported", filePath: exportPath)

        XCTAssertTrue(result.bundleIdMatched)

        // Verify content matches
        let data = try service.getKeymap(bundleId: "com.test.export2", name: "reimported")
        XCTAssertEqual(data["bundleIdentifier"] as? String, "com.test.export2")
        let buttons = data["buttonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(buttons.count, 3)
        let draggable = data["draggableButtonModels"] as? [[String: Any]] ?? []
        XCTAssertEqual(draggable.count, 1)
    }

    func testExportKeymapNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.export3")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.export3")

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_ExportBad_\(UUID().uuidString).plist").path

        XCTAssertThrowsError(try service.exportKeymap(bundleId: "com.test.export3", name: "nonexistent", outputPath: outputPath)) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .keymapNotFound("nonexistent"))
        }
    }

    func testExportKeymapCreatesParentDirectory() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.export4")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)
        _ = try service.listKeymaps(bundleId: "com.test.export4")

        let nestedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_NestedDir_\(UUID().uuidString)")
            .appendingPathComponent("sub")
        let outputPath = nestedDir.appendingPathComponent("exported.plist").path

        _ = try service.exportKeymap(bundleId: "com.test.export4", name: "default", outputPath: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        defer { try? FileManager.default.removeItem(at: nestedDir) }
    }

    func testExportKeymapAppNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.export5")
        defer { cleanupFixture([appDir, containerDir]) }

        let service = makeService(appDir: appDir, containerDir: containerDir)

        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_ExportBadApp_\(UUID().uuidString).plist").path

        XCTAssertThrowsError(try service.exportKeymap(bundleId: "com.nonexistent", name: "default", outputPath: outputPath)) { error in
            guard let keymapError = error as? KeymapError else {
                XCTFail("Expected KeymapError")
                return
            }
            XCTAssertEqual(keymapError, .appNotFound("com.nonexistent"))
        }
    }

    // MARK: - Import/Export Result Codable Tests

    func testImportKeymapResultCodable() throws {
        let result = ImportKeymapResult(
            bundleIdentifier: "com.test", keymapName: "km1", sourcePath: "/tmp/src.plist",
            bundleIdMatched: true, message: "imported"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ImportKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testImportKeymapResultCodableMismatch() throws {
        let result = ImportKeymapResult(
            bundleIdentifier: "com.test", keymapName: "km1", sourcePath: "/tmp/src.plist",
            bundleIdMatched: false, message: "overwritten"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ImportKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertFalse(decoded.bundleIdMatched)
    }

    func testExportKeymapResultCodable() throws {
        let result = ExportKeymapResult(
            bundleIdentifier: "com.test", keymapName: "km1",
            outputPath: "/tmp/out.plist", message: "exported"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExportKeymapResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - New Error Tests

    func testNewErrorDescriptions() {
        XCTAssertEqual(KeymapError.invalidKeymapFile("bad").localizedDescription, "Invalid keymap file: bad")
        XCTAssertEqual(
            KeymapError.bundleIdMismatch(sourceBundleId: "a", targetBundleId: "b").localizedDescription,
            "Keymap bundle identifier 'a' does not match target app 'b'. Use force=true to import anyway."
        )
        XCTAssertEqual(KeymapError.exportFailed("err").localizedDescription, "Failed to export keymap: err")
        XCTAssertEqual(KeymapError.importSourceNotFound("/x").localizedDescription, "Import source file not found: /x")
    }

    func testNewErrorEquality() {
        XCTAssertEqual(
            KeymapError.bundleIdMismatch(sourceBundleId: "a", targetBundleId: "b"),
            KeymapError.bundleIdMismatch(sourceBundleId: "a", targetBundleId: "b")
        )
        XCTAssertNotEqual(
            KeymapError.bundleIdMismatch(sourceBundleId: "a", targetBundleId: "b"),
            KeymapError.bundleIdMismatch(sourceBundleId: "a", targetBundleId: "c")
        )
        XCTAssertEqual(KeymapError.exportFailed("e"), KeymapError.exportFailed("e"))
        XCTAssertEqual(KeymapError.importSourceNotFound("/a"), KeymapError.importSourceNotFound("/a"))
    }
}
