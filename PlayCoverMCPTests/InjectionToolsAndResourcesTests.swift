import XCTest
import Foundation

final class InjectionToolsAndResourcesTests: XCTestCase {

    // MARK: - Helpers

    private func makeFixtureApp(
        bundleId: String = "com.test.inject.tools",
        displayName: String = "InjectToolsApp"
    ) throws -> (appDir: URL, containerDir: URL) {
        let fm = FileManager.default

        let appDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectIT_\(UUID().uuidString)")
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

        // Create a dummy executable
        let execURL = bundleDir.appendingPathComponent(displayName)
        try Data("dummy".utf8).write(to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let containerDir = fm.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_InjectIT_Container_\(UUID().uuidString)")
        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)

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
        let injectionService = InjectionService(appDirectory: appDir, containerDirectory: containerDir)
        InjectionTools.register(on: server, injectionService: injectionService)
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

    private func extractError(_ response: JSONRPCMessage?) -> JSONRPCError? {
        guard let response, case .response(let resp) = response else {
            XCTFail("Expected response")
            return nil
        }
        return resp.error
    }

    // MARK: - Tool Registration

    func testInjectionToolsAreRegistered() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        let listResp = sendRequest(server, JSONRPCRequest(id: .string("tools-list"), method: "tools/list"))
        guard case .response(let lr) = listResp else { XCTFail(); return }
        let listResult: ListToolsResult = try XCTUnwrap(lr.result?.decoded())

        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "inject_playtools" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "remove_playtools" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "check_playtools_installed" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "set_introspection_enabled" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "set_ios_frameworks_enabled" }))
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "set_application_category" }))
    }

    // MARK: - check_playtools_installed

    func testCheckPlayToolsInstalled() throws {
        let (appDir, containerDir) = try makeFixtureApp(bundleId: "com.test.check")
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("check-1"),
            method: "tools/call",
            params: try AnyCodable(["name": "check_playtools_installed", "arguments": ["bundleId": "com.test.check"]])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.test.check")
        XCTAssertFalse(json["installed"] as? Bool ?? true) // dummy binary, not injected
    }

    func testCheckPlayToolsInstalledMissingBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("check-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "check_playtools_installed"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testCheckPlayToolsInstalledNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("check-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "check_playtools_installed", "arguments": ["bundleId": "com.nonexistent"]])
        )))
        XCTAssertNotNil(error)
    }

    // MARK: - inject_playtools

    func testInjectPlayToolsMissingBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("inject-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "inject_playtools"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testInjectPlayToolsNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("inject-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "inject_playtools", "arguments": ["bundleId": "com.nonexistent"]])
        )))
        XCTAssertNotNil(error)
    }

    // MARK: - remove_playtools

    func testRemovePlayToolsMissingBundleId() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("remove-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "remove_playtools"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testRemovePlayToolsNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("remove-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "remove_playtools", "arguments": ["bundleId": "com.nonexistent"]])
        )))
        XCTAssertNotNil(error)
    }

    // MARK: - set_introspection_enabled

    func testSetIntrospectionEnabledMissingParams() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        // Missing enabled
        let error1 = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("intro-no-enabled"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_introspection_enabled", "arguments": ["bundleId": "com.test"]])
        )))
        XCTAssertNotNil(error1)
        XCTAssertEqual(error1?.code, JSONRPCError.invalidParams)

        // Missing bundleId
        let error2 = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("intro-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_introspection_enabled", "arguments": ["enabled": true]])
        )))
        XCTAssertNotNil(error2)
        XCTAssertEqual(error2?.code, JSONRPCError.invalidParams)
    }

    func testSetIntrospectionEnabledNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("intro-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_introspection_enabled", "arguments": ["bundleId": "com.nonexistent", "enabled": true]])
        )))
        XCTAssertNotNil(error)
    }

    // MARK: - set_ios_frameworks_enabled

    func testSetIOSFrameworksMissingParams() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("iosfw-no-enabled"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_ios_frameworks_enabled", "arguments": ["bundleId": "com.test"]])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    // MARK: - set_application_category

    func testSetApplicationCategoryMissingParams() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)

        // Missing category
        let error1 = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("cat-no-cat"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_application_category", "arguments": ["bundleId": "com.test"]])
        )))
        XCTAssertNotNil(error1)
        XCTAssertEqual(error1?.code, JSONRPCError.invalidParams)

        // Missing bundleId
        let error2 = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("cat-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_application_category", "arguments": ["category": "public.app-category.games"]])
        )))
        XCTAssertNotNil(error2)
        XCTAssertEqual(error2?.code, JSONRPCError.invalidParams)
    }

    func testSetApplicationCategoryInvalidCategory() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("cat-invalid"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_application_category", "arguments": ["bundleId": "com.test", "category": "invalid.value"]])
        )))
        XCTAssertNotNil(error)
    }

    func testSetApplicationCategoryNotFound() throws {
        let (appDir, containerDir) = try makeFixtureApp()
        defer { cleanupFixture([appDir, containerDir]) }

        let server = makeServer(appDir: appDir, containerDir: containerDir)
        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("cat-404"),
            method: "tools/call",
            params: try AnyCodable(["name": "set_application_category", "arguments": ["bundleId": "com.nonexistent", "category": "public.app-category.games"]])
        )))
        XCTAssertNotNil(error)
    }
}
