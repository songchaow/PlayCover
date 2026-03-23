import XCTest
import Foundation

final class AppToolsAndResourcesTests: XCTestCase {

    // MARK: - Helpers

    private func makeFixtureApps() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_ToolsTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let apps: [[String: String]] = [
            [
                "dir": "Alpha.app",
                "CFBundleIdentifier": "com.alpha.app",
                "CFBundleName": "Alpha",
                "CFBundleDisplayName": "Alpha App",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleExecutable": "Alpha",
            ],
            [
                "dir": "Beta.app",
                "CFBundleIdentifier": "com.beta.app",
                "CFBundleName": "Beta",
                "CFBundleDisplayName": "Beta App",
                "CFBundleShortVersionString": "2.1.0",
                "CFBundleExecutable": "Beta",
            ],
        ]

        for app in apps {
            guard let dir = app["dir"] else { continue }
            let appDir = tmp.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

            var plist = app
            plist.removeValue(forKey: "dir")
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: appDir.appendingPathComponent("Info.plist"))
        }

        return tmp
    }

    private func cleanupFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeServer(appService: AppService) -> MCPServer {
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(),
                resources: ResourceCapabilities()
            )
        )
        AppTools.register(on: server, appService: appService)
        AppResources.register(on: server, appService: appService)
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

    // MARK: - tools/call: list_installed_apps

    func testToolsCallListInstalledApps() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        // Verify tool is registered
        let listResp = sendRequest(server, JSONRPCRequest(id: .string("tools-list"), method: "tools/list"))
        guard case .response(let lr) = listResp else { XCTFail(); return }
        let listResult: ListToolsResult = try XCTUnwrap(lr.result?.decoded())
        XCTAssertTrue(listResult.tools.contains(where: { $0.name == "list_installed_apps" }))

        // Call the tool
        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("call-1"),
            method: "tools/call",
            params: try AnyCodable(["name": "list_installed_apps"])
        )))

        XCTAssertTrue(text.contains("Alpha App"))
        XCTAssertTrue(text.contains("com.alpha.app"))
        XCTAssertTrue(text.contains("Beta App"))
        XCTAssertTrue(text.contains("com.beta.app"))
    }

    func testToolsCallListInstalledAppsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP_Empty_\(UUID().uuidString)")
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("call-empty"),
            method: "tools/call",
            params: try AnyCodable(["name": "list_installed_apps"])
        )))

        XCTAssertTrue(text.contains("No PlayCover applications found"))
    }

    // MARK: - tools/call: get_app_info

    func testToolsCallGetAppInfo() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let text = try extractResultText(sendRequest(server, JSONRPCRequest(
            id: .string("call-info"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_info", "arguments": ["bundleId": "com.beta.app"]])
        )))

        XCTAssertTrue(text.contains("com.beta.app"))
        XCTAssertTrue(text.contains("Beta App"))
        XCTAssertTrue(text.contains("2.1.0"))
    }

    func testToolsCallGetAppInfoMissingBundleId() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("call-no-bid"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_info"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
    }

    func testToolsCallGetAppInfoNotFound() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("call-notfound"),
            method: "tools/call",
            params: try AnyCodable(["name": "get_app_info", "arguments": ["bundleId": "com.nonexistent"]])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, -32001) // appNotFound
    }

    // MARK: - tools/call: unknown tool

    func testToolsCallUnknownTool() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("call-unknown"),
            method: "tools/call",
            params: try AnyCodable(["name": "nonexistent_tool"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, JSONRPCError.invalidParams)
        XCTAssertTrue(error?.message.contains("Unknown tool") ?? false)
    }

    // MARK: - resources/read: playcover://apps

    func testResourcesReadAppsCollection() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        // Verify resource is registered
        let listResp = sendRequest(server, JSONRPCRequest(id: .string("res-list"), method: "resources/list"))
        guard case .response(let lr) = listResp else { XCTFail(); return }
        let listResult: ListResourcesResult = try XCTUnwrap(lr.result?.decoded())
        XCTAssertTrue(listResult.resources.contains(where: { $0.uri == "playcover://apps" }))
        XCTAssertTrue(listResult.resources.contains(where: { $0.uri == "playcover://apps/{bundleId}" }))

        // Read the resource
        let text = try extractResourceText(sendRequest(server, JSONRPCRequest(
            id: .string("res-read"),
            method: "resources/read",
            params: try AnyCodable(["uri": "playcover://apps"])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [Any]
        XCTAssertEqual(json.count, 2)
    }

    func testResourcesReadSingleApp() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let text = try extractResourceText(sendRequest(server, JSONRPCRequest(
            id: .string("res-read-single"),
            method: "resources/read",
            params: try AnyCodable(["uri": "playcover://apps/com.alpha.app"])
        )))

        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(json["bundleIdentifier"] as? String, "com.alpha.app")
        XCTAssertEqual(json["displayName"] as? String, "Alpha App")
    }

    func testResourcesReadSingleAppNotFound() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("res-read-404"),
            method: "resources/read",
            params: try AnyCodable(["uri": "playcover://apps/com.missing"])
        )))
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, -32001) // appNotFound
    }

    func testResourcesReadUnknownUri() throws {
        let tmp = try makeFixtureApps()
        defer { cleanupFixture(tmp) }

        let appService = AppService(appDirectory: tmp)
        let server = makeServer(appService: appService)

        let error = extractError(sendRequest(server, JSONRPCRequest(
            id: .string("res-read-unknown"),
            method: "resources/read",
            params: try AnyCodable(["uri": "unknown://resource"])
        )))
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.message.contains("Unknown resource URI") ?? false)
    }
}
