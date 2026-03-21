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
        registerInstallManagementTools()
        registerLaunchTools()
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

    private func registerInstallManagementTools() {
        registry.register(
            HostToolDefinition(
                name: "install_ipa",
                summary: "Install a local IPA into PlayCover through a non-interactive Host MCP path."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["path", "inject_playtools", "allow_official_macos"])
                let path = try arguments.requiredString("path")
                let ipaURL = try context.appResolver.resolveIPAURL(path: path)
                let injectPlayTools = try arguments.optionalBool("inject_playtools") ?? true
                let allowOfficialMacOS = try arguments.optionalBool("allow_official_macos") ?? false

                let configuration = InstallerInstallConfiguration(
                    installPlayTools: injectPlayTools,
                    applicationType: InstallPreferences.shared.defaultAppType,
                    officialMacOSHandling: allowOfficialMacOS ? .allow : .fail
                )

                do {
                    let result = try await Installer.install(
                        ipaUrl: ipaURL,
                        export: false,
                        configuration: configuration
                    )

                    let warnings = self.uniqueWarnings(result.warnings)
                    let payload: HostMCPValue = .object([
                        "bundle_id": .string(result.bundleID),
                        "display_name": .string(result.displayName),
                        "installed_path": .string(result.finalURL.path),
                        "has_playtools": .bool(result.hasPlayTools),
                        "replaced_existing_installation": .bool(result.replacedExistingInstallation)
                    ])

                    return .success(
                        message: "Installed IPA for \(result.bundleID).",
                        data: payload,
                        warnings: warnings,
                        debug: [
                            "source_ipa_path": .string(ipaURL.path),
                            "inject_playtools": .bool(injectPlayTools),
                            "allow_official_macos": .bool(allowOfficialMacOS)
                        ]
                    )
                } catch let error as HostToolError {
                    throw error
                } catch let error as InstallerInstallError {
                    throw HostToolError.preconditionFailed(
                        Installer.userFacingErrorMessage(for: error),
                        details: [
                            "path": .string(ipaURL.path),
                            "inject_playtools": .bool(injectPlayTools),
                            "allow_official_macos": .bool(allowOfficialMacOS)
                        ]
                    )
                } catch let error as PlayCoverError {
                    let code: HostToolErrorCode
                    switch error {
                    case .waitInstallation, .waitDownload:
                        code = .preconditionFailed
                    default:
                        code = .executionFailed
                    }
                    throw HostToolError(
                        code: code,
                        message: Installer.userFacingErrorMessage(for: error),
                        details: ["path": .string(ipaURL.path)]
                    )
                } catch {
                    throw HostToolError.executionFailed(
                        Installer.userFacingErrorMessage(for: error),
                        details: ["path": .string(ipaURL.path)]
                    )
                }
            }
        )

        registry.register(
            HostToolDefinition(
                name: "uninstall_app",
                summary: "Uninstall a PlayCover-managed app by bundle id with explicit cleanup options."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id", "options"])
                let bundleID = try arguments.requiredString("bundle_id")
                let optionsObject = try arguments.optionalObject("options") ?? [:]
                try HostUninstallOptionsParser.validateKeys(optionsObject)
                let options = try HostUninstallOptionsParser.parse(optionsObject)
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let result = await Uninstaller.uninstall(app, options: options)

                var warnings: [String] = []
                if runtimeState.isRunning {
                    warnings.append(
                        "The app was running during uninstall. PlayCover does not yet terminate running apps before deletion."
                    )
                }
                if options.removeAppData {
                    warnings.append(
                        "remove_app_data clears PlayCover's external cache locations only; full container reset remains a separate tool."
                    )
                }
                if !options.removesAllManagedArtifacts {
                    warnings.append(
                        "Some per-app artifacts were intentionally preserved because not all cleanup options were enabled."
                    )
                }
                if !result.removedApp {
                    warnings.append(
                        "The managed .app bundle still exists after uninstall; verify Finder locks or running processes."
                    )
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(result.bundleID),
                    "removed_app": .bool(result.removedApp),
                    "removed_app_data": .bool(result.removedAppData),
                    "removed_settings": .bool(result.removedSettings),
                    "removed_keymap": .bool(result.removedKeymap),
                    "removed_playchain": .bool(result.removedPlaychain),
                    "removed_entitlements": .bool(result.removedEntitlements)
                ])

                return .success(
                    message: result.removedApp
                        ? "Uninstalled app \(bundleID)."
                        : "Attempted uninstall for \(bundleID); some files may remain.",
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running_before_uninstall": .bool(runtimeState.isRunning),
                        "best_effort_active_before_uninstall": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )
    }

    private func registerLaunchTools() {
        registry.register(
            HostToolDefinition(
                name: "launch_app",
                summary: "Launch an installed PlayCover-managed app normally or under LLDB."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id", "debug", "terminal"])
                let bundleID = try arguments.requiredString("bundle_id")
                let debugRequested = try arguments.optionalBool("debug") ?? false
                let terminalRequested = try arguments.optionalBool("terminal") ?? false
                let launchMode: PlayAppLaunchMode = debugRequested
                    ? (terminalRequested ? .lldbTerminal : .lldb)
                    : .normal
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)

                var warnings = [
                    "Host MCP skips the interactive Store update prompt before launch to keep this tool non-interactive."
                ]
                if debugRequested {
                    warnings.append(
                        "Debug launch starts the app under LLDB; Host MCP does not attach a debugger to an already-running process."
                    )
                }
                if terminalRequested && !debugRequested {
                    warnings.append("'terminal' is ignored unless 'debug' is true.")
                }
                if runtimeState.isRunning {
                    warnings.append(
                        "Best-effort runtime state indicates the app was already running before launch; macOS may reactivate the existing instance."
                    )
                }

                do {
                    let attempt = try await app.launchAttempt(
                        modeOverride: launchMode,
                        performVersionCheck: false
                    )

                    let message: String
                    if !attempt.accepted {
                        message = "Launch request for \(bundleID) was not accepted."
                    } else if launchMode == .normal {
                        message = "Launched app \(bundleID)."
                    } else if launchMode == .lldbTerminal {
                        message = "Submitted LLDB Terminal launch request for \(bundleID)."
                    } else {
                        message = "Submitted LLDB launch request for \(bundleID)."
                    }

                    let payload: HostMCPValue = .object([
                        "bundle_id": .string(app.info.bundleIdentifier),
                        "display_name": .string(app.name),
                        "launch_mode": .string(launchMode.rawValue),
                        "accepted": .bool(attempt.accepted),
                        "debugger_strategy": .string(launchMode.usesDebugger ? "launch_under_debugger" : "none"),
                        "terminal": .bool(launchMode.usesTerminalWindow)
                    ])

                    return .success(
                        message: message,
                        data: payload,
                        warnings: self.uniqueWarnings(warnings),
                        debug: [
                            "debug_requested": .bool(debugRequested),
                            "terminal_requested": .bool(terminalRequested),
                            "best_effort_running_before_launch": .bool(runtimeState.isRunning),
                            "best_effort_active_before_launch": .bool(runtimeState.isActive),
                            "matched_process_count_before_launch": .int(runtimeState.matchedProcessCount),
                            "version_check_mode": .string("non_interactive_skip"),
                            "running_application_handle_available": .bool(attempt.runningApplication != nil),
                            "blocked_by_version_check": .bool(attempt.blockedByVersionCheck)
                        ]
                    )
                } catch {
                    throw self.launchToolError(
                        for: error,
                        bundleID: bundleID,
                        launchMode: launchMode,
                        debugRequested: debugRequested,
                        terminalRequested: terminalRequested
                    )
                }
            }
        )
    }

    private func launchToolError(
        for error: Error,
        bundleID: String,
        launchMode: PlayAppLaunchMode,
        debugRequested: Bool,
        terminalRequested: Bool
    ) -> HostToolError {
        let details: [String: HostMCPValue] = [
            "bundle_id": .string(bundleID),
            "launch_mode": .string(launchMode.rawValue),
            "debug_requested": .bool(debugRequested),
            "terminal_requested": .bool(terminalRequested)
        ]

        if let launchError = error as? PlayAppLaunchError {
            switch launchError {
            case .playToolsUnavailable, .invalidExecutableArchitecture:
                return HostToolError.preconditionFailed(launchError.localizedDescription, details: details)
            case .launchRequestRejected:
                return HostToolError.executionFailed(launchError.localizedDescription, details: details)
            }
        }

        if let playCoverError = error as? PlayCoverError {
            return HostToolError.preconditionFailed(playCoverError.localizedDescription, details: details)
        }

        if let hostToolError = error as? HostToolError {
            return hostToolError
        }

        return HostToolError.executionFailed(error.localizedDescription, details: details)
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            seen.insert(warning).inserted
        }
    }
}

private enum HostUninstallOptionsParser {
    private static let allowedKeys: Set<String> = [
        "remove_app_data",
        "remove_keymap",
        "remove_settings",
        "remove_entitlements",
        "remove_playchain"
    ]

    static func validateKeys(_ rawValue: [String: HostMCPValue]) throws {
        let unexpected = rawValue.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw HostToolError.unexpectedArguments(unexpected.map { "options.\($0)" })
        }
    }

    static func parse(_ rawValue: [String: HostMCPValue]) throws -> UninstallOptions {
        func boolValue(for key: String) throws -> Bool {
            guard let value = rawValue[key] else {
                return false
            }
            guard let boolValue = value.boolValue else {
                throw HostToolError.invalidArgument(name: "options.\(key)", expected: "bool", actual: value)
            }
            return boolValue
        }

        return UninstallOptions(
            removeAppData: try boolValue(for: "remove_app_data"),
            removeAppKeymap: try boolValue(for: "remove_keymap"),
            removeAppSettings: try boolValue(for: "remove_settings"),
            removeAppEntitlements: try boolValue(for: "remove_entitlements"),
            removePlayChain: try boolValue(for: "remove_playchain")
        )
    }
}
