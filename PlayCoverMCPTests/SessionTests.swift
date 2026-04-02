// SessionTests.swift
// PlayCoverMCPTests

import Foundation
import XCTest
import Network

// MARK: - Bridge Protocol Tests

final class BridgeProtocolTests: XCTestCase {

    // MARK: - Encoding/Decoding

    func testRegisterMessageRoundTrip() throws {
        let payload = RegisterPayload(sessionId: "sess-1", bundleId: "com.example.app", pid: 12345, runtimePort: 52742)
        let message = BridgeMessage.register(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.type, .register)
        XCTAssertEqual(decoded.sessionId, "sess-1")
    }

    func testRegisterAckMessageRoundTrip() throws {
        let payload = RegisterAckPayload(sessionId: "sess-1", status: "ok")
        let message = BridgeMessage.registerAck(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.type, .registerAck)
    }

    func testPingPongRoundTrip() throws {
        let ping = BridgeMessage.ping(PingPayload(sessionId: "sess-1", timestamp: 1000.0))
        let pong = BridgeMessage.pong(PongPayload(sessionId: "sess-1", timestamp: 1000.5))

        let pingData = try bridgeEncode(ping)
        let decodedPing = try bridgeDecode(pingData)
        XCTAssertEqual(decodedPing, ping)

        let pongData = try bridgeEncode(pong)
        let decodedPong = try bridgeDecode(pongData)
        XCTAssertEqual(decodedPong, pong)
    }

    func testCommandMessageRoundTrip() throws {
        let params = AnyCodable(["x": 100.0, "y": 200.0] as [String: Any])
        let payload = CommandPayload(sessionId: "sess-1", commandId: "cmd-1", command: "tap", params: params)
        let message = BridgeMessage.command(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.type, .command)
    }

    func testCommandResponseMessageRoundTrip() throws {
        let result = AnyCodable(["tapped": true] as [String: Any])
        let payload = CommandResponsePayload(sessionId: "sess-1", commandId: "cmd-1", status: "ok", result: result)
        let message = BridgeMessage.commandResponse(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
    }

    func testErrorMessageRoundTrip() throws {
        let payload = BridgeErrorPayload(sessionId: "sess-1", code: 42, message: "something went wrong")
        let message = BridgeMessage.error(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
    }

    func testCloseMessageRoundTrip() throws {
        let payload = ClosePayload(sessionId: "sess-1", reason: "shutdown")
        let message = BridgeMessage.close(payload)

        let data = try bridgeEncode(message)
        let decoded = try bridgeDecode(data)

        XCTAssertEqual(decoded, message)
    }

    // MARK: - String Encoding/Decoding

    func testEncodeToString() throws {
        let message = BridgeMessage.register(
            RegisterPayload(sessionId: "sess-1", bundleId: "com.test", pid: 100, runtimePort: 52742)
        )
        let string = try bridgeEncodeToString(message)
        let decoded = try bridgeDecodeFromString(string)

        XCTAssertEqual(decoded, message)
    }

    // MARK: - Framing

    func testFrameMessage() throws {
        let message = BridgeMessage.ping(PingPayload(sessionId: "sess-1"))
        let framed = try bridgeFrame(message)

        // Should end with newline
        XCTAssertTrue(framed.suffix(1) == Data("\n".utf8))

        // Should be decodable after stripping newline
        let withoutNewline = framed.dropLast()
        let decoded = try bridgeDecode(Data(withoutNewline))
        XCTAssertEqual(decoded, message)
    }

    func testParseFramedSingleMessage() throws {
        let message = BridgeMessage.ping(PingPayload(sessionId: "sess-1"))
        let framed = try bridgeFrame(message)

        let (messages, remaining) = bridgeParseFramed(framed)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first, message)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testParseFramedMultipleMessages() throws {
        let msg1 = BridgeMessage.ping(PingPayload(sessionId: "sess-1"))
        let msg2 = BridgeMessage.pong(PongPayload(sessionId: "sess-1", timestamp: 1.0))
        let msg3 = BridgeMessage.close(ClosePayload(sessionId: "sess-1"))

        var data = Data()
        data.append(try bridgeFrame(msg1))
        data.append(try bridgeFrame(msg2))
        data.append(try bridgeFrame(msg3))

        let (messages, remaining) = bridgeParseFramed(data)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], msg1)
        XCTAssertEqual(messages[1], msg2)
        XCTAssertEqual(messages[2], msg3)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testParseFramedPartial() throws {
        let msg1 = BridgeMessage.ping(PingPayload(sessionId: "sess-1"))
        let fullFrame = try bridgeFrame(msg1)
        let partial = fullFrame.dropLast(2) // Remove "\n" and one char

        let (messages, remaining) = bridgeParseFramed(Data(partial))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(remaining.isEmpty)
    }

    func testParseFramedWithPartialNextMessage() throws {
        let msg1 = BridgeMessage.ping(PingPayload(sessionId: "sess-1"))
        let msg2 = BridgeMessage.pong(PongPayload(sessionId: "sess-1"))
        let frame1 = try bridgeFrame(msg1)
        let frame2Partial = try bridgeFrame(msg2).dropLast(5) // Incomplete second message

        var data = Data()
        data.append(frame1)
        data.append(frame2Partial)

        let (messages, remaining) = bridgeParseFramed(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first, msg1)
        XCTAssertFalse(remaining.isEmpty)
    }

    // MARK: - JSON Structure Validation

    func testRegisterJSONStructure() throws {
        let message = BridgeMessage.register(
            RegisterPayload(sessionId: "s1", bundleId: "com.example", pid: 42, runtimePort: 12345)
        )
        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "register")
        XCTAssertEqual(json["sessionId"] as? String, "s1")
        XCTAssertEqual(json["bundleId"] as? String, "com.example")
        XCTAssertEqual(json["pid"] as? Int32, 42)
        XCTAssertEqual(json["runtimePort"] as? UInt16, 12345)
    }

