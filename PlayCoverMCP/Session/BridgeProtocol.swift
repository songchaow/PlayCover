// BridgeProtocol.swift
// PlayCoverMCP

import Foundation

// MARK: - Bridge Message Type

/// Discriminator for bridge messages exchanged between host and runtime.
public enum BridgeMessageType: String, Codable, Equatable, Sendable {
    case register        // runtime -> host: register a new session
    case registerAck     // host -> runtime: acknowledge registration
    case ping            // either direction: heartbeat
    case pong            // either direction: heartbeat response
    case command         // host -> runtime: send a command (tap, swipe, etc.)
    case commandResponse // runtime -> host: command result
    case error           // either direction: error
    case close           // either direction: close session
}

// MARK: - Payload Types

/// Payload for a `register` message: runtime tells host about itself.
public struct RegisterPayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let bundleId: String
    public let pid: Int32
    public let runtimePort: UInt16

    public init(sessionId: String, bundleId: String, pid: Int32, runtimePort: UInt16) {
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.pid = pid
        self.runtimePort = runtimePort
    }
}

/// Payload for a `register_ack` message: host confirms registration.
public struct RegisterAckPayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let status: String // "ok" or error description

    public init(sessionId: String, status: String) {
        self.sessionId = sessionId
        self.status = status
    }
}

/// Payload for a `ping` message.
public struct PingPayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let timestamp: Double

    public init(sessionId: String, timestamp: Double = Date().timeIntervalSince1970) {
        self.sessionId = sessionId
        self.timestamp = timestamp
    }
}

/// Payload for a `pong` message.
public struct PongPayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let timestamp: Double

    public init(sessionId: String, timestamp: Double = Date().timeIntervalSince1970) {
        self.sessionId = sessionId
        self.timestamp = timestamp
    }
}

/// Payload for a `command` message: host instructs runtime to perform an action.
public struct CommandPayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let commandId: String
    public let command: String // e.g. "tap", "swipe", "long_press"
    public let params: AnyCodable?

    public init(sessionId: String, commandId: String, command: String, params: AnyCodable? = nil) {
        self.sessionId = sessionId
        self.commandId = commandId
        self.command = command
        self.params = params
    }
}

/// Payload for a `command_response` message: runtime reports command result.
public struct CommandResponsePayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let commandId: String
    public let status: String // "ok" or "error"
    public let result: AnyCodable?

    public init(sessionId: String, commandId: String, status: String, result: AnyCodable? = nil) {
        self.sessionId = sessionId
        self.commandId = commandId
        self.status = status
        self.result = result
    }
}

/// Payload for an `error` message.
public struct BridgeErrorPayload: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let code: Int
    public let message: String

    public init(sessionId: String? = nil, code: Int, message: String) {
        self.sessionId = sessionId
        self.code = code
        self.message = message
    }
}

/// Payload for a `close` message.
public struct ClosePayload: Codable, Equatable, Sendable {
    public let sessionId: String
    public let reason: String?

    public init(sessionId: String, reason: String? = nil) {
        self.sessionId = sessionId
        self.reason = reason
    }
}

// MARK: - Bridge Message

/// A type-safe, discriminated union for all bridge messages.
///
/// Wire format: newline-delimited JSON with a `type` discriminator.
/// Example:
/// ```json
/// {"type":"register","sessionId":"sess-1","bundleId":"com.example","pid":12345,"runtimePort":52742}
/// ```
public enum BridgeMessage: Codable, Equatable, Sendable {
    case register(RegisterPayload)
    case registerAck(RegisterAckPayload)
    case ping(PingPayload)
    case pong(PongPayload)
    case command(CommandPayload)
    case commandResponse(CommandResponsePayload)
    case error(BridgeErrorPayload)
    case close(ClosePayload)

    /// The message type discriminator.
    public var type: BridgeMessageType {
        switch self {
        case .register: return .register
        case .registerAck: return .registerAck
        case .ping: return .ping
        case .pong: return .pong
        case .command: return .command
        case .commandResponse: return .commandResponse
        case .error: return .error
        case .close: return .close
        }
    }

