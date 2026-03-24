// TouchService.swift
// PlayCoverMCP

import Foundation

// MARK: - Touch Command Parameters

/// Parameters for a tap command.
public struct TapParams: Codable, Equatable, Sendable {
    /// X coordinate in points (0 = left edge of the app window).
    public let x: Double
    /// Y coordinate in points (0 = top edge of the app window).
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Parameters for a long press command.
public struct LongPressParams: Codable, Equatable, Sendable {
    /// X coordinate in points (0 = left edge of the app window).
    public let x: Double
    /// Y coordinate in points (0 = top edge of the app window).
    public let y: Double
    /// Duration of the press in milliseconds (default: 500).
    public let durationMs: Int

    public init(x: Double, y: Double, durationMs: Int = 500) {
        self.x = x
        self.y = y
        self.durationMs = durationMs
    }
}

/// Result returned after a touch command completes.
public struct TouchResult: Codable, Equatable, Sendable {
    /// Whether the command was executed successfully on the runtime side.
    public let success: Bool
    /// The command that was executed ("tap" or "long_press").
    public let command: String
    /// X coordinate that was tapped.
    public let x: Double
    /// Y coordinate that was tapped.
    public let y: Double
    /// Duration in ms (only relevant for long_press).
    public let durationMs: Int?

    public init(success: Bool, command: String, x: Double, y: Double, durationMs: Int? = nil) {
        self.success = success
        self.command = command
        self.x = x
        self.y = y
        self.durationMs = durationMs
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "success": success,
            "command": command,
            "x": x,
            "y": y,
        ]
        if let durationMs = durationMs {
            dict["durationMs"] = durationMs
        }
        return dict
    }
}

// MARK: - Touch Error

/// Errors specific to touch commands.
public enum TouchError: Error, LocalizedError, Equatable {
    case invalidCoordinates(String)
    case invalidDuration(String)
    case sessionNotReady(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinates(let detail): return "Invalid touch coordinates: \(detail)"
        case .invalidDuration(let detail): return "Invalid duration: \(detail)"
        case .sessionNotReady(let detail): return "Session not ready for touch: \(detail)"
        case .commandFailed(let detail): return "Touch command failed: \(detail)"
        }
    }
}

// MARK: - Touch Service Protocol

/// Protocol for touch services, enabling fake implementations for testing.
public protocol TouchServiceProtocol {
    func tap(sessionId: String, params: TapParams) async throws -> TouchResult
    func longPress(sessionId: String, params: LongPressParams) async throws -> TouchResult
}

// MARK: - Touch Service

/// Service that sends touch commands to a runtime through the bridge.
///
/// Coordinates are in the app window's point coordinate system:
/// - (0, 0) = top-left corner
/// - x increases rightward
/// - y increases downward
///
/// The service validates coordinates (must be non-negative) and duration
/// (must be positive), then sends the command through a `BridgeClient`
/// connected to the session's runtime port.
public final class TouchService: TouchServiceProtocol, Sendable {

    // MARK: - Dependencies

    private let registry: SessionRegistry
    private let clientFactory: (String, UInt16) -> BridgeClient

    // MARK: - Init

    public init(
        registry: SessionRegistry,
        clientFactory: @escaping (String, UInt16) -> BridgeClient = { sessionId, port in
            BridgeClient(sessionId: sessionId, port: port)
        }
    ) {
        self.registry = registry
        self.clientFactory = clientFactory
    }

    // MARK: - Tap

    /// Execute a tap at the given coordinates.
    ///
    /// A tap is a touch-down immediately followed by a touch-up at the same point.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - params: Tap parameters (x, y coordinates).
    /// - Returns: A `TouchResult` describing the outcome.
    /// - Throws: `TouchError` or `BridgeProtocolError`.
    public func tap(sessionId: String, params: TapParams) async throws -> TouchResult {
        try validateCoordinates(x: params.x, y: params.y)

        let session = try getReadySession(sessionId)

        let bridgeParams = AnyCodable([
            "x": params.x,
            "y": params.y,
        ] as [String: Any])

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        _ = try await client.sendCommand("tap", params: bridgeParams, timeout: 5.0)

        return TouchResult(success: true, command: "tap", x: params.x, y: params.y)
    }

