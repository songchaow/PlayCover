// InputService.swift
// PlayCoverMCP

import Foundation

// MARK: - Input Command Parameters

/// Parameters for a press_key command.
///
/// Supported key values include:
/// - Single characters: `"a"`, `"1"`, `" "` (space)
/// - Named keys: `"enter"`, `"escape"`, `"tab"`, `"backspace"`, `"delete"`
/// - Arrow keys: `"up"`, `"down"`, `"left"`, `"right"`
/// - Function keys: `"f1"` through `"f12"`
/// - Modifier keys: `"shift"`, `"control"`, `"option"`, `"command"`
public struct KeyPressParams: Codable, Equatable, Sendable {
    /// The key to press (e.g. "a", "enter", "escape", "space").
    public let key: String
    /// Optional modifier keys held during the press (e.g. ["shift", "command"]).
    public let modifiers: [String]?

    public init(key: String, modifiers: [String]? = nil) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Parameters for a type_text command.
public struct TypeTextParams: Codable, Equatable, Sendable {
    /// The text string to type.
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Result returned after an input command completes.
public struct InputResult: Codable, Equatable, Sendable {
    /// Whether the command was executed successfully on the runtime side.
    public let success: Bool
    /// The command that was executed ("press_key", "type_text", or "toggle_debug_overlay").
    public let command: String
    /// Optional detail about what was executed.
    public let detail: String?

    public init(success: Bool, command: String, detail: String? = nil) {
        self.success = success
        self.command = command
        self.detail = detail
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "success": success,
            "command": command,
        ]
        if let detail = detail {
            dict["detail"] = detail
        }
        return dict
    }
}

// MARK: - Input Error

/// Errors specific to input commands.
public enum InputError: Error, LocalizedError, Equatable {
    case invalidKey(String)
    case invalidText(String)
    case sessionNotReady(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let detail): return "Invalid key: \(detail)"
        case .invalidText(let detail): return "Invalid text: \(detail)"
        case .sessionNotReady(let detail): return "Session not ready for input: \(detail)"
        case .commandFailed(let detail): return "Input command failed: \(detail)"
        }
    }
}

// MARK: - Supported Keys

/// Known key names that are accepted by press_key.
public enum SupportedKeys {
    /// All supported named keys.
    public static let namedKeys: Set<String> = [
        // Whitespace / control
        "enter", "return", "escape", "tab", "backspace", "delete", "space",
        // Arrow keys
        "up", "down", "left", "right",
        // Function keys
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        // Modifiers (can be pressed alone)
        "shift", "control", "option", "command",
        // Common extras
        "home", "end", "pageup", "pagedown", "capslock",
    ]

    /// Valid modifier names for the modifiers array.
    public static let modifierNames: Set<String> = [
        "shift", "control", "option", "command", "alt",
    ]

    /// Check if a key is valid (either a single character or a named key).
    public static func isValid(_ key: String) -> Bool {
        if key.count == 1 { return true }
        return namedKeys.contains(key.lowercased())
    }

    /// Check if a modifier name is valid.
    public static func isValidModifier(_ modifier: String) -> Bool {
        return modifierNames.contains(modifier.lowercased())
    }
}

// MARK: - Input Service Protocol

/// Protocol for input services, enabling fake implementations for testing.
public protocol InputServiceProtocol {
    func pressKey(sessionId: String, params: KeyPressParams) async throws -> InputResult
    func typeText(sessionId: String, params: TypeTextParams) async throws -> InputResult
    func toggleDebugOverlay(sessionId: String) async throws -> InputResult
}

// MARK: - Input Service

/// Service that sends input commands (key press, text, debug overlay) to a runtime through the bridge.
///
/// Key presses are sent as bridge commands with the key name and optional modifiers.
/// Text input sends the entire string to the runtime for sequential key injection.
/// Debug overlay toggles the runtime's DebugController.
public final class InputService: InputServiceProtocol, Sendable {

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

    // MARK: - Press Key

    /// Send a key press to the runtime.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - params: Key press parameters (key name, optional modifiers).
    /// - Returns: An `InputResult` describing the outcome.
    /// - Throws: `InputError` or `BridgeProtocolError`.
    public func pressKey(sessionId: String, params: KeyPressParams) async throws -> InputResult {
        try validateKey(params.key)
        if let modifiers = params.modifiers {
            for modifier in modifiers {
                guard SupportedKeys.isValidModifier(modifier) else {
                    throw InputError.invalidKey("Unknown modifier: '\(modifier)'. Valid modifiers: \(SupportedKeys.modifierNames.sorted().joined(separator: ", "))")
                }
            }
        }

        let session = try getReadySession(sessionId)

        var bridgeDict: [String: Any] = ["key": params.key]
        if let modifiers = params.modifiers, !modifiers.isEmpty {
            bridgeDict["modifiers"] = modifiers
        }
        let bridgeParams = AnyCodable(bridgeDict)

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        _ = try await client.sendCommand("press_key", params: bridgeParams, timeout: 5.0)

        let modDesc = params.modifiers.map { $0.isEmpty ? "" : "\($0.joined(separator: "+"))+" } ?? ""
        return InputResult(success: true, command: "press_key", detail: "\(modDesc)\(params.key)")
    }

