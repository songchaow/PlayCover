// TCPTransportTests.swift
// PlayCoverMCPTests

import XCTest
import Network

final class TCPTransportTests: XCTestCase {

    /// Helper to create a simple echo response (avoids throws inference in non-throwing closures)
    private static func echoResponse(id: RequestID?) -> JSONRPCMessage {
        let dict: Any? = ["echo": "ok"] as [String: Any]
        return .response(JSONRPCResponse(id: id, result: AnyCodable(dict)))
    }

    private static func okResponse(id: RequestID?) -> JSONRPCMessage {
        let dict: Any? = ["ok": true] as [String: Any]
        return .response(JSONRPCResponse(id: id, result: AnyCodable(dict)))
    }

    private static func bufferedResponse(id: RequestID?) -> JSONRPCMessage {
        let dict: Any? = ["buffered": true] as [String: Any]
        return .response(JSONRPCResponse(id: id, result: AnyCodable(dict)))
    }

    // MARK: - Start & Stop

    func testStartAndStop() {
        let transport = TCPTransport(port: 0, handler: { _ in nil })
        let expectation = self.expectation(description: "Transport should become running")

        transport.onStateChange = { state in
            if case .running = state {
                expectation.fulfill()
            }
        }

        transport.start()
        waitForExpectations(timeout: 3.0)

        if case .running(let port) = transport.state {
            XCTAssertGreaterThan(port, 0, "Port should be assigned")
        } else {
            XCTFail("Expected running state, got \(transport.state)")
        }

        let stopExpectation = self.expectation(description: "Transport should stop")
        transport.onStateChange = { state in
            if case .stopped = state {
                stopExpectation.fulfill()
            }
        }
        transport.stop()
        waitForExpectations(timeout: 3.0)
        XCTAssertEqual(transport.state, .stopped)
    }

    // MARK: - Echo Message

    func testEchoMessage() {
        // Set up transport that echoes back with a result
        let transport = TCPTransport(port: 0) { message in
            // Simple echo: for any request, return a success response
            if case .request(let req) = message {
                return Self.echoResponse(id: req.id)
            }
            return nil
        }

        let readyExpectation = expectation(description: "Transport ready")
        transport.onStateChange = { state in
            if case .running = state {
                readyExpectation.fulfill()
            }
        }
        transport.start()
        waitForExpectations(timeout: 3.0)

        guard case .running(let port) = transport.state else {
            XCTFail("Transport not running")
            return
        }

        // Connect with NWConnection
        let responseExpectation = expectation(description: "Received response")
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        connection.stateUpdateHandler = { (state: NWConnection.State) in
            if state == .ready {
                // Send a JSON-RPC request (must end with \n for line-delimited protocol)
                let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":{}}\n"
                let data = request.data(using: .utf8)!
                connection.send(content: data, completion: .contentProcessed { error in
                    XCTAssertNil(error, "Send should succeed")
                })

                // Read response
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, _, error in
                    XCTAssertNil(error, "Receive should succeed")
                    if let data = content, let line = String(data: data, encoding: .utf8) {
                        XCTAssertTrue(line.contains("\"jsonrpc\""), "Response should be JSON-RPC")
                        XCTAssertTrue(line.contains("\"echo\""), "Response should contain echo")
                        responseExpectation.fulfill()
                    }
                }
            }
        }

        let connQueue = DispatchQueue(label: "test.connection")
        connection.start(queue: connQueue)
        waitForExpectations(timeout: 5.0)

