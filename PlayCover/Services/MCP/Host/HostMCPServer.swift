import Foundation

final class HostMCPServer {
    static let shared = HostMCPServer()

    let registry: HostToolRegistry
    let context: HostToolContext

    private(set) var isStarted = false

    init(
        registry: HostToolRegistry = HostToolRegistry(),
        context: HostToolContext = HostToolContext(
            appResolver: HostAppResolver(),
            startupDate: Date()
        )
    ) {
        self.registry = registry
        self.context = context
        registerDefaultTools()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func execute(_ call: HostToolCall) async -> HostToolResult {
        await registry.execute(call, context: context)
    }

    private func registerDefaultTools() {
        registry.register(
            HostToolDefinition(
                name: "host.ping",
                summary: "Verify that the Host MCP registry is reachable."
            ) { _, context in
                .success(
                    message: "Host MCP is ready.",
                    data: .object([
                        "server": .string("host"),
                        "started_at": .string(ISO8601DateFormatter().string(from: context.startupDate)),
                        "registered_tool_count": .int(self.registry.registeredTools().count)
                    ])
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "host.describe_tools",
                summary: "List the currently registered Host MCP tools."
            ) { _, _ in
                let toolObjects = self.registry.registeredTools().map { descriptor in
                    HostMCPValue.object([
                        "name": .string(descriptor.name),
                        "summary": .string(descriptor.summary)
                    ])
                }

                return .success(
                    message: "Registered host tools listed.",
                    data: .array(toolObjects)
                )
            }
        )
    }
}
