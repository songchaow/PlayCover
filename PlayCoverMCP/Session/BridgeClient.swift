// BridgeClient.swift
// PlayCoverMCP

import Foundation
import Network

/// A TCP client that connects to a runtime's bridge listener to send commands.
///
/// Usage:
/// ```swift
/// let client = BridgeClient(sessionId: "sess-1", host: "127.0.0.1", port: 52742)
/// try await client.connect()
/// let response = try await client.sendCommand("tap", params: ["x": 100, "y": 200])
/// client.close()
/// ```
public final class BridgeClient: Sendable {

    // MARK: - Public State

    public let sessionId: String
    public let host: String
    public let port: UInt16
    public private(set) var isConnected: Bool

    // MARK: - Private

    private var connection: NWConnection?
    private let lock = NSLock()
    private var commandCounter: UInt64 = 0
    private var readBuffer = Data()
    private let callbackQueue = DispatchQueue(label: "com.playcover.bridge-client")

    // MARK: - Init

    public init(sessionId: String, host: String = "127.0.0.1", port: UInt16) {
        self.sessionId = sessionId
        self.host = host
        self.port = port
        self.isConnected = false
    }

    deinit {
        close()
    }

    // MARK: - Connection

    /// Connect to the runtime's bridge listener.
    public func connect(timeout: TimeInterval = 5.0) async throws {
        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeProtocolError.invalidMessage("Invalid port: \(port)")
        }

        let conn = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        self.connection = conn

        conn.start(queue: callbackQueue)

        // Wait for connection
        let connected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            var resumed = false
            let resumeOnce: (Result<Bool, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            callbackQueue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(BridgeProtocolError.timeout("Connection to \(self.host):\(self.port) timed out")))
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(true))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(BridgeProtocolError.connectionClosed))
                default:
                    break
                }
            }
        }

        if connected {
            lock.lock()
            self.isConnected = true
            lock.unlock()
        }
    }

    /// Close the connection.
    public func close() {
        lock.lock()
        let conn = self.connection
        self.connection = nil
        self.isConnected = false
        self.readBuffer = Data()
        lock.unlock()

        conn?.cancel()
    }

    // MARK: - Send / Receive

    /// Send a bridge message.
    public func send(_ message: BridgeMessage) async throws {
        lock.lock()
        guard let conn = connection else {
            lock.unlock()
            throw BridgeProtocolError.connectionClosed
        }
        lock.unlock()

        let data = try bridgeFrame(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Receive a single bridge message.
    public func receive(timeout: TimeInterval = 5.0) async throws -> BridgeMessage {
        // Try to parse from buffer first
        lock.lock()
        if let message = tryParseMessageFromBuffer() {
            lock.unlock()
            return message
        }
        lock.unlock()

        // Need more data from the connection
        return try await readNextMessage(timeout: timeout)
    }

    /// Send a command and wait for the response.
    public func sendCommand(
        _ command: String,
        params: AnyCodable? = nil,
        timeout: TimeInterval = 5.0
    ) async throws -> CommandResponsePayload {
        let commandId = nextCommandId()

        let message = BridgeMessage.command(
            CommandPayload(
                sessionId: sessionId,
                commandId: commandId,
                command: command,
                params: params
            )
        )

        try await send(message)

        // Read responses until we get the one matching our commandId
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await receive(timeout: deadline.timeIntervalSinceNow)
            switch response {
            case .commandResponse(let payload) where payload.commandId == commandId:
                if payload.status == "ok" {
                    return payload
                } else {
                    throw BridgeProtocolError.invalidMessage("Command failed: \(payload.status)")
                }
            case .error(let payload):
                throw BridgeProtocolError.invalidMessage("Runtime error: \(payload.message)")
            default:
                // Ignore other messages (pong, etc.)
                continue
            }
        }

        throw BridgeProtocolError.timeout("Waiting for command response '\(commandId)'")
    }

    /// Send a ping and wait for pong.
    public func ping(timeout: TimeInterval = 3.0) async throws {
        let message = BridgeMessage.ping(PingPayload(sessionId: sessionId))
        try await send(message)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await receive(timeout: deadline.timeIntervalSinceNow)
            if case .pong = response {
                return
            }
        }

        throw BridgeProtocolError.timeout("Waiting for pong")
    }

    // MARK: - Private

    private func readNextMessage(timeout: TimeInterval) async throws -> BridgeMessage {
        guard let conn = connection else {
            throw BridgeProtocolError.connectionClosed
        }

        while true {
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                var resumed = false
                let resumeOnce: (Result<Data, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    switch result {
                    case .success(let d): continuation.resume(returning: d)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }

                callbackQueue.asyncAfter(deadline: .now() + timeout) {
                    resumeOnce(.failure(BridgeProtocolError.timeout("Receive timed out")))
                }

                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        resumeOnce(.success(data))
                    } else if isComplete {
                        resumeOnce(.failure(BridgeProtocolError.connectionClosed))
                    } else if let error = error {
                        resumeOnce(.failure(error))
                    } else {
                        resumeOnce(.failure(BridgeProtocolError.connectionClosed))
                    }
                }
            }

            lock.lock()
            readBuffer.append(data)
            if let message = tryParseMessageFromBuffer() {
                lock.unlock()
                return message
            }
            lock.unlock()
        }
    }

    private func tryParseMessageFromBuffer() -> BridgeMessage? {
        if let newlineRange = readBuffer.range(of: Data("\n".utf8)) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineRange.lowerBound]
            readBuffer = Data(readBuffer[newlineRange.upperBound...])
            if !lineData.isEmpty, let message = try? bridgeDecode(lineData) {
                return message
            }
        }
        return nil
    }

    private func nextCommandId() -> String {
        lock.lock()
        defer { lock.unlock() }
        commandCounter += 1
        return "cmd-\(commandCounter)"
    }
}
