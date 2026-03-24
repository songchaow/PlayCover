// SessionLifecycleTests.swift
// PlayCoverMCPTests

import Foundation
import XCTest
import Network

// MARK: - Session Status Tests

final class SessionStatusTests: XCTestCase {

    func testAllStatusValues() {
        XCTAssertEqual(SessionStatus.starting.rawValue, "starting")
        XCTAssertEqual(SessionStatus.ready.rawValue, "ready")
        XCTAssertEqual(SessionStatus.disconnected.rawValue, "disconnected")
        XCTAssertEqual(SessionStatus.closed.rawValue, "closed")
    }

    func testSessionStatusCodable() throws {
        for status in [SessionStatus.starting, .ready, .disconnected, .closed] {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(SessionStatus.self, from: encoded)
            XCTAssertEqual(decoded, status)
        }
    }

    func testSessionInfoDefaultStatusIsReady() {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        XCTAssertEqual(info.status, .ready)
    }

    func testSessionInfoCustomStatus() {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.example", pid: 100, runtimePort: 52742, status: .starting)
        XCTAssertEqual(info.status, .starting)
    }

    func testSessionInfoFromPayloadHasReadyStatus() {
        let payload = RegisterPayload(sessionId: "s1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        let info = SessionInfo(from: payload)
        XCTAssertEqual(info.status, .ready)
    }

    func testSessionInfoToDictionaryIncludesStatus() {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.example", pid: 100, runtimePort: 52742, status: .ready)
        let dict = info.toDictionary()
        XCTAssertEqual(dict["status"] as? String, "ready")
    }
}

// MARK: - Session Service Tests

final class SessionServiceTests: XCTestCase {

    private var registry: SessionRegistry!
    private var service: SessionService!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        service = SessionService(registry: registry)
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        service = nil
        super.tearDown()
    }

    // MARK: - create_session

    func testCreateSessionReturnsExistingReadySession() throws {
        let existing = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(existing)

        let result = try service.createSession(bundleId: "com.example")
        XCTAssertEqual(result.sessionId, "sess-1")
        XCTAssertEqual(result.status, .ready)
    }

    func testCreateSessionReturnsFirstReadySessionForBundleId() throws {
        let info1 = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742, status: .ready)
        let info2 = SessionInfo(sessionId: "sess-2", bundleId: "com.example", pid: 200, runtimePort: 52743, status: .ready)
        try registry.register(info1)
        try registry.register(info2)

        let result = try service.createSession(bundleId: "com.example")
        XCTAssertTrue(["sess-1", "sess-2"].contains(result.sessionId))
    }

    func testCreateSessionWaitsForRuntime() throws {
        let timeout: TimeInterval = 2.0

        // Start a background task that will register a runtime after 0.3s
        let expectation = expectation(description: "runtime registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let runtimeInfo = SessionInfo(
                sessionId: "runtime-sess-1",
                bundleId: "com.newapp",
                pid: 500,
                runtimePort: 53000,
                status: .ready
            )
            try? self.registry.register(runtimeInfo)
            expectation.fulfill()
        }

        let result = try service.createSession(bundleId: "com.newapp", timeout: timeout)
        XCTAssertEqual(result.sessionId, "runtime-sess-1")
        XCTAssertEqual(result.bundleId, "com.newapp")
        XCTAssertEqual(result.status, .ready)
        wait(for: [expectation], timeout: 1.0)
    }

    func testCreateSessionTimeoutWhenNoRuntime() {
        XCTAssertThrowsError(try service.createSession(bundleId: "com.nonexistent", timeout: 0.5)) { error in
            XCTAssertTrue(error is SessionError)
            if let sessionError = error as? SessionError {
                XCTAssertEqual(sessionError, .heartbeatTimeout("No runtime registered for bundleId 'com.nonexistent' within 0s"))
            }
        }
    }

    func testCreateSessionCleansUpPendingOnTimeout() {
        XCTAssertThrowsError(try service.createSession(bundleId: "com.cleanup", timeout: 0.3)) { _ in }

        // Verify no pending sessions left
        let allSessions = registry.listSessions()
        XCTAssertTrue(allSessions.isEmpty)
    }

    func testCreateSessionCleansUpPendingOnSuccess() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let info = SessionInfo(sessionId: "r-1", bundleId: "com.test", pid: 1, runtimePort: 1111, status: .ready)
            try? self.registry.register(info)
        }

        let result = try service.createSession(bundleId: "com.test", timeout: 2.0)
        XCTAssertEqual(result.sessionId, "r-1")

        // Verify no pending sessions left
        let allSessions = registry.listSessions()
        XCTAssertEqual(allSessions.count, 1)
        XCTAssertEqual(allSessions.first?.sessionId, "r-1")
    }

    // MARK: - list_sessions

    func testListSessionsEmpty() {
        let sessions = service.listSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testListSessionsReturnsAll() throws {
        let info1 = SessionInfo(sessionId: "s1", bundleId: "com.app1", pid: 100, runtimePort: 52742)
        let info2 = SessionInfo(sessionId: "s2", bundleId: "com.app2", pid: 200, runtimePort: 52743)
        try registry.register(info1)
        try registry.register(info2)

        let sessions = service.listSessions()
        XCTAssertEqual(sessions.count, 2)
    }

    func testListSessionsFilterByBundleId() throws {
        let info1 = SessionInfo(sessionId: "s1", bundleId: "com.target", pid: 100, runtimePort: 52742)
        let info2 = SessionInfo(sessionId: "s2", bundleId: "com.other", pid: 200, runtimePort: 52743)
        let info3 = SessionInfo(sessionId: "s3", bundleId: "com.target", pid: 300, runtimePort: 52744)
        try registry.register(info1)
        try registry.register(info2)
        try registry.register(info3)

        let sessions = service.listSessions(bundleId: "com.target")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.bundleId == "com.target" })
    }

    func testListSessionsReturnsDifferentStatuses() throws {
        let ready = SessionInfo(sessionId: "r1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        let starting = SessionInfo(sessionId: "p1", bundleId: "com.app", pid: 0, runtimePort: 0, status: .starting)
        try registry.register(ready)
        try registry.register(starting)

        let sessions = service.listSessions()
        XCTAssertEqual(sessions.count, 2)

        let statuses = Set(sessions.map(\.status))
        XCTAssertTrue(statuses.contains(.ready))
        XCTAssertTrue(statuses.contains(.starting))
    }

    // MARK: - get_session

    func testGetSessionFound() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let result = service.getSession("s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, "s1")
    }

    func testGetSessionNotFound() {
        let result = service.getSession("nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - close_session

    func testCloseSession() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let closed = try service.closeSession(sessionId: "s1")
        XCTAssertEqual(closed.sessionId, "s1")
        XCTAssertNil(registry.get("s1"))
    }

    func testCloseSessionNotFound() {
        XCTAssertThrowsError(try service.closeSession(sessionId: "nonexistent")) { error in
            XCTAssertTrue(error is SessionError)
            if let sessionError = error as? SessionError {
                XCTAssertEqual(sessionError, .sessionNotFound("nonexistent"))
            }
        }
    }

    // MARK: - get_status

    func testGetStatus() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        XCTAssertEqual(service.getStatus("s1"), .ready)
    }

    func testGetStatusNotFound() {
        XCTAssertNil(service.getStatus("nonexistent"))
    }
}

