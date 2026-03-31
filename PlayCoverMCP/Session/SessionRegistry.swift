// SessionRegistry.swift
// PlayCoverMCP

import Foundation

/// Thread-safe registry for active runtime sessions.
///
/// Each session represents a running iOS app with PlayTools injected,
/// identified by its sessionId, bundleId, and runtime port.
public final class SessionRegistry: Sendable {

    // MARK: - Private State

    private var sessions: [String: SessionInfo] = [:]
    private let lock = NSLock()

    // MARK: - Change Notification

    /// Called on the main queue whenever the session set changes (register/unregister/status update).
    /// The closure receives a snapshot of all current sessions.
    public var onChange: (([SessionInfo]) -> Void)?

    private func notifyChange() {
        let snapshot = Array(sessions.values)
        if let onChange = onChange {
            DispatchQueue.main.async {
                onChange(snapshot)
            }
        }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Registration

    /// Register a new session. Throws if a session with the same ID already exists.
    public func register(_ info: SessionInfo) throws {
        lock.lock()
        defer { lock.unlock() }

        if sessions[info.sessionId] != nil {
            throw SessionError.sessionAlreadyExists(info.sessionId)
        }
        sessions[info.sessionId] = info
        notifyChange()
    }

    /// Unregister a session by ID. Throws if not found.
    public func unregister(sessionId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard sessions.removeValue(forKey: sessionId) != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }
        notifyChange()
    }

    /// Unregister all sessions for a given bundle ID.
    @discardableResult
    public func unregisterByBundleId(_ bundleId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let toRemove = sessions.values
            .filter { $0.bundleId == bundleId }
            .map(\.sessionId)
        for id in toRemove {
            sessions.removeValue(forKey: id)
        }
        if !toRemove.isEmpty {
            notifyChange()
        }
        return toRemove
    }

    // MARK: - Lookup

    /// Get a session by ID.
    public func get(_ sessionId: String) -> SessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[sessionId]
    }

    /// Get all sessions for a given bundle ID.
    public func getByBundleId(_ bundleId: String) -> [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.filter { $0.bundleId == bundleId }
    }

    /// List all active sessions.
    public func listSessions() -> [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }

    /// Count of active sessions.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    // MARK: - Heartbeat

    /// Update the last heartbeat time for a session. Throws if not found.
    public func updateHeartbeat(sessionId: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard sessions[sessionId] != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }
        sessions[sessionId]?.lastHeartbeat = Date()
    }

    /// Update the status of a session. Throws if not found.
    public func updateStatus(sessionId: String, newStatus: SessionStatus) throws {
        lock.lock()
        defer { lock.unlock() }

        guard sessions[sessionId] != nil else {
            throw SessionError.sessionNotFound(sessionId)
        }
        sessions[sessionId]?.status = newStatus
        notifyChange()
    }

    /// Remove sessions that haven't sent a heartbeat within the given timeout.
    @discardableResult
    public func removeStaleSessions(timeout: TimeInterval) -> [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let stale = sessions.values.filter { now.timeIntervalSince($0.lastHeartbeat) > timeout }
        for info in stale {
            sessions.removeValue(forKey: info.sessionId)
        }
        if !stale.isEmpty {
            notifyChange()
        }
        return stale
    }

    // MARK: - Testing / Reset

    /// Remove all sessions (for testing).
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let hadSessions = !sessions.isEmpty
        sessions.removeAll()
        if hadSessions {
            notifyChange()
        }
    }
}
