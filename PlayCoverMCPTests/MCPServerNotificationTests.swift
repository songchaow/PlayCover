import XCTest
import Foundation

/// Tests for MCPServer's notification sink and wireNotifications functionality (H04).
final class MCPServerNotificationTests: XCTestCase {

    // MARK: - Helpers

    private func makeServer(
        logger: MCPLogger? = nil,
        taskManager: TaskManager? = nil
    ) -> MCPServer {
        MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(),
                resources: ResourceCapabilities()
            ),
            logger: logger,
            taskManager: taskManager
        )
    }

    /// Send `initialize` + `notifications/initialized` to mark server as initialized.
    private func initializeServer(_ server: MCPServer) {
        let initRequest = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: try? AnyCodable(InitializeParams(
                protocolVersion: "2025-11-25",
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "test", version: "1.0")
            ))
        )
        _ = server.handle(.request(initRequest))

        let initialized = JSONRPCNotification(method: "notifications/initialized")
        _ = server.handle(.notification(initialized))
    }

    // MARK: - notificationSink basic tests

    func testNotificationSinkIsNilByDefault() {
        let server = makeServer()
        XCTAssertNil(server.notificationSink)
    }

    func testNotificationSinkCanBeSet() {
        let server = makeServer()
        var called = false
        server.notificationSink = { _ in called = true }
        XCTAssertNotNil(server.notificationSink)

        // Sending a notification should invoke the sink
        let notif = JSONRPCNotification(method: "test/notify")
        server.sendNotification(notif)
        XCTAssertTrue(called)
    }

    func testSendNotificationNoSink() {
        let server = makeServer()
        // Should not crash when notificationSink is nil
        let notif = JSONRPCNotification(method: "test/notify")
        server.sendNotification(notif) // no-op, should not crash
    }

    func testSendNotificationDeliversCorrectMessage() {
        let server = makeServer()
        var receivedMessages: [JSONRPCMessage] = []
        server.notificationSink = { message in
            receivedMessages.append(message)
        }

        let notif = JSONRPCNotification(method: "notifications/test", params: AnyCodable(["key": "value"] as [String: Any] as Any?))
        server.sendNotification(notif)

        XCTAssertEqual(receivedMessages.count, 1)
        if case .notification(let n) = receivedMessages.first {
            XCTAssertEqual(n.method, "notifications/test")
        } else {
            XCTFail("Expected notification message")
        }
    }

    // MARK: - wireNotifications tests

    func testWireNotificationsLoggerForwardsWhenInitialized() {
        let logger = MCPLogger(minLevel: .info)
        let server = makeServer(logger: logger)

        var receivedMessages: [JSONRPCMessage] = []
        server.notificationSink = { message in
            receivedMessages.append(message)
        }
        server.wireNotifications()

        // Server not yet initialized — log should NOT trigger notification
        logger.info("before init")
        XCTAssertEqual(receivedMessages.count, 0, "Should not send notification before initialization")

        // Initialize server
        initializeServer(server)

        // Now log should trigger notification
        logger.info("after init")
        XCTAssertEqual(receivedMessages.count, 1)

        if case .notification(let n) = receivedMessages.first {
            XCTAssertEqual(n.method, "notifications/message")
            // Verify params contain the log data
            let dict = n.params?.dictionary
            XCTAssertEqual(dict?["level"] as? String, "info")
            XCTAssertEqual(dict?["data"] as? String, "after init")
        } else {
            XCTFail("Expected notification message")
        }
    }

    func testWireNotificationsLoggerRespectsMinLevel() {
        let logger = MCPLogger(minLevel: .warning)
        let server = makeServer(logger: logger)

        var receivedMessages: [JSONRPCMessage] = []
        server.notificationSink = { message in
            receivedMessages.append(message)
        }
        server.wireNotifications()
        initializeServer(server)

        // Debug log should be filtered by logger's minLevel
        logger.debug("should be filtered")
        XCTAssertEqual(receivedMessages.count, 0)

        // Warning should pass through
        logger.warning("should pass")
        XCTAssertEqual(receivedMessages.count, 1)
    }

    func testWireNotificationsTaskManagerForwardsWhenInitialized() {
        let taskManager = TaskManager()
        let server = makeServer(taskManager: taskManager)

        var receivedMessages: [JSONRPCMessage] = []
        server.notificationSink = { message in
            receivedMessages.append(message)
        }
        server.wireNotifications()

        // Server not yet initialized — status change should NOT trigger notification
        let result = taskManager.createTask(title: "Test task")
        taskManager.startTask(result.id)
        XCTAssertEqual(receivedMessages.count, 0, "Should not send notification before initialization")

        // Initialize server
        initializeServer(server)

        // Now status change should trigger notification
        let result2 = taskManager.createTask(title: "Test task 2")
        taskManager.startTask(result2.id)
        XCTAssertTrue(receivedMessages.count > 0, "Should send notification after initialization")

        // Check that the notification method is correct
        if case .notification(let n) = receivedMessages.last {
            XCTAssertEqual(n.method, "notifications/tasks/status")
        } else {
            XCTFail("Expected notification message")
        }
    }

    // MARK: - handle() behavior unchanged without notificationSink

    func testHandleRemainsUnchangedWithoutSink() throws {
        let server = makeServer()
        // No notificationSink set

        // Initialize
        let initReq = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: "2025-11-25",
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "test", version: "1.0")
            ))
        )
        let resp = server.handle(.request(initReq))
        guard case .response(let r) = resp else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(r.error, "Expected success response (no error)")

        // Ping should still work
        let pingReq = JSONRPCRequest(id: .integer(2), method: "ping", params: nil)
        let pingResp = server.handle(.request(pingReq))
        guard case .response(let pr) = pingResp else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(pr.error, "Expected success response for ping (no error)")
    }

    // MARK: - wireNotifications with nil logger/taskManager

    func testWireNotificationsWithNilLoggerAndTaskManager() {
        let server = makeServer(logger: nil, taskManager: nil)
        server.notificationSink = { _ in }
        // Should not crash
        server.wireNotifications()
    }

    // MARK: - Multiple notifications

    func testMultipleLogNotificationsDelivered() {
        let logger = MCPLogger(minLevel: .debug)
        let server = makeServer(logger: logger)

        var receivedMessages: [JSONRPCMessage] = []
        server.notificationSink = { message in
            receivedMessages.append(message)
        }
        server.wireNotifications()
        initializeServer(server)

        logger.info("msg1")
        logger.warning("msg2")
        logger.error("msg3")

        XCTAssertEqual(receivedMessages.count, 3)
    }
}
