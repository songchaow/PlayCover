// SessionInputTests.swift
// PlayCoverMCPTests

import Foundation
import XCTest
import Network

// MARK: - Input Parameter Tests

final class InputParamsTests: XCTestCase {

    func testKeyPressParamsInit() {
        let params = KeyPressParams(key: "a")
        XCTAssertEqual(params.key, "a")
        XCTAssertNil(params.modifiers)
    }

    func testKeyPressParamsWithModifiers() {
        let params = KeyPressParams(key: "c", modifiers: ["command"])
        XCTAssertEqual(params.key, "c")
        XCTAssertEqual(params.modifiers, ["command"])
    }

    func testKeyPressParamsCodable() throws {
        let original = KeyPressParams(key: "enter", modifiers: ["shift", "command"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyPressParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testKeyPressParamsWithoutModifiersCodable() throws {
        let original = KeyPressParams(key: "escape")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyPressParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTypeTextParamsInit() {
        let params = TypeTextParams(text: "Hello World")
        XCTAssertEqual(params.text, "Hello World")
    }

    func testTypeTextParamsCodable() throws {
        let original = TypeTextParams(text: "Test input 123!")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypeTextParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Input Result Tests

final class InputResultTests: XCTestCase {

    func testPressKeyResultToDictionary() {
        let result = InputResult(success: true, command: "press_key", detail: "a")
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["command"] as? String, "press_key")
        XCTAssertEqual(dict["detail"] as? String, "a")
    }

    func testTypeTextResultToDictionary() {
        let result = InputResult(success: true, command: "type_text", detail: "5 character(s)")
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["command"] as? String, "type_text")
        XCTAssertEqual(dict["detail"] as? String, "5 character(s)")
    }

    func testToggleDebugOverlayResultToDictionary() {
        let result = InputResult(success: true, command: "toggle_debug_overlay", detail: "toggled")
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["command"] as? String, "toggle_debug_overlay")
        XCTAssertEqual(dict["detail"] as? String, "toggled")
    }

    func testResultWithNilDetail() {
        let result = InputResult(success: false, command: "press_key")
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, false)
        XCTAssertNil(dict["detail"])
    }

    func testInputResultCodable() throws {
        let original = InputResult(success: true, command: "press_key", detail: "enter")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InputResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Input Error Tests

final class InputErrorTests: XCTestCase {

    func testInvalidKeyDescription() {
        let error = InputError.invalidKey("empty key")
        XCTAssertEqual(error.localizedDescription, "Invalid key: empty key")
    }

    func testInvalidTextDescription() {
        let error = InputError.invalidText("empty text")
        XCTAssertEqual(error.localizedDescription, "Invalid text: empty text")
    }

    func testSessionNotReadyDescription() {
        let error = InputError.sessionNotReady("session is starting")
        XCTAssertEqual(error.localizedDescription, "Session not ready for input: session is starting")
    }

    func testCommandFailedDescription() {
        let error = InputError.commandFailed("runtime rejected")
        XCTAssertEqual(error.localizedDescription, "Input command failed: runtime rejected")
    }

    func testInputErrorEquality() {
        XCTAssertEqual(
            InputError.invalidKey("test"),
            InputError.invalidKey("test")
        )
        XCTAssertNotEqual(
            InputError.invalidKey("a"),
            InputError.invalidKey("b")
        )
    }
}

// MARK: - Supported Keys Tests

final class SupportedKeysTests: XCTestCase {

    func testSingleCharacterIsValid() {
        XCTAssertTrue(SupportedKeys.isValid("a"))
        XCTAssertTrue(SupportedKeys.isValid("Z"))
        XCTAssertTrue(SupportedKeys.isValid("1"))
        XCTAssertTrue(SupportedKeys.isValid(" "))
        XCTAssertTrue(SupportedKeys.isValid("!"))
    }

    func testNamedKeysAreValid() {
        XCTAssertTrue(SupportedKeys.isValid("enter"))
        XCTAssertTrue(SupportedKeys.isValid("escape"))
        XCTAssertTrue(SupportedKeys.isValid("tab"))
        XCTAssertTrue(SupportedKeys.isValid("backspace"))
        XCTAssertTrue(SupportedKeys.isValid("delete"))
        XCTAssertTrue(SupportedKeys.isValid("space"))
        XCTAssertTrue(SupportedKeys.isValid("up"))
        XCTAssertTrue(SupportedKeys.isValid("down"))
        XCTAssertTrue(SupportedKeys.isValid("left"))
        XCTAssertTrue(SupportedKeys.isValid("right"))
    }

    func testFunctionKeysAreValid() {
        for i in 1...12 {
            XCTAssertTrue(SupportedKeys.isValid("f\(i)"), "f\(i) should be valid")
        }
    }

    func testModifierKeysAreValid() {
        XCTAssertTrue(SupportedKeys.isValid("shift"))
        XCTAssertTrue(SupportedKeys.isValid("control"))
        XCTAssertTrue(SupportedKeys.isValid("option"))
        XCTAssertTrue(SupportedKeys.isValid("command"))
    }

    func testCaseInsensitiveNamedKeys() {
        XCTAssertTrue(SupportedKeys.isValid("ENTER"))
        XCTAssertTrue(SupportedKeys.isValid("Escape"))
        XCTAssertTrue(SupportedKeys.isValid("TAB"))
    }

    func testEmptyStringIsInvalid() {
        XCTAssertFalse(SupportedKeys.isValid(""))
    }

    func testUnknownMultiCharKeyIsInvalid() {
        XCTAssertFalse(SupportedKeys.isValid("xyz"))
        XCTAssertFalse(SupportedKeys.isValid("f13"))
    }

    func testValidModifiers() {
        XCTAssertTrue(SupportedKeys.isValidModifier("shift"))
        XCTAssertTrue(SupportedKeys.isValidModifier("control"))
        XCTAssertTrue(SupportedKeys.isValidModifier("option"))
        XCTAssertTrue(SupportedKeys.isValidModifier("command"))
        XCTAssertTrue(SupportedKeys.isValidModifier("alt"))
    }

    func testInvalidModifiers() {
        XCTAssertFalse(SupportedKeys.isValidModifier("super"))
        XCTAssertFalse(SupportedKeys.isValidModifier("meta"))
        XCTAssertFalse(SupportedKeys.isValidModifier(""))
    }
}

// MARK: - Input Error MCP Mapping Tests

final class InputErrorMCPMappingTests: XCTestCase {

    func testInvalidKeyMapToInvalidParams() {
        let error = InputError.invalidKey("bad key")
        let mcpErr = PlayCoverMCPError(wrapping: error)
        XCTAssertEqual(mcpErr.code, JSONRPCError.invalidParams)
    }

    func testInvalidTextMapToInvalidParams() {
        let error = InputError.invalidText("empty")
        let mcpErr = PlayCoverMCPError(wrapping: error)
        XCTAssertEqual(mcpErr.code, JSONRPCError.invalidParams)
    }

    func testSessionNotReadyMapToBridgeError() {
        let error = InputError.sessionNotReady("starting")
        let mcpErr = PlayCoverMCPError(wrapping: error)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }

    func testCommandFailedMapToBridgeError() {
        let error = InputError.commandFailed("timeout")
        let mcpErr = PlayCoverMCPError(wrapping: error)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }
}

// MARK: - Fake Input Service Tests

final class FakeInputServiceTests: XCTestCase {

    func testFakePressKeyRecordsCalls() async throws {
        let fake = FakeInputService()
        let params = KeyPressParams(key: "a")
        let result = try await fake.pressKey(sessionId: "s1", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "press_key")
        XCTAssertEqual(result.detail, "a")
        XCTAssertEqual(fake.pressKeyCalls.count, 1)
        XCTAssertEqual(fake.pressKeyCalls.first?.sessionId, "s1")
        XCTAssertEqual(fake.pressKeyCalls.first?.params, params)
    }

    func testFakePressKeyWithModifiersRecordsCalls() async throws {
        let fake = FakeInputService()
        let params = KeyPressParams(key: "c", modifiers: ["command"])
        let result = try await fake.pressKey(sessionId: "s1", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.detail, "command+c")
    }

    func testFakeTypeTextRecordsCalls() async throws {
        let fake = FakeInputService()
        let params = TypeTextParams(text: "Hello")
        let result = try await fake.typeText(sessionId: "s2", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "type_text")
        XCTAssertEqual(result.detail, "5 character(s)")
        XCTAssertEqual(fake.typeTextCalls.count, 1)
        XCTAssertEqual(fake.typeTextCalls.first?.sessionId, "s2")
        XCTAssertEqual(fake.typeTextCalls.first?.params, params)
    }

    func testFakeToggleDebugOverlayRecordsCalls() async throws {
        let fake = FakeInputService()
        let result = try await fake.toggleDebugOverlay(sessionId: "s3")

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.command, "toggle_debug_overlay")
        XCTAssertEqual(result.detail, "toggled")
        XCTAssertEqual(fake.toggleDebugOverlayCalls.count, 1)
        XCTAssertEqual(fake.toggleDebugOverlayCalls.first, "s3")
    }

    func testFakeServiceCanFail() async {
        let fake = FakeInputService()
        fake.setShouldFail(true, message: "test failure")

        do {
            _ = try await fake.pressKey(sessionId: "s1", params: KeyPressParams(key: "a"))
            XCTFail("Should have thrown")
        } catch let error as InputError {
            XCTAssertEqual(error, .commandFailed("test failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFakeTypeTextCanFail() async {
        let fake = FakeInputService()
        fake.setShouldFail(true, message: "type failure")

        do {
            _ = try await fake.typeText(sessionId: "s1", params: TypeTextParams(text: "hello"))
            XCTFail("Should have thrown")
        } catch let error as InputError {
            XCTAssertEqual(error, .commandFailed("type failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFakeToggleDebugOverlayCanFail() async {
        let fake = FakeInputService()
        fake.setShouldFail(true, message: "toggle failure")

        do {
            _ = try await fake.toggleDebugOverlay(sessionId: "s1")
            XCTFail("Should have thrown")
        } catch let error as InputError {
            XCTAssertEqual(error, .commandFailed("toggle failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Input Service Validation Tests

final class InputServiceValidationTests: XCTestCase {

    private var registry: SessionRegistry!
    private var service: InputService!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        service = InputService(registry: registry) { sessionId, port in
            BridgeClient(sessionId: sessionId, port: port)
        }
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        service = nil
        super.tearDown()
    }

    func testPressKeyWithEmptyKeyThrows() async {
        do {
            _ = try await service.pressKey(sessionId: "s1", params: KeyPressParams(key: ""))
            XCTFail("Should throw on empty key")
        } catch let error as InputError {
            if case .invalidKey = error { } else {
                XCTFail("Expected invalidKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPressKeyWithUnknownKeyThrows() async {
        do {
            _ = try await service.pressKey(sessionId: "s1", params: KeyPressParams(key: "unknownkey"))
            XCTFail("Should throw on unknown key")
        } catch let error as InputError {
            if case .invalidKey = error { } else {
                XCTFail("Expected invalidKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPressKeyWithInvalidModifierThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        do {
            _ = try await service.pressKey(sessionId: "s1", params: KeyPressParams(key: "a", modifiers: ["super"]))
            XCTFail("Should throw on invalid modifier")
        } catch let error as InputError {
            if case .invalidKey = error { } else {
                XCTFail("Expected invalidKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTypeTextWithEmptyTextThrows() async {
        do {
            _ = try await service.typeText(sessionId: "s1", params: TypeTextParams(text: ""))
            XCTFail("Should throw on empty text")
        } catch let error as InputError {
            if case .invalidText = error { } else {
                XCTFail("Expected invalidText, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTypeTextWithExcessiveLengthThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        let longText = String(repeating: "a", count: 10_001)
        do {
            _ = try await service.typeText(sessionId: "s1", params: TypeTextParams(text: longText))
            XCTFail("Should throw on excessive text length")
        } catch let error as InputError {
            if case .invalidText = error { } else {
                XCTFail("Expected invalidText, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPressKeySessionNotFoundThrows() async {
        do {
            _ = try await service.pressKey(sessionId: "nonexistent", params: KeyPressParams(key: "a"))
            XCTFail("Should throw session not found")
        } catch let error as SessionError {
            if case .sessionNotFound = error { } else {
                XCTFail("Expected sessionNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPressKeySessionNotReadyThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .starting)
        try registry.register(info)

        do {
            _ = try await service.pressKey(sessionId: "s1", params: KeyPressParams(key: "a"))
            XCTFail("Should throw session not ready")
        } catch let error as InputError {
            if case .sessionNotReady = error { } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testToggleDebugOverlaySessionNotFoundThrows() async {
        do {
            _ = try await service.toggleDebugOverlay(sessionId: "nonexistent")
            XCTFail("Should throw session not found")
        } catch let error as SessionError {
            if case .sessionNotFound = error { } else {
                XCTFail("Expected sessionNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Input Command Encoding Tests

final class InputCommandEncodingTests: XCTestCase {

    func testPressKeyCommandEncoding() throws {
        let params = AnyCodable(["key": "enter", "modifiers": ["command"]] as [String: Any])
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-1",
            command: "press_key",
            params: params
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "press_key")
        XCTAssertEqual(json["sessionId"] as? String, "s1")

        let cmdParams = json["params"] as? [String: Any]
        XCTAssertEqual(cmdParams?["key"] as? String, "enter")
    }

    func testTypeTextCommandEncoding() throws {
        let params = AnyCodable(["text": "Hello World"] as [String: Any])
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-2",
            command: "type_text",
            params: params
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "type_text")

        let cmdParams = json["params"] as? [String: Any]
        XCTAssertEqual(cmdParams?["text"] as? String, "Hello World")
    }

    func testToggleDebugOverlayCommandEncoding() throws {
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-3",
            command: "toggle_debug_overlay",
            params: nil
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "toggle_debug_overlay")
    }
}

// MARK: - Input Tools Registration Tests

final class InputToolsRegistrationTests: XCTestCase {

    private var server: MCPServer!
    private var fakeInputService: FakeInputService!

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
        fakeInputService = FakeInputService()
        InputTools.register(on: server, inputService: fakeInputService)
    }

    override func tearDown() {
        server = nil
        fakeInputService = nil
        super.tearDown()
    }

    func testInputToolsRegistered() {
        let tools = server.toolRegistry.listTools()
        let toolNames = tools.map(\.name)
        XCTAssertTrue(toolNames.contains("press_key"))
        XCTAssertTrue(toolNames.contains("type_text"))
        XCTAssertTrue(toolNames.contains("toggle_debug_overlay"))
    }

    func testPressKeyToolSchema() {
        let tools = server.toolRegistry.listTools()
        let tool = tools.first { $0.name == "press_key" }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.inputSchema.required, ["sessionId", "key"])
    }

    func testTypeTextToolSchema() {
        let tools = server.toolRegistry.listTools()
        let tool = tools.first { $0.name == "type_text" }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.inputSchema.required, ["sessionId", "text"])
    }

    func testToggleDebugOverlayToolSchema() {
        let tools = server.toolRegistry.listTools()
        let tool = tools.first { $0.name == "toggle_debug_overlay" }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.inputSchema.required, ["sessionId"])
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

    // MARK: - press_key tool call tests

    func testPressKeyToolCallSuccess() {
        let resp = callTool("press_key", arguments: [
            "sessionId": "s1",
            "key": "enter"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeInputService.pressKeyCalls.count, 1)
    }

    func testPressKeyToolCallWithModifiers() {
        let resp = callTool("press_key", arguments: [
            "sessionId": "s1",
            "key": "c",
            "modifiers": ["command"]
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeInputService.pressKeyCalls.first?.params.modifiers, ["command"])
    }

    func testPressKeyToolMissingSessionId() {
        let resp = callTool("press_key", arguments: [
            "key": "a"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testPressKeyToolMissingKey() {
        let resp = callTool("press_key", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testPressKeyToolEmptySessionId() {
        let resp = callTool("press_key", arguments: [
            "sessionId": "",
            "key": "a"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testPressKeyToolServiceFailure() {
        fakeInputService.setShouldFail(true, message: "runtime down")
        let resp = callTool("press_key", arguments: [
            "sessionId": "s1",
            "key": "a"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }

    // MARK: - type_text tool call tests

    func testTypeTextToolCallSuccess() {
        let resp = callTool("type_text", arguments: [
            "sessionId": "s1",
            "text": "Hello"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeInputService.typeTextCalls.count, 1)
        XCTAssertEqual(fakeInputService.typeTextCalls.first?.params.text, "Hello")
    }

    func testTypeTextToolMissingSessionId() {
        let resp = callTool("type_text", arguments: [
            "text": "Hello"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTypeTextToolMissingText() {
        let resp = callTool("type_text", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTypeTextToolEmptyText() {
        let resp = callTool("type_text", arguments: [
            "sessionId": "s1",
            "text": ""
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testTypeTextToolServiceFailure() {
        fakeInputService.setShouldFail(true, message: "type failed")
        let resp = callTool("type_text", arguments: [
            "sessionId": "s1",
            "text": "Hello"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }

    // MARK: - toggle_debug_overlay tool call tests

    func testToggleDebugOverlayToolCallSuccess() {
        let resp = callTool("toggle_debug_overlay", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeInputService.toggleDebugOverlayCalls.count, 1)
        XCTAssertEqual(fakeInputService.toggleDebugOverlayCalls.first, "s1")
    }

    func testToggleDebugOverlayToolMissingSessionId() {
        let resp = callTool("toggle_debug_overlay", arguments: [:])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testToggleDebugOverlayToolEmptySessionId() {
        let resp = callTool("toggle_debug_overlay", arguments: [
            "sessionId": ""
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testToggleDebugOverlayToolServiceFailure() {
        fakeInputService.setShouldFail(true, message: "toggle failed")
        let resp = callTool("toggle_debug_overlay", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }
}

// MARK: - Input Bridge Integration Tests

final class InputBridgeIntegrationTests: XCTestCase {

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

    func testPressKeyThroughFakeRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.input.test", sessionId: "input-sess-1")
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "press_key")
            XCTAssertNotNil(payload.params)
            let params = payload.params?.dictionary
            XCTAssertEqual(params?["key"] as? String, "enter")

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

        guard let session = registry.get("input-sess-1") else {
            XCTFail("Session should be registered")
            return
        }
        XCTAssertEqual(session.status, .ready)

        let inputService = InputService(registry: registry)

        let done = expectation(description: "press_key done")
        Task {
            do {
                let result = try await inputService.pressKey(
                    sessionId: "input-sess-1",
                    params: KeyPressParams(key: "enter")
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "press_key")
                done.fulfill()
            } catch {
                XCTFail("press_key failed: \(error)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "press_key")

        fakeRuntime.stop()
    }

    func testTypeTextThroughFakeRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.input.test2", sessionId: "input-sess-2")
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "type_text")
            XCTAssertNotNil(payload.params)
            let params = payload.params?.dictionary
            XCTAssertEqual(params?["text"] as? String, "Hello World")

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

        let inputService = InputService(registry: registry)

        let done = expectation(description: "type_text done")
        Task {
            do {
                let result = try await inputService.typeText(
                    sessionId: "input-sess-2",
                    params: TypeTextParams(text: "Hello World")
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "type_text")
                XCTAssertEqual(result.detail, "11 character(s)")
                done.fulfill()
            } catch {
                XCTFail("type_text failed: \(error)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "type_text")

        fakeRuntime.stop()
    }

    func testToggleDebugOverlayThroughFakeRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.input.test3", sessionId: "input-sess-3")
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "toggle_debug_overlay")

            return CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "ok",
                result: AnyCodable(["toggled": true] as [String: Any])
            )
        }

        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        let inputService = InputService(registry: registry)

        let done = expectation(description: "toggle done")
        Task {
            do {
                let result = try await inputService.toggleDebugOverlay(sessionId: "input-sess-3")
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "toggle_debug_overlay")
                done.fulfill()
            } catch {
                XCTFail("toggle_debug_overlay failed: \(error)")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "toggle_debug_overlay")

        fakeRuntime.stop()
    }

    func testPressKeyToNonExistentSessionFails() async throws {
        let inputService = InputService(registry: registry)

        do {
            _ = try await inputService.pressKey(
                sessionId: "nonexistent",
                params: KeyPressParams(key: "a")
            )
            XCTFail("Should have thrown")
        } catch let error as SessionError {
            if case .sessionNotFound = error { } else {
                XCTFail("Expected sessionNotFound, got \(error)")
            }
        }
    }
}