// MARK: - Session Registry Status Tests

final class SessionRegistryStatusTests: XCTestCase {

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

    func testUpdateStatus() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        try registry.updateStatus(sessionId: "s1", newStatus: .disconnected)
        XCTAssertEqual(registry.get("s1")?.status, .disconnected)
    }

    func testUpdateStatusNotFound() {
        XCTAssertThrowsError(try registry.updateStatus(sessionId: "nonexistent", newStatus: .closed)) { error in
            XCTAssertTrue(error is SessionError)
        }
    }

    func testUpdateStatusMultipleTransitions() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .starting)
        try registry.register(info)

        try registry.updateStatus(sessionId: "s1", newStatus: .ready)
        XCTAssertEqual(registry.get("s1")?.status, .ready)

        try registry.updateStatus(sessionId: "s1", newStatus: .disconnected)
        XCTAssertEqual(registry.get("s1")?.status, .disconnected)

        try registry.updateStatus(sessionId: "s1", newStatus: .closed)
        XCTAssertEqual(registry.get("s1")?.status, .closed)
    }
}

// MARK: - MCP Tool & Resource Integration Tests

final class SessionToolsAndResourcesTests: XCTestCase {

    private var registry: SessionRegistry!
    private var service: SessionService!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        service = SessionService(registry: registry)
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
        SessionTools.register(on: server, sessionService: service)
        SessionResources.register(on: server, sessionService: service)
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        service = nil
        server = nil
        super.tearDown()
    }

    // MARK: - Tool Registration

    func testSessionToolsRegistered() {
        let tools = server.toolRegistry.listTools()
        let toolNames = tools.map(\.name)
        XCTAssertTrue(toolNames.contains("create_session"))
        XCTAssertTrue(toolNames.contains("list_sessions"))
        XCTAssertTrue(toolNames.contains("close_session"))
    }

    func testSessionResourcesRegistered() {
        let resources = server.resourceRegistry.listResources()
        let uris = resources.map(\.uri)
        XCTAssertTrue(uris.contains("playcover://sessions"))
        XCTAssertTrue(uris.contains("playcover://sessions/{sessionId}"))
    }

    // MARK: - tools/call integration

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

    private func readResource(_ uri: String) -> JSONRPCResponse? {
        let idStr = String(UUID().uuidString.prefix(8))
        let request = JSONRPCRequest(
            id: .string(idStr),
            method: "resources/read",
            params: AnyCodable(["uri": uri] as Any)
        )
        let response = server.handle(.request(request))
        guard case .response(let resp) = response else {
            XCTFail("Expected response for resources/read")
            return nil
        }
        return resp
    }

    func testCreateSessionToolReturnsExistingSession() throws {
        let info = SessionInfo(sessionId: "existing", bundleId: "com.example", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let resp = callTool("create_session", arguments: ["bundleId": "com.example"])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertNotNil(resp?.result?.dictionary?["content"])
    }

    func testListSessionsToolEmpty() {
        let resp = callTool("list_sessions", arguments: [:])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
    }

    func testListSessionsToolWithData() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        let resp = callTool("list_sessions", arguments: [:])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertNotNil(resp?.result?.dictionary?["content"])
    }

    func testCloseSessionTool() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let resp = callTool("close_session", arguments: ["sessionId": "s1"])
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)

        XCTAssertNil(registry.get("s1"))
    }

    func testCloseSessionToolNotFound() {
        let resp = callTool("close_session", arguments: ["sessionId": "nonexistent"])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, PlayCoverErrorCode.sessionNotFound.rawValue)
    }

    // MARK: - resources/read integration

    func testReadSessionsResource() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        let resp = readResource("playcover://sessions")
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertNotNil(resp?.result?.dictionary?["contents"])
    }

    func testReadSessionResourceById() throws {
        let info = SessionInfo(sessionId: "s1", bundleId: "com.app", pid: 100, runtimePort: 52742, status: .ready)
        try registry.register(info)

        let resp = readResource("playcover://sessions/s1")
        XCTAssertNotNil(resp?.result)
        XCTAssertNil(resp?.error)
        XCTAssertNotNil(resp?.result?.dictionary?["contents"])
    }

    func testReadSessionResourceNotFound() {
        let resp = readResource("playcover://sessions/nonexistent")
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, PlayCoverErrorCode.sessionNotFound.rawValue)
    }

    func testReadSessionResourceEmptyId() {
        let resp = readResource("playcover://sessions/")
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
    }
}

