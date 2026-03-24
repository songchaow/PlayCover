// MCPErrorExtensions.swift
// PlayCoverMCP

import Foundation

// MARK: - Rich Error Categories

/// Categorized error codes for the PlayCover MCP server.
///
/// These extend beyond the base JSON-RPC codes to provide
/// domain-specific error information for MCP tool responses.
public enum PlayCoverErrorCode: Int, Sendable {
    // Business / domain errors (use -32000 range per JSON-RPC spec for server-defined errors)
    case appNotFound = -32001
    case invalidPath = -32002
    case signingFailed = -32003
    case injectionFailed = -32004
    case uninstallFailed = -32005
    case settingsError = -32006
    case keymapError = -32007
    case taskNotFound = -32008
    case taskAlreadyExists = -32009
    case invalidTaskState = -32010
    case sessionNotFound = -32011
    case bridgeError = -32012
    case entitlementsError = -32013
    case launchFailed = -32014
    case exportFailed = -32015

    /// The default message for this error code.
    public var defaultMessage: String {
        switch self {
        case .appNotFound: return "Application not found"
        case .invalidPath: return "Invalid file path"
        case .signingFailed: return "Code signing failed"
        case .injectionFailed: return "PlayTools injection failed"
        case .uninstallFailed: return "Uninstall failed"
        case .settingsError: return "Settings operation failed"
        case .keymapError: return "Keymap operation failed"
        case .taskNotFound: return "Task not found"
        case .taskAlreadyExists: return "Task already exists"
        case .invalidTaskState: return "Invalid task state transition"
        case .sessionNotFound: return "Session not found"
        case .bridgeError: return "Runtime bridge error"
        case .entitlementsError: return "Entitlements operation failed"
        case .launchFailed: return "App launch failed"
        case .exportFailed: return "IPA export failed"
        }
    }
}

// MARK: - PlayCover MCP Error

/// A rich, structured error type for PlayCover MCP tool handlers.
///
/// Provides categorized error codes, original cause chaining,
/// and structured MCP-compatible error output.
public struct PlayCoverMCPError: Error, LocalizedError, Equatable, Sendable {

    /// The MCP/JSON-RPC error code.
    public let code: Int

    /// Human-readable error message.
    public let message: String

    /// Optional structured error data (encoded as AnyCodable for MCP responses).
    public let data: AnyCodable?

    /// The underlying error that caused this error, if any.
    public let cause: String?

    // MARK: - Init

    public init(code: Int, message: String, data: AnyCodable? = nil, cause: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
        self.cause = cause
    }

    /// Create from a `PlayCoverErrorCode`.
    public init(code: PlayCoverErrorCode, message: String? = nil, data: AnyCodable? = nil, cause: String? = nil) {
        self.code = code.rawValue
        self.message = message ?? code.defaultMessage
        self.data = data
        self.cause = cause
    }

    /// Create from an arbitrary `Error`, preserving the cause chain.
    public init(wrapping error: Error, code: Int? = nil, message: String? = nil) {
        if let mcpErr = error as? PlayCoverMCPError {
            self = mcpErr
            return
        }
        if let mcpBase = error as? MCPError {
            let mappedCode: Int
            switch mcpBase {
            case .invalidParams: mappedCode = JSONRPCError.invalidParams
            case .methodNotRegistered: mappedCode = JSONRPCError.methodNotFound
            case .internalError: mappedCode = JSONRPCError.internalError
            case .invalidJSON: mappedCode = JSONRPCError.parseError
            case .unsupportedProtocolVersion: mappedCode = JSONRPCError.invalidParams
            }
            self.code = mappedCode
            self.message = message ?? mcpBase.localizedDescription
            self.data = nil
            self.cause = nil
            return
        }
        if let settingsErr = error as? SettingsError {
            switch settingsErr {
            case .appNotFound:
                self.code = PlayCoverErrorCode.appNotFound.rawValue
            case .invalidField, .settingsNotFound:
                self.code = PlayCoverErrorCode.settingsError.rawValue
            case .encodingFailed, .decodingFailed:
                self.code = JSONRPCError.internalError
            }
            self.message = message ?? settingsErr.localizedDescription
            self.data = nil
            self.cause = nil
            return
        }
        if let sessionErr = error as? SessionError {
            let mappedCode: Int
            switch sessionErr {
            case .sessionNotFound:
                mappedCode = PlayCoverErrorCode.sessionNotFound.rawValue
            case .sessionAlreadyExists, .invalidSessionId:
                mappedCode = JSONRPCError.invalidParams
            case .heartbeatTimeout:
                mappedCode = PlayCoverErrorCode.bridgeError.rawValue
            }
            self.code = mappedCode
            self.message = message ?? sessionErr.localizedDescription
            self.data = nil
            self.cause = nil
            return
        }
        if let touchErr = error as? TouchError {
            let mappedCode: Int
            switch touchErr {
            case .invalidCoordinates, .invalidDuration, .invalidSteps:
                mappedCode = JSONRPCError.invalidParams
            case .sessionNotReady:
                mappedCode = PlayCoverErrorCode.bridgeError.rawValue
            case .commandFailed:
                mappedCode = PlayCoverErrorCode.bridgeError.rawValue
            }
            self.code = mappedCode
            self.message = message ?? touchErr.localizedDescription
            self.data = nil
            self.cause = nil
            return
        }
        if let inputErr = error as? InputError {
            let mappedCode: Int
            switch inputErr {
            case .invalidKey, .invalidText:
                mappedCode = JSONRPCError.invalidParams
            case .sessionNotReady, .commandFailed:
                mappedCode = PlayCoverErrorCode.bridgeError.rawValue
            }
            self.code = mappedCode
            self.message = message ?? inputErr.localizedDescription
            self.data = nil
            self.cause = nil
            return
        }
        self.code = code ?? JSONRPCError.internalError
        self.message = message ?? error.localizedDescription
        self.data = nil
        self.cause = String(reflecting: type(of: error)) + ": " + error.localizedDescription
    }

    // MARK: - LocalizedError

    public var errorDescription: String? {
        if let cause = cause {
            return "\(message) (caused by: \(cause))"
        }
        return message
    }

    // MARK: - MCP Response Helpers

    /// Convert to a `JSONRPCResponse` error for the given request ID.
    public func toErrorResponse(id: RequestID?) -> JSONRPCResponse {
        .error(id: id, code: code, message: message, data: data)
    }

    /// Convert to `AnyCodable` for use as an error result in tool calls.
    public func toAnyCodable() -> AnyCodable {
        var dict: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let cause = cause {
            dict["cause"] = cause
        }
        return AnyCodable(dict)
    }
}

// MARK: - MCPError Extensions

extension MCPError {
    /// Convert this base MCP error to a `PlayCoverMCPError`.
    public var asPlayCoverError: PlayCoverMCPError {
        PlayCoverMCPError(wrapping: self)
    }
}

// MARK: - Error to MCP Response Mapping

/// Map any `Error` to a proper MCP JSON-RPC error response.
///
/// This is the centralized error handling function that all tool handlers
/// should use (directly or via MCPServer) to ensure consistent error responses.
public func mcpErrorResponse(id: RequestID?, error: Error) -> JSONRPCMessage {
    if let pce = error as? PlayCoverMCPError {
        return .response(pce.toErrorResponse(id: id))
    }
    if let mcpErr = error as? MCPError {
        return .response(mcpErr.asPlayCoverError.toErrorResponse(id: id))
    }
    // Generic fallback
    let wrapped = PlayCoverMCPError(wrapping: error)
    return .response(wrapped.toErrorResponse(id: id))
}