    func testCommandJSONStructure() throws {
        let params = AnyCodable(["x": 100, "y": 200, "duration": 0.5] as [String: Any])
        let message = BridgeMessage.command(
            CommandPayload(sessionId: "s1", commandId: "c1", command: "long_press", params: params)
        )
        let data = try bridgeEncode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "command")
        XCTAssertEqual(json["command"] as? String, "long_press")
        let decodedParams = json["params"] as? [String: Any]
        XCTAssertEqual(decodedParams?["x"] as? Int, 100)
        XCTAssertEqual(decodedParams?["y"] as? Int, 200)
    }
}

// MARK: - Session Registry Tests

final class SessionRegistryTests: XCTestCase {

    private var registry: SessionRegistry!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
    }

    override func tearDown() {
        registry.removeAll()
        registry = nil
        super.tearDown()
    }

    func testRegisterAndRetrieve() throws {
        let info = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let retrieved = registry.get("sess-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.sessionId, "sess-1")
        XCTAssertEqual(retrieved?.bundleId, "com.example")
    }

    func testRegisterDuplicateThrows() throws {
        let info = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        try registry.register(info)

        XCTAssertThrowsError(try registry.register(info)) { error in
            XCTAssertTrue(error is SessionError)
            if let sessionError = error as? SessionError {
                XCTAssertEqual(sessionError, .sessionAlreadyExists("sess-1"))
            }
        }
    }

    func testUnregister() throws {
        let info = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        try registry.register(info)

        try registry.unregister(sessionId: "sess-1")

        XCTAssertNil(registry.get("sess-1"))
        XCTAssertEqual(registry.count, 0)
    }

    func testUnregisterNotFoundThrows() {
        XCTAssertThrowsError(try registry.unregister(sessionId: "nonexistent")) { error in
            XCTAssertTrue(error is SessionError)
        }
    }

    func testListSessions() throws {
        let info1 = SessionInfo(sessionId: "sess-1", bundleId: "com.app1", pid: 100, runtimePort: 52742)
        let info2 = SessionInfo(sessionId: "sess-2", bundleId: "com.app2", pid: 200, runtimePort: 52743)
        try registry.register(info1)
        try registry.register(info2)

        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 2)
    }

    func testGetByBundleId() throws {
        let info1 = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        let info2 = SessionInfo(sessionId: "sess-2", bundleId: "com.other", pid: 200, runtimePort: 52743)
        let info3 = SessionInfo(sessionId: "sess-3", bundleId: "com.example", pid: 300, runtimePort: 52744)
        try registry.register(info1)
        try registry.register(info2)
        try registry.register(info3)

        let exampleSessions = registry.getByBundleId("com.example")
        XCTAssertEqual(exampleSessions.count, 2)

        let otherSessions = registry.getByBundleId("com.other")
        XCTAssertEqual(otherSessions.count, 1)
    }

    func testUnregisterByBundleId() throws {
        let info1 = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        let info2 = SessionInfo(sessionId: "sess-2", bundleId: "com.other", pid: 200, runtimePort: 52743)
        let info3 = SessionInfo(sessionId: "sess-3", bundleId: "com.example", pid: 300, runtimePort: 52744)
        try registry.register(info1)
        try registry.register(info2)
        try registry.register(info3)

        let removed = registry.unregisterByBundleId("com.example")
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(Set(removed), ["sess-1", "sess-3"])

        XCTAssertEqual(registry.count, 1)
        XCTAssertNotNil(registry.get("sess-2"))
    }

    func testUpdateHeartbeat() throws {
        let info = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 100, runtimePort: 52742)
        try registry.register(info)

        let originalTime = registry.get("sess-1")!.lastHeartbeat
        usleep(100_000) // 100ms
        try registry.updateHeartbeat(sessionId: "sess-1")

        let updatedTime = registry.get("sess-1")!.lastHeartbeat
        XCTAssertGreaterThan(updatedTime, originalTime)
    }

    func testUpdateHeartbeatNotFound() throws {
        XCTAssertThrowsError(try registry.updateHeartbeat(sessionId: "nonexistent")) { error in
            XCTAssertTrue(error is SessionError)
        }
    }

    func testRemoveStaleSessions() throws {
        let freshInfo = SessionInfo(sessionId: "fresh", bundleId: "com.app", pid: 100, runtimePort: 52742)
        try registry.register(freshInfo)

        // Manually create a stale session
        let staleInfo = SessionInfo(
            sessionId: "stale",
            bundleId: "com.app",
            pid: 200,
            runtimePort: 52743,
            createdAt: Date().addingTimeInterval(-100),
            lastHeartbeat: Date().addingTimeInterval(-100)
        )
        try registry.register(staleInfo)

        let removed = registry.removeStaleSessions(timeout: 10.0)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.sessionId, "stale")
        XCTAssertEqual(registry.count, 1)
        XCTAssertNotNil(registry.get("fresh"))
    }

    func testSessionInfoFromPayload() {
        let payload = RegisterPayload(sessionId: "sess-1", bundleId: "com.example", pid: 42, runtimePort: 12345)
        let info = SessionInfo(from: payload)

        XCTAssertEqual(info.sessionId, "sess-1")
        XCTAssertEqual(info.bundleId, "com.example")
        XCTAssertEqual(info.pid, 42)
        XCTAssertEqual(info.runtimePort, 12345)
    }

    func testSessionInfoToDictionary() {
        let info = SessionInfo(sessionId: "sess-1", bundleId: "com.example", pid: 42, runtimePort: 12345)
        let dict = info.toDictionary()

        XCTAssertEqual(dict["sessionId"] as? String, "sess-1")
        XCTAssertEqual(dict["bundleId"] as? String, "com.example")
        XCTAssertEqual(dict["pid"] as? Int, 42)
        XCTAssertEqual(dict["runtimePort"] as? Int, 12345)
    }
}

