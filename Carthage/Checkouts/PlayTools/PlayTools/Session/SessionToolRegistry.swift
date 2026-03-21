import Foundation

public typealias SessionToolHandler = (
    _ arguments: SessionToolArguments,
    _ context: SessionToolContext
) async throws -> SessionToolResult

public struct SessionToolDescriptor: Equatable {
    public let name: String
    public let summary: String
}

public struct SessionToolDefinition {
    public let descriptor: SessionToolDescriptor
    public let handler: SessionToolHandler

    public init(name: String, summary: String, handler: @escaping SessionToolHandler) {
        descriptor = SessionToolDescriptor(name: name, summary: summary)
        self.handler = handler
    }
}

public struct SessionToolContext {
    public let sessionID: String
    public let startupDate: Date
    public let processID: Int
    public let bundleID: String

    public init(sessionID: String, startupDate: Date, processID: Int, bundleID: String) {
        self.sessionID = sessionID
        self.startupDate = startupDate
        self.processID = processID
        self.bundleID = bundleID
    }
}

public final class SessionToolRegistry {
    private var tools: [String: SessionToolDefinition] = [:]

    public init() {}

    public func register(_ tool: SessionToolDefinition) {
        tools[tool.descriptor.name] = tool
    }

    public func registeredTools() -> [SessionToolDescriptor] {
        tools.values
            .map(\.descriptor)
            .sorted { $0.name < $1.name }
    }

    public func execute(_ call: SessionToolCall, context: SessionToolContext) async -> SessionToolResult {
        guard let tool = tools[call.name] else {
            return .failure(.toolNotFound(call.name))
        }

        do {
            let arguments = SessionToolArguments(call.arguments)
            return try await tool.handler(arguments, context)
        } catch let error as SessionToolError {
            return .failure(error)
        } catch {
            return .failure(.executionFailed(error.localizedDescription))
        }
    }
}