        connection.cancel()
        transport.stop()
    }

    // MARK: - Multiple Clients

    func testMultipleClients() {
        let transport = TCPTransport(port: 0) { message in
            if case .request(let req) = message {
                return Self.okResponse(id: req.id)
            }
            return nil
        }

        let readyExpectation = expectation(description: "Transport ready")
        transport.onStateChange = { state in
            if case .running = state {
                readyExpectation.fulfill()
            }
        }
        transport.start()
        waitForExpectations(timeout: 3.0)

        guard case .running(let port) = transport.state else {
            XCTFail("Transport not running")
            return
        }

        let clientCount = 3
        let connQueue = DispatchQueue(label: "test.multiconn")
        var connections: [NWConnection] = []
        let allConnected = expectation(description: "All clients connected")
        allConnected.expectedFulfillmentCount = clientCount

        for _ in 0..<clientCount {
            let conn = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            conn.stateUpdateHandler = { (state: NWConnection.State) in
                if state == .ready {
                    allConnected.fulfill()
                }
            }
            conn.start(queue: connQueue)
            connections.append(conn)
        }

        waitForExpectations(timeout: 5.0)

        // Give a moment for the transport to register all connections
        let countExpectation = expectation(description: "Client count check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(transport.connectedClientCount, clientCount,
                           "Should have \(clientCount) connected clients")
            countExpectation.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        // Cleanup
        for conn in connections {
            conn.cancel()
        }
        transport.stop()
    }

    // MARK: - Disconnect

    func testDisconnect() {
        let transport = TCPTransport(port: 0, handler: { _ in nil })

        let readyExpectation = expectation(description: "Transport ready")
        transport.onStateChange = { state in
            if case .running = state {
                readyExpectation.fulfill()
            }
        }
        transport.start()
        waitForExpectations(timeout: 3.0)

        guard case .running(let port) = transport.state else {
            XCTFail("Transport not running")
            return
        }

        // Connect
        let connQueue = DispatchQueue(label: "test.disconnect")
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        let connected = expectation(description: "Client connected")
        connection.stateUpdateHandler = { (state: NWConnection.State) in
            if state == .ready {
                connected.fulfill()
            }
        }
        connection.start(queue: connQueue)
        waitForExpectations(timeout: 3.0)

        // Verify connected
        let checkConnected = expectation(description: "Verify connected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(transport.connectedClientCount, 1)
            checkConnected.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        // Disconnect
        connection.cancel()

        // Wait for disconnect to be processed
        let checkDisconnected = expectation(description: "Verify disconnected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertEqual(transport.connectedClientCount, 0, "Client count should be 0 after disconnect")
            checkDisconnected.fulfill()
        }
        waitForExpectations(timeout: 3.0)

        transport.stop()
    }

    // MARK: - Port In Use

    func testPortInUse() {
        // Start first transport on a random port
        let transport1 = TCPTransport(port: 0, handler: { _ in nil })

        let ready1 = expectation(description: "Transport1 ready")
        transport1.onStateChange = { state in
            if case .running = state {
                ready1.fulfill()
            }
        }
        transport1.start()
        waitForExpectations(timeout: 3.0)

        guard case .running(let occupiedPort) = transport1.state else {
            XCTFail("Transport1 not running")
            return
        }

        // Try to start second transport on the same port
        let transport2 = TCPTransport(port: occupiedPort, handler: { _ in nil })

        let failed2 = expectation(description: "Transport2 should fail")
        transport2.onStateChange = { state in
            if case .failed = state {
                failed2.fulfill()
            }
        }
        transport2.start()
        waitForExpectations(timeout: 5.0)

        if case .failed = transport2.state {
            // Expected
        } else {
            XCTFail("Expected failed state, got \(transport2.state)")
        }

        transport1.stop()
        transport2.stop()
    }

    // MARK: - Partial Line Handling

    func testPartialLineHandling() {
        // Verify that partial lines are buffered correctly
        let transport = TCPTransport(port: 0) { message in
            if case .request(let req) = message {
                return Self.bufferedResponse(id: req.id)
            }
            return nil
        }

        let readyExpectation = expectation(description: "Transport ready")
        transport.onStateChange = { state in
            if case .running = state {
                readyExpectation.fulfill()
            }
        }
        transport.start()
        waitForExpectations(timeout: 3.0)

        guard case .running(let port) = transport.state else {
            XCTFail("Transport not running")
            return
        }

        let connQueue = DispatchQueue(label: "test.partial")
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)

        let connected = expectation(description: "Connected")
        connection.stateUpdateHandler = { (state: NWConnection.State) in
            if state == .ready {
                connected.fulfill()
            }
        }
        connection.start(queue: connQueue)
        waitForExpectations(timeout: 3.0)

        // Create response expectation AFTER previous waits are done
        let responseReceived = expectation(description: "Response received")

        // Set up receive first
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, _, _ in
            if let data = content, let line = String(data: data, encoding: .utf8) {
                XCTAssertTrue(line.contains("\"buffered\""), "Should receive buffered response")
                responseReceived.fulfill()
            }
        }

        // Send the JSON part without newline first
        let jsonPart = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":{}}"
        let part1 = jsonPart.data(using: .utf8)!

        connection.send(content: part1, completion: .contentProcessed { sendError in
            XCTAssertNil(sendError)
            // After a short delay, send just the newline to complete the message
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                let newline = "\n".data(using: .utf8)!
                connection.send(content: newline, completion: .contentProcessed { _ in })
            }
        })

        waitForExpectations(timeout: 8.0)

        connection.cancel()
        transport.stop()
    }

    // MARK: - Not Blocking Main Thread

    func testDoesNotBlockMainThread() {
        let transport = TCPTransport(port: 0, handler: { _ in nil })

        let readyExpectation = expectation(description: "Transport ready")
        transport.onStateChange = { state in
            if case .running = state {
                readyExpectation.fulfill()
            }
        }

        // Start from main thread
        transport.start()

        // Main thread should remain responsive
        let mainThreadCheck = expectation(description: "Main thread responsive")
        DispatchQueue.main.async {
            mainThreadCheck.fulfill()
        }

        waitForExpectations(timeout: 3.0)
        transport.stop()
    }
}
