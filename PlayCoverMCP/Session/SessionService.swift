// SessionService.swift
// PlayCoverMCP

import Foundation

/// Service for managing session lifecycle from the MCP host side.
///
/// Provides create/list/close operations on top of `SessionRegistry`.
/// `create_session` waits for a runtime to register (polling-based).
public final class SessionService: Sendable {

    public typealias BridgeReadinessProbe = @Sendable (SessionInfo, TimeInterval) -> Bool

    private final class ProbeResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let timeoutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        formatter.decimalSeparator = "."
        formatter.groupingSeparator = ""
        return formatter
    }()
    private static let minimumBridgeProbeTimeout: TimeInterval = 0.2
    private static let maximumBridgeProbeTimeout: TimeInterval = 5.0
    public static let defaultBridgeReadinessProbe: BridgeReadinessProbe = { session, timeout in
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ProbeResultBox()

        Task.detached {
            let client = BridgeClient(sessionId: session.sessionId, port: session.runtimePort)
            defer {
                client.close()
                semaphore.signal()
            }

            do {
                try await client.connect(timeout: timeout)
                try await client.ping(timeout: timeout)
                resultBox.set(true)
            } catch {
                resultBox.set(false)
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout + 0.1)
        if waitResult == .timedOut {
            return false
        }
        return resultBox.get()
    }

    // MARK: - Dependencies

    private let registry: SessionRegistry
    private let bridgeReadinessProbe: BridgeReadinessProbe

    // MARK: - Init

    public init(
        registry: SessionRegistry,
        bridgeReadinessProbe: @escaping BridgeReadinessProbe = SessionService.defaultBridgeReadinessProbe
    ) {
        self.registry = registry
        self.bridgeReadinessProbe = bridgeReadinessProbe
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
        let deadline = Date().addingTimeInterval(timeout)
        if let existing = findReachableReadySession(bundleId: bundleId, excludingSessionId: nil, deadline: deadline) {
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
        var observedRegisteredButUnreachableRuntime = false
        while Date() < deadline {
            let readyCandidates = registry.getByBundleId(bundleId)
                .filter { $0.status == .ready && $0.sessionId != pendingId }

            if !readyCandidates.isEmpty {
                observedRegisteredButUnreachableRuntime = true
            }

            if let ready = findReachableReadySession(bundleId: bundleId, excludingSessionId: pendingId, deadline: deadline) {
                try? registry.unregister(sessionId: pendingId)
                return ready
            }
            usleep(100_000) // 100ms
        }

        try? registry.unregister(sessionId: pendingId)
        if observedRegisteredButUnreachableRuntime {
            throw SessionError.heartbeatTimeout(
                "Runtime registered for bundleId '\(bundleId)' but command bridge was not reachable within \(Self.formatTimeout(timeout))"
            )
        }
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

    private func findReachableReadySession(
        bundleId: String,
        excludingSessionId: String?,
        deadline: Date
    ) -> SessionInfo? {
        let candidates = registry.getByBundleId(bundleId)
            .filter { session in
                session.status == .ready && session.sessionId != excludingSessionId
            }
            .sorted { lhs, rhs in
                if lhs.lastHeartbeat != rhs.lastHeartbeat {
                    return lhs.lastHeartbeat > rhs.lastHeartbeat
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.sessionId < rhs.sessionId
            }

        guard !candidates.isEmpty else {
            return nil
        }

        for (index, candidate) in candidates.enumerated() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return nil
            }

            let remainingCandidates = candidates.count - index - 1
            let probeSlots = Double(remainingCandidates + 1)
            let maxTimeoutForCandidate = remainingCandidates > 0
                ? remaining / probeSlots
                : remaining
            let probeTimeout = min(
                Self.maximumBridgeProbeTimeout,
                maxTimeoutForCandidate
            )

            let isOnlyCandidate = index == 0 && remainingCandidates == 0
            guard probeTimeout > 0 else {
                return nil
            }

            guard !isOnlyCandidate || probeTimeout >= Self.minimumBridgeProbeTimeout else {
                return nil
            }

            if bridgeReadinessProbe(candidate, probeTimeout) {
                return candidate
            }
        }

        return nil
    }

}
