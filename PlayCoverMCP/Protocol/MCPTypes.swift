// MCPTypes.swift
// PlayCoverMCPCore

import Foundation

// MARK: - Protocol Constants

public enum MCPProtocolVersion {
    public static let v2025_11_25 = "2025-11-25"
    public static let v2025_06_18 = "2025-06-18"
    public static let v2025_03_26 = "2025-03-26"
    public static let v2024_11_05 = "2024-11-05"

    public static let latest = v2025_11_25
    public static let supportedVersions: [String] = [
        v2025_11_25,
        v2025_06_18,
        v2025_03_26,
    ]

    public static func negotiate(with clientVersion: String) -> String {
        if supportedVersions.contains(clientVersion) {
            return clientVersion
        }

        let compatibleVersion = supportedVersions
            .filter { $0 <= clientVersion }
            .sorted()
            .last

        return compatibleVersion ?? latest
    }
}

public enum JSONRPCVersion {
    public static let two = "2.0"
}

// MARK: - RequestID

/// JSON-RPC request identifier — either a string or an integer.
public enum RequestID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .integer(i)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RequestID must be a string or integer"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        }
    }

    /// Convenience for building dictionaries (JSONSerialization interop).
    public var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .integer(let i): return i
        }
    }
}

// MARK: - AnyCodable

/// A type-erased Codable value that can represent any valid JSON.
public struct AnyCodable: Codable, Equatable, Sendable {
    public let value: Any?

    public init(_ value: Any?) {
        self.value = Self.normalized(value)
    }

    public init(nilValue: Void = ()) {
        self.value = nil
    }

    // MARK: Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = nil
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable cannot decode the given value"
            )
        }
    }

    // MARK: Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value {
            if let bool = v as? Bool {
                try container.encode(bool)
            } else if let int = v as? Int {
                try container.encode(int)
            } else if let double = v as? Double {
                try container.encode(double)
            } else if let string = v as? String {
                try container.encode(string)
            } else if let array = v as? [Any] {
                try container.encode(array.map { AnyCodable($0) })
            } else if let dict = v as? [String: Any] {
                try container.encode(dict.mapValues { AnyCodable($0) })
            } else {
                let context = EncodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "AnyCodable cannot encode the given value"
                )
                throw EncodingError.invalidValue(v, context)
            }
        } else {
            try container.encodeNil()
        }
    }

    // MARK: Conveniences

    /// Wrap any `Encodable` value via a JSON round-trip.
    public init(_ encodable: some Encodable) throws {
        let data = try JSONEncoder().encode(encodable)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        self = decoded
    }

    /// Decode the wrapped value into a concrete `Decodable` type.
    public func decoded<T: Decodable>() throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Return as `[String: Any]` dictionary, or `nil`.
    public var dictionary: [String: Any]? {
        value as? [String: Any]
    }

    /// Return as `String`, or `nil`.
    public var stringValue: String? {
        value as? String
    }

    /// Return as `Int`, or `nil`.
    public var intValue: Int? {
        value as? Int
    }

    /// Return as `Bool`, or `nil`.
    public var boolValue: Bool? {
        value as? Bool
    }

    /// Return as `[Any]`, or `nil`.
    public var arrayValue: [Any]? {
        value as? [Any]
    }

    /// True when the wrapped value is `nil`.
    public var isNil: Bool {
        value == nil
    }

    // MARK: Equatable

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil): return true
        case let (a as Bool, b as Bool): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [Any], b as [Any]):
            return a.count == b.count && zip(a, b).allSatisfy { AnyCodable($0) == AnyCodable($1) }
        case let (a as [String: Any], b as [String: Any]):
            guard a.count == b.count else { return false }
            for key in a.keys {
                guard let bv = b[key] else { return false }
                if AnyCodable(a[key]) != AnyCodable(bv) { return false }
            }
            return true
        default: return false
        }
    }

    // Normalize NSNumber / NSNull to Swift native types
    private static func normalized(_ v: Any?) -> Any? {
        guard let v = v else { return nil }
        if v is NSNull { return nil }
        if let nsn = v as? NSNumber {
            if nsn === kCFBooleanTrue as NSNumber || nsn === kCFBooleanFalse as NSNumber {
                return nsn.boolValue
            }
            // Int check before Double to preserve integer precision
            let val = nsn.doubleValue
            if val == Double(Int(val)) && !nsn.stringValue.contains(".") {
                return nsn.intValue
            }
            return val
        }
        return v
    }
}

