// SessionHealthMonitor.swift
// PlayCoverMCP

import Foundation

/// Periodically checks session health and removes stale sessions.
///
/// The monitor runs on a background timer and:
/// 1. Removes sessions whose `lastHeartbeat` exceeds the stale timeout
/// 2. Marks removed sessions as `.disconnected` before removal
///
/// Usage:
/// ```swift
/// let monitor = SessionHealthMonitor(registry: registry, staleTimeout: 30)
/// monitor.start(interval: 10.0) // check every 10s
/// // ...
/// monitor.stop()
/// ```
public final class SessionHealthMonitor: Sendable {

    // MARK: - Configuration

    /// How long (in seconds) since the last heartbeat before a session is considered stale.
    public let staleTimeout: TimeInterval

    // MARK: - Dependencies

    private let registry: SessionRegistry

    // MARK: - Private

    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.playcover.session-health-monitor")

    /// Callback invoked when stale sessions are removed (for logging / testing).
    public var onStaleSessions: (([SessionInfo]) -> Void)?

    // MARK: - Init

    /// Create a health monitor.
    /// - Parameters:
    ///   - registry: The session registry to monitor.
    ///   - staleTimeout: Seconds since last heartbeat before a session is considered stale (default: 30s).
    public init(registry: SessionRegistry, staleTimeout: TimeInterval = 30.0) {
        self.registry = registry
        self.staleTimeout = staleTimeout
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start periodic health checks.
    /// - Parameter interval: Time between checks in seconds (default: 10s).
    public func start(interval: TimeInterval = 10.0) {
        lock.lock()
        defer { lock.unlock() }

        // Cancel any existing timer
        timer?.cancel()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            self?.checkHealth()
        }
        source.resume()
        self.timer = source
    }

    /// Stop the health monitor.
    public func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()

        t?.cancel()
    }

    /// Whether the monitor is currently running.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    /// Manually trigger a health check (useful for testing).
    public func checkHealth() {
        let stale = registry.removeStaleSessions(timeout: staleTimeout)
        if !stale.isEmpty {
            onStaleSessions?(stale)
        }
    }
}