    /// Extract the sessionId if available.
    public var sessionId: String? {
        switch self {
        case .register(let p): return p.sessionId
        case .registerAck(let p): return p.sessionId
        case .ping(let p): return p.sessionId
        case .pong(let p): return p.sessionId
        case .command(let p): return p.sessionId
        case .commandResponse(let p): return p.sessionId
        case .error(let p): return p.sessionId
        case .close(let p): return p.sessionId
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case type, sessionId, bundleId, pid, runtimePort,
             timestamp, commandId, command, params, status, result,
             code, message, reason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)

        switch self {
        case .register(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.bundleId, forKey: .bundleId)
            try container.encode(p.pid, forKey: .pid)
            try container.encode(p.runtimePort, forKey: .runtimePort)

        case .registerAck(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.status, forKey: .status)

        case .ping(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.timestamp, forKey: .timestamp)

        case .pong(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.timestamp, forKey: .timestamp)

        case .command(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.commandId, forKey: .commandId)
            try container.encode(p.command, forKey: .command)
            try container.encodeIfPresent(p.params, forKey: .params)

        case .commandResponse(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encode(p.commandId, forKey: .commandId)
            try container.encode(p.status, forKey: .status)
            try container.encodeIfPresent(p.result, forKey: .result)

        case .error(let p):
            try container.encodeIfPresent(p.sessionId, forKey: .sessionId)
            try container.encode(p.code, forKey: .code)
            try container.encode(p.message, forKey: .message)

        case .close(let p):
            try container.encode(p.sessionId, forKey: .sessionId)
            try container.encodeIfPresent(p.reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BridgeMessageType.self, forKey: .type)

        switch type {
        case .register:
            let p = RegisterPayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                bundleId: try container.decode(String.self, forKey: .bundleId),
                pid: try container.decode(Int32.self, forKey: .pid),
                runtimePort: try container.decode(UInt16.self, forKey: .runtimePort)
            )
            self = .register(p)

        case .registerAck:
            let p = RegisterAckPayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                status: try container.decode(String.self, forKey: .status)
            )
            self = .registerAck(p)

        case .ping:
            let p = PingPayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                timestamp: try container.decode(Double.self, forKey: .timestamp)
            )
            self = .ping(p)

        case .pong:
            let p = PongPayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                timestamp: try container.decode(Double.self, forKey: .timestamp)
            )
            self = .pong(p)

        case .command:
            let params: AnyCodable? = try container.decodeIfPresent(AnyCodable.self, forKey: .params)
            let p = CommandPayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                commandId: try container.decode(String.self, forKey: .commandId),
                command: try container.decode(String.self, forKey: .command),
                params: params
            )
            self = .command(p)

        case .commandResponse:
            let result: AnyCodable? = try container.decodeIfPresent(AnyCodable.self, forKey: .result)
            let p = CommandResponsePayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                commandId: try container.decode(String.self, forKey: .commandId),
                status: try container.decode(String.self, forKey: .status),
                result: result
            )
            self = .commandResponse(p)

        case .error:
            let p = BridgeErrorPayload(
                sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
                code: try container.decode(Int.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
            self = .error(p)

        case .close:
            let p = ClosePayload(
                sessionId: try container.decode(String.self, forKey: .sessionId),
                reason: try container.decodeIfPresent(String.self, forKey: .reason)
            )
            self = .close(p)
        }
    }
}

// MARK: - Wire Format Helpers

/// Encode a `BridgeMessage` to JSON data (single line).
public func bridgeEncode(_ message: BridgeMessage) throws -> Data {
    try JSONEncoder().encode(message)
}

/// Decode a JSON line into a `BridgeMessage`.
public func bridgeDecode(_ data: Data) throws -> BridgeMessage {
    try JSONDecoder().decode(BridgeMessage.self, from: data)
}

/// Encode a `BridgeMessage` to a JSON string (single line, no trailing newline).
public func bridgeEncodeToString(_ message: BridgeMessage) throws -> String {
    let data = try bridgeEncode(message)
    return String(data: data, encoding: .utf8) ?? ""
}

/// Decode a JSON string into a `BridgeMessage`.
public func bridgeDecodeFromString(_ string: String) throws -> BridgeMessage {
    guard let data = string.data(using: .utf8) else {
        throw BridgeProtocolError.invalidUTF8
    }
    return try bridgeDecode(data)
}

// MARK: - Framing

