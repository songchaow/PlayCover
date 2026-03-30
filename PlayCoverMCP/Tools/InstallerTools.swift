// InstallerTools.swift
// PlayCoverMCP

import Foundation

private enum TaskToolNames {
    static let get = "get_task"
    static let list = "list_tasks"
    static let cancel = "cancel_task"
}

private func encodeJSONText<T: Encodable>(_ value: T, fallback: String = "{}") throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? fallback
}

private func taskTrackingMessage(prefix: String) -> String {
    "\(prefix) Use the \(TaskToolNames.get) tool to track progress, \(TaskToolNames.list) to inspect tasks, or \(TaskToolNames.cancel) to cancel the task."
}

private func taskTrackingTools() -> [String: String] {
    [
        "get": TaskToolNames.get,
        "list": TaskToolNames.list,
        "cancel": TaskToolNames.cancel,
    ]
}

/// Registers IPA install/export MCP tools on the server.
///
/// Tools registered:
/// - `install_ipa`: Install an IPA file into PlayCover (long-running task)
/// - `export_patched_ipa`: Export a patched IPA with PlayTools embedded (long-running task)
public enum InstallerTools {

    /// Register both installer tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        installerService: InstallerService,
        taskManager: TaskManager
    ) {
        registerInstallIPA(on: server, installerService: installerService, taskManager: taskManager)
        registerExportPatchedIPA(on: server, installerService: installerService, taskManager: taskManager)
    }

    // MARK: - install_ipa

    private static func registerInstallIPA(
        on server: MCPServer,
        installerService: InstallerService,
        taskManager: TaskManager
    ) {
        let tool = Tool(
            name: "install_ipa",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "ipaPath": AnyCodable([
                        "type": "string",
                        "description": "Absolute path to the .ipa file to install"
                    ] as Any),
                    "injectPlayTools": AnyCodable([
                        "type": "boolean",
                        "description": "Whether to inject PlayTools into the app (default: true)"
                    ] as Any),
                    "applicationCategory": AnyCodable([
                        "type": "string",
                        "description": "LSApplicationCategoryType value (e.g., 'public.app-category.games')"
                    ] as Any)
                ],
                required: ["ipaPath"]
            ),
            description: "Install an IPA file into PlayCover. This is a long-running operation; use the returned task ID with the get_task tool to track progress.",
            title: "Install IPA"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "install_ipa") { arguments in
            guard let args = arguments?.dictionary,
                  let ipaPath = args["ipaPath"] as? String,
                  !ipaPath.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "install_ipa requires a non-empty 'ipaPath' parameter"
                )
            }

            let injectPlayTools = args["injectPlayTools"] as? Bool ?? true
            let applicationCategory = args["applicationCategory"] as? String

            // Create a background task for the install
            let createResult = taskManager.createTask(
                title: "Installing IPA: \(URL(fileURLWithPath: ipaPath).lastPathComponent)"
            )
            let taskId = createResult.id

            // Launch async work
            DispatchQueue.global(qos: .userInitiated).async {
                taskManager.startTask(taskId)

                do {
                    let result = try installerService.install(
                        ipaPath: ipaPath,
                        injectPlayTools: injectPlayTools,
                        applicationCategory: applicationCategory,
                        progress: { total, current, message in
                            taskManager.updateProgress(taskId, progress: TaskProgress(
                                total: total, current: current, message: message
                            ))
                        }
                    )

                    let resultData: [String: Any] = [
                        "bundleIdentifier": result.bundleIdentifier,
                        "appPath": result.appPath,
                        "injectPlayTools": result.injectPlayTools
                    ]
                    let jsonData = try JSONSerialization.data(
                        withJSONObject: resultData,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    let text = String(data: jsonData, encoding: .utf8) ?? "{}"

                    taskManager.completeTask(taskId, result: TaskResult(content: [
                        TaskContentItem(kind: .text, text: text)
                    ]))
                } catch {
                    taskManager.failTask(taskId, error: TaskError(
                        code: PlayCoverErrorCode.exportFailed.rawValue,
                        message: error.localizedDescription
                    ))
                }
            }

            let response: [String: Any] = [
                "taskId": taskId,
                "status": "started",
                "message": taskTrackingMessage(prefix: "IPA installation started."),
                "trackingTools": taskTrackingTools(),
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - export_patched_ipa

    private static func registerExportPatchedIPA(
        on server: MCPServer,
        installerService: InstallerService,
        taskManager: TaskManager
    ) {
        let tool = Tool(
            name: "export_patched_ipa",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "ipaPath": AnyCodable([
                        "type": "string",
                        "description": "Absolute path to the source .ipa file to export"
                    ] as Any),
                    "outputDirectory": AnyCodable([
                        "type": "string",
                        "description": "Directory for the output .ipa file (default: ~/Documents)"
                    ] as Any),
                    "applicationCategory": AnyCodable([
                        "type": "string",
                        "description": "LSApplicationCategoryType value (e.g., 'public.app-category.games')"
                    ] as Any)
                ],
                required: ["ipaPath"]
            ),
            description: "Export a patched IPA with PlayTools embedded. This is a long-running operation; use the returned task ID with the get_task tool to track progress.",
            title: "Export Patched IPA"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "export_patched_ipa") { arguments in
            guard let args = arguments?.dictionary,
                  let ipaPath = args["ipaPath"] as? String,
                  !ipaPath.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "export_patched_ipa requires a non-empty 'ipaPath' parameter"
                )
            }

            let outputDirectory = args["outputDirectory"] as? String
            let applicationCategory = args["applicationCategory"] as? String

            // Create a background task for the export
            let createResult = taskManager.createTask(
                title: "Exporting IPA: \(URL(fileURLWithPath: ipaPath).lastPathComponent)"
            )
            let taskId = createResult.id

            // Launch async work
            DispatchQueue.global(qos: .userInitiated).async {
                taskManager.startTask(taskId)

                do {
                    let result = try installerService.export(
                        ipaPath: ipaPath,
                        outputDirectory: outputDirectory,
                        applicationCategory: applicationCategory,
                        progress: { total, current, message in
                            taskManager.updateProgress(taskId, progress: TaskProgress(
                                total: total, current: current, message: message
                            ))
                        }
                    )

                    let resultData: [String: Any] = [
                        "bundleIdentifier": result.bundleIdentifier,
                        "ipaPath": result.ipaPath
                    ]
                    let jsonData = try JSONSerialization.data(
                        withJSONObject: resultData,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    let text = String(data: jsonData, encoding: .utf8) ?? "{}"

                    taskManager.completeTask(taskId, result: TaskResult(content: [
                        TaskContentItem(kind: .text, text: text)
                    ]))
                } catch {
                    taskManager.failTask(taskId, error: TaskError(
                        code: PlayCoverErrorCode.exportFailed.rawValue,
                        message: error.localizedDescription
                    ))
                }
            }

            let response: [String: Any] = [
                "taskId": taskId,
                "status": "started",
                "message": taskTrackingMessage(prefix: "IPA export started."),
                "trackingTools": taskTrackingTools(),
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }
}

