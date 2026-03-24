// SessionInfo.swift
// PlayCoverMCP

import Foundation

// MARK: - Session Info

/// Represents an active session between the MCP host and a runtime (PlayTools in an app process).
public struct SessionInfo: Codable, Equatable, Sendable {
    /// Unique session identifier.
    public let sessionId: String

    /// Bundle identifier of the app this session is for.
    public let bundleId: String

    /// Process ID of the runtime (app process).
    public let pid: Int32

    /// The TCP port on which the runtime is listening for commands.
    public let runtimePort: UInt16

    /// When the session was registered.
    public let createdAt: Date

    /// Last time a heartbeat (ping/pong) was received from this runtime.
    public var lastHeartbeat: Date

    public init(
        sessionId: String,
        bundleId: String,
        pid: Int32,
        runtimePort: UInt16,
        createdAt: Date = Date(),
        lastHeartbeat: Date = Date()
    ) {
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.pid = pid
        self.runtimePort = runtimePort
        self.createdAt = createdAt
        self.lastHeartbeat = lastHeartbeat
    }

    /// Create a SessionInfo from a RegisterPayload.
    public init(from payload: RegisterPayload) {
        self.sessionId = payload.sessionId
        self.bundleId = payload.bundleId
        self.pid = payload.pid
        self.runtimePort = payload.runtimePort
        self.createdAt = Date()
        self.lastHeartbeat = Date()
    }

    /// Convert to a dictionary for MCP JSON responses.
    public func toDictionary() -> [String: Any] {
        [
            "sessionId": sessionId,
            "bundleId": bundleId,
            "pid": Int(pid),
            "runtimePort": Int(runtimePort),
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "lastHeartbeat": ISO8601DateFormatter().string(from: lastHeartbeat),
        ]
    }
}

// MARK: - Session Error

/// Errors related to session management.
public enum SessionError: Error, LocalizedError, Equatable {
    case sessionNotFound(String)
    case sessionAlreadyExists(String)
    case invalidSessionId(String)
    case heartbeatTimeout(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "Session not found: \(id)"
        case .sessionAlreadyExists(let id): return "Session already exists: \(id)"
        case .invalidSessionId(let id): return "Invalid session ID: \(id)"
        case .heartbeatTimeout(let id): return "Session heartbeat timed out: \(id)"
        }
    }
}