// MARK: - Session Lifecycle with Fake Runtime Tests

final class SessionLifecycleIntegrationTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!
    private var service: SessionService!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(port: 0, registry: registry)
        service = SessionService(registry: registry)
        let logger = MCPLogger(minLevel: .info)
        server = MCPServer(
            serverInfo: Implementation(name: "test", version: "0.0.1"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(listChanged: false),
                resources: ResourceCapabilities(subscribe: false, listChanged: false),
                logging: true,
                tasks: true
            ),
            logger: logger
        )
        SessionTools.register(on: server, sessionService: service)
        SessionResources.register(on: server, sessionService: service)
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        service = nil
        server = nil
        super.tearDown()
    }

    func testFullLifecycleWithFakeRuntime() throws {
        let port = try registrationListener.start()

        // Step 1: Start fake runtime (registers automatically)
        let fakeRuntime = FakeRuntimeServer(bundleId: "com.lifecycle.test", sessionId: "lc-sess-1")
        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Step 2: Verify session is in registry
        XCTAssertEqual(registry.count, 1)
        let session = registry.get("lc-sess-1")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.status, .ready)
        XCTAssertEqual(session?.bundleId, "com.lifecycle.test")

        // Step 3: create_session should return existing
        let created = try service.createSession(bundleId: "com.lifecycle.test")
        XCTAssertEqual(created.sessionId, "lc-sess-1")

        // Step 4: list_sessions via tool
        let listRequest = JSONRPCRequest(
            id: .string("list-1"),
            method: "tools/call",
            params: AnyCodable([
                "name": "list_sessions",
                "arguments": [:]
            ] as [String: Any])
        )
        let listResponse = server.handle(.request(listRequest))
        guard case .response(let listResp) = listResponse else {
            XCTFail("Expected response for list_sessions")
            return
        }
        XCTAssertNotNil(listResp.result)
        XCTAssertNil(listResp.error)

        // Step 5: Read session resource
        let readRequest = JSONRPCRequest(
            id: .string("read-1"),
            method: "resources/read",
            params: AnyCodable(["uri": "playcover://sessions/lc-sess-1"] as Any)
        )
        let readResponse = server.handle(.request(readRequest))
        guard case .response(let readResp) = readResponse else {
            XCTFail("Expected response for resources/read")
            return
        }
        XCTAssertNotNil(readResp.result)
        XCTAssertNil(readResp.error)

        // Step 6: close_session
        let closed = try service.closeSession(sessionId: "lc-sess-1")
        XCTAssertEqual(closed.sessionId, "lc-sess-1")

        // Step 7: Verify session is gone
        XCTAssertNil(registry.get("lc-sess-1"))

        fakeRuntime.stop()
    }

    func testCreateSessionWithDelayedRuntime() throws {
        let port = try registrationListener.start()

        // Start fake runtime and wait for full registration
        let fakeRuntime = FakeRuntimeServer(bundleId: "com.delayed", sessionId: "delayed-sess")
        let started = expectation(description: "runtime started")
        let registered = expectation(description: "runtime registered")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // At this point the runtime is registered. create_session should return it immediately.
        let result = try service.createSession(bundleId: "com.delayed", timeout: 2.0)
        XCTAssertEqual(result.sessionId, "delayed-sess")
        XCTAssertEqual(result.bundleId, "com.delayed")
        XCTAssertEqual(result.status, .ready)

        fakeRuntime.stop()
    }
}
