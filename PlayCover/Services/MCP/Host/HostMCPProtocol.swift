import Foundation

enum HostMCPValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([HostMCPValue])
    case object([String: HostMCPValue])

    init(from decoder: Decoder) throws {
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
        } else if let value = try? container.decode([HostMCPValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HostMCPValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported HostMCPValue payload")
        }
    }

    func encode(to encoder: Encoder) throws {
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

extension HostMCPValue {
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

    var arrayValue: [HostMCPValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: HostMCPValue]? {
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

struct HostToolCall: Codable, Equatable {
    let name: String
    let arguments: [String: HostMCPValue]

    init(name: String, arguments: [String: HostMCPValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

enum HostToolErrorCode: String, Codable {
    case toolNotFound
    case invalidArguments
    case appNotFound
    case fileNotFound
    case preconditionFailed
    case executionFailed
}

struct HostToolError: Error, Codable, Equatable {
    let code: HostToolErrorCode
    let message: String
    let details: [String: HostMCPValue]

    init(code: HostToolErrorCode, message: String, details: [String: HostMCPValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension HostToolError: LocalizedError {
    var errorDescription: String? {
        message
    }
}

extension HostToolError {
    static func toolNotFound(_ toolName: String) -> HostToolError {
        HostToolError(
            code: .toolNotFound,
            message: "Unknown host tool: \(toolName)",
            details: ["tool": .string(toolName)]
        )
    }

    static func invalidArgument(
        name: String,
        expected: String,
        actual: HostMCPValue? = nil
    ) -> HostToolError {
        var details: [String: HostMCPValue] = [
            "argument": .string(name),
            "expected": .string(expected)
        ]
        if let actual {
            details["actual"] = .string(actual.debugTypeName)
        }

        return HostToolError(
            code: .invalidArguments,
            message: "Invalid argument '\(name)'. Expected \(expected).",
            details: details
        )
    }

    static func missingArgument(_ name: String) -> HostToolError {
        HostToolError(
            code: .invalidArguments,
            message: "Missing required argument '\(name)'.",
            details: ["argument": .string(name)]
        )
    }

    static func unexpectedArguments(_ keys: [String]) -> HostToolError {
        HostToolError(
            code: .invalidArguments,
            message: "Unexpected arguments: \(keys.joined(separator: ", ")).",
            details: ["unexpected_keys": .array(keys.map { .string($0) })]
        )
    }

    static func appNotFound(bundleID: String) -> HostToolError {
        HostToolError(
            code: .appNotFound,
            message: "Installed app not found for bundle id '\(bundleID)'.",
            details: ["bundle_id": .string(bundleID)]
        )
    }

    static func fileNotFound(path: String) -> HostToolError {
        HostToolError(
            code: .fileNotFound,
            message: "File does not exist at path '\(path)'.",
            details: ["path": .string(path)]
        )
    }

    static func preconditionFailed(
        _ message: String,
        details: [String: HostMCPValue] = [:]
    ) -> HostToolError {
        HostToolError(code: .preconditionFailed, message: message, details: details)
    }

    static func executionFailed(
        _ message: String,
        details: [String: HostMCPValue] = [:]
    ) -> HostToolError {
        HostToolError(code: .executionFailed, message: message, details: details)
    }
}

struct HostToolResult: Codable, Equatable {
    let ok: Bool
    let message: String
    let data: HostMCPValue?
    let warnings: [String]
    let debug: [String: HostMCPValue]
    let error: HostToolError?

    static func success(
        message: String,
        data: HostMCPValue? = nil,
        warnings: [String] = [],
        debug: [String: HostMCPValue] = [:]
    ) -> HostToolResult {
        HostToolResult(
            ok: true,
            message: message,
            data: data,
            warnings: warnings,
            debug: debug,
            error: nil
        )
    }

    static func failure(
        _ error: HostToolError,
        warnings: [String] = [],
        debug: [String: HostMCPValue] = [:]
    ) -> HostToolResult {
        HostToolResult(
            ok: false,
            message: error.message,
            data: nil,
            warnings: warnings,
            debug: debug,
            error: error
        )
    }
}

struct HostToolArguments {
    let rawValue: [String: HostMCPValue]

    init(_ rawValue: [String: HostMCPValue]) {
        self.rawValue = rawValue
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = rawValue[key] else { return nil }
        guard let stringValue = value.stringValue else {
            throw HostToolError.invalidArgument(name: key, expected: "string", actual: value)
        }
        return stringValue
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw HostToolError.missingArgument(key)
        }
        return value
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = rawValue[key] else { return nil }
        guard let boolValue = value.boolValue else {
            throw HostToolError.invalidArgument(name: key, expected: "bool", actual: value)
        }
        return boolValue
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = rawValue[key] else { return nil }
        guard let intValue = value.intValue else {
            throw HostToolError.invalidArgument(name: key, expected: "int", actual: value)
        }
        return intValue
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = rawValue[key] else { return nil }
        guard let doubleValue = value.doubleValue else {
            throw HostToolError.invalidArgument(name: key, expected: "double", actual: value)
        }
        return doubleValue
    }

    func optionalArray(_ key: String) throws -> [HostMCPValue]? {
        guard let value = rawValue[key] else { return nil }
        guard let arrayValue = value.arrayValue else {
            throw HostToolError.invalidArgument(name: key, expected: "array", actual: value)
        }
        return arrayValue
    }

    func optionalObject(_ key: String) throws -> [String: HostMCPValue]? {
        guard let value = rawValue[key] else { return nil }
        guard let objectValue = value.objectValue else {
            throw HostToolError.invalidArgument(name: key, expected: "object", actual: value)
        }
        return objectValue
    }

    func unexpectedKeys(allowed: Set<String>) -> [String] {
        rawValue.keys.filter { !allowed.contains($0) }.sorted()
    }

    func validateKeys(allowed: Set<String>) throws {
        let unexpected = unexpectedKeys(allowed: allowed)
        guard unexpected.isEmpty else {
            throw HostToolError.unexpectedArguments(unexpected)
        }
    }
}