/// Registers standard MCP tool wrappers for background task inspection and cancellation.
///
/// Tools registered:
/// - `get_task`: Get the current status of a task by ID
/// - `list_tasks`: List all known tasks
/// - `cancel_task`: Cancel a task by ID
public enum TaskTools {

    /// Register task tool metadata and handlers on the server.
    public static func register(on server: MCPServer, taskManager: TaskManager) {
        registerGetTask(on: server, taskManager: taskManager)
        registerListTasks(on: server, taskManager: taskManager)
        registerCancelTask(on: server, taskManager: taskManager)
    }

    private static func registerGetTask(on server: MCPServer, taskManager: TaskManager) {
        let tool = Tool(
            name: TaskToolNames.get,
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "taskId": AnyCodable([
                        "type": "string",
                        "description": "The task ID to query"
                    ] as Any),
                ],
                required: ["taskId"]
            ),
            description: "Get the current status of a background task by its task ID. Equivalent to the JSON-RPC tasks/get method.",
            title: "Get Task"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: TaskToolNames.get) { arguments in
            let taskId = try requireTaskId(arguments, toolName: TaskToolNames.get)
            guard let status = taskManager.getTask(taskId) else {
                throw PlayCoverMCPError(code: .taskNotFound, message: "Task not found: \(taskId)")
            }

            let text = try encodeJSONText(GetTaskResult(status: status))
            return CallToolResult(content: [.text(content: text)])
        }
    }

    private static func registerListTasks(on server: MCPServer, taskManager: TaskManager) {
        let tool = Tool(
            name: TaskToolNames.list,
            inputSchema: InputSchema(type: "object", properties: [:]),
            description: "List all known background tasks. Equivalent to the JSON-RPC tasks/list method.",
            title: "List Tasks"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: TaskToolNames.list) { _ in
            let result = ListTasksResult(tasks: taskManager.listTasks(includeCompleted: true))
            let text = try encodeJSONText(result, fallback: "{\n  \"tasks\" : [\n\n  ]\n}")
            return CallToolResult(content: [.text(content: text)])
        }
    }

    private static func registerCancelTask(on server: MCPServer, taskManager: TaskManager) {
        let tool = Tool(
            name: TaskToolNames.cancel,
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "taskId": AnyCodable([
                        "type": "string",
                        "description": "The task ID to cancel"
                    ] as Any),
                ],
                required: ["taskId"]
            ),
            description: "Cancel a background task by its task ID. Equivalent to the JSON-RPC tasks/cancel method.",
            title: "Cancel Task"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: TaskToolNames.cancel) { arguments in
            let taskId = try requireTaskId(arguments, toolName: TaskToolNames.cancel)
            guard taskManager.getTask(taskId) != nil else {
                throw PlayCoverMCPError(code: .taskNotFound, message: "Task not found: \(taskId)")
            }

            taskManager.cancelTask(taskId)
            let status = taskManager.getTask(taskId)!
            let text = try encodeJSONText(GetTaskResult(status: status))
            return CallToolResult(content: [.text(content: text)])
        }
    }

    private static func requireTaskId(_ arguments: AnyCodable?, toolName: String) throws -> String {
        guard let taskId = arguments?.dictionary?["taskId"] as? String,
              !taskId.isEmpty else {
            throw PlayCoverMCPError(
                code: JSONRPCError.invalidParams,
                message: "\(toolName) requires a non-empty 'taskId' parameter"
            )
        }
        return taskId
    }
}
