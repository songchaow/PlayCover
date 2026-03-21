import Foundation

final class HostMCPServer {
    static let shared = HostMCPServer()

    let registry: HostToolRegistry
    let context: HostToolContext

    private let dateFormatter = ISO8601DateFormatter()

    private(set) var isStarted = false

    init(
        registry: HostToolRegistry = HostToolRegistry(),
        context: HostToolContext = HostToolContext(
            appResolver: HostAppResolver(),
            startupDate: Date()
        )
    ) {
        self.registry = registry
        self.context = context
        registerDefaultTools()
        registerAppQueryTools()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    func execute(_ call: HostToolCall) async -> HostToolResult {
        await registry.execute(call, context: context)
    }

    private func registerDefaultTools() {
        registry.register(
            HostToolDefinition(
                name: "host.ping",
                summary: "Verify that the Host MCP registry is reachable."
            ) { _, context in
                .success(
                    message: "Host MCP is ready.",
                    data: .object([
                        "server": .string("host"),
                        "started_at": .string(self.dateFormatter.string(from: context.startupDate)),
                        "registered_tool_count": .int(self.registry.registeredTools().count)
                    ])
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "host.describe_tools",
                summary: "List the currently registered Host MCP tools."
            ) { _, _ in
                let toolObjects = self.registry.registeredTools().map { descriptor in
                    HostMCPValue.object([
                        "name": .string(descriptor.name),
                        "summary": .string(descriptor.summary)
                    ])
                }

                return .success(
                    message: "Registered host tools listed.",
                    data: .array(toolObjects)
                )
            }
        )
    }

    private func registerAppQueryTools() {
        registry.register(
            HostToolDefinition(
                name: "list_apps",
                summary: "List installed PlayCover-managed apps."
            ) { arguments, context in
                try arguments.validateKeys(allowed: [])
                let apps = try context.appResolver.listInstalledApps()

                var warnings: [String] = []
                let payload = apps.map { app -> HostMCPValue in
                    let playToolsStatus = context.appResolver.playToolsStatus(for: app)
                    if let detectionWarning = playToolsStatus.detectionWarning {
                        warnings.append(detectionWarning)
                    }

                    return .object([
                        "bundle_id": .string(app.info.bundleIdentifier),
                        "display_name": .string(app.name),
                        "version": .string(app.info.bundleVersion),
                        "path": .string(app.url.path),
                        "has_playtools": .bool(playToolsStatus.hasPlayTools)
                    ])
                }

                return .success(
                    message: apps.isEmpty ? "No installed apps found." : "Listed \(apps.count) installed app(s).",
                    data: .array(payload),
                    warnings: self.uniqueWarnings(warnings)
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "get_app_info",
                summary: "Read structured metadata for an installed app by bundle id."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let playToolsStatus = context.appResolver.playToolsStatus(for: app)

                var warnings: [String] = []
                if let detectionWarning = playToolsStatus.detectionWarning {
                    warnings.append(detectionWarning)
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(app.info.bundleIdentifier),
                    "display_name": .string(app.info.displayName),
                    "bundle_name": .string(app.info.bundleName),
                    "version": .string(app.info.bundleVersion),
                    "executable_name": .string(app.info.executableName),
                    "minimum_os_version": .string(app.info.minimumOSVersion),
                    "category": .string(app.info.applicationCategoryType.rawValue),
                    "icon_name": .string(app.info.primaryIconName),
                    "path": .string(app.url.path),
                    "executable_path": .string(app.executable.path),
                    "has_playtools": .bool(playToolsStatus.hasPlayTools)
                ])

                return .success(
                    message: "Resolved app info for \(bundleID).",
                    data: payload,
                    warnings: warnings
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "app_status",
                summary: "Return a first-pass best-effort status snapshot for an installed app."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let playToolsStatus = context.appResolver.playToolsStatus(for: app)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)

                var warnings = [
                    "'running' and 'active' currently mirror best-effort NSWorkspace snapshots, not a persistent session tracker.",
                    "'launching', 'terminated', and 'debug_mode' are unavailable until Host MCP tracks runtime sessions explicitly."
                ]
                if let detectionWarning = playToolsStatus.detectionWarning {
                    warnings.append(detectionWarning)
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(app.info.bundleIdentifier),
                    "display_name": .string(app.name),
                    "installed": .bool(true),
                    "has_playtools": .bool(playToolsStatus.hasPlayTools),
                    "debug_capable": .bool(context.appResolver.debugCapable(for: app)),
                    "best_effort_running": .bool(runtimeState.isRunning),
                    "best_effort_active": .bool(runtimeState.isActive),
                    "running": .bool(runtimeState.isRunning),
                    "active": .bool(runtimeState.isActive),
                    "launching": .null,
                    "terminated": .null,
                    "debug_mode": .null
                ])

                return .success(
                    message: "Resolved app status for \(bundleID).",
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "status_source": .string("NSWorkspace.shared.runningApplications"),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            seen.insert(warning).inserted
        }
    }
}
