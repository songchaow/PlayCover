// CaptureToolsTests.swift
// PlayCoverMCPTests

import Foundation
import XCTest

// MARK: - Capture Parameter Tests

final class CaptureParamsTests: XCTestCase {

    func testCaptureFrameParamsDefaults() {
        let params = CaptureFrameParams()
        XCTAssertNil(params.outputPath)
        XCTAssertEqual(params.durationMs, 100)
        XCTAssertEqual(params.captureTarget, .queueScope)
    }

    func testCaptureFrameParamsCustomValues() {
        let params = CaptureFrameParams(
            outputPath: "/tmp/test.gputrace",
            durationMs: 500,
            captureTarget: .scope
        )
        XCTAssertEqual(params.outputPath, "/tmp/test.gputrace")
        XCTAssertEqual(params.durationMs, 500)
        XCTAssertEqual(params.captureTarget, .scope)
    }

    func testCaptureFrameParamsCodable() throws {
        let original = CaptureFrameParams(
            outputPath: "/tmp/test.gputrace",
            durationMs: 200,
            captureTarget: .scope
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureFrameParams.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCaptureFrameParamsWithoutOutputPathCodable() throws {
        let original = CaptureFrameParams(durationMs: 150)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureFrameParams.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.captureTarget, .queueScope)
    }
}

// MARK: - Capture Result Tests

final class CaptureResultTests: XCTestCase {

    func testCaptureFrameResultToDictionary() {
        let result = CaptureFrameResult(
            success: true,
            outputPath: "/tmp/capture.gputrace",
            message: "Capture completed"
        )
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["output_path"] as? String, "/tmp/capture.gputrace")
        XCTAssertEqual(dict["message"] as? String, "Capture completed")
    }

    func testCaptureFrameResultWithoutOutputPath() {
        let result = CaptureFrameResult(success: false, message: "Capture failed")
        let dict = result.toDictionary()

        XCTAssertEqual(dict["success"] as? Bool, false)
        XCTAssertNil(dict["output_path"])
        XCTAssertEqual(dict["message"] as? String, "Capture failed")
    }

