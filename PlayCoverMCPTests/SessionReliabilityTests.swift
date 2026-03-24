// SessionReliabilityTests.swift
// PlayCoverMCPTests
//
// S05: Session reliability, timeout, disconnect, and E2E smoke tests.

import Foundation
import XCTest
import Network

// MARK: - Session Health Monitor Tests

final class SessionHealthMonitorTests: XCTestCase {

    private var registry: SessionRegistry!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        super.tearDown()
    }

    func testMonitorStartStop() {
        let monitor = SessionHealthMonitor(registry: registry, staleTimeout: 5.0)
        XCTAssertFalse(monitor.isRunning)

        monitor.start(interval: 1.0)
        XCTAssertTrue(monitor.isRunning)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testMonitorRemovesStaleSessions() throws {
        // Register a stale session (heartbeat 100 seconds ago)
        let staleInfo = SessionInfo(
            sessionId: "stale-1",
            bundleId: "com.stale",
            pid: 100,
            runtimePort: 52742,
            createdAt: Date().addingTimeInterval(-100),
            lastHeartbeat: Date().addingTimeInterval(-100),
            status: .ready
        )
        try registry.register(staleInfo)

        // Register a fresh session
        let freshInfo = SessionInfo(
            sessionId: "fresh-1",
            bundleId: "com.fresh",
            pid: 200,
            runtimePort: 52743,
            status: .ready
        )
        try registry.register(freshInfo)

        XCTAssertEqual(registry.count, 2)

        let monitor = SessionHealthMonitor(registry: registry, staleTimeout: 10.0)

        let removed = expectation(description: "stale session removed")
        monitor.onStaleSessions = { sessions in
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions.first?.sessionId, "stale-1")
            removed.fulfill()
        }

        // Manually trigger health check
        monitor.checkHealth()

        wait(for: [removed], timeout: 2.0)

        XCTAssertEqual(registry.count, 1)
        XCTAssertNotNil(registry.get("fresh-1"))
        XCTAssertNil(registry.get("stale-1"))
    }

    func testMonitorDoesNothingWhenNoStaleSessions() throws {
        let freshInfo = SessionInfo(
            sessionId: "fresh-1",
            bundleId: "com.fresh",
            pid: 100,
            runtimePort: 52742,
            status: .ready
        )
        try registry.register(freshInfo)

        let monitor = SessionHealthMonitor(registry: registry, staleTimeout: 30.0)

        var callbackInvoked = false
        monitor.onStaleSessions = { _ in
            callbackInvoked = true
        }

        monitor.checkHealth()

        XCTAssertFalse(callbackInvoked)
        XCTAssertEqual(registry.count, 1)
    }

    func testMonitorPeriodicCheck() throws {
        let staleInfo = SessionInfo(
            sessionId: "stale-periodic",
            bundleId: "com.stale",
            pid: 100,
            runtimePort: 52742,
            createdAt: Date().addingTimeInterval(-100),
            lastHeartbeat: Date().addingTimeInterval(-100),
            status: .ready
        )
        try registry.register(staleInfo)

        let monitor = SessionHealthMonitor(registry: registry, staleTimeout: 5.0)

        let removed = expectation(description: "stale session removed by periodic check")
        monitor.onStaleSessions = { sessions in
            if sessions.contains(where: { $0.sessionId == "stale-periodic" }) {
                removed.fulfill()
            }
        }

        // Start periodic check with short interval
        monitor.start(interval: 0.5)

        wait(for: [removed], timeout: 3.0)

        monitor.stop()

        XCTAssertEqual(registry.count, 0)
    }
}

// MARK: - Registration Listener Disconnect Tests

final class RegistrationListenerDisconnectTests: XCTestCase {

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

    func testRuntimeDisconnectUpdatesStatus() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.disconnect.test", sessionId: "disc-sess-1")
        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Verify session is ready
        XCTAssertEqual(registry.get("disc-sess-1")?.status, .ready)

