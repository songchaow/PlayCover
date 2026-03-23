import XCTest
import Foundation

final class SettingsToolsAndResourcesTests: XCTestCase {

    // MARK: - Helpers

    private func makeFixtureApp(
        bundleId: String = "com.test.settings",
        displayName: String = "SettingsApp"
    ) throws -> (appDir: URL, containerDir: URL) {
        let fm = FileManager.default

        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_SettingsIT_\(UUID().uuidString)")
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
            .appendingPathComponent("PlayCoverMCP_SettingsIT_Container_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let settingsDir = containerDir.appendingPathComponent("App Settings")
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        // Create default settings
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
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: defaults, format: .xml, options: 0
        )
        try data.write(to: settingsDir.appendingPathComponent(bundleId).appendingPathExtension("plist"))

        return (appDir, containerDir)
    }

    private func cleanupFixture(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeServer(appDir: URL, containerDir: URL) -> MCPServer {
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(),
                resources: ResourceCapabilities()
            )
        )
        let appService = AppService(appDirectory: appDir)
        let settingsService = SettingsService(appDirectory: appDir, containerDirectory: containerDir)

        // Register app resources (including settings resource routing)
        AppResources.register(on: server, appService: appService, settingsService: settingsService)
        SettingsResources.register(on: server)
        SettingsTools.register(on: server, settingsService: settingsService)
        return server
    }

    private func sendRequest(_ server: MCPServer, _ request: JSONRPCRequest) -> JSONRPCMessage? {
        server.handle(.request(request))
    }

    private func extractResultText(_ response: JSONRPCMessage?) throws -> String {
        guard let response, case .response(let resp) = response else {
            XCTFail("Expected response")
            return ""
        }
        XCTAssertNil(resp.error, "Unexpected error: \(String(describing: resp.error))")
        XCTAssertNotNil(resp.result)

        let result: CallToolResult = try XCTUnwrap(resp.result?.decoded())
        guard case .text(let content) = result.content.first else {
            XCTFail("Expected text content")
            return ""
        }
        return content
    }

    private func extractResourceText(_ response: JSONRPCMessage?) throws -> String {
        guard let response, case .response(let resp) = response else {
            XCTFail("Expected response")
            return ""
        }
        XCTAssertNil(resp.error, "Unexpected error: \(String(describing: resp.error))")
        XCTAssertNotNil(resp.result)

        let result: ReadResourceResult = try XCTUnwrap(resp.result?.decoded())
        return result.contents.first?.text ?? ""
    }

    private func extractError(_ response: JSONRPCMessage?) -> JSONRPCError? {
        guard let response, case .response(let resp) = response else {
            XCTFail("Expected response")
            return nil
        }
        return resp.error
    }

    // MARK: - Tool Registration

    func testSettingsToolsAreRegistered() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        let listResp = sendRequest(server, JSONRPCRequest(id: .string("tools-list"), method: "tools/list"))
        guard case .response(let lr) = listResp else { XCTFail(); return }
        let listResult: ListToolsResult = try XCTUnwrap(lr.result?.decoded())

        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "get_app_settings" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "update_app_settings" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "reset_app_settings" }))
    }

    // MARK: - get_app_settings

    func testGetAppSettings() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.getsettings")
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("get-1"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_settings", "arguments": ["bundleId": "com.test.getsettings"]])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.test.getsettings")
        XCTAssertEqual(json["keymapping"] as? Bool, true)
        XCTAssertEqual(json["windowWidth"] as? Int, 1920)
    }

    func testGetAppSettingsMissingBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("get-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_settings"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testGetAppSettingsNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("get-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_settings", "arguments": ["bundleId": "com.nonexistent"]])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, -32001)
    }

    // MARK: - update_app_settings

    func testUpdateAppSettings() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.updatesettings")
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("update-1"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "update_app_settings",
                "arguments": [
                    "bundleId": "com.test.updatesettings",
                    "changes": ["keymapping": false, "sensitivity": 80]
                ]
            ])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.test.updatesettings")
        let updatedFields = json["updatedFields"] as! [String]
        XCTAssertTrue(updatedFields.contains("keymapping"))
        XCTAssertTrue(updatedFields.contains("sensitivity"))

        // Verify via get
        let getText = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("get-after-update"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "get_app_settings",
                "arguments": ["bundleId": "com.test.updatesettings"]
            ])
        )))
        let getJson = try JSONSerialization.jsonObject(with: Data(getText.utf8)) as! [String: Any]
        XCTAssertEqual(getJson["keymapping"] as? Bool, false)
    }

    func testUpdateAppSettingsMissingChanges() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("update-no-changes"),
            method: "tools/call",
            params: try AnyCodable(["name": "update_app_settings", "arguments": ["bundleId": "com.test"]])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testUpdateAppSettingsInvalidField() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("update-bad-field"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "update_app_settings",
                "arguments": [
                    "bundleId": "com.test.settings",
                    "changes": ["invalidField": true]
                ]
            ])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, -32006) // settingsError
    }

    // MARK: - reset_app_settings

    func testResetAppSettings() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.resetsettings")
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        // First update
        _ = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("update-before-reset"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "update_app_settings",
                "arguments": [
                    "bundleId": "com.test.resetsettings",
                    "changes": ["keymapping": false, "bypass": true]
                ]
            ])
        )))

        // Then reset
        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("reset-1"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "reset_app_settings",
                "arguments": ["bundleId": "com.test.resetsettings"]
            ])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.test.resetsettings")
        XCTAssertTrue((json["message"] as? String)?.contains("reset to defaults") ?? false)

        // Verify defaults restored
        let getText = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("get-after-reset"),
            method: "tools/call",
            params: try AnyCodable([
                "name": "get_app_settings",
                "arguments": ["bundleId": "com.test.resetsettings"]
            ])
        )))
        let getJson = try JSONSerialization.jsonObject(with: Data(getText.utf8)) as! [String: Any]
        XCTAssertEqual(getJson["keymapping"] as? Bool, true)
        XCTAssertEqual(getJson["bypass"] as? Bool, false)
    }

    func testResetAppSettingsMissingBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("reset-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "reset_app_settings"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    // MARK: - Resource: playcover://apps/{bundleId}/settings

    func testSettingsResourceIsRegistered() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        let listResp = sendRequest(server, JSONRPCRequest(id: .string("res-list"), method: "resources/list"))
        guard case .response(let lr) = listResp else { XCTFail(); return }
        let listResult: ListResourcesResult = try XCTUnwrap(lr.result?.decoded())
        XCTAssertTrue(listResult.resources.contains(where: {
            $0.uri == "playcover://apps/{bundleId}/settings"
        }))
    }

    func testReadSettingsResource() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.settingsresource")
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let text = try extractResourceText(sendRequest(server, JSONRPCRequest(
            id: .string("res-read-settings"),
            method: "resources/read",
            params: try AnyCodable(["uri": "playcover://apps/com.test.settingsresource/settings"])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.test.settingsresource")
        XCTAssertEqual(json["keymapping"] as? Bool, true)
    }

    func testReadSettingsResourceNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("res-read-404"),
            method: "resources/read",
            params: try AnyCodable(["uri": "playcover://apps/com.nonexistent/settings"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, -32001)
    }
}