    // MARK: - Long Press

    /// Execute a long press at the given coordinates.
    ///
    /// A long press is a touch-down, hold for `durationMs` milliseconds,
    /// then touch-up at the same point.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - params: Long press parameters (x, y, durationMs).
    /// - Returns: A `TouchResult` describing the outcome.
    /// - Throws: `TouchError` or `BridgeProtocolError`.
    public func longPress(sessionId: String, params: LongPressParams) async throws -> TouchResult {
        try validateCoordinates(x: params.x, y: params.y)
        try validateDuration(params.durationMs)

        let session = try getReadySession(sessionId)

        let bridgeParams = AnyCodable([
            "x": params.x,
            "y": params.y,
            "durationMs": params.durationMs,
        ] as [String: Any])

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        // long_press timeout should accommodate the duration plus some buffer
        let timeoutSec = Double(params.durationMs) / 1000.0 + 5.0
        _ = try await client.sendCommand("long_press", params: bridgeParams, timeout: timeoutSec)

        return TouchResult(success: true, command: "long_press", x: params.x, y: params.y, durationMs: params.durationMs)
    }

    // MARK: - Validation

    private func validateCoordinates(x: Double, y: Double) throws {
        if x < 0 || y < 0 {
            throw TouchError.invalidCoordinates("Coordinates must be non-negative (got x=\(x), y=\(y))")
        }
        if x.isNaN || y.isNaN || x.isInfinite || y.isInfinite {
            throw TouchError.invalidCoordinates("Coordinates must be finite numbers (got x=\(x), y=\(y))")
        }
    }

    private func validateDuration(_ durationMs: Int) throws {
        if durationMs <= 0 {
            throw TouchError.invalidDuration("Duration must be positive (got \(durationMs)ms)")
        }
        if durationMs > 60_000 {
            throw TouchError.invalidDuration("Duration must be at most 60000ms (got \(durationMs)ms)")
        }
    }

    private func getReadySession(_ sessionId: String) throws -> SessionInfo {
        guard let session = registry.get(sessionId) else {
            throw SessionError.sessionNotFound(sessionId)
        }
        guard session.status == .ready else {
            throw TouchError.sessionNotReady("Session '\(sessionId)' is in '\(session.status.rawValue)' state, expected 'ready'")
        }
        return session
    }
}

// MARK: - Fake Touch Service (for testing)

/// A fake touch service that records commands without making real bridge connections.
/// Useful for testing MCP tool handlers in isolation.
public final class FakeTouchService: TouchServiceProtocol, Sendable {

    private let lock = NSLock()
    private var _tapCalls: [(sessionId: String, params: TapParams)] = []
    private var _longPressCalls: [(sessionId: String, params: LongPressParams)] = []
    private var _shouldFail: Bool = false
    private var _failureMessage: String = "Fake failure"

    public init() {}

    /// All recorded tap calls.
    public var tapCalls: [(sessionId: String, params: TapParams)] {
        lock.lock()
        defer { lock.unlock() }
        return _tapCalls
    }

    /// All recorded long press calls.
    public var longPressCalls: [(sessionId: String, params: LongPressParams)] {
        lock.lock()
        defer { lock.unlock() }
        return _longPressCalls
    }

    /// Configure the fake to throw errors.
    public func setShouldFail(_ fail: Bool, message: String = "Fake failure") {
        lock.lock()
        _shouldFail = fail
        _failureMessage = message
        lock.unlock()
    }

    public func tap(sessionId: String, params: TapParams) async throws -> TouchResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _tapCalls.append((sessionId: sessionId, params: params))
        lock.unlock()

        if shouldFail {
            throw TouchError.commandFailed(message)
        }

        return TouchResult(success: true, command: "tap", x: params.x, y: params.y)
    }

    public func longPress(sessionId: String, params: LongPressParams) async throws -> TouchResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _longPressCalls.append((sessionId: sessionId, params: params))
        lock.unlock()

        if shouldFail {
            throw TouchError.commandFailed(message)
        }

        return TouchResult(success: true, command: "long_press", x: params.x, y: params.y, durationMs: params.durationMs)
    }
}