// MARK: - Fake Runtime Server

/// A fake runtime server for testing bridge communication.
///
/// Simulates a PlayTools runtime that:
/// 1. Starts a TCP listener on an ephemeral port (command listener)
/// 2. Connects to a registration listener and sends a `register` message
/// 3. Responds to ping/pong
/// 4. Handles commands with a configurable handler
///
/// IMPORTANT: The `start()` method must be called from a test method
/// (XCTestCase) since it uses `XCTestExpectation`.
final class FakeRuntimeServer: NSObject {

    let bundleId: String
    let pid: Int32
    let sessionId: String

    private var listener: NWListener?
    private var registrationConnection: NWConnection?
    private(set) var commandPort: UInt16?
    private(set) var isRunning = false

    /// All commands received by this fake runtime.
    private(set) var receivedCommands: [CommandPayload] = []
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.playcover.test.fake-runtime")
    private var startedFulfilled = false
    private var registeredFulfilled = false

    /// Custom handler for commands. Return a response payload.
    var onCommand: ((CommandPayload) -> CommandResponsePayload)?

    /// Called when the server stops.
    var onStop: (() -> Void)?

    init(bundleId: String = "com.fake.app", pid: Int32 = 9999, sessionId: String = "fake-session-1") {
        self.bundleId = bundleId
        self.pid = pid
        self.sessionId = sessionId
    }

