// InstallerTools.swift
// PlayCoverMCP

import Foundation

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
            description: "Install an IPA file into PlayCover. This is a long-running operation; use the returned task ID to track progress.",
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
                "message": "IPA installation started. Use tasks/get to track progress."
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
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
            description: "Export a patched IPA with PlayTools embedded. This is a long-running operation; use the returned task ID to track progress.",
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
                "message": "IPA export started. Use tasks/get to track progress."
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }
}
