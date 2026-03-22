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

    /// Shared logger instance for structured server-side logging.
    public let logger: MCPLogger?

    /// Shared task manager for background task tracking.
    public let taskManager: TaskManager?

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
        resourceRegistry: ResourceRegistry = ResourceRegistry(),
        logger: MCPLogger? = nil,
        taskManager: TaskManager? = nil
    ) {
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.toolRegistry = toolRegistry
        self.resourceRegistry = resourceRegistry
        self.logger = logger
        self.taskManager = taskManager

        registerBuiltinHandlers()
        registerLoggingHandlers()
        registerTaskHandlers()
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
        } catch let error as PlayCoverMCPError {
            return .response(error.toErrorResponse(id: id))
        } catch let error as MCPError {
            let (code, message) = mapMCPError(error)
            return .response(.error(id: id, code: code, message: message))
        } catch {
            let wrapped = PlayCoverMCPError(wrapping: error)
            return .response(wrapped.toErrorResponse(id: id))
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

    // MARK: - Logging handlers

    private func registerLoggingHandlers() {
        guard let logger = logger else { return }

        // logging/setLevel
        register(method: "logging/setLevel") { params in
            guard let params = params else {
                throw MCPError.invalidParams("logging/setLevel requires params")
            }
            let setParams: SetLoggingLevelParams
            do {
                setParams = try params.decoded()
            } catch {
                throw MCPError.invalidParams("Failed to decode SetLoggingLevelParams: \(error.localizedDescription)")
            }
            logger.setMinLevel(setParams.level)
            return AnyCodable([:])
        }

        // notifications/message (client -> server log messages)
        // Handled as notification, see handleNotification below
    }

    // MARK: - Task handlers

    private func registerTaskHandlers() {
        guard let taskManager = taskManager else { return }

        // tasks/create
        register(method: "tasks/create") { params in
            let createParams: CreateTaskParams
            do {
                createParams = try (params ?? AnyCodable([:])).decoded()
            } catch {
                throw MCPError.invalidParams("Failed to decode CreateTaskParams: \(error.localizedDescription)")
            }
            let result = taskManager.createTask(id: createParams.id, title: createParams.title, tool: createParams.tool)
            return try AnyCodable(result)
        }

        // tasks/get
        register(method: "tasks/get") { params in
            guard let params = params,
                  let taskId = params.stringValue else {
                throw MCPError.invalidParams("tasks/get requires a string 'id' param")
            }
            guard let status = taskManager.getTask(taskId) else {
                throw PlayCoverMCPError(code: .taskNotFound, message: "Task not found: \(taskId)")
            }
            return try AnyCodable(GetTaskResult(status: status))
        }

        // tasks/list
        register(method: "tasks/list") { params in
            let tasks = taskManager.listTasks(includeCompleted: true)
            return try AnyCodable(ListTasksResult(tasks: tasks))
        }

        // tasks/cancel
        register(method: "tasks/cancel") { params in
            guard let params = params,
                  let taskId = params.stringValue else {
                throw MCPError.invalidParams("tasks/cancel requires a string 'id' param")
            }
            guard taskManager.getTask(taskId) != nil else {
                throw PlayCoverMCPError(code: .taskNotFound, message: "Task not found: \(taskId)")
            }
            taskManager.cancelTask(taskId)
            let status = taskManager.getTask(taskId)!
            return try AnyCodable(GetTaskResult(status: status))
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