    /// Start the fake runtime. Must be called from a test method.
    /// This method is non-blocking. Use waitForExpectations to wait for
    /// startedExpectation and registeredExpectation.
    /// - Parameter registrationPort: The host's registration listener port.
    /// - Parameter startedExpectation: Fulfilled when the command listener is ready.
    /// - Parameter registeredExpectation: Fulfilled when registration with host is complete.
    func start(registrationPort: UInt16 = 52741, startedExpectation: XCTestExpectation, registeredExpectation: XCTestExpectation) throws {
        // 1. Start command listener on ephemeral port
        guard let nwPort = NWEndpoint.Port(rawValue: 0) else {
            throw BridgeProtocolError.invalidMessage("Cannot create ephemeral port")
        }

        let cmdListener = try NWListener(using: .tcp, on: nwPort)
        self.listener = cmdListener

        cmdListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = cmdListener.port?.rawValue {
                    self?.lock.lock()
                    self?.commandPort = port
                    self?.isRunning = true
                    let shouldFulfill = !self!.startedFulfilled
                    self?.startedFulfilled = true
                    self?.lock.unlock()
                    if shouldFulfill {
                        startedExpectation.fulfill()
                    }

                    // Initiate registration to host
                    self?.connectAndRegister(registrationPort: registrationPort, registeredExpectation: registeredExpectation)
                }
            case .cancelled, .failed:
                self?.lock.lock()
                self?.isRunning = false
                let shouldFulfillStarted = !self!.startedFulfilled
                let shouldFulfillRegistered = !self!.registeredFulfilled
                self?.startedFulfilled = true
                self?.registeredFulfilled = true
                self?.lock.unlock()
                if shouldFulfillStarted { startedExpectation.fulfill() }
                if shouldFulfillRegistered { registeredExpectation.fulfill() }
            default:
                break
            }
        }

        cmdListener.newConnectionHandler = { [weak self] connection in
            self?.handleCommandConnection(connection)
        }

        cmdListener.start(queue: callbackQueue)
    }

    /// Connect to the host's registration listener and send a register message.
    private func connectAndRegister(registrationPort: UInt16, registeredExpectation: XCTestExpectation) {
        guard let cmdPort = commandPort else { return }

        let regHost = NWEndpoint.Host("127.0.0.1")
        guard let regPort = NWEndpoint.Port(rawValue: registrationPort) else {
            return
        }

        let regConn = NWConnection(host: regHost, port: regPort, using: .tcp)
        self.registrationConnection = regConn

        regConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let registerMsg = BridgeMessage.register(
                    RegisterPayload(
                        sessionId: self.sessionId,
                        bundleId: self.bundleId,
                        pid: self.pid,
                        runtimePort: cmdPort
                    )
                )
                if let data = try? bridgeFrame(registerMsg) {
                    regConn.send(content: data, completion: .contentProcessed { _ in })
                }

                // Clear handler after initiating registration to prevent
                // double-fulfill when stop() cancels the connection
                regConn.stateUpdateHandler = nil
                self.readRegistrationResponse(connection: regConn, expectation: registeredExpectation)
            case .failed:
                self.lock.lock()
                let shouldFulfill = !self.registeredFulfilled
                self.registeredFulfilled = true
                self.lock.unlock()
                if shouldFulfill { registeredExpectation.fulfill() }
            case .cancelled:
                self.lock.lock()
                let shouldFulfill = !self.registeredFulfilled
                self.registeredFulfilled = true
                self.lock.unlock()
                if shouldFulfill { registeredExpectation.fulfill() }
            default:
                break
            }
        }

        regConn.start(queue: callbackQueue)
    }

    /// Stop the fake runtime.
    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()

        listener?.cancel()
        listener = nil

        // Send close message if connected, brief delay to allow it to be sent
        if let conn = registrationConnection {
            let closeMsg = BridgeMessage.close(ClosePayload(sessionId: sessionId, reason: "shutdown"))
            if let data = try? bridgeFrame(closeMsg) {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
            usleep(100_000) // 100ms delay for send to complete
            conn.cancel()
            registrationConnection = nil
        }

        onStop?()
    }

    // MARK: - Private

    private func readRegistrationResponse(connection: NWConnection, expectation: XCTestExpectation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, !data.isEmpty else {
                // Connection closed or no data - stop reading
                return
            }

            if let message = try? bridgeDecode(data) {
                switch message {
                case .registerAck:
                    self?.lock.lock()
                    self?.registeredFulfilled = true
                    self?.lock.unlock()
                    expectation.fulfill()
                    return
                case .error:
                    self?.lock.lock()
                    self?.registeredFulfilled = true
                    self?.lock.unlock()
                    expectation.fulfill()
                    return
                default:
                    break
                }
            }

            // Read more (only for non-terminating messages)
            self?.readRegistrationResponse(connection: connection, expectation: expectation)
        }
    }

    private func handleCommandConnection(_ connection: NWConnection) {
        connection.start(queue: callbackQueue)
        var readBuffer = Data()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                readBuffer.append(data)

                while let newlineRange = readBuffer.range(of: Data("\n".utf8)) {
                    let lineData = readBuffer[readBuffer.startIndex..<newlineRange.lowerBound]
                    readBuffer = Data(readBuffer[newlineRange.upperBound...])

                    if !lineData.isEmpty, let message = try? bridgeDecode(lineData) {
                        self.handleHostMessage(message, connection: connection)
                    }
                }

                // Continue reading
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, ic, e in
                    _ = d; _ = ic; _ = e
                }
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func handleHostMessage(_ message: BridgeMessage, connection: NWConnection) {
        switch message {
        case .ping(let payload):
            let pong = BridgeMessage.pong(PongPayload(sessionId: payload.sessionId, timestamp: payload.timestamp))
            if let data = try? bridgeFrame(pong) {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }

        case .command(let payload):
            lock.lock()
            receivedCommands.append(payload)
            lock.unlock()

            let response: CommandResponsePayload
            if let handler = onCommand {
                response = handler(payload)
            } else {
                response = CommandResponsePayload(
                    sessionId: payload.sessionId,
                    commandId: payload.commandId,
                    status: "ok",
                    result: nil
                )
            }

            let responseMsg = BridgeMessage.commandResponse(response)
            if let data = try? bridgeFrame(responseMsg) {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }

        case .close:
            connection.cancel()
            stop()

        default:
            break
        }
    }
}

