// StreamableHTTPTransport.swift
// PlayCoverMCP — GUI-only (depends on Hummingbird)

#if canImport(Hummingbird)
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import Logging

/// Streamable HTTP transport for MCP server.
///
/// Implements the MCP 2025-11-25 Streamable HTTP specification.
/// Provides a single HTTP endpoint (/mcp) that supports:
/// - POST: Client sends JSON-RPC messages
/// - GET:  Client opens SSE stream for server-to-client messages
/// - DELETE: Client terminates session
@available(macOS 14, *)
public final class StreamableHTTPTransport {

    // MARK: - Types

    /// Same signature as TCPTransport.MessageHandler / StdioTransport.MessageHandler
    public typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?

    /// Transport state
    public enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped): return true
            case (.starting, .starting): return true
            case (.running(let a), .running(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    /// Listen host configuration (mirrors TCPTransport.ListenHost)
    public enum ListenHost: String, CaseIterable, Equatable {
        case loopback = "127.0.0.1"
        case allInterfaces = "0.0.0.0"
    }

    // MARK: - Public Properties

    public private(set) var state: State = .stopped
    public let port: UInt16
    public let host: ListenHost
    public let endpointPath: String

    /// Callback for state changes (dispatched to main queue)
    public var onStateChange: ((State) -> Void)?

    /// Callback for session count changes (dispatched to main queue)
    public var onSessionCountChanged: ((Int) -> Void)?

    /// Current active session count
    public var activeSessionCount: Int { sessionManager.activeSessionCount }

    // MARK: - Internal

    let sessionManager = MCPSessionManager()

    private let handler: MessageHandler
    private var serverTask: Task<Void, Never>?
    private let lock = NSLock()

    /// Maximum request body size (1 MB)
    private let maxBodySize = 1_048_576

    // MARK: - Init

    /// Create a StreamableHTTPTransport.
    /// - Parameters:
    ///   - port: Port to listen on. Defaults to 19820.
    ///   - host: Host to listen on. Defaults to loopback (127.0.0.1).
    ///   - endpointPath: HTTP endpoint path. Defaults to "/mcp".
    ///   - handler: Message handler, same signature as TCPTransport.MessageHandler.
    public init(
        port: UInt16 = 19820,
        host: ListenHost = .loopback,
        endpointPath: String = "/mcp",
        handler: @escaping MessageHandler
    ) {
        self.port = port
        self.host = host
        self.endpointPath = endpointPath
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Start the HTTP server. Non-blocking.
    public func start() {
        lock.lock()
        guard case .stopped = state else {
            lock.unlock()
            return
        }
        setState(.starting)
        lock.unlock()

        serverTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runServer()
        }
    }

    /// Stop the HTTP server.
    public func stop() {
        lock.lock()
        serverTask?.cancel()
        serverTask = nil
        sessionManager.removeExpiredSessions() // cleanup
        setState(.stopped)
        lock.unlock()
    }

    // MARK: - Server

    private func runServer() async {
        let handlerRef = self.handler
        let sessionMgr = self.sessionManager
        let maxBody = self.maxBodySize
        let path = self.endpointPath

        // Build router
        let router = Router()

        router.post(RouterPath(path)) { [weak self] request, _ -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            return await self.handlePost(
                request: request,
                handler: handlerRef,
                sessionManager: sessionMgr,
                maxBodySize: maxBody
            )
        }

        router.get(RouterPath(path)) { [weak self] request, _ -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            return self.handleGet(request: request, sessionManager: sessionMgr)
        }

        router.delete(RouterPath(path)) { [weak self] request, _ -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }
            return self.handleDelete(request: request, sessionManager: sessionMgr)
        }

        var logger = Logger(label: "io.playcover.mcp.http")
        logger.logLevel = .error

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host.rawValue, port: Int(port))
            ),
            onServerRunning: { [weak self] channel in
                self?.handleServerRunning(channel)
            },
            logger: logger
        )

        do {
            try await app.run()
        } catch is CancellationError {
            // Normal shutdown
        } catch {
            await MainActor.run { [weak self] in
                self?.setState(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - POST Handler

    private func handlePost(
        request: Request,
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager,
        maxBodySize: Int
    ) async -> Response {
        // 1. Origin validation
        if let origin = request.headers[.origin] {
            guard isValidOrigin(origin) else {
                return Response(status: .forbidden)
            }
        }

        // 2. Validate Content-Type
        guard let contentType = request.headers[.contentType],
              contentType.contains("application/json") else {
            return makeJSONRPCErrorResponse(
                id: nil,
                code: JSONRPCError.invalidRequest,
                message: "Content-Type must be application/json"
            )
        }

        // 3. Collect request body
        var mutableRequest = request
        let bodyBuffer: ByteBuffer
        do {
            bodyBuffer = try await mutableRequest.collectBody(upTo: maxBodySize)
        } catch {
            return makeJSONRPCErrorResponse(
                id: nil,
                code: JSONRPCError.parseError,
                message: "Failed to read request body"
            )
        }

        guard let bodyData = bodyBuffer.getData(
            at: bodyBuffer.readerIndex,
            length: bodyBuffer.readableBytes
        ) else {
            return makeJSONRPCErrorResponse(
                id: nil,
                code: JSONRPCError.parseError,
                message: "Empty request body"
            )
        }

        // 4. Parse JSON-RPC message
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage.parse(bodyData)
        } catch {
            return makeJSONRPCErrorResponse(
                id: nil,
                code: JSONRPCError.parseError,
                message: "Parse error: \(error.localizedDescription)"
            )
        }

        // 5. Route by message type
        switch message {
        case .notification(let notif):
            return handleNotification(
                notif: notif,
                message: message,
                request: request,
                handler: handler,
                sessionManager: sessionManager
            )

        case .response:
            // Client-originated responses: just dispatch and return 202
            _ = handler(message)
            return Response(status: .accepted)

        case .request(let req):
            return handleRequest(
                req: req,
                message: message,
                request: request,
                handler: handler,
                sessionManager: sessionManager
            )
        }
    }

    // MARK: - POST sub-handlers

    private func handleNotification(
        notif: JSONRPCNotification,
        message: JSONRPCMessage,
        request: Request,
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager
    ) -> Response {
        // For initialized notification, mark session
        if notif.method == "notifications/initialized" {
            if let sessionId = request.headers[mcpSessionIdField] {
                sessionManager.markInitialized(sessionId)
            }
        }
        _ = handler(message)
        return Response(status: .accepted)
    }

    private func handleRequest(
        req: JSONRPCRequest,
        message: JSONRPCMessage,
        request: Request,
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager
    ) -> Response {
        // Special handling for "initialize"
        if req.method == "initialize" {
            return handleInitialize(
                message: message,
                handler: handler,
                sessionManager: sessionManager
            )
        }

        // Validate Mcp-Session-Id
        guard let sessionId = request.headers[mcpSessionIdField],
              sessionManager.validateSession(sessionId) != nil else {
            return makeJSONRPCErrorResponse(
                id: req.id,
                code: JSONRPCError.invalidRequest,
                message: "Invalid or missing session ID",
                status: .notFound
            )
        }

        // Validate Mcp-Protocol-Version (optional but recommended)
        // We allow requests without it for backward compatibility in Phase 1

        // Process request
        if let response = handler(message) {
            return makeJSONResponse(response, sessionId: sessionId)
        }
        return Response(status: .accepted)
    }

    private func handleInitialize(
        message: JSONRPCMessage,
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager
    ) -> Response {
        let sessionId = sessionManager.createSession()

        notifySessionCountChanged()

        guard let response = handler(message) else {
            return Response(status: .internalServerError)
        }

        // Encode response
        guard let jsonData = try? response.encode() else {
            return Response(status: .internalServerError)
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        if let name = HTTPField.Name("Mcp-Session-Id") {
            headers[name] = sessionId
        }

        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: jsonData))
        )
    }

    // MARK: - GET Handler (SSE stream)

    private func handleGet(request: Request, sessionManager: MCPSessionManager) -> Response {
        // 1. Origin validation
        if let origin = request.headers[.origin] {
            guard isValidOrigin(origin) else {
                return Response(status: .forbidden)
            }
        }

        // 2. Validate Accept header
        guard let accept = request.headers[.accept],
              accept.contains("text/event-stream") else {
            return Response(status: .notAcceptable)
        }

        // 3. Validate session
        guard let sessionId = request.headers[mcpSessionIdField],
              sessionManager.validateSession(sessionId) != nil else {
            return Response(status: .badRequest)
        }

        // 4. Create SSE response with async stream
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

        // Send primer event
        let primerData = SSEEncoder.encodePrimerEvent(
            eventId: "stream-\(UUID().uuidString.prefix(8))"
        )
        continuation.yield(ByteBuffer(data: primerData))

        // Keep stream open for future pushes (H04 will wire server notifications here)
        // For Phase 1, just hold the connection open

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        // Disable buffering
        if let name = HTTPField.Name("X-Accel-Buffering") {
            headers[name] = "no"
        }

        return Response(
            status: .ok,
            headers: headers,
            body: .init(asyncSequence: stream)
        )
    }

    // MARK: - DELETE Handler

    private func handleDelete(request: Request, sessionManager: MCPSessionManager) -> Response {
        guard let sessionId = request.headers[mcpSessionIdField] else {
            return Response(status: .badRequest)
        }

        if sessionManager.terminateSession(sessionId) {
            notifySessionCountChanged()
            return Response(status: .ok)
        } else {
            return Response(status: .notFound)
        }
    }

    // MARK: - Origin Validation

    /// Validate the Origin header to prevent DNS rebinding attacks.
    /// For local servers, allow requests from localhost origins and requests without Origin.
    private func isValidOrigin(_ origin: String) -> Bool {
        let allowedOrigins = [
            "http://localhost",
            "http://127.0.0.1",
            "https://localhost",
            "https://127.0.0.1",
            "http://[::1]",
            "https://[::1]"
        ]
        for allowed in allowedOrigins {
            if origin == allowed || origin.hasPrefix(allowed + ":") {
                return true
            }
        }
        return false
    }

    // MARK: - Response Helpers

    /// Build a JSON response from a JSONRPCMessage, including session header.
    private func makeJSONResponse(_ message: JSONRPCMessage, sessionId: String? = nil) -> Response {
        guard let jsonData = try? message.encode() else {
            return Response(status: .internalServerError)
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        if let sessionId = sessionId, let name = HTTPField.Name("Mcp-Session-Id") {
            headers[name] = sessionId
        }

        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: jsonData))
        )
    }

    /// Build a JSON-RPC error response.
    private func makeJSONRPCErrorResponse(
        id: RequestID?,
        code: Int,
        message: String,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        let errorResponse = JSONRPCResponse.error(id: id, code: code, message: message)
        let rpcMessage = JSONRPCMessage.response(errorResponse)
        guard let jsonData = try? rpcMessage.encode() else {
            return Response(status: .internalServerError)
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/json"

        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: jsonData))
        )
    }

    // MARK: - State Management

    private func setState(_ newState: State) {
        state = newState
        let callback = onStateChange
        if let callback = callback {
            DispatchQueue.main.async {
                callback(newState)
            }
        }
    }

    private func notifySessionCountChanged() {
        let count = sessionManager.activeSessionCount
        if let callback = onSessionCountChanged {
            DispatchQueue.main.async {
                callback(count)
            }
        }
    }

    // MARK: - Custom Header Names

    /// Mcp-Session-Id custom header field name
    private var mcpSessionIdField: HTTPField.Name {
        HTTPField.Name("Mcp-Session-Id")!
    }

    /// Mcp-Protocol-Version custom header field name
    private var mcpProtocolVersionField: HTTPField.Name {
        HTTPField.Name("Mcp-Protocol-Version")!
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let data = ("StreamableHTTPTransport: \(message)\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }
}

// MARK: - ApplicationProtocol + onServerRunning for port detection

@available(macOS 14, *)
extension StreamableHTTPTransport {

    /// Internal method to detect actual port and update state.
    /// This is called from `runServer` when the Hummingbird app starts.
    fileprivate func handleServerRunning(_ channel: any Channel) {
        // Extract the actual port from the channel's local address
        if let localAddress = channel.localAddress,
           let port = localAddress.port {
            let actualPort = UInt16(port)
            DispatchQueue.main.async { [weak self] in
                self?.setState(.running(port: actualPort))
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setState(.running(port: self?.port ?? 19820))
            }
        }
    }
}
#endif
