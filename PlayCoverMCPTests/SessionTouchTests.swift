// SessionTouchTests.swift
// PlayCoverMCPTests

import Foundation
import XCTest
import Network

// MARK: - Touch Parameter Validation Tests

final class TouchParamsTests: XCTestCase {

    func testTapParamsInit() {
        let params = TapParams(x: 100.0, y: 200.0)
        XCTAssertEqual(params.x, 100.0)
        XCTAssertEqual(params.y, 200.0)
    }

    func testLongPressParamsDefaultDuration() {
        let params = LongPressParams(x: 50.0, y: 75.0)
        XCTAssertEqual(params.x, 50.0)
        XCTAssertEqual(params.y, 75.0)
        XCTAssertEqual(params.durationMs, 500)
    }

    func testLongPressParamsCustomDuration() {
        let params = LongPressParams(x: 50.0, y: 75.0, durationMs: 1500)
        XCTAssertEqual(params.durationMs, 1500)
    }

    func testTapParamsCodable() throws {
        let original = TapParams(x: 123.5, y: 456.7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TapParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLongPressParamsCodable() throws {
        let original = LongPressParams(x: 100.0, y: 200.0, durationMs: 2000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LongPressParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Touch Result Tests

final class TouchResultTests: XCTestCase {

    func testTapResultToDictionary() {
        let result = TouchResult(success: true, command: "tap", x: 100.0, y: 200.0)
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["command"] as? String, "tap")
        XCTAssertEqual(dict["x"] as? Double, 100.0)
        XCTAssertEqual(dict["y"] as? Double, 200.0)
        XCTAssertNil(dict["durationMs"])
    }

    func testLongPressResultToDictionary() {
        let result = TouchResult(success: true, command: "long_press", x: 50.0, y: 75.0, durationMs: 1000)
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["command"] as? String, "long_press")
        XCTAssertEqual(dict["x"] as? Double, 50.0)
        XCTAssertEqual(dict["y"] as? Double, 75.0)
        XCTAssertEqual(dict["durationMs"] as? Int, 1000)
    }

    func testTouchResultCodable() throws {
        let original = TouchResult(success: true, command: "tap", x: 10.0, y: 20.0, durationMs: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TouchResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Touch Error Tests

final class TouchErrorTests: XCTestCase {

    func testInvalidCoordinatesDescription() {
        let error = TouchError.invalidCoordinates("x must be non-negative")
        XCTAssertEqual(error.localizedDescription, "Invalid touch coordinates: x must be non-negative")
    }

    func testInvalidDurationDescription() {
        let error = TouchError.invalidDuration("must be positive")
        XCTAssertEqual(error.localizedDescription, "Invalid duration: must be positive")
    }

    func testSessionNotReadyDescription() {
        let error = TouchError.sessionNotReady("session is starting")
        XCTAssertEqual(error.localizedDescription, "Session not ready for touch: session is starting")
    }

    func testCommandFailedDescription() {
        let error = TouchError.commandFailed("runtime rejected")
        XCTAssertEqual(error.localizedDescription, "Touch command failed: runtime rejected")
    }

    func testTouchErrorEquality() {
        XCTAssertEqual(
            TouchError.invalidCoordinates("test"),
            TouchError.invalidCoordinates("test")
        )
        XCTAssertNotEqual(
            TouchError.invalidCoordinates("a"),
            TouchError.invalidCoordinates("b")
        )
    }
}

// MARK: - Touch Error MCP Mapping Tests

final class TouchErrorMCPMappingTests: XCTestCase {

    func testInvalidCoordinatesMapToInvalidParams() {
        let touchErr = TouchError.invalidCoordinates("negative x")
        let mcpErr = PlayCoverMCPError(wrapping: touchErr)
        XCTAssertEqual(mcpErr.code, JSONRPCError.invalidParams)
    }

    func testInvalidDurationMapToInvalidParams() {
        let touchErr = TouchError.invalidDuration("zero")
        let mcpErr = PlayCoverMCPError(wrapping: touchErr)
        XCTAssertEqual(mcpErr.code, JSONRPCError.invalidParams)
    }

    func testSessionNotReadyMapToBridgeError() {
        let touchErr = TouchError.sessionNotReady("starting")
        let mcpErr = PlayCoverMCPError(wrapping: touchErr)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }

    func testCommandFailedMapToBridgeError() {
        let touchErr = TouchError.commandFailed("timeout")
        let mcpErr = PlayCoverMCPError(wrapping: touchErr)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }
}

// MARK: - Fake Touch Service Tests

final class FakeTouchServiceTests: XCTestCase {

    func testFakeTapRecordsCalls() async throws {
        let fake = FakeTouchService()
        let params = TapParams(x: 100.0, y: 200.0)
        let result = try await fake.tap(sessionId: "s1", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "tap")
        XCTAssertEqual(result.x, 100.0)
        XCTAssertEqual(result.y, 200.0)
        XCTAssertEqual(fake.tapCalls.count, 1)
        XCTAssertEqual(fake.tapCalls.first?.sessionId, "s1")
        XCTAssertEqual(fake.tapCalls.first?.params, params)
    }

    func testFakeLongPressRecordsCalls() async throws {
        let fake = FakeTouchService()
        let params = LongPressParams(x: 50.0, y: 75.0, durationMs: 1000)
        let result = try await fake.longPress(sessionId: "s2", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "long_press")
        XCTAssertEqual(result.x, 50.0)
        XCTAssertEqual(result.y, 75.0)
        XCTAssertEqual(result.durationMs, 1000)
        XCTAssertEqual(fake.longPressCalls.count, 1)
        XCTAssertEqual(fake.longPressCalls.first?.sessionId, "s2")
    }

    func testFakeServiceCanFail() async {
        let fake = FakeTouchService()
        fake.setShouldFail(true, message: "test failure")

        do {
            _ = try await fake.tap(sessionId: "s1", params: TapParams(x: 0, y: 0))
            XCTFail("Should have thrown")
        } catch let error as TouchError {
            XCTAssertEqual(error, .commandFailed("test failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Touch Service Validation Tests

final class TouchServiceValidationTests: XCTestCase {

    private var registry: SessionRegistry!
    private var service: TouchService!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        // Use a client factory that immediately fails connection — we only test validation
        service = TouchService(registry: registry) { sessionId, port in
            BridgeClient(sessionId: sessionId, port: port)
        }
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        service = nil
        super.tearDown()
    }

    func testTapWithNegativeXThrows() async {
        do {
            _ = try await service.tap(sessionId: "s1", params: TapParams(x: -1, y: 100))
            XCTFail("Should throw on negative x")
        } catch let error as TouchError {
            if case .invalidCoordinates = error {
                // Expected
            } else {
                XCTFail("Expected invalidCoordinates, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTapWithNegativeYThrows() async {
        do {
            _ = try await service.tap(sessionId: "s1", params: TapParams(x: 100, y: -5))
            XCTFail("Should throw on negative y")
        } catch let error as TouchError {
            if case .invalidCoordinates = error {
                // Expected
            } else {
                XCTFail("Expected invalidCoordinates, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLongPressWithZeroDurationThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        do {
            _ = try await service.longPress(sessionId: "s1", params: LongPressParams(x: 100, y: 100, durationMs: 0))
            XCTFail("Should throw on zero duration")
        } catch let error as TouchError {
            if case .invalidDuration = error {
                // Expected
            } else {
                XCTFail("Expected invalidDuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLongPressWithExcessiveDurationThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        do {
            _ = try await service.longPress(sessionId: "s1", params: LongPressParams(x: 100, y: 100, durationMs: 120_000))
            XCTFail("Should throw on excessive duration")
        } catch let error as TouchError {
            if case .invalidDuration = error {
                // Expected
            } else {
                XCTFail("Expected invalidDuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTapSessionNotFoundThrows() async {
        do {
            _ = try await service.tap(sessionId: "nonexistent", params: TapParams(x: 100, y: 100))
            XCTFail("Should throw session not found")
        } catch let error as SessionError {
            if case .sessionNotFound = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTapSessionNotReadyThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .starting)
        try registry.register(info)

        do {
            _ = try await service.tap(sessionId: "s1", params: TapParams(x: 100, y: 100))
            XCTFail("Should throw session not ready")
        } catch let error as TouchError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLongPressSessionDisconnectedThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .disconnected)
        try registry.register(info)

        do {
            _ = try await service.longPress(sessionId: "s1", params: LongPressParams(x: 100, y: 100, durationMs: 500))
            XCTFail("Should throw session not ready")
        } catch let error as TouchError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Touch Command Encoding Tests

final class TouchCommandEncodingTests: XCTestCase {

    func testTapCommandEncoding() throws {
        let params = AnyCodable(["x": 100.0, "y": 200.0] as [String: Any])
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-1",
            command: "tap",
            params: params
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "tap")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
        XCTAssertEqual(json["commandId"] as? String, "cmd-1")

        let cmdParams = json["params"] as? [String: Any]
        XCTAssertEqual(cmdParams?["x"] as? Double, 100.0)
        XCTAssertEqual(cmdParams?["y"] as? Double, 200.0)
    }

    func testLongPressCommandEncoding() throws {
        let params = AnyCodable(["x": 50.0, "y": 75.0, "durationMs": 1500] as [String: Any])
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-2",
            command: "long_press",
            params: params
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "long_press")

        let cmdParams = json["params"] as? [String: Any]
        XCTAssertEqual(cmdParams?["x"] as? Double, 50.0)
        XCTAssertEqual(cmdParams?["y"] as? Double, 75.0)
        XCTAssertEqual(cmdParams?["durationMs"] as? Int, 1500)
    }

    func testTapCommandResponseDecoding() throws {
        let response = CommandResponsePayload(
            sessionId: "s1",
            commandId: "cmd-1",
            status: "ok",
            result: AnyCodable(["tapped": true] as [String: Any])
        )
        let message = BridgeMessage.commandResponse(response)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        if case .commandResponse(let payload) = decoded {
            XCTAssertEqual(payload.status, "ok")
            XCTAssertEqual(payload.commandId, "cmd-1")
        } else {
            XCTFail("Expected commandResponse")
        }
    }
}

// MARK: - Touch Tools Registration Tests

final class TouchToolsRegistrationTests: XCTestCase {

    private var server: MCPServer!
    private var fakeTouchService: FakeTouchService!

    override func setUp() {
        super.setUp()
        let logger = MCPLogger(minLevel: .info)
        let taskManager = TaskManager()
        server = MCPServer(
            serverInfo: Implementation(name: "test", version: "0.0.1"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(listChanged: false),
                resources: ResourceCapabilities(subscribe: false, listChanged: false),
                logging: true,
                tasks: true
            ),
            logger: logger,
            taskManager: taskManager
        )
        fakeTouchService = FakeTouchService()
        TouchTools.register(on: server, touchService: fakeTouchService)
    }

    override func tearDown() {
        server = nil
        fakeTouchService = nil
        super.tearDown()
    }

    func testTouchToolsRegistered() {
        let tools = server.toolRegistry.listTools()
        let toolNames = tools.map(\.name)
        XCTAssertTrue(toolNames.contains("tap"))
        XCTAssertTrue(toolNames.contains("long_press"))
    }

    func testTapToolSchema() {
        let tools = server.toolRegistry.listTools()
        let tapTool = tools.first { $0.name == "tap" }
        XCTAssertNotNil(tapTool)
        XCTAssertEqual(tapTool?.inputSchema.required, ["sessionId", "x", "y"])
    }

    func testLongPressToolSchema() {
        let tools = server.toolRegistry.listTools()
        let lpTool = tools.first { $0.name == "long_press" }
        XCTAssertNotNil(lpTool)
        XCTAssertEqual(lpTool?.inputSchema.required, ["sessionId", "x", "y"])
    }

    // MARK: - Tool call integration

    private func callTool(_ name: String, arguments: [String: Any]) -> JSONRPCResponse? {
        let idStr = String(UUID().uuidString.prefix(8))
        let request = JSONRPCRequest(
            id: .string(idStr),
            method: "tools/call",
            params: AnyCodable(["name": name, "arguments": arguments] as [String: Any])
        )
        let response = server.handle(.request(request))
        guard case .response(let resp) = response else {
            XCTFail("Expected response for \(name)")
            return nil
        }
        return resp
    }

    func testTapToolCallSuccess() {
        let resp = callTool("tap", arguments: [
            "sessionId": "s1",
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeTouchService.tapCalls.count, 1)
    }

    func testLongPressToolCallSuccess() {
        let resp = callTool("long_press", arguments: [
            "sessionId": "s1",
            "x": 50.0,
            "y": 75.0,
            "durationMs": 1000
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeTouchService.longPressCalls.count, 1)
    }

    func testLongPressToolCallDefaultDuration() {
        let resp = callTool("long_press", arguments: [
            "sessionId": "s1",
            "x": 50.0,
            "y": 75.0
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeTouchService.longPressCalls.first?.params.durationMs, 500)
    }

    func testTapToolMissingSessionId() {
        let resp = callTool("tap", arguments: [
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTapToolMissingX() {
        let resp = callTool("tap", arguments: [
            "sessionId": "s1",
            "y": 200.0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTapToolMissingY() {
        let resp = callTool("tap", arguments: [
            "sessionId": "s1",
            "x": 100.0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTapToolEmptySessionId() {
        let resp = callTool("tap", arguments: [
            "sessionId": "",
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTapToolServiceFailure() {
        fakeTouchService.setShouldFail(true, message: "runtime down")

        let resp = callTool("tap", arguments: [
            "sessionId": "s1",
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }
}

// MARK: - Touch Bridge Integration Tests

final class TouchBridgeIntegrationTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(port: 0, registry: registry)
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        super.tearDown()
    }

    /// Helper to extract a numeric value from AnyCodable dictionary as Double.
    /// AnyCodable decodes integers first, so 150.0 may come back as Int 150.
    private func numericValue(_ dict: [String: Any]?, key: String) -> Double? {
        guard let dict = dict else { return nil }
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        return nil
    }

    func testTapThroughFakeRuntime() throws {
        let port = try registrationListener.start()

        // Start fake runtime that will handle the tap command
        let fakeRuntime = FakeRuntimeServer(bundleId: "com.touch.test", sessionId: "touch-sess-1")
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "tap")
            // params should contain x and y values
            XCTAssertNotNil(payload.params, "params should not be nil")
            XCTAssertNotNil(payload.params?.dictionary, "params.dictionary should not be nil")

            return CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "ok",
                result: AnyCodable(["executed": true] as [String: Any])
            )
        }

        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Verify session is in registry
        guard let session = registry.get("touch-sess-1") else {
            XCTFail("Session should be registered")
            return
        }
        XCTAssertEqual(session.status, .ready)

        // Create touch service connected to the runtime
        let touchService = TouchService(registry: registry)

        // Execute tap
        let tapDone = expectation(description: "tap done")
        Task {
            do {
                let result = try await touchService.tap(
                    sessionId: "touch-sess-1",
                    params: TapParams(x: 150.0, y: 250.0)
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "tap")
                XCTAssertEqual(result.x, 150.0)
                XCTAssertEqual(result.y, 250.0)
                tapDone.fulfill()
            } catch {
                XCTFail("Tap failed: \(error)")
                tapDone.fulfill()
            }
        }
        wait(for: [tapDone], timeout: 10.0)

        // Verify the fake runtime received the command
        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "tap")

        fakeRuntime.stop()
    }

    func testLongPressThroughFakeRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.touch.test2", sessionId: "touch-sess-2")
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "long_press")
            XCTAssertNotNil(payload.params, "params should not be nil")
            XCTAssertNotNil(payload.params?.dictionary, "params.dictionary should not be nil")
            let params = payload.params?.dictionary
            // Verify keys exist (values may be Int or Double after JSON round-trip)
            XCTAssertNotNil(params?["x"], "x param should exist")
            XCTAssertNotNil(params?["y"], "y param should exist")
            XCTAssertNotNil(params?["durationMs"], "durationMs param should exist")

            return CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "ok",
                result: AnyCodable(["executed": true] as [String: Any])
            )
        }

        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        let touchService = TouchService(registry: registry)

        let lpDone = expectation(description: "long press done")
        Task {
            do {
                let result = try await touchService.longPress(
                    sessionId: "touch-sess-2",
                    params: LongPressParams(x: 200.0, y: 300.0, durationMs: 1500)
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "long_press")
                XCTAssertEqual(result.x, 200.0)
                XCTAssertEqual(result.y, 300.0)
                XCTAssertEqual(result.durationMs, 1500)
                lpDone.fulfill()
            } catch {
                XCTFail("Long press failed: \(error)")
                lpDone.fulfill()
            }
        }
        wait(for: [lpDone], timeout: 10.0)

        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "long_press")

        fakeRuntime.stop()
    }

    func testTapToNonExistentSessionFails() async throws {
        let touchService = TouchService(registry: registry)

        do {
            _ = try await touchService.tap(
                sessionId: "nonexistent",
                params: TapParams(x: 100, y: 100)
            )
            XCTFail("Should have thrown")
        } catch let error as SessionError {
            if case .sessionNotFound = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotFound, got \(error)")
            }
        }
    }
}