// MARK: - Helper: Start NWListener and wait for ready

/// Start an NWListener on the given port and return the actual bound port.
// MARK: - Bridge Client & Network Tests

final class BridgeClientTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(port: 0, registry: registry)
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        super.tearDown()
    }

    func testClientConnectAndDisconnect() async throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        guard let runtimePort = fakeRuntime.commandPort else {
            XCTFail("Fake runtime should have a command port")
            return
        }

        let client = BridgeClient(sessionId: fakeRuntime.sessionId, port: runtimePort)
        try await client.connect(timeout: 2.0)
        XCTAssertTrue(client.isConnected)

        client.close()
        XCTAssertFalse(client.isConnected)
        fakeRuntime.stop()
    }

    func testClientConnectionRefused() async {
        let client = BridgeClient(sessionId: "test-1", port: 1)
        do {
            try await client.connect(timeout: 1.0)
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
        XCTAssertFalse(client.isConnected)
    }

    func testClientTimeout() async throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        guard let runtimePort = fakeRuntime.commandPort else {
            XCTFail("Fake runtime should have a command port")
            return
        }

        let client = BridgeClient(sessionId: fakeRuntime.sessionId, port: runtimePort)
        try await client.connect(timeout: 2.0)

        // Try to receive with a short timeout - should timeout since fake runtime
        // only responds to commands via onCommand handler
        do {
            _ = try await client.receive(timeout: 0.5)
            XCTFail("Should have timed out")
        } catch {
            // Expected timeout or connection issue
        }

        client.close()
        fakeRuntime.stop()
    }
}

