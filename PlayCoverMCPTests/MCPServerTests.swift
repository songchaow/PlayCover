import XCTest
import Foundation

final class MCPServerTests: XCTestCase {

    private func makeServer() -> MCPServer {
        MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(tools: ToolCapabilities(), resources: ResourceCapabilities())
        )
    }

    private func makeTaskToolServer(taskManager: TaskManager) -> MCPServer {
        let server = MCPServer(
            serverInfo: Implementation(name: "TestServer", version: "0.1.0"),
            capabilities: ServerCapabilities(
                tools: ToolCapabilities(),
                tasks: TaskCapabilities(
                    list: EmptyCapability(),
                    cancel: EmptyCapability()
                )
            ),
            taskManager: taskManager
        )
        TaskTools.register(on: server, taskManager: taskManager)
        return server
    }

    private func extractToolText(from response: JSONRPCMessage?) throws -> String {
        guard let response else {
            XCTFail("Expected response")
            return ""
        }
        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return ""
        }
        XCTAssertNil(resp.error)

        let result: CallToolResult = try XCTUnwrap(resp.result?.decoded())
        guard case .text(let content) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        return content
    }

    // MARK: - Initialize

    func testInitializeResponse() throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            id: .string("init-1"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: MCPProtocolVersion.v2025_11_25,
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
        XCTAssertEqual(result.protocolVersion, MCPProtocolVersion.v2025_11_25)
        XCTAssertEqual(result.serverInfo.name, "TestServer")
        XCTAssertEqual(result.serverInfo.version, "0.1.0")
        XCTAssertNotNil(result.capabilities.tools)
        XCTAssertNotNil(result.capabilities.resources)
    }

    func testInitializeNegotiatesRequestedOlderSupportedVersion() throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            id: .string("init-older"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: MCPProtocolVersion.v2025_03_26,
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "older-client", version: "1.0")
            ))
        )

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }

        let result: InitializeResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.protocolVersion, MCPProtocolVersion.v2025_03_26)
    }

    func testInitializeSupports2025_06_18() throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            id: .string("init-2025-06-18"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: MCPProtocolVersion.v2025_06_18,
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "mid-client", version: "1.0")
            ))
        )

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }

        let result: InitializeResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.protocolVersion, MCPProtocolVersion.v2025_06_18)
    }

    func testInitializeFallsBackForNewerUnknownProtocolVersion() throws {
        let server = makeServer()
        let request = JSONRPCRequest(
            id: .string("init-future"),
            method: "initialize",
            params: try AnyCodable(InitializeParams(
                protocolVersion: "2099-01-01",
                capabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "future-client", version: "1.0")
            ))
        )

        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }

        let result: InitializeResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.protocolVersion, MCPProtocolVersion.latest)
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
        XCTAssertEqual(result.status.state, TaskState.pending)
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
            params: try AnyCodable(["taskId": "t1"])
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: GetTaskResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.status.id, "t1")
        XCTAssertEqual(result.status.state, TaskState.pending)
    }

    func testTasksGetAcceptsLegacyStringParam() throws {
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
            id: .string("get-legacy"),
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
            params: try AnyCodable(["taskId": "nonexistent"])
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, -32008) // taskNotFound
    }

    func testTasksGetRequiresTaskIdField() throws {
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
            id: .string("get-invalid"),
            method: "tasks/get",
            params: try AnyCodable(["id": "t1"])
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertEqual(resp.error?.code, JSONRPCError.invalidParams)
        XCTAssertTrue(resp.error?.message.contains("taskId") ?? false)
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
            params: try AnyCodable(["taskId": "t1"])
        )
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: GetTaskResult = try XCTUnwrap(resp.result?.decoded())
        XCTAssertEqual(result.status.state, TaskState.cancelled)
    }

    func testTasksCancelAcceptsLegacyStringParam() throws {
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
            id: .string("cancel-legacy"),
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
        XCTAssertEqual(result.status.state, TaskState.cancelled)
    }

    func testTaskToolsAreRegistered() throws {
        let server = makeTaskToolServer(taskManager: TaskManager())
        let request = JSONRPCRequest(id: .string("task-tools-list"), method: "tools/list")
        let response = server.handle(.request(request))

        guard case .response(let resp) = response else {
            XCTFail("Expected response")
            return
        }
        XCTAssertNil(resp.error)

        let result: ListToolsResult = try XCTUnwrap(resp.result?.decoded())
        let toolNames = Set(result.tools.map(\.name))
        XCTAssertTrue(toolNames.contains("get_task"))
        XCTAssertTrue(toolNames.contains("list_tasks"))
        XCTAssertTrue(toolNames.contains("cancel_task"))
    }

    func testGetTaskToolReturnsTaskStatus() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "task-1", title: "Example")
        let server = makeTaskToolServer(taskManager: taskManager)

        let request = JSONRPCRequest(
            id: .string("get-task-tool"),
            method: "tools/call",
            params: AnyCodable([
                "name": "get_task",
                "arguments": ["taskId": "task-1"]
            ])
        )
        let response = server.handle(.request(request))
        let text = try extractToolText(from: response)
        let result: GetTaskResult = try JSONDecoder().decode(GetTaskResult.self, from: Data(text.utf8))

        XCTAssertEqual(result.status.id, "task-1")
        XCTAssertEqual(result.status.state, TaskState.pending)
    }

    func testListTasksToolReturnsAllTasks() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "task-1", title: "First")
        taskManager.createTask(id: "task-2", title: "Second")
        taskManager.startTask("task-2")
        let server = makeTaskToolServer(taskManager: taskManager)

        let request = JSONRPCRequest(
            id: .string("list-task-tool"),
            method: "tools/call",
            params: AnyCodable(["name": "list_tasks", "arguments": [:]])
        )
        let response = server.handle(.request(request))
        let text = try extractToolText(from: response)
        let result: ListTasksResult = try JSONDecoder().decode(ListTasksResult.self, from: Data(text.utf8))
        let ids = Set(result.tasks.map { $0.id })

        XCTAssertEqual(ids, ["task-1", "task-2"])
    }

    func testCancelTaskToolCancelsTask() throws {
        let taskManager = TaskManager()
        taskManager.createTask(id: "task-1", title: "Cancelable")
        taskManager.startTask("task-1")
        let server = makeTaskToolServer(taskManager: taskManager)

        let request = JSONRPCRequest(
            id: .string("cancel-task-tool"),
            method: "tools/call",
            params: AnyCodable([
                "name": "cancel_task",
                "arguments": ["taskId": "task-1"]
            ])
        )
        let response = server.handle(.request(request))
        let text = try extractToolText(from: response)
        let result: GetTaskResult = try JSONDecoder().decode(GetTaskResult.self, from: Data(text.utf8))

        XCTAssertEqual(result.status.id, "task-1")
        XCTAssertEqual(result.status.state, TaskState.cancelled)
        XCTAssertEqual(taskManager.getTask("task-1")?.state, TaskState.cancelled)
    }

    func testInstallerToolResponsesMentionTaskTools() throws {
        let taskManager = TaskManager()
        let server = makeTaskToolServer(taskManager: taskManager)
        let appDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayCoverMCP-InstallerToolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: appDirectory) }

        let installerService = InstallerService(
            appDirectory: appDirectory,
            playToolsFrameworkPath: appDirectory.appendingPathComponent("PlayTools.framework")
        )
        InstallerTools.register(on: server, installerService: installerService, taskManager: taskManager)

        let installResponse = server.handle(.request(JSONRPCRequest(
            id: .string("install-tool"),
            method: "tools/call",
            params: AnyCodable([
                "name": "install_ipa",
                "arguments": ["ipaPath": "/tmp/missing-install.ipa"]
            ])
        )))
        let installText = try extractToolText(from: installResponse)
        let installJSON = try JSONSerialization.jsonObject(with: Data(installText.utf8)) as! [String: Any]
        let installTracking = installJSON["trackingTools"] as? [String: Any]

        XCTAssertEqual(installJSON["status"] as? String, "started")
        XCTAssertTrue((installJSON["message"] as? String ?? "").contains("get_task"))
        XCTAssertEqual(installTracking?["get"] as? String, "get_task")
        XCTAssertEqual(installTracking?["list"] as? String, "list_tasks")
        XCTAssertEqual(installTracking?["cancel"] as? String, "cancel_task")

        let exportResponse = server.handle(.request(JSONRPCRequest(
            id: .string("export-tool"),
            method: "tools/call",
            params: AnyCodable([
                "name": "export_patched_ipa",
                "arguments": ["ipaPath": "/tmp/missing-export.ipa"]
            ])
        )))
        let exportText = try extractToolText(from: exportResponse)
        let exportJSON = try JSONSerialization.jsonObject(with: Data(exportText.utf8)) as! [String: Any]
        let exportTracking = exportJSON["trackingTools"] as? [String: Any]

        XCTAssertEqual(exportJSON["status"] as? String, "started")
        XCTAssertTrue((exportJSON["message"] as? String ?? "").contains("get_task"))
        XCTAssertEqual(exportTracking?["get"] as? String, "get_task")
        XCTAssertEqual(exportTracking?["list"] as? String, "list_tasks")
        XCTAssertEqual(exportTracking?["cancel"] as? String, "cancel_task")
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
