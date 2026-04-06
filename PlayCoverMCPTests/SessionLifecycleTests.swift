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

    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sessionIds: [String] = []
        private var timeouts: [TimeInterval] = []

        func record(sessionId: String, timeout: TimeInterval) {
            lock.lock()
            sessionIds.append(sessionId)
            timeouts.append(timeout)
            lock.unlock()
        }

        func recordedSessionIds() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return sessionIds
        }

        func recordedTimeouts() -> [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return timeouts
        }
    }

    private var registry: SessionRegistry!
    private var service: SessionService!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        service = SessionService(registry: registry, bridgeReadinessProbe: { _, _ in true })
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
                XCTAssertEqual(sessionError, .heartbeatTimeout("No runtime registered for bundleId 'com.nonexistent' within 0.5s"))
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

    func testCreateSessionWaitsForBridgeReachability() throws {
        let bridgeBecomesReachableAt = Date().addingTimeInterval(0.4)
        service = SessionService(registry: registry, bridgeReadinessProbe: { session, _ in
            session.sessionId == "runtime-sess-1" && Date() >= bridgeBecomesReachableAt
        })

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let runtimeInfo = SessionInfo(
                sessionId: "runtime-sess-1",
                bundleId: "com.bridge.ready",
                pid: 500,
                runtimePort: 53000,
                status: .ready
            )
            try? self.registry.register(runtimeInfo)
        }

        let start = Date()
        let result = try service.createSession(bundleId: "com.bridge.ready", timeout: 1.5)

        XCTAssertEqual(result.sessionId, "runtime-sess-1")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.35)
    }

    func testCreateSessionTimesOutWhenRuntimeRegisteredButBridgeNotReachable() throws {
        let readyRuntime = SessionInfo(
            sessionId: "runtime-sess-1",
            bundleId: "com.bridge.timeout",
            pid: 500,
            runtimePort: 53000,
            status: .ready
        )
        try registry.register(readyRuntime)
        service = SessionService(registry: registry, bridgeReadinessProbe: { _, _ in false })

        XCTAssertThrowsError(try service.createSession(bundleId: "com.bridge.timeout", timeout: 0.3)) { error in
            XCTAssertTrue(error is SessionError)
            if let sessionError = error as? SessionError {
                XCTAssertEqual(
                    sessionError,
                    .heartbeatTimeout("Runtime registered for bundleId 'com.bridge.timeout' but command bridge was not reachable within 0.3s")
                )
            }
        }
    }

    func testCreateSessionPrefersFreshestReachableReadySession() throws {
        let staleRuntime = SessionInfo(
            sessionId: "runtime-stale",
            bundleId: "com.bridge.order",
            pid: 500,
            runtimePort: 53000,
            createdAt: Date().addingTimeInterval(-20),
            lastHeartbeat: Date().addingTimeInterval(-20),
            status: .ready
        )
        let freshRuntime = SessionInfo(
            sessionId: "runtime-fresh",
            bundleId: "com.bridge.order",
            pid: 501,
            runtimePort: 53001,
            createdAt: Date().addingTimeInterval(-5),
            lastHeartbeat: Date().addingTimeInterval(-1),
            status: .ready
        )
        try registry.register(staleRuntime)
        try registry.register(freshRuntime)

        let recorder = ProbeRecorder()
        service = SessionService(registry: registry, bridgeReadinessProbe: { session, _ in
            recorder.record(sessionId: session.sessionId, timeout: 0)
            return session.sessionId == "runtime-fresh"
        })

        let result = try service.createSession(bundleId: "com.bridge.order", timeout: 1.0)
        let probedSessionIds = recorder.recordedSessionIds()

        XCTAssertEqual(result.sessionId, "runtime-fresh")
        XCTAssertEqual(probedSessionIds.first, "runtime-fresh")
    }

    func testCreateSessionBridgeProbeUsesRemainingDeadlineUpToCommandTimeout() throws {
        let readyRuntime = SessionInfo(
            sessionId: "runtime-sess-1",
            bundleId: "com.bridge.probe-timeout",
            pid: 500,
            runtimePort: 53000,
            status: .ready
        )
        try registry.register(readyRuntime)

        let recorder = ProbeRecorder()
        service = SessionService(registry: registry, bridgeReadinessProbe: { _, timeout in
            recorder.record(sessionId: "runtime-sess-1", timeout: timeout)
            return true
        })

        _ = try service.createSession(bundleId: "com.bridge.probe-timeout", timeout: 10.0)
        let observedTimeouts = recorder.recordedTimeouts()

        XCTAssertEqual(observedTimeouts.count, 1)
        guard let firstTimeout = observedTimeouts.first else {
            return XCTFail("Expected a probe timeout to be recorded")
        }
        XCTAssertEqual(firstTimeout, 5.0, accuracy: 0.001)
    }

    func testCreateSessionFallsBackToOlderReachableSessionWhenFreshestProbeFails() throws {
        let olderReachableRuntime = SessionInfo(
            sessionId: "runtime-older-reachable",
            bundleId: "com.bridge.fallback",
            pid: 500,
            runtimePort: 53000,
            createdAt: Date().addingTimeInterval(-20),
            lastHeartbeat: Date().addingTimeInterval(-10),
            status: .ready
        )
        let freshestUnreachableRuntime = SessionInfo(
            sessionId: "runtime-freshest-unreachable",
            bundleId: "com.bridge.fallback",
            pid: 501,
            runtimePort: 53001,
            createdAt: Date().addingTimeInterval(-2),
            lastHeartbeat: Date().addingTimeInterval(-1),
            status: .ready
        )
        try registry.register(olderReachableRuntime)
        try registry.register(freshestUnreachableRuntime)

        let recorder = ProbeRecorder()
        service = SessionService(registry: registry, bridgeReadinessProbe: { session, timeout in
            recorder.record(sessionId: session.sessionId, timeout: timeout)
            return session.sessionId == "runtime-older-reachable"
        })

        let result = try service.createSession(bundleId: "com.bridge.fallback", timeout: 1.0)
        let probedSessionIds = recorder.recordedSessionIds()

        XCTAssertEqual(result.sessionId, "runtime-older-reachable")
        XCTAssertEqual(probedSessionIds, ["runtime-freshest-unreachable", "runtime-older-reachable"])
    }

    func testCreateSessionReservesProbeBudgetForOlderFallbackSessions() throws {
        let olderReachableRuntime = SessionInfo(
            sessionId: "runtime-older-reachable",
            bundleId: "com.bridge.fallback-slow",
            pid: 500,
            runtimePort: 53000,
            createdAt: Date().addingTimeInterval(-20),
            lastHeartbeat: Date().addingTimeInterval(-10),
            status: .ready
        )
        let freshestSlowUnreachableRuntime = SessionInfo(
            sessionId: "runtime-freshest-slow-unreachable",
            bundleId: "com.bridge.fallback-slow",
            pid: 501,
            runtimePort: 53001,
            createdAt: Date().addingTimeInterval(-2),
            lastHeartbeat: Date().addingTimeInterval(-1),
            status: .ready
        )
        try registry.register(olderReachableRuntime)
        try registry.register(freshestSlowUnreachableRuntime)

        let recorder = ProbeRecorder()
        service = SessionService(registry: registry, bridgeReadinessProbe: { session, timeout in
            recorder.record(sessionId: session.sessionId, timeout: timeout)
            if session.sessionId == "runtime-freshest-slow-unreachable" {
                Thread.sleep(forTimeInterval: min(0.2, timeout))
                return false
            }
            return session.sessionId == "runtime-older-reachable"
        })

        let result = try service.createSession(bundleId: "com.bridge.fallback-slow", timeout: 0.35)
        let recordedTimeouts = recorder.recordedTimeouts()

        XCTAssertEqual(result.sessionId, "runtime-older-reachable")
        XCTAssertEqual(recorder.recordedSessionIds(), ["runtime-freshest-slow-unreachable", "runtime-older-reachable"])
        XCTAssertEqual(recordedTimeouts.count, 2)
        XCTAssertEqual(recordedTimeouts[0], 0.175, accuracy: 0.03)
        XCTAssertGreaterThan(recordedTimeouts[1], 0.1)
    }

    func testCreateSessionSkipsProbeWhenRemainingDeadlineBelowMinimumProbeTimeout() throws {
        let readyRuntime = SessionInfo(
            sessionId: "runtime-sess-1",
            bundleId: "com.bridge.short-deadline",
            pid: 500,
            runtimePort: 53000,
            status: .ready
        )
        try registry.register(readyRuntime)

        let recorder = ProbeRecorder()
        service = SessionService(registry: registry, bridgeReadinessProbe: { session, timeout in
            recorder.record(sessionId: session.sessionId, timeout: timeout)
            return true
        })

        XCTAssertThrowsError(try service.createSession(bundleId: "com.bridge.short-deadline", timeout: 0.05)) { error in
            XCTAssertEqual(
                error as? SessionError,
                .heartbeatTimeout("Runtime registered for bundleId 'com.bridge.short-deadline' but command bridge was not reachable within 0.05s")
            )
        }

        XCTAssertTrue(recorder.recordedTimeouts().isEmpty)
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
        service = SessionService(registry: registry, bridgeReadinessProbe: { _, _ in true })
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

    func testCreateSessionToolAcceptsIntegerTimeout() {
        let start = Date()
        let resp = callTool("create_session", arguments: [
            "bundleId": "com.integer-timeout",
            "timeout": 1
        ])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(resp?.result)
        XCTAssertNotNil(resp?.error)
        XCTAssertGreaterThanOrEqual(elapsed, 0.8)
        XCTAssertLessThan(elapsed, 3.0)
        XCTAssertEqual(resp?.error?.code, PlayCoverErrorCode.bridgeError.rawValue)
        XCTAssertEqual(
            resp?.error?.message,
            "Session heartbeat timed out: No runtime registered for bundleId 'com.integer-timeout' within 1s"
        )
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

    func testCreateSessionToolRejectsNonPositiveTimeout() {
        let resp = callTool("create_session", arguments: [
            "bundleId": "com.invalid-timeout",
            "timeout": 0
        ])
        XCTAssertNil(resp?.result)
        XCTAssertEqual(resp?.error?.code, JSONRPCError.invalidParams)
        XCTAssertEqual(resp?.error?.message, "create_session 'timeout' must be greater than 0")
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
                logging: EmptyCapability(),
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
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