        // Stop the runtime (sends close message)
        fakeRuntime.stop()

        // Wait for cleanup
        let cleanup = expectation(description: "cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cleanup.fulfill() }
        wait(for: [cleanup], timeout: 2.0)

        // Session should have been unregistered by close message handler
        XCTAssertNil(registry.get("disc-sess-1"))
    }
}

// MARK: - Session Closed Error Tests

final class SessionClosedErrorTests: XCTestCase {

    private var registry: SessionRegistry!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        super.tearDown()
    }

    func testTouchOnClosedSessionThrows() async throws {
        let info = SessionInfo(
            sessionId: "closed-1",
            bundleId: "com.closed",
            pid: 100,
            runtimePort: 52742,
            status: .closed
        )
        try registry.register(info)

        let touchService = TouchService(registry: registry)

        do {
            _ = try await touchService.tap(
                sessionId: "closed-1",
                params: TapParams(x: 100, y: 100)
            )
            XCTFail("Should throw on closed session")
        } catch let error as TouchError {
            if case .sessionNotReady = error {
                // Expected: session is closed, not ready
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        }
    }

    func testTouchOnDisconnectedSessionThrows() async throws {
        let info = SessionInfo(
            sessionId: "disc-1",
            bundleId: "com.disc",
            pid: 100,
            runtimePort: 52742,
            status: .disconnected
        )
        try registry.register(info)

        let touchService = TouchService(registry: registry)

        do {
            _ = try await touchService.tap(
                sessionId: "disc-1",
                params: TapParams(x: 100, y: 100)
            )
            XCTFail("Should throw on disconnected session")
        } catch let error as TouchError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        }
    }

    func testInputOnClosedSessionThrows() async throws {
        let info = SessionInfo(
            sessionId: "closed-2",
            bundleId: "com.closed",
            pid: 100,
            runtimePort: 52742,
            status: .closed
        )
        try registry.register(info)

        let inputService = InputService(registry: registry)

        do {
            _ = try await inputService.pressKey(
                sessionId: "closed-2",
                params: KeyPressParams(key: "a")
            )
            XCTFail("Should throw on closed session")
        } catch let error as InputError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        }
    }

    func testInputOnDisconnectedSessionThrows() async throws {
        let info = SessionInfo(
            sessionId: "disc-2",
            bundleId: "com.disc",
            pid: 100,
            runtimePort: 52742,
            status: .disconnected
        )
        try registry.register(info)

        let inputService = InputService(registry: registry)

        do {
            _ = try await inputService.pressKey(
                sessionId: "disc-2",
                params: KeyPressParams(key: "enter")
            )
            XCTFail("Should throw on disconnected session")
        } catch let error as InputError {
            if case .sessionNotReady = error {
                // Expected
            } else {
                XCTFail("Expected sessionNotReady, got \(error)")
            }
        }
    }

    func testCloseSessionAfterDisconnect() throws {
        let info = SessionInfo(
            sessionId: "disc-close-1",
            bundleId: "com.disc",
            pid: 100,
            runtimePort: 52742,
            status: .disconnected
        )
        try registry.register(info)

        let service = SessionService(registry: registry)

        // Should be able to close a disconnected session
        let closed = try service.closeSession(sessionId: "disc-close-1")
        XCTAssertEqual(closed.sessionId, "disc-close-1")
        XCTAssertNil(registry.get("disc-close-1"))
    }
}

// MARK: - Bridge Client Timeout Tests

final class BridgeClientTimeoutTests: XCTestCase {

    func testConnectionTimeoutToUnresponsiveHost() async {
        // Try to connect to a port where nothing is listening
        let client = BridgeClient(sessionId: "timeout-test", port: 1)
        do {
            try await client.connect(timeout: 1.0)
            XCTFail("Should have thrown on connection timeout")
        } catch {
            // Expected: timeout or connection refused
        }
        XCTAssertFalse(client.isConnected)
    }

