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
        taskManager: TaskManager,
        uploadManager: UploadManager? = nil,
        ipaDownloader: IPADownloader? = nil
    ) {
        registerInstallIPA(on: server, installerService: installerService, taskManager: taskManager, uploadManager: uploadManager, ipaDownloader: ipaDownloader)
        registerExportPatchedIPA(on: server, installerService: installerService, taskManager: taskManager, uploadManager: uploadManager, ipaDownloader: ipaDownloader)
    }

    // MARK: - install_ipa

    private static func registerInstallIPA(
        on server: MCPServer,
        installerService: InstallerService,
        taskManager: TaskManager,
        uploadManager: UploadManager?,
        ipaDownloader: IPADownloader?
    ) {
        let tool = Tool(
            name: "install_ipa",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "ipaPath": AnyCodable([
                        "type": "string",
                        "description": "Absolute path to the .ipa file to install. Supports @filename references from uploaded files (via POST /upload). Either ipaPath or ipaURL is required."
                    ] as Any),
                    "ipaURL": AnyCodable([
                        "type": "string",
                        "description": "HTTP or HTTPS URL to download the .ipa file from. The server will download and install it. Either ipaPath or ipaURL is required."
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
                required: []
            ),
            description: "Install an IPA file into PlayCover. Accepts either a local file path (ipaPath) or a remote URL (ipaURL). This is a long-running operation; use the returned task ID with the get_task tool to track progress.",
            title: "Install IPA"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "install_ipa") { arguments in
            let args = arguments?.dictionary ?? [:]
            let rawPath = args["ipaPath"] as? String
            let ipaURLString = args["ipaURL"] as? String

            // Validate: at least one must be provided
            guard (rawPath != nil && !rawPath!.isEmpty) || (ipaURLString != nil && !ipaURLString!.isEmpty) else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "install_ipa requires either 'ipaPath' or 'ipaURL' parameter"
                )
            }

            // If ipaURL is provided, validate it synchronously before creating the task
            var validatedURL: URL?
            if let urlString = ipaURLString, !urlString.isEmpty {
                let downloader = ipaDownloader ?? IPADownloader.defaultDownloader()
                validatedURL = try downloader.validateURL(urlString)
            }

            let injectPlayTools = args["injectPlayTools"] as? Bool ?? true
            let applicationCategory = args["applicationCategory"] as? String

            // Determine task title
            let taskTitle: String
            if let url = validatedURL {
                taskTitle = "Installing IPA from URL: \(url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent)"
            } else {
                taskTitle = "Installing IPA: \(URL(fileURLWithPath: rawPath ?? "").lastPathComponent)"
            }

            let createResult = taskManager.createTask(title: taskTitle)
            let taskId = createResult.id

            DispatchQueue.global(qos: .userInitiated).async {
                taskManager.startTask(taskId)

                var downloadedFile: URL?
                do {
                    let resolvedPath: String

                    if let url = validatedURL {
                        // Download from URL (progress maps to 0-40%)
                        let downloader = ipaDownloader ?? IPADownloader.defaultDownloader()
                        let localFile = try downloader.download(
                            url: url,
                            progress: { total, current, message in
                                let mapped = Int(Double(current) / Double(max(total, 1)) * 40)
                                taskManager.updateProgress(taskId, progress: TaskProgress(
                                    total: 100, current: mapped, message: message
                                ))
                            }
                        )
                        downloadedFile = localFile
                        resolvedPath = localFile.path
                    } else if let path = rawPath {
                        // Resolve @filename references
                        if path.hasPrefix("@"), let mgr = uploadManager {
                            resolvedPath = try mgr.resolvePathParameter(path, sessionId: nil)
                        } else if path.hasPrefix("@") {
                            throw PlayCoverMCPError(
                                code: JSONRPCError.invalidParams,
                                message: "File references (@filename) are only supported in HTTP transport mode with upload enabled"
                            )
                        } else {
                            resolvedPath = path
                        }
                    } else {
                        throw PlayCoverMCPError(
                            code: JSONRPCError.invalidParams,
                            message: "install_ipa requires either 'ipaPath' or 'ipaURL' parameter"
                        )
                    }

                    // Install (progress maps to 40-100% for URL mode, 0-100% for path mode)
                    let hasURL = validatedURL != nil
                    let result = try installerService.install(
                        ipaPath: resolvedPath,
                        injectPlayTools: injectPlayTools,
                        applicationCategory: applicationCategory,
                        progress: { total, current, message in
                            let mapped: Int
                            if hasURL {
                                mapped = 40 + Int(Double(current) / Double(max(total, 1)) * 60)
                            } else {
                                mapped = current
                            }
                            taskManager.updateProgress(taskId, progress: TaskProgress(
                                total: 100, current: mapped, message: message
                            ))
                        }
                    )

                    // Cleanup downloaded file
                    if let file = downloadedFile {
                        ipaDownloader?.cleanup(file: file)
                    }

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
                    // Cleanup on failure
                    if let file = downloadedFile {
                        ipaDownloader?.cleanup(file: file)
                    }
                    let wrapped = PlayCoverMCPError(wrapping: error)
                    taskManager.failTask(taskId, error: TaskError(
                        code: wrapped.code,
                        message: wrapped.message
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
        taskManager: TaskManager,
        uploadManager: UploadManager?,
        ipaDownloader: IPADownloader?
    ) {
        let tool = Tool(
            name: "export_patched_ipa",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "ipaPath": AnyCodable([
                        "type": "string",
                        "description": "Absolute path to the source .ipa file to export. Supports @filename references from uploaded files (via POST /upload). Either ipaPath or ipaURL is required."
                    ] as Any),
                    "ipaURL": AnyCodable([
                        "type": "string",
                        "description": "HTTP or HTTPS URL to download the source .ipa file from. Either ipaPath or ipaURL is required."
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
                required: []
            ),
            description: "Export a patched IPA with PlayTools embedded. Accepts either a local file path (ipaPath) or a remote URL (ipaURL). This is a long-running operation; use the returned task ID with the get_task tool to track progress.",
            title: "Export Patched IPA"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "export_patched_ipa") { arguments in
            let args = arguments?.dictionary ?? [:]
            let rawPath = args["ipaPath"] as? String
            let ipaURLString = args["ipaURL"] as? String

            guard (rawPath != nil && !rawPath!.isEmpty) || (ipaURLString != nil && !ipaURLString!.isEmpty) else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "export_patched_ipa requires either 'ipaPath' or 'ipaURL' parameter"
                )
            }

            var validatedURL: URL?
            if let urlString = ipaURLString, !urlString.isEmpty {
                let downloader = ipaDownloader ?? IPADownloader.defaultDownloader()
                validatedURL = try downloader.validateURL(urlString)
            }

            let outputDirectory = args["outputDirectory"] as? String
            let applicationCategory = args["applicationCategory"] as? String

            let taskTitle: String
            if let url = validatedURL {
                taskTitle = "Exporting IPA from URL: \(url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent)"
            } else {
                taskTitle = "Exporting IPA: \(URL(fileURLWithPath: rawPath ?? "").lastPathComponent)"
            }

            let createResult = taskManager.createTask(title: taskTitle)
            let taskId = createResult.id

            DispatchQueue.global(qos: .userInitiated).async {
                taskManager.startTask(taskId)

                var downloadedFile: URL?
                do {
                    let resolvedPath: String

                    if let url = validatedURL {
                        let downloader = ipaDownloader ?? IPADownloader.defaultDownloader()
                        let localFile = try downloader.download(
                            url: url,
                            progress: { total, current, message in
                                let mapped = Int(Double(current) / Double(max(total, 1)) * 40)
                                taskManager.updateProgress(taskId, progress: TaskProgress(
                                    total: 100, current: mapped, message: message
                                ))
                            }
                        )
                        downloadedFile = localFile
                        resolvedPath = localFile.path
                    } else if let path = rawPath {
                        if path.hasPrefix("@"), let mgr = uploadManager {
                            resolvedPath = try mgr.resolvePathParameter(path, sessionId: nil)
                        } else if path.hasPrefix("@") {
                            throw PlayCoverMCPError(
                                code: JSONRPCError.invalidParams,
                                message: "File references (@filename) are only supported in HTTP transport mode with upload enabled"
                            )
                        } else {
                            resolvedPath = path
                        }
                    } else {
                        throw PlayCoverMCPError(
                            code: JSONRPCError.invalidParams,
                            message: "export_patched_ipa requires either 'ipaPath' or 'ipaURL' parameter"
                        )
                    }

                    let hasURL = validatedURL != nil
                    let result = try installerService.export(
                        ipaPath: resolvedPath,
                        outputDirectory: outputDirectory,
                        applicationCategory: applicationCategory,
                        progress: { total, current, message in
                            let mapped: Int
                            if hasURL {
                                mapped = 40 + Int(Double(current) / Double(max(total, 1)) * 60)
                            } else {
                                mapped = current
                            }
                            taskManager.updateProgress(taskId, progress: TaskProgress(
                                total: 100, current: mapped, message: message
                            ))
                        }
                    )

                    if let file = downloadedFile {
                        ipaDownloader?.cleanup(file: file)
                    }

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
                    if let file = downloadedFile {
                        ipaDownloader?.cleanup(file: file)
                    }
                    let wrapped = PlayCoverMCPError(wrapping: error)
                    taskManager.failTask(taskId, error: TaskError(
                        code: wrapped.code,
                        message: wrapped.message
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
