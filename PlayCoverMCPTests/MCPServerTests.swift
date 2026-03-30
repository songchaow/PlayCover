import XCTest
import Foundation

final class MCPServerTests: XCTestCase {

    private func makeServer() -> MCPServer {
        MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(tools: ToolCapabilities(), resources: ResourceCapabilities())
        )
    }

    // MARK: - Initialize

    func testInitializeResponse() throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            id: .string("init-1"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: "2025-11-25",
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "test-client", version: "1.0")
            ))
        )

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.id, .string("init-1"))
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)

        // Verify the result can be decoded as InitializeResult
        let result: InitializeResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.protocolVersion, MCPProtocolVersion.latest)
        XCTAssertEqual(result.serverInfo.name, "TestServer")
        XCTAssertEqual(result.serverInfo.version, "0.1.0")
        XCTAssertNotNil(result.capabilities.tools)
        XCTAssertNotNil(result.capabilities.resources)
    }

    // MARK: - Ping

    func testPingResponse() {
        let server = makeServer()
        let request = JSONRPCRequest(id: .integer(1), method: "ping")

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.id, .integer(1))
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    // MARK: - tools/list

    func testToolsListEmpty() throws {
        let server = makeServer()
        let request = JSONRPCRequest(id: .string("list-1"), method: "tools/list")

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)

        // Verify the result contains an empty tools array
        let resultData = try XCTUnwrap(try? JSONEncoder().encode(resp.result!))
        let json = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
        XCTAssertEqual((json["tools"] as? [Any])?.count, 0)
    }

    func testToolsListWithRegisteredTool() throws {
        let server = makeServer()
        server.toolRegistry.register(Tool(
            name: "test_tool",
            inputSchema: InputSchema(type: "object"),
            description: "A test tool"
        ))

        let request = JSONRPCRequest(id: .string("list-2"), method: "tools/list")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        let result: ListToolsResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.tools.count, 1)
        XCTAssertEqual(result.tools.first?.name, "test_tool")
    }

    // MARK: - resources/list

    func testResourcesListEmpty() throws {
        let server = makeServer()
        let request = JSONRPCRequest(id: .string("list-3"), method: "resources/list")

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testResourcesListWithRegisteredResource() throws {
        let server = makeServer()
        server.resourceRegistry.register(Resource(
            uri: "test://resource",
            name: "Test Resource"
        ))

        let request = JSONRPCRequest(id: .string("list-4"), method: "resources/list")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        let result: ListResourcesResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.resources.count, 1)
        XCTAssertEqual(result.resources.first?.uri, "test://resource")
    }

    // MARK: - Unknown method

    func testUnknownMethodReturnsError() {
        let server = makeServer()
        let request = JSONRPCRequest(id: .integer(99), method: "nonexistent/method")

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.id, .integer(99))
        XCTAssertNil(resp.result)
        XCTAssertEqual(resp.error?.code, JSONRPCError.methodNotFound)
        XCTAssertTrue(resp.error?.message.contains("nonexistent/method") ?? false)
    }

    // MARK: - Custom handler

    func testCustomHandlerRegistration() throws {
        let server = makeServer()
        server.register(method: "custom/echo") { params in
            return params ?? AnyCodable([:])
        }

        let request = JSONRPCRequest(
            id: .string("echo-1"),
            method: "custom/echo",
            params: try AnyCodable(["message": "hello"])
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNotNil(resp.result)
        XCTAssertNil(resp.error)
    }

    func testCustomHandlerError() {
        let server = makeServer()
        server.register(method: "custom/fail") { _ in
            throw MCPError.internalError("something went wrong")
        }

        let request = JSONRPCRequest(id: .string("fail-1"), method: "custom/fail")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.result)
        XCTAssertEqual(resp.error?.code, JSONRPCError.internalError)
    }

    // MARK: - Notifications

    func testInitializedNotification() {
        let server = makeServer()
        XCTAssertFalse(server.isInitialized)

        let notif = JSONRPCNotification(method: "notifications/initialized")
        let response = server.handle(.notification(notif))

        XCTAssertNil(response)
        XCTAssertTrue(server.isInitialized)
    }

    func testResponseHandlingReturnsNil() {
        let server = makeServer()
        let resp = JSONRPCResponse(id: .integer(1), result: AnyCodable([:]))
        let response = server.handle(.response(resp))
        XCTAssertNil(response)
    }

    // MARK: - PlayCoverMCPError handling

    func testPlayCoverMCPErrorHandling() {
        let server = makeServer()
        server.register(method: "test/playcover-error") { _ in
            throw PlayCoverMCPError(code: .appNotFound, message: "App not found")
        }

        let request = JSONRPCRequest(id: .string("pce-1"), method: "test/playcover-error")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.result)
        XCTAssertEqual(resp.error?.code, -32001)
        XCTAssertEqual(resp.error?.message, "App not found")
    }

    func testGenericErrorHandling() {
        let server = makeServer()
        server.register(method: "test/generic-error") { _ in
            struct CustomError: Error {}
            throw CustomError()
        }

        let request = JSONRPCRequest(id: .string("ge-1"), method: "test/generic-error")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.result)
        XCTAssertEqual(resp.error?.code, JSONRPCError.internalError)
    }

    // MARK: - Initialize with logging/tasks capabilities

    func testInitializeIncludesLoggingCapability() throws {
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(),
                logging: EmptyCapability(),
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            )
        )
        let request = JSONRPCRequest(
            id: .string("init-logging"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: "2025-11-25",
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "test-client", version: "1.0")
            ))
        )

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        let result: InitializeResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertNotNil(result.capabilities.logging)
        XCTAssertNotNil(result.capabilities.tasks?.list)
        XCTAssertNotNil(result.capabilities.tasks?.cancel)
    }

    // MARK: - Logging handlers

    func testSetLogLevel() throws {
        let logger = MCPLogger(minLevel: .warning)
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(logging: EmptyCapability()),
            logger: logger
        )

        XCTAssertEqual(logger.minLevel, .warning)

        let request = JSONRPCRequest(
            id: .string("log-1"),
            method: "logging/setLevel",
            params: try AnyCodable(SetLoggingLevelParams(level: .debug))
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)
        XCTAssertEqual(logger.minLevel, .debug)
    }

    func testSetLogLevelMissingParams() {
        let logger = MCPLogger(minLevel: .info)
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(logging: EmptyCapability()),
            logger: logger
        )

        let request = JSONRPCRequest(id: .string("log-2"), method: "logging/setLevel")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, JSONRPCError.invalidParams)
    }

    // MARK: - Task handlers

    func testTasksCreate() throws {
        let taskManager = TaskManager()
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )

        let request = JSONRPCRequest(
            id: .string("task-1"),
            method: "tasks/create",
            params: try AnyCodable(CreateTaskParams(id: "my-task", title: "Test Task"))
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: CreateTaskResult = try XCTUnwrap(try resp.result?.decoded())
        XCTAssertEqual(result.id, "my-task")
        XCTAssertEqual(result.status.state, .pending)
    }

    func testTasksGet() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "t1", title: "Test")
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )

        let request = JSONRPCRequest(
            id: .string("get-1"),
            method: "tasks/get",
            params: try AnyCodable("t1")
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: GetTaskResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.status.id, "t1")
        XCTAssertEqual(result.status.state, .pending)
    }

    func testTasksGetNotFound() throws {
        let taskManager = TaskManager()
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )

        let request = JSONRPCRequest(
            id: .string("get-2"),
            method: "tasks/get",
            params: try AnyCodable("nonexistent")
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, -32008) // taskNotFound
    }

    func testTasksList() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "t1", title: "First")
        taskManager.createTask(id: "t2", title: "Second")
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )

        let request = JSONRPCRequest(id: .string("list-1"), method: "tasks/list")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: ListTasksResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.tasks.count, 2)
    }

    func testTasksCancel() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "t1")
        taskManager.startTask("t1")
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )

        let request = JSONRPCRequest(
            id: .string("cancel-1"),
            method: "tasks/cancel",
            params: try AnyCodable("t1")
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: GetTaskResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.status.state, .cancelled)
    }

    // MARK: - No-logger / No-taskManager: methods not registered

    func testLoggingNotAvailableWithoutLogger() {
        let server = makeServer()
        let request = JSONRPCRequest(id: .string("no-log"), method: "logging/setLevel")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, JSONRPCError.methodNotFound)
    }

    func testTasksNotAvailableWithoutTaskManager() {
        let server = makeServer()
        let request = JSONRPCRequest(id: .string("no-task"), method: "tasks/create")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, JSONRPCError.methodNotFound)
    }
}