// MARK: - Registration & Full Handshake Tests

final class SessionHandshakeTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(port: 0, registry: registry)
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        super.tearDown()
    }

    func testRuntimeRegistersWithHost() throws {
        let port = try registrationListener.start()
        XCTAssertTrue(registrationListener.isRunning)
        XCTAssertNotNil(registrationListener.localPort)

        let fakeRuntime = FakeRuntimeServer()
        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Verify session is registered
        let sessions = registry.listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, fakeRuntime.sessionId)
        XCTAssertEqual(sessions.first?.bundleId, fakeRuntime.bundleId)
        XCTAssertEqual(sessions.first?.pid, fakeRuntime.pid)
        XCTAssertNotNil(sessions.first?.runtimePort)

        fakeRuntime.stop()
    }

    func testHostCanSendCommandToRuntime() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "test_command")
            return CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "ok",
                result: AnyCodable(["acknowledged": true] as [String: Any])
            )
        }

        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Connect bridge client to runtime's command port
        guard let cmdPort = fakeRuntime.commandPort else {
            XCTFail("Fake runtime should have a command port")
            return
        }
        let client = BridgeClient(sessionId: fakeRuntime.sessionId, port: cmdPort)
        let connected = expectation(description: "client connected")
        Task {
            do {
                try await client.connect(timeout: 2.0)
                connected.fulfill()
            } catch {
                XCTFail("Connection failed: \(error)")
            }
        }
        wait(for: [connected], timeout: 3.0)

        // Send command
        let commandSent = expectation(description: "command sent")
        Task {
            do {
                let params = AnyCodable(["key": "value"] as [String: Any])
                let response = try await client.sendCommand("test_command", params: params, timeout: 3.0)
                XCTAssertEqual(response.status, "ok")
                commandSent.fulfill()
            } catch {
                XCTFail("Command failed: \(error)")
            }
        }
        wait(for: [commandSent], timeout: 5.0)

        // Verify fake runtime received the command
        XCTAssertEqual(fakeRuntime.receivedCommands.count, 1)
        XCTAssertEqual(fakeRuntime.receivedCommands.first?.command, "test_command")

        client.close()
        fakeRuntime.stop()
    }

    func testCommandFailureIncludesRuntimeMessage() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        fakeRuntime.onCommand = { payload in
            XCTAssertEqual(payload.command, "test_command")
            return CommandResponsePayload(
                sessionId: payload.sessionId,
                commandId: payload.commandId,
                status: "error",
                result: AnyCodable(["message": "GPU trace document not supported"] as [String: Any])
            )
        }

        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        guard let cmdPort = fakeRuntime.commandPort else {
            XCTFail("Fake runtime should have a command port")
            return
        }
        let client = BridgeClient(sessionId: fakeRuntime.sessionId, port: cmdPort)
        let connected = expectation(description: "client connected")
        Task {
            do {
                try await client.connect(timeout: 2.0)
                connected.fulfill()
            } catch {
                XCTFail("Connection failed: \(error)")
            }
        }
        wait(for: [connected], timeout: 3.0)

        let commandFailed = expectation(description: "command failed with detail")
        Task {
            do {
                _ = try await client.sendCommand("test_command", timeout: 3.0)
                XCTFail("Command should have failed")
            } catch let error as BridgeProtocolError {
                XCTAssertEqual(error, .invalidMessage("Command failed: GPU trace document not supported"))
                commandFailed.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [commandFailed], timeout: 5.0)

        client.close()
        fakeRuntime.stop()
    }

    func testPingPongThroughRegistration() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        // Update heartbeat via registry (simulating what the listener does on ping)
        try registry.updateHeartbeat(sessionId: fakeRuntime.sessionId)

        let session = registry.get(fakeRuntime.sessionId)
        XCTAssertNotNil(session)

        fakeRuntime.stop()
    }

    func testRuntimeCloseUnregistersSession() throws {
        let port = try registrationListener.start()

        let fakeRuntime = FakeRuntimeServer()
        let started = expectation(description: "fake runtime started")
        let registered = expectation(description: "registration completed")
        try fakeRuntime.start(registrationPort: port, startedExpectation: started, registeredExpectation: registered)
        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(registry.count, 1)

        // Stop fake runtime (should send close)
        fakeRuntime.stop()

        // Wait for cleanup
        let cleanupWait = expectation(description: "wait for cleanup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            cleanupWait.fulfill()
        }
        wait(for: [cleanupWait], timeout: 1.0)

        // Session should be unregistered
        XCTAssertEqual(registry.count, 0)
    }

    func testMultipleRuntimes() throws {
        let port = try registrationListener.start()

        let fake1 = FakeRuntimeServer(bundleId: "com.app1", sessionId: "sess-1")
        let fake2 = FakeRuntimeServer(bundleId: "com.app2", sessionId: "sess-2")

        let started1 = expectation(description: "fake1 started")
        let registered1 = expectation(description: "fake1 registered")
        let started2 = expectation(description: "fake2 started")
        let registered2 = expectation(description: "fake2 registered")
        try fake1.start(registrationPort: port, startedExpectation: started1, registeredExpectation: registered1)
        try fake2.start(registrationPort: port, startedExpectation: started2, registeredExpectation: registered2)

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(registry.count, 2)
        XCTAssertEqual(registry.getByBundleId("com.app1").count, 1)
        XCTAssertEqual(registry.getByBundleId("com.app2").count, 1)

        fake1.stop()
        fake2.stop()
    }
}