    func testCaptureFrameResultCodable() throws {
        let original = CaptureFrameResult(
            success: true,
            outputPath: "/tmp/test.gputrace",
            message: "OK"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureFrameResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCaptureStatusResultToDictionary() {
        let result = CaptureStatusResult(
            available: true,
            supportsGpuTrace: true,
            isCapturing: false,
            enabled: true
        )
        let dict = result.toDictionary()

        XCTAssertEqual(dict["available"] as? Bool, true)
        XCTAssertEqual(dict["supports_gpu_trace"] as? Bool, true)
        XCTAssertEqual(dict["is_capturing"] as? Bool, false)
        XCTAssertEqual(dict["enabled"] as? Bool, true)
    }

    func testCaptureStatusResultCodable() throws {
        let original = CaptureStatusResult(
            available: true,
            supportsGpuTrace: false,
            isCapturing: true,
            enabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureStatusResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Capture Error Tests

final class CaptureErrorTests: XCTestCase {

    func testInvalidDurationDescription() {
        let error = CaptureError.invalidDuration("must be positive")
        XCTAssertEqual(error.localizedDescription, "Invalid capture duration: must be positive")
    }

    func testSessionNotReadyDescription() {
        let error = CaptureError.sessionNotReady("session is starting")
        XCTAssertEqual(error.localizedDescription, "Session not ready for capture: session is starting")
    }

    func testCommandFailedDescription() {
        let error = CaptureError.commandFailed("runtime rejected")
        XCTAssertEqual(error.localizedDescription, "Capture command failed: runtime rejected")
    }

    func testCaptureNotAvailableDescription() {
        let error = CaptureError.captureNotAvailable("MTLCaptureManager not found")
        XCTAssertEqual(error.localizedDescription, "Metal capture not available: MTLCaptureManager not found")
    }

    func testCaptureErrorEquality() {
        XCTAssertEqual(
            CaptureError.commandFailed("test"),
            CaptureError.commandFailed("test")
        )
        XCTAssertNotEqual(
            CaptureError.commandFailed("a"),
            CaptureError.commandFailed("b")
        )
    }
}

// MARK: - Capture Error MCP Mapping Tests

final class CaptureErrorMCPMappingTests: XCTestCase {

    func testInvalidDurationMapToInvalidParams() {
        let captureErr = CaptureError.invalidDuration("zero")
        let mcpErr = PlayCoverMCPError(wrapping: captureErr)
        XCTAssertEqual(mcpErr.code, JSONRPCError.invalidParams)
    }

    func testCommandFailedMapToBridgeError() {
        let captureErr = CaptureError.commandFailed("timeout")
        let mcpErr = PlayCoverMCPError(wrapping: captureErr)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }

    func testSessionNotReadyMapToBridgeError() {
        let captureErr = CaptureError.sessionNotReady("starting")
        let mcpErr = PlayCoverMCPError(wrapping: captureErr)
        XCTAssertEqual(mcpErr.code, PlayCoverErrorCode.bridgeError.rawValue)
    }
}

// MARK: - Fake Capture Service Tests

final class FakeCaptureServiceTests: XCTestCase {

    func testFakeCaptureFrameRecordsCalls() async throws {
        let fake = FakeCaptureService()
        let params = CaptureFrameParams(outputPath: "/tmp/test.gputrace", durationMs: 200, captureTarget: .scope)
        let result = try await fake.captureFrame(sessionId: "s1", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputPath, "/tmp/test.gputrace")
        XCTAssertEqual(fake.captureFrameCalls.count, 1)
        XCTAssertEqual(fake.captureFrameCalls.first?.sessionId, "s1")
        XCTAssertEqual(fake.captureFrameCalls.first?.params, params)
    }

    func testFakeCaptureFrameDefaultOutputPath() async throws {
        let fake = FakeCaptureService()
        let params = CaptureFrameParams(durationMs: 100)
        let result = try await fake.captureFrame(sessionId: "s1", params: params)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputPath, "/tmp/capture.gputrace")
    }

    func testFakeGetCaptureStatusRecordsCalls() async throws {
        let fake = FakeCaptureService()
        let result = try await fake.getCaptureStatus(sessionId: "s2")

        XCTAssertTrue(result.available)
        XCTAssertTrue(result.supportsGpuTrace)
        XCTAssertFalse(result.isCapturing)
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(fake.getCaptureStatusCalls.count, 1)
        XCTAssertEqual(fake.getCaptureStatusCalls.first, "s2")
    }

    func testFakeGetCaptureStatusCustomResult() async throws {
        let fake = FakeCaptureService()
        fake.setStatusResult(CaptureStatusResult(
            available: false, supportsGpuTrace: false, isCapturing: false, enabled: false
        ))
        let result = try await fake.getCaptureStatus(sessionId: "s3")

        XCTAssertFalse(result.available)
        XCTAssertFalse(result.supportsGpuTrace)
        XCTAssertFalse(result.enabled)
    }

    func testFakeCaptureServiceCanFail() async {
        let fake = FakeCaptureService()
        fake.setShouldFail(true, message: "test failure")

        do {
            _ = try await fake.captureFrame(sessionId: "s1", params: CaptureFrameParams())
            XCTFail("Should have thrown")
        } catch let error as CaptureError {
            XCTAssertEqual(error, .commandFailed("test failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFakeGetCaptureStatusCanFail() async {
        let fake = FakeCaptureService()
        fake.setShouldFail(true, message: "status failure")

        do {
            _ = try await fake.getCaptureStatus(sessionId: "s1")
            XCTFail("Should have thrown")
        } catch let error as CaptureError {
            XCTAssertEqual(error, .commandFailed("status failure"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Capture Service Validation Tests

final class CaptureServiceValidationTests: XCTestCase {

    private var registry: SessionRegistry!
    private var service: CaptureService!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        service = CaptureService(registry: registry) { sessionId, port in
            BridgeClient(sessionId: sessionId, port: port)
        }
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        service = nil
        super.tearDown()
    }

    func testCaptureFrameWithZeroDurationThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        do {
            _ = try await service.captureFrame(sessionId: "s1", params: CaptureFrameParams(durationMs: 0))
            XCTFail("Should throw on zero duration")
        } catch let error as CaptureError {
            if case .invalidDuration = error {
                // Expected
            } else {
                XCTFail("Expected invalidDuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCaptureFrameWithExcessiveDurationThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        do {
            _ = try await service.captureFrame(sessionId: "s1", params: CaptureFrameParams(durationMs: 60_000))
            XCTFail("Should throw on excessive duration")
        } catch let error as CaptureError {
            if case .invalidDuration = error {
                // Expected
            } else {
                XCTFail("Expected invalidDuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCaptureFrameSessionNotFoundThrows() async {
        do {
            _ = try await service.captureFrame(sessionId: "nonexistent", params: CaptureFrameParams())
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

    func testCaptureFrameSessionNotReadyThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .starting)
        try registry.register(info)

        do {
            _ = try await service.captureFrame(sessionId: "s1", params: CaptureFrameParams())
            XCTFail("Should throw session not ready")
        } catch let error as CaptureError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetCaptureStatusSessionNotFoundThrows() async {
        do {
            _ = try await service.getCaptureStatus(sessionId: "nonexistent")
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

    func testGetCaptureStatusSessionNotReadyThrows() async throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .disconnected)
        try registry.register(info)

        do {
            _ = try await service.getCaptureStatus(sessionId: "s1")
            XCTFail("Should throw session not ready")
        } catch let error as CaptureError {
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

// MARK: - Capture Command Encoding Tests

final class CaptureCommandEncodingTests: XCTestCase {

    func testCaptureFrameCommandEncoding() throws {
        let params = AnyCodable([
            "duration_ms": 200,
            "output_path": "/tmp/test.gputrace",
            "capture_target": "queue_scope"
        ] as [String: Any])
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-1",
            command: BridgeCommandName.captureFrame,
            params: params
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "capture_frame")
        XCTAssertEqual(json["sessionId"] as? String, "s1")

        let cmdParams = json["params"] as? [String: Any]
        XCTAssertNotNil(cmdParams?["duration_ms"])
        XCTAssertEqual(cmdParams?["output_path"] as? String, "/tmp/test.gputrace")
        XCTAssertEqual(cmdParams?["capture_target"] as? String, "queue_scope")
    }

    func testGetCaptureStatusCommandEncoding() throws {
        let command = CommandPayload(
            sessionId: "s1",
            commandId: "cmd-2",
            command: BridgeCommandName.getCaptureStatus
        )
        let message = BridgeMessage.command(command)

        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "get_capture_status")
    }

    func testCaptureFrameResponseDecoding() throws {
        let response = CommandResponsePayload(
            sessionId: "s1",
            commandId: "cmd-1",
            status: "ok",
            result: AnyCodable([
                "output_path": "/tmp/capture.gputrace",
                "message": "Capture completed"
            ] as [String: Any])
        )
        let message = BridgeMessage.commandResponse(response)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        if case .commandResponse(let payload) = decoded {
            XCTAssertEqual(payload.status, "ok")
            XCTAssertEqual(payload.commandId, "cmd-1")
            let result = payload.result?.dictionary
            XCTAssertEqual(result?["output_path"] as? String, "/tmp/capture.gputrace")
        } else {
            XCTFail("Expected commandResponse")
        }
    }
}

// MARK: - Capture Tools Registration Tests

final class CaptureToolsRegistrationTests: XCTestCase {

    private var server: MCPServer!
    private var fakeCaptureService: FakeCaptureService!

    override func setUp() {
        super.setUp()
        let logger = MCPLogger(minLevel: .info)
        let taskManager = TaskManager()
        server = MCPServer(
            serverInfo: Implementation(name: "test", version: "0.0.1"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(listChanged: false),
                resources: ResourceCapabilities(subscribe: false, listChanged: false),
                logging: EmptyCapability(),
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            logger: logger,
            taskManager: taskManager
        )
        fakeCaptureService = FakeCaptureService()
        CaptureTools.register(on: server, captureService: fakeCaptureService)
    }

    override func tearDown() {
        server = nil
        fakeCaptureService = nil
        super.tearDown()
    }

    func testCaptureToolsRegistered() {
        let tools = server.toolRegistry.listTools()
        let toolNames = tools.map(\.name)
        XCTAssertTrue(toolNames.contains("capture_metal_frame"))
        XCTAssertTrue(toolNames.contains("get_capture_status"))
    }

    func testCaptureMetalFrameToolSchema() {
        let tools = server.toolRegistry.listTools()
        let captureTool = tools.first { $0.name == "capture_metal_frame" }
        XCTAssertNotNil(captureTool)
        XCTAssertEqual(captureTool?.inputSchema.required, ["sessionId"])
        XCTAssertNotNil(captureTool?.inputSchema.properties?["sessionId"])
        XCTAssertNotNil(captureTool?.inputSchema.properties?["output_path"])
        XCTAssertNotNil(captureTool?.inputSchema.properties?["duration_ms"])
        XCTAssertNotNil(captureTool?.inputSchema.properties?["capture_target"])

        let captureTargetProperty = captureTool?.inputSchema.properties?["capture_target"]?.value as? [String: Any]
        let supportedTargets = captureTargetProperty?["enum"] as? [String]
        XCTAssertEqual(supportedTargets, ["device", "scope", "queue", "queue_scope"])
    }

    func testGetCaptureStatusToolSchema() {
        let tools = server.toolRegistry.listTools()
        let statusTool = tools.first { $0.name == "get_capture_status" }
        XCTAssertNotNil(statusTool)
        XCTAssertEqual(statusTool?.inputSchema.required, ["sessionId"])
        XCTAssertNotNil(statusTool?.inputSchema.properties?["sessionId"])
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

    private func toolTextContent(from response: JSONRPCResponse?) -> String? {
        let content = response?.result?.dictionary?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }

    // MARK: - capture_metal_frame tool call tests

    func testCaptureMetalFrameToolCallSuccess() {
        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.count, 1)
    }

    func testCaptureMetalFrameToolCallWithCustomParams() {
        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": "s1",
            "output_path": "/tmp/custom.gputrace",
            "duration_ms": 500,
            "capture_target": "queue_scope"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.count, 1)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.first?.params.outputPath, "/tmp/custom.gputrace")
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.first?.params.durationMs, 500)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.first?.params.captureTarget, .queueScope)
    }

    func testCaptureMetalFrameToolCallDefaultDuration() {
        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.first?.params.durationMs, 100)
        XCTAssertEqual(fakeCaptureService.captureFrameCalls.first?.params.captureTarget, .queueScope)
    }

    func testCaptureMetalFrameToolMissingSessionId() {
        let resp = callTool("capture_metal_frame", arguments: [:])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testCaptureMetalFrameToolEmptySessionId() {
        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": ""
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testCaptureMetalFrameToolInvalidCaptureTarget() {
        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": "s1",
            "capture_target": "banana"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testCaptureMetalFrameToolServiceFailure() {
        fakeCaptureService.setShouldFail(true, message: "capture failed")

        let resp = callTool("capture_metal_frame", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }

    // MARK: - get_capture_status tool call tests

    func testGetCaptureStatusToolCallSuccess() {
        let resp = callTool("get_capture_status", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertEqual(fakeCaptureService.getCaptureStatusCalls.count, 1)
    }

    func testGetCaptureStatusToolCallIncludesDiagnostics() throws {
        fakeCaptureService.setStatusResult(CaptureStatusResult(
            available: true,
            supportsGpuTrace: false,
            isCapturing: false,
            enabled: true,
            supportsDeveloperTools: true,
            hasDefaultDevice: true,
            defaultDeviceName: "Apple M4",
            failureReason: "gpu_trace_document_unsupported",
            diagnosticSummary: "enabled=true, captureManagerAvailable=true, supportsGPUTrace=false",
            queueDiscoveryInstalled: true,
            trackedCommandQueueCount: 2,
            latestCommandQueueLabel: "main-render-queue",
            latestCommandQueueDeviceName: "Apple M4",
            latestCommandQueueClassName: "AGXMetalG17XFamilyCommandQueue",
            defaultCaptureScopeLabel: "qqfc.default.scope",
            mostActiveCommandQueueLabel: "main-render-queue",
            mostActiveCommandQueueDeviceName: "Apple M4",
            mostActiveCommandQueueClassName: "CaptureMTLCommandQueue",
            mostActiveCommandQueueSummary: "class=CaptureMTLCommandQueue, commandBufferCommits=9",
            trackedCommandQueues: [
                TrackedCommandQueueActivityResult(
                    source: "newCommandQueue",
                    className: "CaptureMTLCommandQueue",
                    label: "main-render-queue",
                    deviceName: "Apple M4",
                    discoveryCount: 2,
                    rankingScore: 50,
                    commandBufferCreationCount: 12,
                    commandBufferCommitCount: 9,
                    activityScore: 1200,
                    summary: "class=CaptureMTLCommandQueue, label=main-render-queue",
                    activitySummary: "class=CaptureMTLCommandQueue, commandBufferCommits=9"
                )
            ]
        ))

        let resp = callTool("get_capture_status", arguments: [
            "sessionId": "s1"
        ])

        let text = try XCTUnwrap(toolTextContent(from: resp))
        let data = try XCTUnwrap(text.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["supports_gpu_trace"] as? Bool, false)
        XCTAssertEqual(json["supports_developer_tools"] as? Bool, true)
        XCTAssertEqual(json["has_default_device"] as? Bool, true)
        XCTAssertEqual(json["default_device_name"] as? String, "Apple M4")
        XCTAssertEqual(json["failure_reason"] as? String, "gpu_trace_document_unsupported")
        XCTAssertEqual(json["diagnostic_summary"] as? String, "enabled=true, captureManagerAvailable=true, supportsGPUTrace=false")
        XCTAssertEqual(json["most_active_command_queue_label"] as? String, "main-render-queue")
        let trackedQueues = try XCTUnwrap(json["tracked_command_queues"] as? [[String: Any]])
        XCTAssertEqual(trackedQueues.count, 1)
        XCTAssertEqual(trackedQueues[0]["command_buffer_commit_count"] as? Int, 9)
    }

    func testGetCaptureStatusToolMissingSessionId() {
        let resp = callTool("get_capture_status", arguments: [:])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testGetCaptureStatusToolEmptySessionId() {
        let resp = callTool("get_capture_status", arguments: [
            "sessionId": ""
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }

    func testGetCaptureStatusToolServiceFailure() {
        fakeCaptureService.setShouldFail(true, message: "status failed")

        let resp = callTool("get_capture_status", arguments: [
            "sessionId": "s1"
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
    }
}
