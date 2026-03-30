// SessionService.swift
// PlayCoverMCP

import Foundation

/// Service for managing session lifecycle from the MCP host side.
///
/// Provides create/list/close operations on top of `SessionRegistry`.
/// `create_session` waits for a runtime to register (polling-based).
public final class SessionService: Sendable {

    private static let timeoutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ""
        return formatter
    }()

    // MARK: - Dependencies

    private let registry: SessionRegistry

    // MARK: - Init

    public init(registry: SessionRegistry) {
        self.registry = registry
    }

    // MARK: - Create

    /// Create (or find) a session for the given bundleId.
    ///
    /// If an active session already exists for this bundleId, it is returned immediately.
    /// Otherwise, a pending session is created and the method polls until a runtime
    /// registers for the same bundleId or the timeout is reached.
    ///
    /// - Parameters:
    ///   - bundleId: The app's bundle identifier.
    ///   - timeout: Maximum time to wait for runtime registration (default 10s).
    /// - Returns: The ready session info.
    /// - Throws: `SessionError` on timeout or registration failure.
    public func createSession(bundleId: String, timeout: TimeInterval = 10.0) throws -> SessionInfo {
        // 1. Check for existing ready session
        if let existing = registry.getByBundleId(bundleId).first(where: { $0.status == .ready }) {
            return existing
        }

        // 2. Create a pending session entry
        let pendingId = "pending-\(bundleId)-\(UInt64.random(in: 0...UInt64.max))"
        let pendingInfo = SessionInfo(
            sessionId: pendingId,
            bundleId: bundleId,
            pid: 0,
            runtimePort: 0,
            status: .starting
        )
        try registry.register(pendingInfo)

        // 3. Poll for runtime registration
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ready = registry.getByBundleId(bundleId)
                .first(where: { $0.status == .ready && $0.sessionId != pendingId }) {
                // Clean up pending session
                try? registry.unregister(sessionId: pendingId)
                return ready
            }
            usleep(100_000) // 100ms
        }

        // 4. Timeout: clean up and throw
        try? registry.unregister(sessionId: pendingId)
        throw SessionError.heartbeatTimeout(
            "No runtime registered for bundleId '\(bundleId)' within \(Self.formatTimeout(timeout))"
        )
    }

    // MARK: - List

    /// List all sessions, optionally filtered by bundleId.
    ///
    /// - Parameter bundleId: Optional bundle ID filter.
    /// - Returns: Array of session info objects.
    public func listSessions(bundleId: String? = nil) -> [SessionInfo] {
        if let bundleId = bundleId {
            return registry.getByBundleId(bundleId)
        }
        return registry.listSessions()
    }

    // MARK: - Get

    /// Get a single session by ID.
    ///
    /// - Parameter sessionId: The session identifier.
    /// - Returns: The session info, or nil if not found.
    public func getSession(_ sessionId: String) -> SessionInfo? {
        registry.get(sessionId)
    }

    // MARK: - Close

    /// Close a session by ID.
    ///
    /// Updates the status to `.closed`, then unregisters from the registry.
    ///
    /// - Parameter sessionId: The session identifier.
    /// - Returns: The session info before removal.
    /// - Throws: `SessionError.sessionNotFound` if the session doesn't exist.
    public func closeSession(sessionId: String) throws -> SessionInfo {
        guard let session = registry.get(sessionId) else {
            throw SessionError.sessionNotFound(sessionId)
        }

        try registry.updateStatus(sessionId: sessionId, newStatus: .closed)
        try registry.unregister(sessionId: sessionId)

        return session
    }

    // MARK: - Status

    /// Get the status of a session.
    ///
    /// - Parameter sessionId: The session identifier.
    /// - Returns: The session status, or nil if not found.
    public func getStatus(_ sessionId: String) -> SessionStatus? {
        registry.get(sessionId)?.status
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        let number = NSNumber(value: timeout)
        let formatted = timeoutFormatter.string(from: number) ?? String(timeout)
        return "\(formatted)s"
    }
}