final class RegistrationListenerHostCommandTests: XCTestCase {

    private var registry: SessionRegistry!
    private var registrationListener: RegistrationListener!

    override func setUp() {
        super.setUp()
        registry = SessionRegistry()
        registrationListener = RegistrationListener(
            port: 0,
            registry: registry,
            commandHandler: { payload in
                CommandResponsePayload(
                    sessionId: payload.sessionId,
                    commandId: payload.commandId,
                    status: "ok",
                    result: AnyCodable([
                        "handled": true,
                        "command": payload.command,
                    ] as [String: Any])
                )
            }
        )
    }

    override func tearDown() {
        registrationListener?.stop()
        registry?.removeAll()
        registrationListener = nil
        registry = nil
        super.tearDown()
    }

    func testRuntimeCanSendHostCommandOverRegistrationPort() async throws {
        let sessionId = "sess-host-bridge"
        try registry.register(SessionInfo(sessionId: sessionId, bundleId: "com.example.app", pid: 42, runtimePort: 52742))
        let port = try registrationListener.start()

        let response = try await sendRegistrationCommand(
            port: port,
            payload: CommandPayload(
                sessionId: sessionId,
                commandId: "cmd-host-1",
                command: BridgeCommandName.hostDisassembleBitcode,
                params: AnyCodable(["bitcode_base64": "QQ=="] as [String: Any])
            )
        )

        guard case .commandResponse(let payload) = response else {
            return XCTFail("Expected commandResponse from registration listener")
        }
        XCTAssertEqual(payload.sessionId, sessionId)
        XCTAssertEqual(payload.commandId, "cmd-host-1")
        XCTAssertEqual(payload.status, "ok")
        XCTAssertEqual(payload.result?.dictionary?["handled"] as? Bool, true)
        XCTAssertEqual(payload.result?.dictionary?["command"] as? String, BridgeCommandName.hostDisassembleBitcode)
    }