// MARK: - JSON-RPC Error

public struct JSONRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes
    public static let parseError      = -32700
    public static let invalidRequest  = -32600
    public static let methodNotFound  = -32601
    public static let invalidParams   = -32602
    public static let internalError   = -32603

    enum CodingKeys: String, CodingKey { case code, message, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

// MARK: - JSON-RPC Message Types

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: RequestID
    public let method: String
    public let params: AnyCodable?

    public init(id: RequestID, method: String, params: AnyCodable? = nil) {
        self.jsonrpc = JSONRPCVersion.two
        self.id = id
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encodeIfPresent(params, forKey: .params)
    }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: RequestID?
    public let result: AnyCodable?
    public let error: JSONRPCError?

    public init(id: RequestID?, result: AnyCodable? = nil, error: JSONRPCError? = nil) {
        self.jsonrpc = JSONRPCVersion.two
        self.id = id
        self.result = result
        self.error = error
    }

    /// Convenience for success response.
    public static func success(id: RequestID?, result: AnyCodable?) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result)
    }

    /// Convenience for error response.
    public static func error(id: RequestID?, code: Int, message: String, data: AnyCodable? = nil) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message, data: data))
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: AnyCodable?

    public init(method: String, params: AnyCodable? = nil) {
        self.jsonrpc = JSONRPCVersion.two
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, method, params }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(method, forKey: .method)
        try c.encodeIfPresent(params, forKey: .params)
    }
}

/// Discriminated union for incoming JSON-RPC messages.
public enum JSONRPCMessage: Equatable, Sendable {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)

    /// Parse a raw JSON line into the appropriate message type.
    public static func parse(_ data: Data) throws -> JSONRPCMessage {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw MCPError.invalidJSON(data)
        }

        let hasMethod = json["method"] != nil
        let hasId = json["id"] != nil
        let hasResult = json["result"] != nil
        let hasError = json["error"] != nil

        if hasMethod && hasId {
            return .request(try JSONDecoder().decode(JSONRPCRequest.self, from: data))
        } else if hasMethod && !hasId {
            return .notification(try JSONDecoder().decode(JSONRPCNotification.self, from: data))
        } else {
            return .response(try JSONDecoder().decode(JSONRPCResponse.self, from: data))
        }
    }

    /// Encode this message back to JSON data.
    public func encode() throws -> Data {
        switch self {
        case .request(let r):   return try JSONEncoder().encode(r)
        case .response(let r):  return try JSONEncoder().encode(r)
        case .notification(let n): return try JSONEncoder().encode(n)
        }
    }

    /// Convenience: return the `RequestID` if this is a request, else nil.
    public var requestId: RequestID? {
        switch self {
        case .request(let r): return r.id
        default: return nil
        }
    }
}

// MARK: - MCP Error

public enum MCPError: Error, LocalizedError, Equatable {
    case invalidJSON(Data)
    case unsupportedProtocolVersion(String)
    case methodNotRegistered(String)
    case invalidParams(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid JSON message"
        case .unsupportedProtocolVersion(let v):
            return "Unsupported protocol version: \(v)"
        case .methodNotRegistered(let m):
            return "Method not registered: \(m)"
        case .invalidParams(let msg):
            return msg
        case .internalError(let msg):
            return msg
        }
    }
}

// MARK: - Implementation Info

public struct Implementation: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let title: String?
    public let description: String?
    public let websiteUrl: String?

    public init(name: String, version: String, title: String? = nil,
                description: String? = nil, websiteUrl: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
        self.description = description
        self.websiteUrl = websiteUrl
    }

    enum CodingKeys: String, CodingKey {
        case name, version, title, description
        case websiteUrl = "websiteUrl"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(websiteUrl, forKey: .websiteUrl)
    }
}

// MARK: - Server & Client Capabilities

public struct EmptyCapability: Codable, Equatable, Sendable {
    public init() {}
}

public struct TaskRequestToolCapabilities: Codable, Equatable, Sendable {
    public let call: EmptyCapability?

