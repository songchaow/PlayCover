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
