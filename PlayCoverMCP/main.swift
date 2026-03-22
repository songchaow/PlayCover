import Foundation

/// PlayCoverMCP server entry point.
///
/// Bootstraps the MCP server with stdio transport, logging, and task management.
/// Logs are written to stderr to avoid interfering with the JSON-RPC protocol on stdout.

let serverInfo = Implementation(
    name: "playcover-mcp",
    version: "0.2.0"
)

let logger = MCPLogger(minLevel: .info)

let taskManager = TaskManager()

let capabilities = ServerCapabilities(
    tools: ToolCapabilities(listChanged: false),
    resources: ResourceCapabilities(subscribe: false, listChanged: false),
    logging: true,
    tasks: true
)

let server = MCPServer(
    serverInfo: serverInfo,
    capabilities: capabilities,
    logger: logger,
    taskManager: taskManager
)

let transport = StdioTransport { message in
    server.handle(message)
}

transport.run()