    public init(call: EmptyCapability? = nil) {
        self.call = call
    }
}

public struct TaskRequestCapabilities: Codable, Equatable, Sendable {
    public let tools: TaskRequestToolCapabilities?

    public init(tools: TaskRequestToolCapabilities? = nil) {
        self.tools = tools
    }
}

public struct TaskCapabilities: Codable, Equatable, Sendable {
    public let list: EmptyCapability?
    public let cancel: EmptyCapability?
    public let requests: TaskRequestCapabilities?

    public init(
        list: EmptyCapability? = nil,
        cancel: EmptyCapability? = nil,
        requests: TaskRequestCapabilities? = nil
    ) {
        self.list = list
        self.cancel = cancel
        self.requests = requests
    }
}

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public let tools: ToolCapabilities?
    public let resources: ResourceCapabilities?
    public let logging: EmptyCapability?
    public let tasks: TaskCapabilities?
    public let prompts: PromptCapabilities?
    public let experimental: AnyCodable?

    public init(tools: ToolCapabilities? = nil, resources: ResourceCapabilities? = nil,
                logging: EmptyCapability? = nil, tasks: TaskCapabilities? = nil, prompts: PromptCapabilities? = nil,
                experimental: AnyCodable? = nil) {
        self.tools = tools
        self.resources = resources
        self.logging = logging
        self.tasks = tasks
        self.prompts = prompts
        self.experimental = experimental
    }

    enum CodingKeys: String, CodingKey { case tools, resources, logging, tasks, prompts, experimental }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(resources, forKey: .resources)
        try c.encodeIfPresent(logging, forKey: .logging)
        try c.encodeIfPresent(tasks, forKey: .tasks)
        try c.encodeIfPresent(prompts, forKey: .prompts)
        try c.encodeIfPresent(experimental, forKey: .experimental)
    }
}

public struct ClientCapabilities: Codable, Equatable, Sendable {
    public let roots: RootsCapability?
    public let sampling: AnyCodable?
    public let experimental: AnyCodable?

    public init(roots: RootsCapability? = nil, sampling: AnyCodable? = nil,
                experimental: AnyCodable? = nil) {
        self.roots = roots
        self.sampling = sampling
        self.experimental = experimental
    }

    enum CodingKeys: String, CodingKey { case roots, sampling, experimental }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(roots, forKey: .roots)
        try c.encodeIfPresent(sampling, forKey: .sampling)
        try c.encodeIfPresent(experimental, forKey: .experimental)
    }
}

public struct ToolCapabilities: Codable, Equatable, Sendable {
    public let listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }

    enum CodingKeys: String, CodingKey { case listChanged = "listChanged" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(listChanged, forKey: .listChanged)
    }
}

public struct ResourceCapabilities: Codable, Equatable, Sendable {
    public let subscribe: Bool?
    public let listChanged: Bool?

    public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }

    enum CodingKeys: String, CodingKey { case subscribe, listChanged = "listChanged" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(subscribe, forKey: .subscribe)
        try c.encodeIfPresent(listChanged, forKey: .listChanged)
    }
}

public struct PromptCapabilities: Codable, Equatable, Sendable {
    public let listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }

    enum CodingKeys: String, CodingKey { case listChanged = "listChanged" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(listChanged, forKey: .listChanged)
    }
}

public struct RootsCapability: Codable, Equatable, Sendable {
    public let listChanged: Bool?

    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }

    enum CodingKeys: String, CodingKey { case listChanged = "listChanged" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(listChanged, forKey: .listChanged)
    }
}

// MARK: - Initialize

public struct InitializeParams: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let capabilities: ClientCapabilities
    public let clientInfo: Implementation

    enum CodingKeys: String, CodingKey {
        case protocolVersion, capabilities
        case clientInfo = "clientInfo"
    }
}

public struct InitializeResult: Codable, Equatable, Sendable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: Implementation
    public let instructions: String?

    public init(protocolVersion: String, capabilities: ServerCapabilities,
                serverInfo: Implementation, instructions: String? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion, capabilities, instructions
        case serverInfo = "serverInfo"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(serverInfo, forKey: .serverInfo)
        try c.encodeIfPresent(instructions, forKey: .instructions)
    }
}