    func testSendCommandTimeoutWhenRuntimeDoesNotRespond() async throws {
        // Start a TCP listener that accepts connections but never responds
        guard let nwPort = NWEndpoint.Port(rawValue: 0) else {
            XCTFail("Cannot create port")
            return
        }
        let silentListener = try NWListener(using: .tcp, on: nwPort)
        let listenerQueue = DispatchQueue(label: "com.test.silent-listener")

        let ready = expectation(description: "listener ready")
        var boundPort: UInt16 = 0

        silentListener.stateUpdateHandler = { state in
            if case .ready = state {
                if let port = silentListener.port?.rawValue {
                    boundPort = port
                    ready.fulfill()
                }
            }
        }
        silentListener.newConnectionHandler = { connection in
            connection.start(queue: listenerQueue)
            // Accept the connection but never respond — simulate unresponsive runtime
        }
        silentListener.start(queue: listenerQueue)

        await fulfillment(of: [ready], timeout: 3.0)

        let client = BridgeClient(sessionId: "timeout-test", port: boundPort)
        try await client.connect(timeout: 2.0)
        XCTAssertTrue(client.isConnected)

        // Try to send a command — should timeout because the "runtime" never responds
        do {
            _ = try await client.sendCommand("test", timeout: 1.0)
            XCTFail("Should have timed out")
        } catch {
            // Expected: timeout
        }

        client.close()
        silentListener.cancel()
    }
}

// MARK: - Session E2E Smoke Tests (with Fake Runtime)

