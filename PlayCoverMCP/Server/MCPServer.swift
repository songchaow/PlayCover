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

    /// A tool handler receives the tool's input arguments and returns a CallToolResult.
    public typealias ToolHandler = @Sendable (AnyCodable?) throws -> CallToolResult

    /// A resource handler receives the resource URI and arguments, returns a ReadResourceResult.
    public typealias ResourceHandler = @Sendable (String, AnyCodable?) throws -> ReadResourceResult

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

    /// Callback for sending server-initiated notifications to clients.
    /// The transport layer sets this to route notifications through the appropriate channel.
    /// - Parameter message: The JSON-RPC notification to send
    public var notificationSink: ((JSONRPCMessage) -> Void)?

    // MARK: - Private

    private var methodHandlers: [String: RequestHandler] = [:]
    private var toolHandlers: [String: ToolHandler] = [:]
    private var resourceHandlers: [String: ResourceHandler] = [:]
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

    /// Register a tool handler that will be dispatched via `tools/call`.
    ///
    /// The `name` parameter should match the `Tool.name` registered in `toolRegistry`.
    public func registerTool(name: String, handler: @escaping ToolHandler) {
        lock.lock()
        defer { lock.unlock() }
        toolHandlers[name] = handler
    }

    /// Register a resource handler that will be dispatched via `resources/read`.
    ///
    /// The `uriTemplate` parameter is used to match resource URIs.
    /// Use exact URIs for fixed resources or prefix matching for template resources.
    public func registerResource(uriTemplate: String, handler: @escaping ResourceHandler) {
        lock.lock()
        defer { lock.unlock() }
        resourceHandlers[uriTemplate] = handler
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

    // MARK: - Server-initiated notifications

    /// Convenience: send a notification through the sink.
    /// No-op if `notificationSink` is not set (e.g., in CLI mode without wiring).
    public func sendNotification(_ notification: JSONRPCNotification) {
        let message = JSONRPCMessage.notification(notification)
        notificationSink?(message)
    }

    /// Wire up logger and task manager to send notifications through `notificationSink`.
    ///
    /// Call this **after** setting `notificationSink`. The wiring sets `MCPLogger.onLog` and
    /// `TaskManager.onStatusChange` callbacks to forward events as MCP notifications.
    ///
    /// - Note: Only sends notifications when the server has been initialized (i.e., the client
    ///   has sent `notifications/initialized`). This prevents notifications from being sent
    ///   during the handshake phase.
    public func wireNotifications() {
        // Wire logger → notifications/message
        logger?.onLog = { [weak self] entry in
            guard let self = self, self.isInitialized else { return }
            let params = LoggingMessageParams(level: entry.level, data: entry.message, logger: entry.logger)
            if let paramsAnyCodable = try? AnyCodable(params) {
                let notif = JSONRPCNotification(method: "notifications/message", params: paramsAnyCodable)
                self.sendNotification(notif)
            }
        }

        // Wire task manager → notifications/tasks/update
        taskManager?.onStatusChange = { [weak self] taskId, status in
            guard let self = self, self.isInitialized else { return }
            if let statusAnyCodable = try? AnyCodable(status) {
                let notif = JSONRPCNotification(method: "notifications/tasks/update", params: statusAnyCodable)
                self.sendNotification(notif)
            }
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

        // tools/call — dispatches to registered tool handlers by name
        register(method: "tools/call") { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server deallocated")
            }
            guard let params = params,
                  let name = params.dictionary?["name"] as? String else {
                throw MCPError.invalidParams("tools/call requires params with 'name' field")
            }
            let arguments: AnyCodable? = params.dictionary?["arguments"].map { AnyCodable($0) }

            let handler = self.lock.withLock { self.toolHandlers[name] }
            guard let handler = handler else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "Unknown tool: \(name)"
                )
            }

            let result = try handler(arguments)
            return try AnyCodable(result)
        }

        // resources/read — dispatches to registered resource handlers by URI
        register(method: "resources/read") { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server deallocated")
            }
            guard let params = params,
                  let uri = params.dictionary?["uri"] as? String else {
                throw MCPError.invalidParams("resources/read requires params with 'uri' field")
            }
            let arguments: AnyCodable? = params.dictionary?["arguments"].map { AnyCodable($0) }

            // Try exact match first, then prefix match for template resources
            let handler: ResourceHandler? = self.lock.withLock {
                if let exact = self.resourceHandlers[uri] {
                    return exact
                }
                // Find longest matching prefix
                let sorted = self.resourceHandlers.keys.sorted { $0.count > $1.count }
                for template in sorted {
                    if uri.hasPrefix(template) {
                        return self.resourceHandlers[template]
                    }
                }
                return nil
            }

            guard let handler = handler else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "Unknown resource URI: \(uri)"
                )
            }

            let result = try handler(uri, arguments)
            return try AnyCodable(result)
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