// MARK: - Tool & Resource Models

public struct Tool: Codable, Equatable, Sendable {
    public let name: String
    public let inputSchema: InputSchema
    public let description: String?
    public let title: String?

    public init(name: String, inputSchema: InputSchema,
                description: String? = nil, title: String? = nil) {
        self.name = name
        self.inputSchema = inputSchema
        self.description = description
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case name, inputSchema, description, title }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(inputSchema, forKey: .inputSchema)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

/// Minimal JSON Schema representation for tool input parameters.
public struct InputSchema: Codable, Equatable, Sendable {
    public let type: String
    public let properties: [String: AnyCodable]?
    public let required: [String]?

    public init(type: String = "object", properties: [String: AnyCodable]? = nil,
                required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    enum CodingKeys: String, CodingKey { case type, properties, required }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(properties, forKey: .properties)
        try c.encodeIfPresent(required, forKey: .required)
    }
}

public struct Resource: Codable, Equatable, Sendable {
    public let uri: String
    public let name: String
    public let description: String?
    public let title: String?
    public let mimeType: String?

    public init(uri: String, name: String, description: String? = nil,
                title: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.title = title
        self.mimeType = mimeType
    }

    enum CodingKeys: String, CodingKey {
        case uri, name, description, title, mimeType
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uri, forKey: .uri)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
    }
}

// MARK: - List Results

public struct ListToolsResult: Codable, Equatable, Sendable {
    public let tools: [Tool]
    public let nextCursor: String?

    public init(tools: [Tool], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey { case tools, nextCursor = "nextCursor" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

public struct ListResourcesResult: Codable, Equatable, Sendable {
    public let resources: [Resource]
    public let nextCursor: String?

    public init(resources: [Resource], nextCursor: String? = nil) {
        self.resources = resources
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey { case resources, nextCursor = "nextCursor" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resources, forKey: .resources)
        try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

// MARK: - Paginated Request Params

public struct PaginatedParams: Decodable, Equatable, Sendable {
    public let cursor: String?

    public init(cursor: String? = nil) {
        self.cursor = cursor
    }
}

// MARK: - Tool Call Result

/// Content types that can appear in a tool call result.
public enum ToolContent: Codable, Equatable, Sendable {
    case text(content: String)
    case image(data: String, mimeType: String)
    case resource(resource: EmbeddedResource)

    enum CodingKeys: String, CodingKey { case type, text, data, mimeType, resource }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let content):
            try c.encode("text", forKey: .type)
            try c.encode(content, forKey: .text)
        case .image(let data, let mimeType):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        case .resource(let resource):
            try c.encode("resource", forKey: .type)
            try c.encode(resource, forKey: .resource)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let content = try c.decode(String.self, forKey: .text)
            self = .text(content: content)
        case "image":
            let data = try c.decode(String.self, forKey: .data)
            let mimeType = try c.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        case "resource":
            let resource = try c.decode(EmbeddedResource.self, forKey: .resource)
            self = .resource(resource: resource)
        default:
            let context = DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "Unknown ToolContent type: \(type)"
            )
            throw DecodingError.dataCorrupted(context)
        }
    }
}

/// An embedded resource reference within tool content.
public struct EmbeddedResource: Codable, Equatable, Sendable {
    public let uri: String
    public let name: String?
    public let mimeType: String?
    public let text: String?

    public init(uri: String, name: String? = nil, mimeType: String? = nil, text: String? = nil) {
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.text = text
    }
}

/// Result of a `tools/call` invocation.
public struct CallToolResult: Codable, Equatable, Sendable {
    public let content: [ToolContent]
    public let isError: Bool?

    public init(content: [ToolContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    enum CodingKeys: String, CodingKey { case content, isError = "isError" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(isError, forKey: .isError)
    }
}

// MARK: - Resource Read Result

/// A single resource content item returned by `resources/read`.
public struct ResourceContent: Codable, Equatable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let text: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case uri, mimeType, text }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uri, forKey: .uri)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(text, forKey: .text)
    }
}

/// Result of a `resources/read` invocation.
public struct ReadResourceResult: Codable, Equatable, Sendable {
    public let contents: [ResourceContent]

    public init(contents: [ResourceContent]) {
        self.contents = contents
    }
}
