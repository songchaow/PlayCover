import Foundation

typealias HostToolHandler = (_ arguments: HostToolArguments, _ context: HostToolContext) async throws -> HostToolResult

struct HostToolDescriptor: Equatable {
    let name: String
    let summary: String
}

struct HostToolDefinition {
    let descriptor: HostToolDescriptor
    let handler: HostToolHandler

    init(name: String, summary: String, handler: @escaping HostToolHandler) {
        descriptor = HostToolDescriptor(name: name, summary: summary)
        self.handler = handler
    }
}

struct HostToolContext {
    let appResolver: HostAppResolver
    let startupDate: Date
}

final class HostToolRegistry {
    private var tools: [String: HostToolDefinition] = [:]

    func register(_ tool: HostToolDefinition) {
        tools[tool.descriptor.name] = tool
    }

    func registeredTools() -> [HostToolDescriptor] {
        tools.values
            .map(\.descriptor)
            .sorted { $0.name < $1.name }
    }

    func execute(_ call: HostToolCall, context: HostToolContext) async -> HostToolResult {
        guard let tool = tools[call.name] else {
            return .failure(.toolNotFound(call.name))
        }

        do {
            let arguments = HostToolArguments(call.arguments)
            return try await tool.handler(arguments, context)
        } catch let error as HostToolError {
            return .failure(error)
        } catch {
            return .failure(.executionFailed(error.localizedDescription))
        }
    }
}