/// Read newline-delimited JSON messages from a data buffer.
///
/// Returns (messages, remainingData). Each message must end with '\n'.
public func bridgeParseFramed(_ data: Data) -> (messages: [BridgeMessage], remaining: Data) {
    var messages: [BridgeMessage] = []
    var remaining = data
    let newline = Data("\n".utf8)

    while let range = remaining.range(of: newline) {
        let lineData = remaining[remaining.startIndex..<range.lowerBound]
        remaining = Data(remaining[range.upperBound...])
        if !lineData.isEmpty {
            if let message = try? bridgeDecode(lineData) {
                messages.append(message)
            }
        }
    }

    return (messages, remaining)
}

/// Frame a single message for transmission (JSON + newline).
public func bridgeFrame(_ message: BridgeMessage) throws -> Data {
    var data = try bridgeEncode(message)
    data.append("\n".data(using: .utf8)!)
    return data
}

// MARK: - Well-Known Command Names

/// Command name constants for use with `CommandPayload.command`.
///
/// These strings are shared between `BridgeClient` (host side) and
/// `BridgeListener` (runtime side). Adding a constant here ensures
/// both sides use the same wire value.
public enum BridgeCommandName {
    // -- Touch / Input --
    public static let tap = "tap"
    public static let longPress = "long_press"
    public static let swipe = "swipe"
    public static let drag = "drag"
    public static let pressKey = "press_key"
    public static let typeText = "type_text"
    public static let toggleDebugOverlay = "toggle_debug_overlay"

    // -- Runtime -> Host utility commands --
    /// Ask the host PlayCover process to run `llvm-dis` on behalf of the injected runtime.
    ///
    /// Params:
    /// - `bitcode_base64` (String): base64-encoded LLVM bitcode payload.
    /// - `timeout_seconds` (Int, optional): host-side execution timeout.
    ///
    /// Response data:
    /// - `ir_text` (String): disassembled LLVM IR text.
    /// - `elapsed_seconds` (Double): host-side execution time.
    /// - `input_size` (Int): input bitcode size.
    /// - `output_size` (Int): output IR text size.
    /// - `executable_path` (String): actual `llvm-dis` path used by host.
    public static let hostDisassembleBitcode = "host_disassemble_bitcode"

    // -- Metal Capture (R03) --
    /// Trigger a one-frame GPU capture.
    ///
    /// Params (all optional):
    /// - `output_path` (String): custom `.gputrace` file path.
    /// - `duration_ms` (Int): capture duration in ms (default 100).
    /// - `capture_target` (String): one of `device`, `scope`, `queue`, `queue_scope`.
    ///
    /// Response data:
    /// - `output_path` (String): actual file path of the `.gputrace`.
    /// - `message` (String): human-readable status.
    public static let captureFrame = "capture_frame"

    /// Query the current Metal capture status.
    ///
    /// Params: none.
    ///
    /// Response data:
    /// - `available` (Bool): whether `MTLCaptureManager` is accessible.
    /// - `supports_gpu_trace` (Bool): whether `.gpuTraceDocument` destination is supported.
    /// - `supports_developer_tools` (Bool, optional): whether capture is available to Xcode / developer tools.
    /// - `has_default_device` (Bool, optional): whether the runtime process can see a default Metal device.
    /// - `default_device_name` (String, optional): the runtime-visible default Metal device name.
    /// - `is_capturing` (Bool): whether a capture is currently in progress.
    /// - `enabled` (Bool): whether `metalCaptureEnabled` is ON in settings.
    /// - `failure_reason` (String, optional): stable diagnostic reason when capture is not ready.
    /// - `diagnostic_summary` (String, optional): flattened runtime diagnostics for debugging.
    public static let getCaptureStatus = "get_capture_status"
}

// MARK: - Errors

/// Errors specific to the bridge protocol.
public enum BridgeProtocolError: Error, LocalizedError, Equatable {
    case invalidUTF8
    case invalidMessage(String)
    case timeout(String)
    case connectionClosed
    case connectionRefused
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Invalid UTF-8 in bridge message"
        case .invalidMessage(let detail): return "Invalid bridge message: \(detail)"
        case .timeout(let detail): return "Bridge operation timed out: \(detail)"
        case .connectionClosed: return "Bridge connection closed"
        case .connectionRefused: return "Bridge connection refused"
        case .encodingFailed(let detail): return "Bridge encoding failed: \(detail)"
        }
    }
}
