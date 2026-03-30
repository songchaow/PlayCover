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

    /// Manages SSE streams for all sessions (GET and POST SSE streams).
    let sseStreamManager = SSEStreamManager()

    /// Reference to the MCPServer for wiring notifications.
    private weak var mcpServer: MCPServer?

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
    ///   - mcpServer: Optional MCPServer reference for wiring server-initiated notifications.
    public init(
        port: UInt16 = 19820,
        host: ListenHost = .loopback,
        endpointPath: String = "/mcp",
        handler: @escaping MessageHandler,
        mcpServer: MCPServer? = nil
    ) {
        self.port = port
        self.host = host
        self.endpointPath = endpointPath
        self.handler = handler
        self.mcpServer = mcpServer

        // Wire MCPServer's notificationSink to push through SSE streams
        if let server = mcpServer {
            wireNotificationSink(server: server)
        }
    }

    /// Wire the MCPServer's notificationSink to route notifications through SSE streams.
    /// Also calls `server.wireNotifications()` to bridge logger and task manager.
    private func wireNotificationSink(server: MCPServer) {
        server.notificationSink = { [weak self] message in
            guard let self = self else { return }
            do {
                let eventId = "evt-\(UUID().uuidString.prefix(8))"
                let sseData = try SSEEncoder.encode(message, eventId: eventId)
                // Broadcast to all sessions' GET streams
                for sessionId in self.sessionManager.allSessionIds {
                    self.sseStreamManager.sendToSession(sessionId: sessionId, data: sseData)
                }
            } catch {
                self.log("Failed to encode notification for SSE: \(error.localizedDescription)")
            }
        }
        server.wireNotifications()
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
        // Close all SSE streams before cleaning up sessions
        sseStreamManager.closeAllStreams()
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

        // 2. Validate Accept and Content-Type
        guard let accept = request.headers[.accept], isValidPostAcceptHeader(accept) else {
            return makeJSONRPCErrorResponse(
                id: nil,
                code: JSONRPCError.invalidRequest,
                message: "Accept header must include application/json and text/event-stream",
                status: .notAcceptable
            )
        }

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
            switch validateSessionContext(request: request, sessionManager: sessionManager) {
            case .success(let sessionId):
                return handleNotification(
                    notif: notif,
                    message: message,
                    handler: handler,
                    sessionManager: sessionManager,
                    sessionId: sessionId
                )
            case .failure(let issue):
                return makeSessionValidationErrorResponse(issue: issue, requestId: nil)
            }

        case .response:
            switch validateSessionContext(request: request, sessionManager: sessionManager) {
            case .success:
                _ = handler(message)
                return Response(status: .accepted)
            case .failure(let issue):
                return makeSessionValidationErrorResponse(issue: issue, requestId: nil)
            }

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
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager,
        sessionId: String
    ) -> Response {
        if notif.method == "notifications/initialized" {
            sessionManager.markInitialized(sessionId)
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
        if req.method == "initialize" {
            return handleInitialize(
                message: message,
                handler: handler,
                sessionManager: sessionManager
            )
        }

        let sessionId: String
        switch validateSessionContext(request: request, sessionManager: sessionManager) {
        case .success(let validatedSessionId):
            sessionId = validatedSessionId
        case .failure(let issue):
            return makeSessionValidationErrorResponse(issue: issue, requestId: req.id)
        }

        let shouldUseSSE = shouldUseSSEResponse(
            forMethod: req.method,
            acceptHeader: request.headers[.accept]
        )

        if shouldUseSSE {
            return handleRequestWithSSE(
                message: message,
                handler: handler,
                sessionId: sessionId
            )
        }

        if let response = handler(message) {
            return makeJSONResponse(response, sessionId: sessionId)
        }
        return Response(status: .accepted)
    }

    /// Handle a request with SSE stream response, allowing intermediate notifications.
    private func handleRequestWithSSE(
        message: JSONRPCMessage,
        handler: @escaping MessageHandler,
        sessionId: String
    ) -> Response {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let streamId = "post-\(UUID().uuidString.prefix(8))"

        // 1. Register stream for intermediate pushes during request processing
        sseStreamManager.register(
            sessionId: sessionId,
            streamId: streamId,
            continuation: continuation,
            type: .post
        )

        // 2. Process request (may trigger onLog/onStatusChange → pushed to GET streams)
        if let response = handler(message) {
            // 3. Send final response as SSE event
            do {
                let sseData = try SSEEncoder.encode(response, eventId: "\(streamId)-final")
                continuation.yield(ByteBuffer(data: sseData))
            } catch {
                log("Failed to encode SSE response: \(error.localizedDescription)")
            }
        }

        // 4. Finish stream
        sseStreamManager.remove(streamId: streamId)

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"

        return Response(
            status: .ok,
            headers: headers,
            body: .init(asyncSequence: stream)
        )
    }

    private func handleInitialize(
        message: JSONRPCMessage,
        handler: @escaping MessageHandler,
        sessionManager: MCPSessionManager
    ) -> Response {
        guard let response = handler(message) else {
            return Response(status: .internalServerError)
        }

        guard case .response(let rpcResponse) = response else {
            return Response(status: .internalServerError)
        }

        if rpcResponse.error != nil {
            return makeJSONResponse(response)
        }

        guard let result: InitializeResult = try? rpcResponse.result?.decoded(),
              MCPProtocolVersion.supportedVersions.contains(result.protocolVersion) else {
            return Response(status: .internalServerError)
        }

        let sessionId = sessionManager.createSession()
        sessionManager.setProtocolVersion(sessionId, version: result.protocolVersion)
        notifySessionCountChanged()

        guard let jsonData = try? response.encode() else {
            return Response(status: .internalServerError)
        }

        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[mcpSessionIdField] = sessionId
        headers[mcpProtocolVersionField] = result.protocolVersion

        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: jsonData))
        )
    }

    // MARK: - GET Handler (SSE stream)

    private func handleGet(request: Request, sessionManager: MCPSessionManager) -> Response {
        if let origin = request.headers[.origin] {
            guard isValidOrigin(origin) else {
                return Response(status: .forbidden)
            }
        }

        guard let accept = request.headers[.accept],
              accept.contains("text/event-stream") else {
            return Response(status: .notAcceptable)
        }

        let getContext: GetRequestContext
        switch validateGetRequestContext(request: request, sessionManager: sessionManager) {
        case .success(let validatedContext):
            getContext = validatedContext
        case .failure(let issue):
            return makeHTTPErrorResponse(for: issue)
        }

        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let streamId = "get-\(UUID().uuidString.prefix(8))"

        let primerData = SSEEncoder.encodePrimerEvent(eventId: streamId)
        continuation.yield(ByteBuffer(data: primerData))

        switch getContext {
        case .bound(let sessionId):
            sseStreamManager.register(
                sessionId: sessionId,
                streamId: streamId,
                continuation: continuation,
                type: .get
            )
        case .anonymous:
            continuation.finish()
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
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
        if let origin = request.headers[.origin] {
            guard isValidOrigin(origin) else {
                return Response(status: .forbidden)
            }
        }

        let sessionId: String
        switch validateSessionContext(request: request, sessionManager: sessionManager) {
        case .success(let validatedSessionId):
            sessionId = validatedSessionId
        case .failure(let issue):
            return makeHTTPErrorResponse(for: issue)
        }

        if sessionManager.terminateSession(sessionId) {
            sseStreamManager.closeSession(sessionId: sessionId)
            notifySessionCountChanged()
            return Response(status: .ok)
        }

        return Response(status: .notFound)
    }

    // MARK: - Session / Header Validation

    private enum SessionValidationIssue: Error {
        case missingSessionId
        case invalidSessionId
        case missingProtocolVersion
        case unsupportedProtocolVersion(String)
        case protocolVersionMismatch(expected: String, actual: String)
    }

    private enum GetRequestContext {
        case anonymous
        case bound(String)
    }

    private func validateGetRequestContext(
        request: Request,
        sessionManager: MCPSessionManager
    ) -> Result<GetRequestContext, SessionValidationIssue> {
        if let sessionId = request.headers[mcpSessionIdField] {
            guard !sessionId.isEmpty else {
                return .failure(.missingSessionId)
            }

            switch validateSessionContext(request: request, sessionManager: sessionManager) {
            case .success(let validatedSessionId):
                return .success(.bound(validatedSessionId))
            case .failure(let issue):
                return .failure(issue)
            }
        }

        if let protocolVersion = request.headers[mcpProtocolVersionField], !protocolVersion.isEmpty,
           !MCPProtocolVersion.supportedVersions.contains(protocolVersion) {
            return .failure(.unsupportedProtocolVersion(protocolVersion))
        }

        return .success(.anonymous)
    }

    private func validateSessionContext(
        request: Request,
        sessionManager: MCPSessionManager
    ) -> Result<String, SessionValidationIssue> {
        guard let sessionId = request.headers[mcpSessionIdField], !sessionId.isEmpty else {
            return .failure(.missingSessionId)
        }

        guard let session = sessionManager.validateSession(sessionId) else {
            return .failure(.invalidSessionId)
        }

        let protocolVersion: String
        if let headerProtocolVersion = request.headers[mcpProtocolVersionField], !headerProtocolVersion.isEmpty {
            protocolVersion = headerProtocolVersion
        } else if let negotiatedVersion = session.protocolVersion, !negotiatedVersion.isEmpty {
            protocolVersion = negotiatedVersion
        } else {
            return .failure(.missingProtocolVersion)
        }

        guard MCPProtocolVersion.supportedVersions.contains(protocolVersion) else {
            return .failure(.unsupportedProtocolVersion(protocolVersion))
        }

        if let negotiatedVersion = session.protocolVersion,
           negotiatedVersion != protocolVersion {
            return .failure(.protocolVersionMismatch(expected: negotiatedVersion, actual: protocolVersion))
        }

        return .success(sessionId)
    }

    private func isValidPostAcceptHeader(_ accept: String) -> Bool {
        accept.contains("application/json") && accept.contains("text/event-stream")
    }

    private func shouldUseSSEResponse(forMethod method: String, acceptHeader: String?) -> Bool {
        guard let acceptHeader = acceptHeader,
              acceptHeader.contains("text/event-stream") else {
            return false
        }

        switch method {
        case "tools/call":
            return true
        default:
            return false
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

    private func makeSessionValidationErrorResponse(
        issue: SessionValidationIssue,
        requestId: RequestID?
    ) -> Response {
        switch issue {
        case .missingSessionId:
            return makeJSONRPCErrorResponse(
                id: requestId,
                code: JSONRPCError.invalidRequest,
                message: "Missing session ID",
                status: .badRequest
            )
        case .invalidSessionId:
            return makeJSONRPCErrorResponse(
                id: requestId,
                code: JSONRPCError.invalidRequest,
                message: "Invalid or expired session ID",
                status: .notFound
            )
        case .missingProtocolVersion:
            return makeJSONRPCErrorResponse(
                id: requestId,
                code: JSONRPCError.invalidRequest,
                message: "Missing MCP-Protocol-Version header",
                status: .badRequest
            )
        case .unsupportedProtocolVersion(let version):
            return makeJSONRPCErrorResponse(
                id: requestId,
                code: JSONRPCError.invalidRequest,
                message: "Unsupported MCP-Protocol-Version: \(version)",
                status: .badRequest
            )
        case .protocolVersionMismatch(let expected, let actual):
            return makeJSONRPCErrorResponse(
                id: requestId,
                code: JSONRPCError.invalidRequest,
                message: "MCP-Protocol-Version mismatch: expected \(expected), got \(actual)",
                status: .badRequest
            )
        }
    }

    private func makeHTTPErrorResponse(for issue: SessionValidationIssue) -> Response {
        switch issue {
        case .missingSessionId, .missingProtocolVersion, .unsupportedProtocolVersion, .protocolVersionMismatch:
            return Response(status: .badRequest)
        case .invalidSessionId:
            return Response(status: .notFound)
        }
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

// MARK: - SSEStreamManager

/// Manages SSE streams for all sessions.
///
/// Each session can have:
/// - One or more GET SSE streams (for server-initiated messages)
/// - Zero or more POST SSE streams (for request processing)
///
/// Thread-safe: all mutations are guarded by an internal lock.
@available(macOS 14, *)
final class SSEStreamManager {

    /// A registered SSE stream
    struct StreamInfo {
        let sessionId: String
        let streamId: String
        let continuation: AsyncStream<ByteBuffer>.Continuation
        let type: StreamType
        let createdAt: Date

        enum StreamType {
            case get     // GET /mcp SSE stream
            case post    // POST /mcp SSE stream (for a specific request)
        }
    }

    private var streams: [String: StreamInfo] = [:]  // streamId -> StreamInfo
    private let lock = NSLock()

    /// Register a new SSE stream.
    func register(sessionId: String, streamId: String, continuation: AsyncStream<ByteBuffer>.Continuation, type: StreamInfo.StreamType) {
        lock.lock()
        streams[streamId] = StreamInfo(sessionId: sessionId, streamId: streamId, continuation: continuation, type: type, createdAt: Date())
        lock.unlock()
    }

    /// Remove a stream (on disconnect or completion). Finishes the continuation.
    func remove(streamId: String) {
        lock.lock()
        if let info = streams.removeValue(forKey: streamId) {
            info.continuation.finish()
        }
        lock.unlock()
    }

    /// Send an SSE event to a specific stream by ID.
    func send(streamId: String, data: Data) {
        lock.lock()
        if let info = streams[streamId] {
            info.continuation.yield(ByteBuffer(data: data))
        }
        lock.unlock()
    }

    /// Send a notification to ONE of the session's GET streams.
    /// Per MCP spec: "MUST send each JSON-RPC message on only one of the connected streams"
    func sendToSession(sessionId: String, data: Data) {
        lock.lock()
        // Find the first GET stream for this session
        let getStream = streams.values.first { $0.sessionId == sessionId && $0.type == .get }
        if let stream = getStream {
            stream.continuation.yield(ByteBuffer(data: data))
        }
        lock.unlock()
    }

    /// Close all streams for a session. Called when session is terminated.
    func closeSession(sessionId: String) {
        lock.lock()
        let sessionStreams = streams.filter { $0.value.sessionId == sessionId }
        for (id, info) in sessionStreams {
            info.continuation.finish()
            streams.removeValue(forKey: id)
        }
        lock.unlock()
    }

    /// Close all streams. Called on transport shutdown.
    func closeAllStreams() {
        lock.lock()
        for (_, info) in streams {
            info.continuation.finish()
        }
        streams.removeAll()
        lock.unlock()
    }

    /// Get the count of registered streams.
    var streamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }

    /// Get the count of GET streams for a specific session.
    func getStreamCount(sessionId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.values.filter { $0.sessionId == sessionId && $0.type == .get }.count
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