    // MARK: - Type Text

    /// Send text input to the runtime.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - params: Type text parameters (text string).
    /// - Returns: An `InputResult` describing the outcome.
    /// - Throws: `InputError` or `BridgeProtocolError`.
    public func typeText(sessionId: String, params: TypeTextParams) async throws -> InputResult {
        try validateText(params.text)

        let session = try getReadySession(sessionId)

        let bridgeParams = AnyCodable(["text": params.text] as [String: Any])

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        // Allow more time for longer texts
        let timeoutSec = max(5.0, Double(params.text.count) * 0.1 + 5.0)
        _ = try await client.sendCommand("type_text", params: bridgeParams, timeout: timeoutSec)

        return InputResult(success: true, command: "type_text", detail: "\(params.text.count) character(s)")
    }

    // MARK: - Toggle Debug Overlay

    /// Toggle the debug overlay on the runtime.
    ///
    /// - Parameter sessionId: The target session identifier.
    /// - Returns: An `InputResult` describing the outcome.
    /// - Throws: `InputError` or `BridgeProtocolError`.
    public func toggleDebugOverlay(sessionId: String) async throws -> InputResult {
        let session = try getReadySession(sessionId)

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        _ = try await client.sendCommand("toggle_debug_overlay", timeout: 5.0)

        return InputResult(success: true, command: "toggle_debug_overlay", detail: "toggled")
    }

    // MARK: - Validation

    private func validateKey(_ key: String) throws {
        if key.isEmpty {
            throw InputError.invalidKey("Key must not be empty")
        }
        guard SupportedKeys.isValid(key) else {
            throw InputError.invalidKey("Unknown key: '\(key)'. Use a single character or a named key (e.g. 'enter', 'escape', 'tab', 'up', 'down', etc.)")
        }
    }

    private func validateText(_ text: String) throws {
        if text.isEmpty {
            throw InputError.invalidText("Text must not be empty")
        }
        if text.count > 10_000 {
            throw InputError.invalidText("Text length must be at most 10000 characters (got \(text.count))")
        }
    }

    private func getReadySession(_ sessionId: String) throws -> SessionInfo {
        guard let session = registry.get(sessionId) else {
            throw SessionError.sessionNotFound(sessionId)
        }
        guard session.status == .ready else {
            throw InputError.sessionNotReady("Session '\(sessionId)' is in '\(session.status.rawValue)' state, expected 'ready'")
        }
        return session
    }
}

// MARK: - Fake Input Service (for testing)

/// A fake input service that records commands without making real bridge connections.
/// Useful for testing MCP tool handlers in isolation.
public final class FakeInputService: InputServiceProtocol, Sendable {

    private let lock = NSLock()
    private var _pressKeyCalls: [(sessionId: String, params: KeyPressParams)] = []
    private var _typeTextCalls: [(sessionId: String, params: TypeTextParams)] = []
    private var _toggleDebugOverlayCalls: [String] = []
    private var _shouldFail: Bool = false
    private var _failureMessage: String = "Fake failure"

    public init() {}

    /// All recorded press_key calls.
    public var pressKeyCalls: [(sessionId: String, params: KeyPressParams)] {
        lock.lock()
        defer { lock.unlock() }
        return _pressKeyCalls
    }

    /// All recorded type_text calls.
    public var typeTextCalls: [(sessionId: String, params: TypeTextParams)] {
        lock.lock()
        defer { lock.unlock() }
        return _typeTextCalls
    }

    /// All recorded toggle_debug_overlay calls (session IDs).
    public var toggleDebugOverlayCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _toggleDebugOverlayCalls
    }

    /// Configure the fake to throw errors.
    public func setShouldFail(_ fail: Bool, message: String = "Fake failure") {
        lock.lock()
        _shouldFail = fail
        _failureMessage = message
        lock.unlock()
    }

    public func pressKey(sessionId: String, params: KeyPressParams) async throws -> InputResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _pressKeyCalls.append((sessionId: sessionId, params: params))
        lock.unlock()

        if shouldFail {
            throw InputError.commandFailed(message)
        }

        let modDesc = params.modifiers.map { $0.isEmpty ? "" : "\($0.joined(separator: "+"))+" } ?? ""
        return InputResult(success: true, command: "press_key", detail: "\(modDesc)\(params.key)")
    }

    public func typeText(sessionId: String, params: TypeTextParams) async throws -> InputResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _typeTextCalls.append((sessionId: sessionId, params: params))
        lock.unlock()

        if shouldFail {
            throw InputError.commandFailed(message)
        }

        return InputResult(success: true, command: "type_text", detail: "\(params.text.count) character(s)")
    }

    public func toggleDebugOverlay(sessionId: String) async throws -> InputResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _toggleDebugOverlayCalls.append(sessionId)
        lock.unlock()

        if shouldFail {
            throw InputError.commandFailed(message)
        }

        return InputResult(success: true, command: "toggle_debug_overlay", detail: "toggled")
    }
}
