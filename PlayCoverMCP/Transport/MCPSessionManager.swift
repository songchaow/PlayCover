// MCPSessionManager.swift
// PlayCoverMCPCore

import Foundation

/// Manages MCP Streamable HTTP sessions.
///
/// Each session represents a client that has completed the `initialize` handshake.
/// Sessions are identified by a cryptographically secure session ID (`Mcp-Session-Id` header).
public final class MCPSessionManager: @unchecked Sendable {

    public enum InvalidSessionReason: String, Equatable, Sendable {
        case notFound
        case expired
        case terminated
    }

    public enum SessionValidationResult: Sendable {
        case valid(Session)
        case invalid(InvalidSessionReason)
    }

    /// Session state
    public struct Session: Sendable {
        public let id: String
        public let createdAt: Date
        public var lastActivityAt: Date
        public var isInitialized: Bool  // true after receiving `notifications/initialized`
        public var protocolVersion: String?

        public init(id: String) {
            self.id = id
            self.createdAt = Date()
            self.lastActivityAt = Date()
            self.isInitialized = false
            self.protocolVersion = nil
        }
    }

    /// Session timeout interval (default: 30 minutes)
    public var sessionTimeout: TimeInterval = 30 * 60

    /// How long to remember explicitly terminated sessions, so the transport can
    /// distinguish “this was intentionally deleted” from “this is an old/stale session”.
    public var terminatedSessionRetention: TimeInterval = 30 * 60

    private var sessions: [String: Session] = [:]
    private var terminatedSessions: [String: Date] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Session Lifecycle

    /// Create a new session and return its ID.
    /// Called when `initialize` request is received.
    public func createSession() -> String {
        let sessionId = generateSessionId()
        let session = Session(id: sessionId)

        lock.lock()
        pruneTerminatedSessionsLocked(now: Date())
        sessions[sessionId] = session
        lock.unlock()

        return sessionId
    }

    /// Validate a session ID and explain why it is invalid when possible.
    /// Valid sessions have their activity timestamp refreshed.
    public func validateSessionState(_ sessionId: String) -> SessionValidationResult {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        pruneTerminatedSessionsLocked(now: now)

        guard var session = sessions[sessionId] else {
            if terminatedSessions[sessionId] != nil {
                return .invalid(.terminated)
            }
            return .invalid(.notFound)
        }

        if now.timeIntervalSince(session.lastActivityAt) > sessionTimeout {
            sessions.removeValue(forKey: sessionId)
            return .invalid(.expired)
        }

        session.lastActivityAt = now
        sessions[sessionId] = session
        return .valid(session)
    }

    /// Validate a session ID. Returns the session if valid, nil if expired/not found.
    /// Also updates the last activity timestamp.
    public func validateSession(_ sessionId: String) -> Session? {
        switch validateSessionState(sessionId) {
        case .valid(let session):
            return session
        case .invalid:
            return nil
        }
    }

    /// Mark a session as fully initialized (after receiving `notifications/initialized`).
    public func markInitialized(_ sessionId: String) {
        lock.lock()
        sessions[sessionId]?.isInitialized = true
        lock.unlock()
    }

    /// Set the negotiated protocol version for a session.
    public func setProtocolVersion(_ sessionId: String, version: String) {
        lock.lock()
        sessions[sessionId]?.protocolVersion = version
        lock.unlock()
    }

    /// Terminate a session. Called on DELETE request or timeout.
    /// Returns true if the session existed and was removed.
    @discardableResult
    public func terminateSession(_ sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneTerminatedSessionsLocked(now: Date())
        let removed = sessions.removeValue(forKey: sessionId) != nil
        if removed {
            terminatedSessions[sessionId] = Date()
        }
        return removed
    }

    /// Get the number of active sessions.
    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    /// Get all active session IDs.
    public var allSessionIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.keys)
    }

    /// Remove all expired sessions and outdated termination tombstones.
    public func removeExpiredSessions() {
        lock.lock()
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivityAt) <= sessionTimeout
        }
        pruneTerminatedSessionsLocked(now: now)
        lock.unlock()
    }

    /// Get a session without updating its activity timestamp.
    public func getSession(_ sessionId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]
    }

    // MARK: - Private

    private func pruneTerminatedSessionsLocked(now: Date) {
        terminatedSessions = terminatedSessions.filter { _, deletedAt in
            now.timeIntervalSince(deletedAt) <= terminatedSessionRetention
        }
    }

    /// Generate a cryptographically secure session ID.
    private func generateSessionId() -> String {
        // UUID is cryptographically secure on Apple platforms
        return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
