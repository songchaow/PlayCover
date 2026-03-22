import Foundation

/// PlayCoverMCP server entry point.
///
/// Bootstraps the MCP server with stdio transport and runs the event loop.
/// Logs are written to stderr to avoid interfering with the JSON-RPC protocol on stdout.

let serverInfo = Implementation(
    name: "playcover-mcp",
    version: "0.1.0"
)

let capabilities = ServerCapabilities(
    tools: ToolCapabilities(listChanged: false),
    resources: ResourceCapabilities(subscribe: false, listChanged: false)
)

let server = MCPServer(
    serverInfo: serverInfo,
    capabilities: capabilities
)

let transport = StdioTransport { message in
    server.handle(message)
}

transport.run()
