// MCPSessionManager.swift
// PlayCoverMCPCore

import Foundation

/// Manages MCP Streamable HTTP sessions.
///
/// Each session represents a client that has completed the `initialize` handshake.
/// Sessions are identified by a cryptographically secure session ID (`Mcp-Session-Id` header).
public final class MCPSessionManager: @unchecked Sendable {

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

    private var sessions: [String: Session] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Session Lifecycle

    /// Create a new session and return its ID.
    /// Called when `initialize` request is received.
    public func createSession() -> String {
        let sessionId = generateSessionId()
        let session = Session(id: sessionId)

        lock.lock()
        sessions[sessionId] = session
        lock.unlock()

        return sessionId
    }

    /// Validate a session ID. Returns the session if valid, nil if expired/not found.
    /// Also updates the last activity timestamp.
    public func validateSession(_ sessionId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }

        guard var session = sessions[sessionId] else {
            return nil
        }

        // Check expiry
        if Date().timeIntervalSince(session.lastActivityAt) > sessionTimeout {
            sessions.removeValue(forKey: sessionId)
            return nil
        }

        // Update last activity
        session.lastActivityAt = Date()
        sessions[sessionId] = session
        return session
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
        return sessions.removeValue(forKey: sessionId) != nil
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

    /// Remove all expired sessions.
    public func removeExpiredSessions() {
        lock.lock()
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.lastActivityAt) <= sessionTimeout
        }
        lock.unlock()
    }

    /// Get a session without updating its activity timestamp.
    public func getSession(_ sessionId: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]
    }

    // MARK: - Private

    /// Generate a cryptographically secure session ID.
    private func generateSessionId() -> String {
        // UUID is cryptographically secure on Apple platforms
        return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