    func testRegistrationCommandRequiresKnownSession() async throws {
        let port = try registrationListener.start()

        let response = try await sendRegistrationCommand(
            port: port,
            payload: CommandPayload(
                sessionId: "missing-session",
                commandId: "cmd-host-2",
                command: BridgeCommandName.hostDisassembleBitcode,
                params: nil
            )
        )

        guard case .commandResponse(let payload) = response else {
            return XCTFail("Expected commandResponse for missing session")
        }
        XCTAssertEqual(payload.status, "error")
        XCTAssertEqual(payload.result?.dictionary?["message"] as? String, "Session not registered: missing-session")
    }

    private func sendRegistrationCommand(
        port: UInt16,
        payload: CommandPayload,
        timeout: TimeInterval = 3.0
    ) async throws -> BridgeMessage {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }

        try await waitForConnectionReady(connection, timeout: timeout)
        try await sendBridgeMessage(.command(payload), on: connection)
        return try await receiveBridgeMessage(on: connection, timeout: timeout)
    }

    private func waitForConnectionReady(_ connection: NWConnection, timeout: TimeInterval) async throws {
        connection.start(queue: .global(qos: .userInitiated))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(BridgeProtocolError.timeout("registration command connect timed out")))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(BridgeProtocolError.connectionClosed))
                default:
                    break
                }
            }
        }
    }

    private func sendBridgeMessage(_ message: BridgeMessage, on connection: NWConnection) async throws {
        let data = try bridgeFrame(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveBridgeMessage(on connection: NWConnection, timeout: TimeInterval) async throws -> BridgeMessage {
        var buffer = Data()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BridgeMessage, Error>) in
            var resumed = false
            let resumeOnce: (Result<BridgeMessage, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let message):
                    continuation.resume(returning: message)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        let (messages, remaining) = bridgeParseFramed(buffer)
                        buffer = remaining
                        if let first = messages.first {
                            resumeOnce(.success(first))
                        } else {
                            receiveNext()
                        }
                        return
                    }
                    if let error {
                        resumeOnce(.failure(error))
                    } else if isComplete {
                        resumeOnce(.failure(BridgeProtocolError.connectionClosed))
                    } else {
                        resumeOnce(.failure(BridgeProtocolError.invalidMessage("Empty registration command response")))
                    }
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(BridgeProtocolError.timeout("registration command receive timed out")))
            }
            receiveNext()
        }
    }
}

// MARK: - Session Error Tests

final class SessionErrorTests: XCTestCase {

    func testSessionNotFoundDescription() {
        let error = SessionError.sessionNotFound("sess-1")
        XCTAssertEqual(error.localizedDescription, "Session not found: sess-1")
    }

    func testSessionAlreadyExistsDescription() {
        let error = SessionError.sessionAlreadyExists("sess-1")
        XCTAssertEqual(error.localizedDescription, "Session already exists: sess-1")
    }

    func testBridgeProtocolErrorDescriptions() {
        XCTAssertEqual(BridgeProtocolError.invalidUTF8.localizedDescription, "Invalid UTF-8 in bridge message")
        XCTAssertEqual(BridgeProtocolError.connectionClosed.localizedDescription, "Bridge connection closed")
        XCTAssertEqual(BridgeProtocolError.connectionRefused.localizedDescription, "Bridge connection refused")
    }

    func testPlayCoverMCPErrorWrapping() {
        let sessionError = SessionError.sessionNotFound("sess-1")
        let mcpError = PlayCoverMCPError(code: .sessionNotFound, message: "Session not found", cause: sessionError.localizedDescription)

        XCTAssertEqual(mcpError.code, PlayCoverErrorCode.sessionNotFound.rawValue)
        XCTAssertEqual(mcpError.message, "Session not found")
    }
}
