// MCPSessionManagerTests.swift
// PlayCoverMCPTests

import XCTest

final class MCPSessionManagerTests: XCTestCase {

    func testCreateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertEqual(manager.activeSessionCount, 1)
    }

    func testValidateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        let session = manager.validateSession(sessionId)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, sessionId)
        XCTAssertFalse(session!.isInitialized)
    }

    func testValidateNonexistentSession() {
        let manager = MCPSessionManager()
        XCTAssertNil(manager.validateSession("nonexistent"))
    }

    func testTerminateSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()
        XCTAssertEqual(manager.activeSessionCount, 1)

        let removed = manager.terminateSession(sessionId)
        XCTAssertTrue(removed)
        XCTAssertEqual(manager.activeSessionCount, 0)

        // Validate should fail after termination
        XCTAssertNil(manager.validateSession(sessionId))
    }

    func testValidateSessionStateReportsTerminatedSession() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        XCTAssertTrue(manager.terminateSession(sessionId))

        switch manager.validateSessionState(sessionId) {
        case .valid:
            XCTFail("Expected terminated session to stay invalid")
        case .invalid(let reason):
            XCTAssertEqual(reason, .terminated)
        }
    }

    func testTerminateNonexistentSession() {
        let manager = MCPSessionManager()
        let removed = manager.terminateSession("nonexistent")
        XCTAssertFalse(removed)
    }

    func testMarkInitialized() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        manager.markInitialized(sessionId)
        let session = manager.getSession(sessionId)
        XCTAssertTrue(session!.isInitialized)
    }

    func testSetProtocolVersion() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        manager.setProtocolVersion(sessionId, version: "2025-11-25")
        let session = manager.getSession(sessionId)
        XCTAssertEqual(session?.protocolVersion, "2025-11-25")
    }

    func testSessionExpiry() {
        let manager = MCPSessionManager()
        manager.sessionTimeout = 0.1 // 100ms for test

        let sessionId = manager.createSession()
        XCTAssertNotNil(manager.validateSession(sessionId))

        // Wait for expiry
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertNil(manager.validateSession(sessionId))
    }

    func testValidateSessionStateReportsExpiredSession() {
        let manager = MCPSessionManager()
        manager.sessionTimeout = 0.1

        let sessionId = manager.createSession()
        Thread.sleep(forTimeInterval: 0.2)

        switch manager.validateSessionState(sessionId) {
        case .valid:
            XCTFail("Expected expired session to be reported as invalid")
        case .invalid(let reason):
            XCTAssertEqual(reason, .expired)
        }
    }

    func testRemoveExpiredSessions() {
        let manager = MCPSessionManager()
        manager.sessionTimeout = 0.1

        _ = manager.createSession()
        _ = manager.createSession()
        XCTAssertEqual(manager.activeSessionCount, 2)

        Thread.sleep(forTimeInterval: 0.2)

        manager.removeExpiredSessions()
        XCTAssertEqual(manager.activeSessionCount, 0)
    }

    func testRemoveExpiredSessionsAlsoPrunesOldTerminationTombstones() {
        let manager = MCPSessionManager()
        manager.terminatedSessionRetention = 0.1

        let sessionId = manager.createSession()
        XCTAssertTrue(manager.terminateSession(sessionId))

        Thread.sleep(forTimeInterval: 0.2)
        manager.removeExpiredSessions()

        switch manager.validateSessionState(sessionId) {
        case .valid:
            XCTFail("Expected terminated tombstone to be pruned after retention window")
        case .invalid(let reason):
            XCTAssertEqual(reason, .notFound)
        }
    }

    func testMultipleSessions() {
        let manager = MCPSessionManager()
        let id1 = manager.createSession()
        let id2 = manager.createSession()
        let id3 = manager.createSession()

        XCTAssertEqual(manager.activeSessionCount, 3)
        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id2, id3)

        manager.terminateSession(id2)
        XCTAssertEqual(manager.activeSessionCount, 2)
        XCTAssertNotNil(manager.validateSession(id1))
        XCTAssertNil(manager.validateSession(id2))
        XCTAssertNotNil(manager.validateSession(id3))
    }

    func testSessionIdFormat() {
        let manager = MCPSessionManager()
        let sessionId = manager.createSession()

        // Should be a 32-character hex string (UUID without dashes)
        XCTAssertEqual(sessionId.count, 32)
        XCTAssertTrue(sessionId.allSatisfy { $0.isHexDigit })
    }

    func testConcurrentAccess() {
        let manager = MCPSessionManager()
        let iterations = 100

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        var sessionIds: [String] = []
        let lock = NSLock()

        for _ in 0..<iterations {
            group.enter()
            queue.async {
                let id = manager.createSession()
                lock.lock()
                sessionIds.append(id)
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        XCTAssertEqual(manager.activeSessionCount, iterations)
        XCTAssertEqual(Set(sessionIds).count, iterations) // All unique
    }
}
