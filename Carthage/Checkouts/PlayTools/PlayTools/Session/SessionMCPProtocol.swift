import Foundation

public enum SessionMCPValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SessionMCPValue])
    case object([String: SessionMCPValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SessionMCPValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SessionMCPValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported SessionMCPValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public extension SessionMCPValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .int(value):
            return value
        case let .double(value) where value.rounded() == value:
            return Int(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        default:
            return nil
        }
    }

    var arrayValue: [SessionMCPValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: SessionMCPValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var debugTypeName: String {
        switch self {
        case .null:
            return "null"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .double:
            return "double"
        case .string:
            return "string"
        case .array:
            return "array"
        case .object:
            return "object"
        }
    }
}

public struct SessionToolCall: Codable, Equatable {
    public let name: String
    public let arguments: [String: SessionMCPValue]

    public init(name: String, arguments: [String: SessionMCPValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

public enum SessionToolErrorCode: String, Codable {
    case toolNotFound
    case invalidArguments
    case preconditionFailed
    case executionFailed
}

public struct SessionToolError: Error, Codable, Equatable {
    public let code: SessionToolErrorCode
    public let message: String
    public let details: [String: SessionMCPValue]

    public init(
        code: SessionToolErrorCode,
        message: String,
        details: [String: SessionMCPValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension SessionToolError: LocalizedError {
    public var errorDescription: String? {
        message
    }
}

public extension SessionToolError {
    static func toolNotFound(_ toolName: String) -> SessionToolError {
        SessionToolError(
            code: .toolNotFound,
            message: "Unknown session tool: \(toolName)",
            details: ["tool": .string(toolName)]
        )
    }

    static func invalidArgument(
        name: String,
        expected: String,
        actual: SessionMCPValue? = nil
    ) -> SessionToolError {
        var details: [String: SessionMCPValue] = [
            "argument": .string(name),
            "expected": .string(expected)
        ]
        if let actual {
            details["actual"] = .string(actual.debugTypeName)
        }

        return SessionToolError(
            code: .invalidArguments,
            message: "Invalid argument '\(name)'. Expected \(expected).",
            details: details
        )
    }

    static func missingArgument(_ name: String) -> SessionToolError {
        SessionToolError(
            code: .invalidArguments,
            message: "Missing required argument '\(name)'.",
            details: ["argument": .string(name)]
        )
    }

    static func unexpectedArguments(_ keys: [String]) -> SessionToolError {
        SessionToolError(
            code: .invalidArguments,
            message: "Unexpected arguments: \(keys.joined(separator: ", ")).",
            details: ["unexpected_keys": .array(keys.map { .string($0) })]
        )
    }

    static func preconditionFailed(
        _ message: String,
        details: [String: SessionMCPValue] = [:]
    ) -> SessionToolError {
        SessionToolError(code: .preconditionFailed, message: message, details: details)
    }

    static func executionFailed(
        _ message: String,
        details: [String: SessionMCPValue] = [:]
    ) -> SessionToolError {
        SessionToolError(code: .executionFailed, message: message, details: details)
    }
}

public struct SessionToolResult: Codable, Equatable {
    public let ok: Bool
    public let message: String
    public let data: SessionMCPValue?
    public let warnings: [String]
    public let debug: [String: SessionMCPValue]
    public let error: SessionToolError?

    public static func success(
        message: String,
        data: SessionMCPValue? = nil,
        warnings: [String] = [],
        debug: [String: SessionMCPValue] = [:]
    ) -> SessionToolResult {
        SessionToolResult(
            ok: true,
            message: message,
            data: data,
            warnings: warnings,
            debug: debug,
            error: nil
        )
    }

    public static func failure(
        _ error: SessionToolError,
        warnings: [String] = [],
        debug: [String: SessionMCPValue] = [:]
    ) -> SessionToolResult {
        SessionToolResult(
            ok: false,
            message: error.message,
            data: nil,
            warnings: warnings,
            debug: debug,
            error: error
        )
    }
}

public struct SessionToolArguments {
    public let rawValue: [String: SessionMCPValue]

    public init(_ rawValue: [String: SessionMCPValue]) {
        self.rawValue = rawValue
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = rawValue[key] else { return nil }
        guard let stringValue = value.stringValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "string", actual: value)
        }
        return stringValue
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return value
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = rawValue[key] else { return nil }
        guard let boolValue = value.boolValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "bool", actual: value)
        }
        return boolValue
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = rawValue[key] else { return nil }
        guard let intValue = value.intValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "int", actual: value)
        }
        return intValue
    }

    public func optionalDouble(_ key: String) throws -> Double? {
        guard let value = rawValue[key] else { return nil }
        guard let doubleValue = value.doubleValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "double", actual: value)
        }
        return doubleValue
    }

    public func optionalArray(_ key: String) throws -> [SessionMCPValue]? {
        guard let value = rawValue[key] else { return nil }
        guard let arrayValue = value.arrayValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "array", actual: value)
        }
        return arrayValue
    }

    public func optionalObject(_ key: String) throws -> [String: SessionMCPValue]? {
        guard let value = rawValue[key] else { return nil }
        guard let objectValue = value.objectValue else {
            throw SessionToolError.invalidArgument(name: key, expected: "object", actual: value)
        }
        return objectValue
    }

    public func unexpectedKeys(allowed: Set<String>) -> [String] {
        rawValue.keys.filter { !allowed.contains($0) }.sorted()
    }

    public func validateKeys(allowed: Set<String>) throws {
        let unexpected = unexpectedKeys(allowed: allowed)
        guard unexpected.isEmpty else {
            throw SessionToolError.unexpectedArguments(unexpected)
        }
    }
}
