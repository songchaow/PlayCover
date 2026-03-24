// RegistrationListener.swift
// PlayCoverMCP

import Foundation
import Network

/// A TCP server that listens for runtime registration requests.
///
/// When a PlayTools runtime starts in an app process, it connects to this listener
/// and sends a `register` message. The listener adds the session to the registry
/// and responds with `register_ack`.
public final class RegistrationListener: Sendable {

    // MARK: - Constants

    /// Default well-known port for runtime registration.
    public static let defaultPort: UInt16 = 52741

    // MARK: - Public State

    /// The port this listener is bound to (useful when binding to port 0).
    public private(set) var localPort: UInt16?

    /// Whether the listener is currently running.
    public private(set) var isRunning: Bool

    // MARK: - Private

    private let requestedPort: UInt16
    private let registry: SessionRegistry
    private var listener: NWListener?
    private let lock = NSLock()
    private var activeConnections: [String: NWConnection] = [:]
    private var readBuffers: [ObjectIdentifier: Data] = [:]
    private let callbackQueue = DispatchQueue(label: "com.playcover.registration-listener")

    // MARK: - Init

    /// Create a registration listener.
    /// - Parameters:
    ///   - port: Port to bind to. Use 0 for an ephemeral port, or `defaultPort` for the well-known port.
    ///   - registry: The session registry to register sessions into.
    public init(port: UInt16 = defaultPort, registry: SessionRegistry) {
        self.requestedPort = port
        self.registry = registry
        self.isRunning = false
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the listener. Returns the actual bound port.
    @discardableResult
    public func start() throws -> UInt16 {
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw BridgeProtocolError.invalidMessage("Invalid port: \(requestedPort)")
        }

        let parameters = NWParameters.tcp
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw BridgeProtocolError.connectionRefused
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = nwListener.port?.rawValue {
                    self?.lock.lock()
                    self?.localPort = port
                    self?.isRunning = true
                    self?.lock.unlock()
                }
            case .cancelled, .failed:
                self?.lock.lock()
                self?.isRunning = false
                self?.lock.unlock()
            default:
                break
            }
        }

        nwListener.start(queue: callbackQueue)

        self.listener = nwListener

        // Wait briefly for the listener to become ready
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            lock.lock()
            let port = localPort
            lock.unlock()
            if port != nil { return port! }
            usleep(100_000) // 100ms
        }

        nwListener.cancel()
        throw BridgeProtocolError.timeout("Registration listener failed to start")
    }

    /// Stop the listener and close all active connections.
    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        self.isRunning = false
        self.localPort = nil
        let connections = activeConnections
        activeConnections.removeAll()
        lock.unlock()

        for (_, conn) in connections {
            conn.cancel()
        }
        listener?.cancel()
    }

    // MARK: - Private

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: callbackQueue)

        let connId = ObjectIdentifier(connection)
        readBuffers[connId] = Data()

        readFromConnection(connection)
    }

    private func readFromConnection(_ connection: NWConnection) {
        let connId = ObjectIdentifier(connection)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if let data = data, !data.isEmpty {
                self.readBuffers[connId, default: Data()].append(data)
                let readBuffer = self.readBuffers[connId]!

                // Parse all complete messages
                var remaining = readBuffer
                while let newlineRange = remaining.range(of: Data("\n".utf8)) {
                    let lineData = remaining[remaining.startIndex..<newlineRange.lowerBound]
                    remaining = Data(remaining[newlineRange.upperBound...])

                    if !lineData.isEmpty {
                        if let message = try? bridgeDecode(lineData) {
                            self.handleMessage(message, connection: connection)
                        }
                    }
                }
                self.readBuffers[connId] = remaining

                // Continue reading
                self.readFromConnection(connection)
            } else if isComplete || error != nil {
                self.removeConnection(connection)
                self.readBuffers.removeValue(forKey: connId)
                connection.cancel()
            }
        }
    }

    private func handleMessage(_ message: BridgeMessage, connection: NWConnection) {
        switch message {
        case .register(let payload):
            handleRegister(payload, connection: connection)
        case .ping(let payload):
            handlePing(payload, connection: connection)
        case .close(let payload):
            handleUnregister(payload.sessionId, connection: connection)
        default:
            // Ignore other messages on the registration channel
            break
        }
    }

    private func handleRegister(_ payload: RegisterPayload, connection: NWConnection) {
        let sessionInfo = SessionInfo(from: payload)

        do {
            try registry.register(sessionInfo)
            let ack = BridgeMessage.registerAck(
                RegisterAckPayload(sessionId: payload.sessionId, status: "ok")
            )
            sendToConnection(connection, message: ack)

            lock.lock()
            activeConnections[payload.sessionId] = connection
            lock.unlock()
        } catch SessionError.sessionAlreadyExists {
            // Re-register: remove old, add new
            registry.unregisterByBundleId(payload.bundleId)
            do {
                try registry.register(sessionInfo)
            } catch {
                // Should not happen after removal
                return
            }
            let ack = BridgeMessage.registerAck(
                RegisterAckPayload(sessionId: payload.sessionId, status: "ok")
            )
            sendToConnection(connection, message: ack)

            lock.lock()
            activeConnections[payload.sessionId] = connection
            lock.unlock()
        } catch {
            let ack = BridgeMessage.error(
                BridgeErrorPayload(
                    sessionId: payload.sessionId,
                    code: -1,
                    message: error.localizedDescription
                )
            )
            sendToConnection(connection, message: ack)
        }
    }

    private func handlePing(_ payload: PingPayload, connection: NWConnection) {
        do {
            try registry.updateHeartbeat(sessionId: payload.sessionId)
        } catch {
            // Session not found, ignore
        }

        let pong = BridgeMessage.pong(PongPayload(sessionId: payload.sessionId, timestamp: payload.timestamp))
        sendToConnection(connection, message: pong)
    }

    private func handleUnregister(_ sessionId: String, connection: NWConnection) {
        try? registry.unregister(sessionId: sessionId)
        removeConnection(connection)

        let ack = BridgeMessage.close(ClosePayload(sessionId: sessionId, reason: "acknowledged"))
        sendToConnection(connection, message: ack)

        connection.cancel()
    }

    private func sendToConnection(_ connection: NWConnection, message: BridgeMessage) {
        guard let data = try? bridgeFrame(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.lock()
        activeConnections = activeConnections.filter { $0.value === connection }
        lock.unlock()
    }
}
