// MCPServer.swift
// PlayCoverMCPCore

import Foundation

/// Central MCP server: dispatches JSON-RPC requests to registered handlers.
///
/// Built-in methods (`initialize`, `ping`, `tools/list`, `resources/list`)
/// are registered automatically. Additional methods can be added via `register(method:handler:)`.
public final class MCPServer {

    /// A request handler receives optional params and returns a result.
    public typealias RequestHandler = @Sendable (AnyCodable?) throws -> AnyCodable

    // MARK: - Public state

    public let serverInfo: Implementation
    public let capabilities: ServerCapabilities
    public let toolRegistry: ToolRegistry
    public let resourceRegistry: ResourceRegistry

    /// Whether the client has sent the `notifications/initialized` notification.
    public private(set) var isInitialized = false

    // MARK: - Private

    private var methodHandlers: [String: RequestHandler] = [:]
    private let lock = NSLock()

    // MARK: - Init

    public init(
        serverInfo: Implementation,
        capabilities: ServerCapabilities,
        toolRegistry: ToolRegistry = ToolRegistry(),
        resourceRegistry: ResourceRegistry = ResourceRegistry()
    ) {
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.toolRegistry = toolRegistry
        self.resourceRegistry = resourceRegistry

        registerBuiltinHandlers()
    }

    // MARK: - Handler registration

    /// Register a custom request handler for the given method name.
    public func register(method: String, handler: @escaping RequestHandler) {
        lock.lock()
        defer { lock.unlock() }
        methodHandlers[method] = handler
    }

    // MARK: - Message dispatch

    /// Handle an incoming JSON-RPC message. Returns a response for requests,
    /// or nil for notifications.
    public func handle(_ message: JSONRPCMessage) -> JSONRPCMessage? {
        switch message {
        case .request(let request):
            return handleRequest(request)
        case .notification(let notification):
            handleNotification(notification)
            return nil
        case .response:
            // Server does not handle client-originated responses.
            return nil
        }
    }

    // MARK: - Private: Request handling

    private func handleRequest(_ request: JSONRPCRequest) -> JSONRPCMessage {
        let id = request.id
        let handler: RequestHandler? = lock.withLock { methodHandlers[request.method] }

        guard let handler = handler else {
            return .response(.error(
                id: id,
                code: JSONRPCError.methodNotFound,
                message: "Method not found: \(request.method)"
            ))
        }

        do {
            let result = try handler(request.params)
            return .response(.success(id: id, result: result))
        } catch let error as MCPError {
            let (code, message) = mapMCPError(error)
            return .response(.error(id: id, code: code, message: message))
        } catch {
            return .response(.error(
                id: id,
                code: JSONRPCError.internalError,
                message: "Internal error: \(error.localizedDescription)"
            ))
        }
    }

    private func handleNotification(_ notification: JSONRPCNotification) {
        switch notification.method {
        case "notifications/initialized":
            isInitialized = true
        default:
            break
        }
    }

    // MARK: - Built-in handlers

    private func registerBuiltinHandlers() {
        register(method: "initialize") { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server deallocated")
            }
            return try self.handleInitialize(params: params)
        }

        register(method: "ping") { _ in
            AnyCodable([:])
        }

        register(method: "tools/list") { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Server deallocated")
            }
            return try AnyCodable(ListToolsResult(tools: self.toolRegistry.listTools()))
        }

        register(method: "resources/list") { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Server deallocated")
            }
            return try AnyCodable(ListResourcesResult(resources: self.resourceRegistry.listResources()))
        }
    }

    private func handleInitialize(params: AnyCodable?) throws -> AnyCodable {
        guard let params = params else {
            throw MCPError.invalidParams("initialize requires params")
        }

        let initParams: InitializeParams
        do {
            initParams = try params.decoded()
        } catch {
            throw MCPError.invalidParams("Failed to decode InitializeParams: \(error.localizedDescription)")
        }

        // Version negotiation: return the latest version we support
        let negotiatedVersion = MCPProtocolVersion.latest

        let result = InitializeResult(
            protocolVersion: negotiatedVersion,
            capabilities: capabilities,
            serverInfo: serverInfo,
            instructions: "PlayCoverMCP server for managing iOS app installation, launching, and input simulation."
        )

        return try AnyCodable(result)
    }

    // MARK: - Helpers

    private func mapMCPError(_ error: MCPError) -> (Int, String) {
        switch error {
        case .invalidJSON:
            return (JSONRPCError.parseError, error.localizedDescription)
        case .methodNotRegistered:
            return (JSONRPCError.methodNotFound, error.localizedDescription)
        case .unsupportedProtocolVersion:
            return (JSONRPCError.invalidParams, error.localizedDescription)
        case .invalidParams:
            return (JSONRPCError.invalidParams, error.localizedDescription)
        case .internalError:
            return (JSONRPCError.internalError, error.localizedDescription)
        }
    }
}

// MARK: - NSLock + withLock (macOS 12+)

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
