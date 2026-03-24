// TCPTransport.swift
// PlayCoverMCP

import Foundation
import Network

/// TCP transport for MCP server, compatible with StdioTransport's MessageHandler interface.
/// Supports listening on loopback (127.0.0.1) or all interfaces (0.0.0.0).
/// Supports multiple concurrent client connections.
/// Uses line-delimited JSON-RPC protocol (same as StdioTransport).
public final class TCPTransport {

    // MARK: - Types

    /// Same signature as StdioTransport.MessageHandler
    public typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?

    /// Listen host configuration
    public enum ListenHost: String, CaseIterable, Equatable {
        /// Listen on 127.0.0.1 only (local connections)
        case loopback = "127.0.0.1"
        /// Listen on 0.0.0.0 (all interfaces, accessible from network)
        case allInterfaces = "0.0.0.0"

        /// The NWHost value for NWEndpoint
        var nwHost: NWEndpoint.Host {
            switch self {
            case .loopback:
                return .ipv4(.loopback)
            case .allInterfaces:
                return .ipv4(.any)
            }
        }
    }

    /// Current transport state
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

    /// State change callback
    public var onStateChange: ((State) -> Void)?

    /// Client count change callback (dispatched to main queue)
    public var onClientCountChanged: ((Int) -> Void)?

    // MARK: - Properties

    /// Current state (read from any thread, written only from queue)
    public private(set) var state: State = .stopped

    /// Number of currently connected clients
    public private(set) var connectedClientCount: Int = 0

    /// The port this transport is configured for
    public let port: UInt16

    /// The host this transport is configured to listen on
    public let host: ListenHost

    private let handler: MessageHandler
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    private let queue = DispatchQueue(label: "io.playcover.mcp.tcp", qos: .userInitiated)
    private let lock = NSLock()

    // MARK: - Init

    /// Create a TCPTransport.
    /// - Parameters:
    ///   - port: Port to listen on. Use 0 for system-assigned port (useful in tests).
    ///   - host: Host to listen on. Defaults to loopback (127.0.0.1).
    ///   - handler: Message handler, same signature as StdioTransport.MessageHandler.
    public init(port: UInt16 = 19820, host: ListenHost = .loopback, handler: @escaping MessageHandler) {
        self.port = port
        self.host = host
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Start listening for TCP connections.
    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stop listening and disconnect all clients.
    public func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Internal (queue-confined)

    private func startOnQueue() {
        guard case .stopped = state else { return }

        setState(.starting)

        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: host.nwHost,
                port: NWEndpoint.Port(rawValue: port) ?? .any
            )

            let newListener = try NWListener(using: params)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] newState in
                self?.queue.async {
                    self?.handleListenerStateChange(newState)
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.handleNewConnection(connection)
                }
            }

            newListener.start(queue: queue)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil

        // Disconnect all clients
        let allClients = clients.values
        clients.removeAll()
        for client in allClients {
            client.cancel()
        }
        connectedClientCount = 0
        setState(.stopped)
    }

    private func handleListenerStateChange(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            if let port = listener?.port?.rawValue {
                setState(.running(port: port))
                log("TCPTransport: listening on \(host.rawValue):\(port)")
            }
        case .failed(let error):
            setState(.failed(error.localizedDescription))
            log("TCPTransport: listener failed: \(error)")
            // Attempt cleanup
            listener?.cancel()
            listener = nil
        case .cancelled:
            // Normal shutdown, state already handled by stop()
            break
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let client = ClientConnection(connection: connection, handler: handler, queue: queue) { [weak self] clientId in
            self?.queue.async {
                self?.removeClient(clientId)
            }
        }

        let clientId = ObjectIdentifier(client)
        clients[clientId] = client
        connectedClientCount = clients.count
        notifyClientCountChanged()

        log("TCPTransport: client connected (\(connectedClientCount) total)")
        client.start()
    }

    private func removeClient(_ clientId: ObjectIdentifier) {
        if clients.removeValue(forKey: clientId) != nil {
            connectedClientCount = clients.count
            notifyClientCountChanged()
            log("TCPTransport: client disconnected (\(connectedClientCount) total)")
        }
    }

    private func notifyClientCountChanged() {
        let count = connectedClientCount
        if let callback = onClientCountChanged {
            DispatchQueue.main.async {
                callback(count)
            }
        }
    }

    private func setState(_ newState: State) {
        state = newState
        let callback = onStateChange
        if let callback = callback {
            DispatchQueue.main.async {
                callback(newState)
            }
        }
    }

    private func log(_ message: String) {
        // Use stderr to avoid interfering with any protocol stream
        let data = (message + "\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }
}

// MARK: - ClientConnection

/// Manages a single TCP client connection with its own data buffer.
private final class ClientConnection {

    typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?
    typealias DisconnectHandler = (ObjectIdentifier) -> Void

    private let connection: NWConnection
    private let handler: MessageHandler
    private let queue: DispatchQueue
    private let onDisconnect: DisconnectHandler
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping MessageHandler,
         queue: DispatchQueue, onDisconnect: @escaping DisconnectHandler) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
        self.onDisconnect = onDisconnect
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                // Connection is established, start receiving data
                self.scheduleReceive()
            case .failed, .cancelled:
                self.onDisconnect(ObjectIdentifier(self))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Receive loop

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }

            if isComplete {
                // Connection closed by remote
                self.connection.cancel()
                return
            }

            if let error = error {
                self.logError("receive error: \(error)")
                self.connection.cancel()
                return
            }

            // Continue reading
            self.scheduleReceive()
        }
    }

    private func processBuffer() {
        let newline = UInt8(0x0A) // '\n'

        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            // Remove the line and the newline character
            buffer.removeSubrange(buffer.startIndex...index)

            guard !lineData.isEmpty else { continue }

            do {
                let message = try JSONRPCMessage.parse(Data(lineData))
                if let response = handler(message) {
                    try sendResponse(response)
                }
            } catch {
                logError("error processing message: \(error.localizedDescription)")
                // Send JSON-RPC parse error response
                sendParseError()
            }
        }
    }

    // MARK: - Send

    private func sendResponse(_ message: JSONRPCMessage) throws {
        let data = try message.encode()
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let sendData = line.data(using: .utf8) else { return }

        connection.send(content: sendData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logError("send error: \(error)")
            }
        })
    }

    private func sendParseError() {
        let errorResponse = """
        {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
        """
        if let data = (errorResponse + "\n").data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func logError(_ message: String) {
        let data = ("TCPTransport: \(message)\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }
}