final class SessionE2ESmokeTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!
    private var sessionService: SessionService!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(port: 0, registry: registry)
        sessionService = SessionService(registry: registry)

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

        SessionTools.register(on: server, sessionService: sessionService)
        SessionResources.register(on: server, sessionService: sessionService)
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        sessionService = nil
        server = nil
        super.tearDown()
    }

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

    /// Complete E2E smoke: register runtime -> create session -> tap -> type_text -> close
    func testSessionE2ESmoke_RegisterTapTypeClose() throws {
        let port = try registrationListener.start()

        // Register fake touch + input services on the server
        let touchService = TouchService(registry: registry)
        let inputService = InputService(registry: registry)
        TouchTools.register(on: server, touchService: touchService)
        InputTools.register(on: server, inputService: inputService)

        // Step 1: Start fake runtime
        let fakeRuntime = FakeRuntimeServer(bundleId: "com.e2e.test", sessionId: "e2e-sess-1")
        fakeRuntime.onCommand = { payload in
            CommandResponsePayload(
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

        // Step 2: create_session via MCP tool
        let createResp = callTool("create_session", arguments: ["bundleId": "com.e2e.test"])
        XCTAssertNotNil(createResp?.result, "create_session should succeed")
        XCTAssertNil(createResp?.error)

        // Step 3: list_sessions should show the session
        let listResp = callTool("list_sessions", arguments: [:])
        XCTAssertNotNil(listResp?.result)
        XCTAssertNil(listResp?.error)

        // Step 4: tap via MCP tool
        let tapDone = expectation(description: "tap done")
        Task {
            do {
                let result = try await touchService.tap(
                    sessionId: "e2e-sess-1",
                    params: TapParams(x: 100, y: 200)
                )
                XCTAssertTrue(result.success)
                tapDone.fulfill()
            } catch {
                XCTFail("tap failed: \(error)")
                tapDone.fulfill()
            }
        }
        wait(for: [tapDone], timeout: 10.0)

        // Step 5: type_text via bridge
        let typeDone = expectation(description: "type_text done")
        Task {
            do {
                let result = try await inputService.typeText(
                    sessionId: "e2e-sess-1",
                    params: TypeTextParams(text: "Hello")
                )
                XCTAssertTrue(result.success)
                typeDone.fulfill()
            } catch {
                XCTFail("type_text failed: \(error)")
                typeDone.fulfill()
            }
        }
        wait(for: [typeDone], timeout: 10.0)

        // Step 6: press_key via bridge
        let keyDone = expectation(description: "press_key done")
        Task {
            do {
                let result = try await inputService.pressKey(
                    sessionId: "e2e-sess-1",
                    params: KeyPressParams(key: "enter")
                )
                XCTAssertTrue(result.success)
                keyDone.fulfill()
            } catch {
                XCTFail("press_key failed: \(error)")
                keyDone.fulfill()
            }
        }
        wait(for: [keyDone], timeout: 10.0)

        // Step 7: Verify commands received by fake runtime
        XCTAssertEqual(fakeRuntime.receivedCommands.count, 3)
        XCTAssertEqual(fakeRuntime.receivedCommands[0].command, "tap")
        XCTAssertEqual(fakeRuntime.receivedCommands[1].command, "type_text")
        XCTAssertEqual(fakeRuntime.receivedCommands[2].command, "press_key")

        // Step 8: close_session
        let closeResp = callTool("close_session", arguments: ["sessionId": "e2e-sess-1"])
        XCTAssertNotNil(closeResp?.result)
        XCTAssertNil(closeResp?.error)

        // Step 9: Verify session is gone
        XCTAssertNil(registry.get("e2e-sess-1"))

        // Step 10: Verify tap on closed session fails
        let failResp = callTool("tap", arguments: [
            "sessionId": "e2e-sess-1",
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNil(failResp?.result)
        XCTAssertNotNil(failResp?.error, "tap on closed session should return error")

        fakeRuntime.stop()
    }

    /// Smoke test: multiple sessions for different apps
    func testSessionE2ESmoke_MultipleSessions() throws {
        let port = try registrationListener.start()

        let fake1 = FakeRuntimeServer(bundleId: "com.app1.test", sessionId: "multi-1")
        let fake2 = FakeRuntimeServer(bundleId: "com.app2.test", sessionId: "multi-2")

        fake1.onCommand = { payload in
            CommandResponsePayload(sessionId: payload.sessionId, commandId: payload.commandId, status: "ok", result: nil)
        }
        fake2.onCommand = { payload in
            CommandResponsePayload(sessionId: payload.sessionId, commandId: payload.commandId, status: "ok", result: nil)
        }

        let started1 = expectation(description: "fake1 started")
        let registered1 = expectation(description: "fake1 registered")
        let started2 = expectation(description: "fake2 started")
        let registered2 = expectation(description: "fake2 registered")

        try fake1.start(registrationPort: port, startedExpectation: started1, registeredExpectation: registered1)
        try fake2.start(registrationPort: port, startedExpectation: started2, registeredExpectation: registered2)

        waitForExpectations(timeout: 5.0)

        // Both sessions should be registered
        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.get("multi-1")?.status, .ready)
        XCTAssertEqual(registry.get("multi-2")?.status, .ready)

        // list_sessions should return 2
        let listResp = callTool("list_sessions", arguments: [:])
        XCTAssertNotNil(listResp?.result)

        // list_sessions with filter
        let filteredResp = callTool("list_sessions", arguments: ["bundleId": "com.app1.test"])
        XCTAssertNotNil(filteredResp?.result)

        // Close both
        let close1 = callTool("close_session", arguments: ["sessionId": "multi-1"])
        XCTAssertNotNil(close1?.result)
        XCTAssertEqual(registry.count, 1)

        let close2 = callTool("close_session", arguments: ["sessionId": "multi-2"])
        XCTAssertNotNil(close2?.result)
        XCTAssertEqual(registry.count, 0)

        fake1.stop()
        fake2.stop()
    }

    /// Smoke test: create_session timeout when no runtime registers
    func testSessionE2ESmoke_CreateSessionTimeout() {
        let resp = callTool("create_session", arguments: [
            "bundleId": "com.nonexistent.app",
            "timeout": 0.5
        ])
        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error, "create_session should fail when no runtime registers")
    }

    /// Smoke test: operations on non-existent session
    func testSessionE2ESmoke_NonExistentSession() {
        let touchService = TouchService(registry: registry)
        TouchTools.register(on: server, touchService: touchService)

        let tapResp = callTool("tap", arguments: [
            "sessionId": "nonexistent",
            "x": 100.0,
            "y": 200.0
        ])
        XCTAssertNil(tapResp?.result)
        XCTAssertNotNil(tapResp?.error)

        let closeResp = callTool("close_session", arguments: ["sessionId": "nonexistent"])
        XCTAssertNil(closeResp?.result)
        XCTAssertNotNil(closeResp?.error)
    }
}

// MARK: - Swipe and Drag E2E with Fake Runtime

final class SessionSwipeDragE2ETests: XCTestCase {

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

    func testSwipeThenDragE2E() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.swipedrag.test", sessionId: "sd-sess-1")
        fakeRuntime.onCommand = { payload in
            CommandResponsePayload(
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

        // Swipe
        let swipeDone = expectation(description: "swipe done")
        Task {
            do {
                let result = try await touchService.swipe(
                    sessionId: "sd-sess-1",
                    params: SwipeParams(startX: 10, startY: 20, endX: 300, endY: 400, durationMs: 300, steps: 10)
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "swipe")
                swipeDone.fulfill()
            } catch {
                XCTFail("swipe failed: \(error)")
                swipeDone.fulfill()
            }
        }
        wait(for: [swipeDone], timeout: 10.0)

        // Drag
        let dragDone = expectation(description: "drag done")
        Task {
            do {
                let result = try await touchService.drag(
                    sessionId: "sd-sess-1",
                    params: DragParams(startX: 50, startY: 60, endX: 200, endY: 250,
                                       durationMs: 500, holdDelayMs: 100, steps: 10)
                )
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.command, "drag")
                dragDone.fulfill()
            } catch {
                XCTFail("drag failed: \(error)")
                dragDone.fulfill()
            }
        }
        wait(for: [dragDone], timeout: 10.0)

        // Toggle debug overlay
        let inputService = InputService(registry: registry)
        let toggleDone = expectation(description: "toggle done")
        Task {
            do {
                let result = try await inputService.toggleDebugOverlay(sessionId: "sd-sess-1")
                XCTAssertTrue(result.success)
                toggleDone.fulfill()
            } catch {
                XCTFail("toggle_debug_overlay failed: \(error)")
                toggleDone.fulfill()
            }
        }
        wait(for: [toggleDone], timeout: 10.0)

        // Verify all commands received
        XCTAssertEqual(fakeRuntime.receivedCommands.count, 3)
        XCTAssertEqual(fakeRuntime.receivedCommands[0].command, "swipe")
        XCTAssertEqual(fakeRuntime.receivedCommands[1].command, "drag")
        XCTAssertEqual(fakeRuntime.receivedCommands[2].command, "toggle_debug_overlay")

        fakeRuntime.stop()
    }
}

// MARK: - Runtime Error Response Tests

final class RuntimeErrorResponseTests: XCTestCase {

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

    func testCommandFailureFromRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer(bundleId: "com.error.test", sessionId: "err-sess-1")
        // Return an error status from runtime
        fakeRuntime.onCommand = { payload in
            CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "error",
                result: AnyCodable(["message": "UI element not found"] as [String: Any])
            )
        }

        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        let touchService = TouchService(registry: registry)

        let done = expectation(description: "tap should fail")
        Task {
            do {
                _ = try await touchService.tap(
                    sessionId: "err-sess-1",
                    params: TapParams(x: 100, y: 200)
                )
                XCTFail("Should have thrown on error response")
                done.fulfill()
            } catch {
                // Expected: error from runtime
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10.0)

        fakeRuntime.stop()
    }
}
