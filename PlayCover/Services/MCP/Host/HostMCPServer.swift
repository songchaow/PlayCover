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
        registerDataCleanupTools()
        registerConfigurationTools()
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

    private func registerDataCleanupTools() {
        registry.register(
            HostToolDefinition(
                name: "clear_cache",
                summary: "Clear PlayCover-managed external cache locations for an installed app."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let matchedPaths = Uninstaller.matchingExternalCacheURLs(bundleID: bundleID)
                    .map(\.path)
                    .sorted()

                await Uninstaller.clearCache(of: app)

                let remainingPaths = Set(
                    Uninstaller.matchingExternalCacheURLs(bundleID: bundleID)
                        .map(\.path)
                )
                let removedPaths = matchedPaths.filter { !remainingPaths.contains($0) }
                let blockedPaths = matchedPaths.filter { remainingPaths.contains($0) }

                var warnings = self.cleanupWarningsForRunningApp(runtimeState)
                if !blockedPaths.isEmpty {
                    warnings.append(
                        "Some external cache entries still exist after cleanup; verify Finder locks or that the app is not recreating them."
                    )
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(bundleID),
                    "performed": .bool(!matchedPaths.isEmpty && blockedPaths.isEmpty),
                    "paths_touched": self.pathArrayValue(matchedPaths),
                    "removed_paths": self.pathArrayValue(removedPaths),
                    "remaining_paths": self.pathArrayValue(blockedPaths)
                ])

                let message: String
                if matchedPaths.isEmpty {
                    message = "No external cache entries found for \(bundleID)."
                } else if blockedPaths.isEmpty {
                    message = "Cleared external cache for \(bundleID)."
                } else {
                    message = "Attempted to clear external cache for \(bundleID); some entries remain."
                }

                return .success(
                    message: message,
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount),
                        "matched_path_count_before_cleanup": .int(matchedPaths.count),
                        "remaining_path_count_after_cleanup": .int(blockedPaths.count)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "clear_preferences",
                summary: "Delete the app container preferences plist for an installed app."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let preferencesPath = app.container.userPrefsUrl.path
                let existedBeforeCleanup = app.container.doesPreferencesExist()

                app.container.clearPreferences()

                let existsAfterCleanup = app.container.doesPreferencesExist()
                let touchedPaths = existedBeforeCleanup ? [preferencesPath] : []

                var warnings = self.cleanupWarningsForRunningApp(runtimeState)
                if existedBeforeCleanup && existsAfterCleanup {
                    warnings.append(
                        "The preferences file still exists after cleanup; verify file permissions or a running app rewriting it."
                    )
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(bundleID),
                    "performed": .bool(existedBeforeCleanup && !existsAfterCleanup),
                    "paths_touched": self.pathArrayValue(touchedPaths),
                    "preference_path": .string(preferencesPath),
                    "preference_existed": .bool(existedBeforeCleanup)
                ])

                let message: String
                if !existedBeforeCleanup {
                    message = "No preferences plist found for \(bundleID)."
                } else if existsAfterCleanup {
                    message = "Attempted to clear preferences for \(bundleID); the plist still exists."
                } else {
                    message = "Cleared preferences for \(bundleID)."
                }

                return .success(
                    message: message,
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "clear_playchain",
                summary: "Delete PlayChain files for an installed app."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let candidatePaths = [
                    app.playChainURL.path,
                    app.playChainURL.appendingPathExtension("keyCover").path,
                    app.playChainURL.appendingPathExtension("db").path
                ]
                let existingPaths = candidatePaths.filter { FileManager.default.fileExists(atPath: $0) }

                app.clearPlayChain()

                let remainingPaths = existingPaths.filter { FileManager.default.fileExists(atPath: $0) }
                let removedPaths = existingPaths.filter { !FileManager.default.fileExists(atPath: $0) }

                var warnings = self.cleanupWarningsForRunningApp(runtimeState)
                if !remainingPaths.isEmpty {
                    warnings.append(
                        "Some PlayChain artifacts still exist after cleanup; verify file permissions or that the app is not rewriting them."
                    )
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(bundleID),
                    "performed": .bool(!existingPaths.isEmpty && remainingPaths.isEmpty),
                    "paths_touched": self.pathArrayValue(existingPaths),
                    "removed_paths": self.pathArrayValue(removedPaths),
                    "remaining_paths": self.pathArrayValue(remainingPaths)
                ])

                let message: String
                if existingPaths.isEmpty {
                    message = "No PlayChain artifacts found for \(bundleID)."
                } else if remainingPaths.isEmpty {
                    message = "Cleared PlayChain data for \(bundleID)."
                } else {
                    message = "Attempted to clear PlayChain data for \(bundleID); some artifacts remain."
                }

                return .success(
                    message: message,
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount),
                        "candidate_path_count": .int(candidatePaths.count)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "reset_container",
                summary: "Delete the installed app's PlayCover container directory."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let containerPath = app.container.containerUrl.path
                let existedBeforeCleanup = app.container.doesExist()

                app.container.clear()

                let existsAfterCleanup = app.container.doesExist()
                let touchedPaths = existedBeforeCleanup ? [containerPath] : []

                var warnings = self.cleanupWarningsForRunningApp(runtimeState)
                if existedBeforeCleanup && existsAfterCleanup {
                    warnings.append(
                        "The container directory still exists after reset; verify file permissions or active file locks."
                    )
                }

                let payload: HostMCPValue = .object([
                    "bundle_id": .string(bundleID),
                    "performed": .bool(existedBeforeCleanup && !existsAfterCleanup),
                    "paths_touched": self.pathArrayValue(touchedPaths),
                    "container_path": .string(containerPath),
                    "container_existed": .bool(existedBeforeCleanup)
                ])

                let message: String
                if !existedBeforeCleanup {
                    message = "No app container found for \(bundleID)."
                } else if existsAfterCleanup {
                    message = "Attempted to reset the container for \(bundleID); the directory still exists."
                } else {
                    message = "Reset the container for \(bundleID)."
                }

                return .success(
                    message: message,
                    data: payload,
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )
    }

    private func registerConfigurationTools() {
        registry.register(
            HostToolDefinition(
                name: "get_app_settings",
                summary: "Read supported per-app settings, metadata overrides, and launch environment state."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let playToolsStatus = context.appResolver.playToolsStatus(for: app)

                var warnings = self.configurationLimitationsWarnings()
                if let detectionWarning = playToolsStatus.detectionWarning {
                    warnings.append(detectionWarning)
                }

                return .success(
                    message: "Resolved app settings for \(bundleID).",
                    data: self.configurationSnapshot(for: app, playToolsStatus: playToolsStatus),
                    warnings: self.uniqueWarnings(warnings)
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "set_app_settings",
                summary: "Patch supported per-app settings and selected metadata overrides."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id", "patch"])
                let bundleID = try arguments.requiredString("bundle_id")
                guard let patchObject = try arguments.optionalObject("patch"), !patchObject.isEmpty else {
                    throw HostToolError.preconditionFailed(
                        "Patch object must contain at least one supported field.",
                        details: ["bundle_id": .string(bundleID)]
                    )
                }

                let patch = try HostAppSettingsPatchParser.parse(patchObject)
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let playToolsStatusBefore = context.appResolver.playToolsStatus(for: app)
                let before = self.configurationSnapshot(for: app, playToolsStatus: playToolsStatusBefore)

                var updatedSettings = app.settings.settings
                patch.apply(to: &updatedSettings)
                app.settings.settings = updatedSettings
                guard app.settings.encode() else {
                    throw HostToolError.executionFailed(
                        "Failed to persist app settings for \(bundleID).",
                        details: [
                            "bundle_id": .string(bundleID),
                            "settings_path": .string(app.settings.settingsUrl.path)
                        ]
                    )
                }

                var resigned = false
                if let applicationCategoryType = patch.applicationCategoryType {
                    try app.info.setApplicationCategoryType(applicationCategoryType)
                    try Shell.signApp(app.executable)
                    resigned = true
                }

                let playToolsStatusAfter = context.appResolver.playToolsStatus(for: app)
                let after = self.configurationSnapshot(for: app, playToolsStatus: playToolsStatusAfter)

                var warnings = self.configurationLimitationsWarnings()
                warnings.append(contentsOf: self.modificationWarningsForRunningApp(
                    runtimeState,
                    effect: "Settings changes usually apply on next launch and can race with a running app."
                ))
                if resigned {
                    warnings.append("Changing application_category_type rewrites Info.plist and re-signs the app bundle.")
                }
                if let detectionWarning = playToolsStatusBefore.detectionWarning {
                    warnings.append(detectionWarning)
                }
                if let detectionWarning = playToolsStatusAfter.detectionWarning {
                    warnings.append(detectionWarning)
                }

                return .success(
                    message: "Updated app settings for \(bundleID).",
                    data: .object([
                        "bundle_id": .string(bundleID),
                        "applied_fields": self.stringArrayValue(patch.appliedFields),
                        "resigned": .bool(resigned),
                        "before": before,
                        "after": after
                    ]),
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "settings_path": .string(app.settings.settingsUrl.path),
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "set_launch_env",
                summary: "Configure DYLD-backed launch environment flags for an installed app."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id", "introspection", "ios_frameworks"])
                let bundleID = try arguments.requiredString("bundle_id")
                let introspection = try arguments.optionalBool("introspection")
                let iosFrameworks = try arguments.optionalBool("ios_frameworks")
                guard introspection != nil || iosFrameworks != nil else {
                    throw HostToolError.preconditionFailed(
                        "Provide at least one of 'introspection' or 'ios_frameworks'.",
                        details: ["bundle_id": .string(bundleID)]
                    )
                }

                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let before = self.launchEnvironmentSnapshot(for: app)
                let changed = try self.applyLaunchEnvironmentPatch(
                    to: app,
                    introspection: introspection,
                    iosFrameworks: iosFrameworks
                )
                let after = self.launchEnvironmentSnapshot(for: app)

                var warnings = self.modificationWarningsForRunningApp(
                    runtimeState,
                    effect: "Launch environment changes affect future launches and may require a relaunch to observe."
                )
                if !changed {
                    warnings.append("Requested launch environment flags already matched the current configuration.")
                }

                return .success(
                    message: changed
                        ? "Updated launch environment for \(bundleID)."
                        : "Launch environment for \(bundleID) already matched the requested values.",
                    data: .object([
                        "bundle_id": .string(bundleID),
                        "applied_fields": self.stringArrayValue(
                            [
                                introspection != nil ? "introspection" : nil,
                                iosFrameworks != nil ? "ios_frameworks" : nil
                            ].compactMap { $0 }
                        ),
                        "changed": .bool(changed),
                        "before": before,
                        "after": after
                    ]),
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "info_plist_path": .string(app.info.url.path),
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "sign_app",
                summary: "Re-sign an installed app using PlayCover's composed entitlements flow."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let playToolsStatusBefore = context.appResolver.playToolsStatus(for: app)

                try app.signForHostMCP()

                let playToolsStatusAfter = context.appResolver.playToolsStatus(for: app)
                var warnings = self.modificationWarningsForRunningApp(
                    runtimeState,
                    effect: "Re-signing while the app is running may not affect the current process until relaunch."
                )
                if let detectionWarning = playToolsStatusBefore.detectionWarning {
                    warnings.append(detectionWarning)
                }
                if let detectionWarning = playToolsStatusAfter.detectionWarning {
                    warnings.append(detectionWarning)
                }

                return .success(
                    message: "Re-signed app \(bundleID).",
                    data: .object([
                        "bundle_id": .string(bundleID),
                        "display_name": .string(app.name),
                        "entitlements_path": .string(app.entitlements.path),
                        "has_playtools": .bool(playToolsStatusAfter.hasPlayTools),
                        "metadata": self.appMetadataSnapshot(for: app),
                        "launch_env": self.launchEnvironmentSnapshot(for: app)
                    ]),
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount),
                        "settings_path": .string(app.settings.settingsUrl.path)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "inject_playtools",
                summary: "Inject PlayTools into an installed app and re-sign the bundle."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let playToolsStatusBefore = context.appResolver.playToolsStatus(for: app)

                var warnings = self.modificationWarningsForRunningApp(
                    runtimeState,
                    effect: "Injected PlayTools are intended for subsequent launches; a running app may keep the old binary mapped."
                )
                if let detectionWarning = playToolsStatusBefore.detectionWarning {
                    warnings.append(detectionWarning)
                }

                if playToolsStatusBefore.hasPlayTools {
                    return .success(
                        message: "PlayTools are already installed for \(bundleID).",
                        data: .object([
                            "bundle_id": .string(bundleID),
                            "performed": .bool(false),
                            "has_playtools": .bool(true)
                        ]),
                        warnings: self.uniqueWarnings(warnings),
                        debug: [
                            "plugin_path": .string(self.playToolsPluginPath(for: app)),
                            "best_effort_running": .bool(runtimeState.isRunning),
                            "best_effort_active": .bool(runtimeState.isActive),
                            "matched_process_count": .int(runtimeState.matchedProcessCount)
                        ]
                    )
                }

                try await PlayTools.installInIPA(app.executable)

                let playToolsStatusAfter = context.appResolver.playToolsStatus(for: app)
                if let detectionWarning = playToolsStatusAfter.detectionWarning {
                    warnings.append(detectionWarning)
                }

                return .success(
                    message: "Injected PlayTools into \(bundleID).",
                    data: .object([
                        "bundle_id": .string(bundleID),
                        "performed": .bool(true),
                        "has_playtools": .bool(playToolsStatusAfter.hasPlayTools)
                    ]),
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "plugin_path": .string(self.playToolsPluginPath(for: app)),
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
                        "matched_process_count": .int(runtimeState.matchedProcessCount)
                    ]
                )
            }
        )

        registry.register(
            HostToolDefinition(
                name: "remove_playtools",
                summary: "Remove PlayTools from an installed app and re-sign the bundle."
            ) { arguments, context in
                try arguments.validateKeys(allowed: ["bundle_id"])
                let bundleID = try arguments.requiredString("bundle_id")
                let app = try context.appResolver.resolveApp(bundleID: bundleID)
                let runtimeState = await context.appResolver.bestEffortRuntimeState(bundleID: bundleID)
                let playToolsStatusBefore = context.appResolver.playToolsStatus(for: app)

                var warnings = self.modificationWarningsForRunningApp(
                    runtimeState,
                    effect: "Removing PlayTools affects future launches; a running app may keep the injected framework loaded until exit."
                )
                if let detectionWarning = playToolsStatusBefore.detectionWarning {
                    warnings.append(detectionWarning)
                }

                if !playToolsStatusBefore.hasPlayTools {
                    return .success(
                        message: "PlayTools are already absent for \(bundleID).",
                        data: .object([
                            "bundle_id": .string(bundleID),
                            "performed": .bool(false),
                            "has_playtools": .bool(false)
                        ]),
                        warnings: self.uniqueWarnings(warnings),
                        debug: [
                            "plugin_path": .string(self.playToolsPluginPath(for: app)),
                            "best_effort_running": .bool(runtimeState.isRunning),
                            "best_effort_active": .bool(runtimeState.isActive),
                            "matched_process_count": .int(runtimeState.matchedProcessCount)
                        ]
                    )
                }

                try await PlayTools.removeFromApp(app.executable)

                let playToolsStatusAfter = context.appResolver.playToolsStatus(for: app)
                if let detectionWarning = playToolsStatusAfter.detectionWarning {
                    warnings.append(detectionWarning)
                }

                return .success(
                    message: "Removed PlayTools from \(bundleID).",
                    data: .object([
                        "bundle_id": .string(bundleID),
                        "performed": .bool(true),
                        "has_playtools": .bool(playToolsStatusAfter.hasPlayTools)
                    ]),
                    warnings: self.uniqueWarnings(warnings),
                    debug: [
                        "plugin_path": .string(self.playToolsPluginPath(for: app)),
                        "best_effort_running": .bool(runtimeState.isRunning),
                        "best_effort_active": .bool(runtimeState.isActive),
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

    private func configurationSnapshot(for app: PlayApp, playToolsStatus: HostPlayToolsStatus) -> HostMCPValue {
        .object([
            "bundle_id": .string(app.info.bundleIdentifier),
            "display_name": .string(app.name),
            "settings_path": .string(app.settings.settingsUrl.path),
            "settings_file_exists": .bool(FileManager.default.fileExists(atPath: app.settings.settingsUrl.path)),
            "has_playtools": .bool(playToolsStatus.hasPlayTools),
            "settings": supportedSettingsSnapshot(for: app.settings.settings),
            "metadata": appMetadataSnapshot(for: app),
            "launch_env": launchEnvironmentSnapshot(for: app)
        ])
    }

    private func supportedSettingsSnapshot(for settings: AppSettingsData) -> HostMCPValue {
        .object([
            "keymapping": .bool(settings.keymapping),
            "sensitivity": .double(Double(settings.sensitivity)),
            "disable_timeout": .bool(settings.disableTimeout),
            "ios_device_model": .string(settings.iosDeviceModel),
            "window_width": .int(settings.windowWidth),
            "window_height": .int(settings.windowHeight),
            "custom_scaler": .double(settings.customScaler),
            "resolution": .int(settings.resolution),
            "aspect_ratio": .int(settings.aspectRatio),
            "notch": .bool(settings.notch),
            "bypass": .bool(settings.bypass),
            "play_chain": .bool(settings.playChain),
            "play_chain_debugging": .bool(settings.playChainDebugging),
            "inverse_screen_values": .bool(settings.inverseScreenValues),
            "metal_hud": .bool(settings.metalHUD),
            "window_fix_method": .int(settings.windowFixMethod),
            "root_work_dir": .bool(settings.rootWorkDir),
            "no_km_on_input": .bool(settings.noKMOnInput),
            "enable_scroll_wheel": .bool(settings.enableScrollWheel),
            "hide_title_bar": .bool(settings.hideTitleBar),
            "floating_window": .bool(settings.floatingWindow),
            "check_mic_permission_sync": .bool(settings.checkMicPermissionSync),
            "limit_motion_update_frequency": .bool(settings.limitMotionUpdateFrequency),
            "disable_builtin_mouse": .bool(settings.disableBuiltinMouse),
            "resizable_aspect_ratio_type": .int(settings.resizableAspectRatioType),
            "resizable_aspect_ratio_width": .int(settings.resizableAspectRatioWidth),
            "resizable_aspect_ratio_height": .int(settings.resizableAspectRatioHeight),
            "block_sleep_spamming": .bool(settings.blockSleepSpamming)
        ])
    }

    private func appMetadataSnapshot(for app: PlayApp) -> HostMCPValue {
        .object([
            "application_category_type": .string(app.info.applicationCategoryType.rawValue)
        ])
    }

    private func launchEnvironmentSnapshot(for app: PlayApp) -> HostMCPValue {
        let rawValue = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        let entries = launchEnvironmentEntries(for: app)

        return .object([
            "dyld_library_path": .string(rawValue),
            "dyld_library_path_entries": stringArrayValue(entries),
            "introspection_enabled": .bool(entries.contains(PlayApp.introspection)),
            "ios_frameworks_enabled": .bool(entries.contains(PlayApp.iosFrameworks))
        ])
    }

    private func launchEnvironmentEntries(for app: PlayApp) -> [String] {
        let rawValue = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        return normalizedDYLDEntries(rawValue.split(separator: ":").map(String.init))
    }

    private func normalizedDYLDEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    @discardableResult
    private func applyLaunchEnvironmentPatch(
        to app: PlayApp,
        introspection: Bool?,
        iosFrameworks: Bool?
    ) throws -> Bool {
        let originalEntries = launchEnvironmentEntries(for: app)
        var updatedEntries = originalEntries

        if let introspection {
            setDYLDEntry(PlayApp.introspection, enabled: introspection, entries: &updatedEntries)
        }
        if let iosFrameworks {
            setDYLDEntry(PlayApp.iosFrameworks, enabled: iosFrameworks, entries: &updatedEntries)
        }

        updatedEntries = normalizedDYLDEntries(updatedEntries)
        guard updatedEntries != originalEntries else {
            return false
        }

        var environment = app.info.lsEnvironment
        if updatedEntries.isEmpty {
            environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        } else {
            environment["DYLD_LIBRARY_PATH"] = updatedEntries.joined(separator: ":")
        }

        try app.info.setLSEnvironment(environment)
        try Shell.signApp(app.executable)
        return true
    }

    private func setDYLDEntry(_ entry: String, enabled: Bool, entries: inout [String]) {
        if enabled {
            if !entries.contains(entry) {
                entries.append(entry)
            }
        } else {
            entries.removeAll { $0 == entry }
        }
    }

    private func modificationWarningsForRunningApp(
        _ runtimeState: HostRuntimeStateSnapshot,
        effect: String
    ) -> [String] {
        guard runtimeState.isRunning else {
            return []
        }

        return [
            "Best-effort runtime state indicates the app is running. \(effect)"
        ]
    }

    private func configurationLimitationsWarnings() -> [String] {
        [
            "open_with_lldb and open_lldb_with_terminal are not exposed here because PlayCover does not persist them in the per-app settings plist.",
            "Use set_launch_env for DYLD-backed launch flags; the legacy inject_introspection plist value is not treated as authoritative."
        ]
    }

    private func playToolsPluginPath(for app: PlayApp) -> String {
        app.executable.deletingLastPathComponent()
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")
            .path
    }

    private func cleanupWarningsForRunningApp(_ runtimeState: HostRuntimeStateSnapshot) -> [String] {
        guard runtimeState.isRunning else {
            return []
        }

        return [
            "Best-effort runtime state indicates the app is running; Host MCP does not stop apps before cleanup, so files may be recreated during deletion."
        ]
    }

    private func stringArrayValue(_ values: [String]) -> HostMCPValue {
        .array(values.map { .string($0) })
    }

    private func pathArrayValue(_ paths: [String]) -> HostMCPValue {
        stringArrayValue(paths)
    }

    private func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { warning in
            seen.insert(warning).inserted
        }
    }
}

private struct HostAppSettingsPatch {
    let appliedFields: [String]
    let applicationCategoryType: LSApplicationCategoryType?
    private let applier: (inout AppSettingsData) -> Void

    init(
        appliedFields: [String],
        applicationCategoryType: LSApplicationCategoryType?,
        applier: @escaping (inout AppSettingsData) -> Void
    ) {
        self.appliedFields = appliedFields
        self.applicationCategoryType = applicationCategoryType
        self.applier = applier
    }

    func apply(to settings: inout AppSettingsData) {
        applier(&settings)
    }
}

private enum HostAppSettingsPatchParser {
    private static let allowedKeys: Set<String> = [
        "application_category_type",
        "aspect_ratio",
        "block_sleep_spamming",
        "bypass",
        "check_mic_permission_sync",
        "custom_scaler",
        "disable_builtin_mouse",
        "disable_timeout",
        "enable_scroll_wheel",
        "floating_window",
        "hide_title_bar",
        "inverse_screen_values",
        "ios_device_model",
        "keymapping",
        "limit_motion_update_frequency",
        "metal_hud",
        "no_km_on_input",
        "notch",
        "play_chain",
        "play_chain_debugging",
        "resizable_aspect_ratio_height",
        "resizable_aspect_ratio_type",
        "resizable_aspect_ratio_width",
        "resolution",
        "root_work_dir",
        "sensitivity",
        "window_fix_method",
        "window_height",
        "window_width"
    ]

    static func parse(_ rawValue: [String: HostMCPValue]) throws -> HostAppSettingsPatch {
        let unexpected = rawValue.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw HostToolError.unexpectedArguments(unexpected.map { "patch.\($0)" })
        }

        var appliedFields: [String] = []
        var applicationCategoryType: LSApplicationCategoryType?
        var appliers: [(inout AppSettingsData) -> Void] = []

        for key in rawValue.keys.sorted() {
            guard let value = rawValue[key] else { continue }

            switch key {
            case "application_category_type":
                let rawCategory = try stringValue(value, key: key)
                guard let category = LSApplicationCategoryType(rawValue: rawCategory) else {
                    throw HostToolError.preconditionFailed(
                        "Unknown application_category_type '\(rawCategory)'.",
                        details: [
                            "argument": .string("patch.\(key)"),
                            "value": .string(rawCategory)
                        ]
                    )
                }
                applicationCategoryType = category
            case "aspect_ratio":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.aspectRatio = parsed }
            case "block_sleep_spamming":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.blockSleepSpamming = parsed }
            case "bypass":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.bypass = parsed }
            case "check_mic_permission_sync":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.checkMicPermissionSync = parsed }
            case "custom_scaler":
                let parsed = try positiveDoubleValue(value, key: key)
                appliers.append { $0.customScaler = parsed }
            case "disable_builtin_mouse":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.disableBuiltinMouse = parsed }
            case "disable_timeout":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.disableTimeout = parsed }
            case "enable_scroll_wheel":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.enableScrollWheel = parsed }
            case "floating_window":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.floatingWindow = parsed }
            case "hide_title_bar":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.hideTitleBar = parsed }
            case "inverse_screen_values":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.inverseScreenValues = parsed }
            case "ios_device_model":
                let parsed = try stringValue(value, key: key)
                appliers.append { $0.iosDeviceModel = parsed }
            case "keymapping":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.keymapping = parsed }
            case "limit_motion_update_frequency":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.limitMotionUpdateFrequency = parsed }
            case "metal_hud":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.metalHUD = parsed }
            case "no_km_on_input":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.noKMOnInput = parsed }
            case "notch":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.notch = parsed }
            case "play_chain":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.playChain = parsed }
            case "play_chain_debugging":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.playChainDebugging = parsed }
            case "resizable_aspect_ratio_height":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.resizableAspectRatioHeight = parsed }
            case "resizable_aspect_ratio_type":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.resizableAspectRatioType = parsed }
            case "resizable_aspect_ratio_width":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.resizableAspectRatioWidth = parsed }
            case "resolution":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.resolution = parsed }
            case "root_work_dir":
                let parsed = try boolValue(value, key: key)
                appliers.append { $0.rootWorkDir = parsed }
            case "sensitivity":
                let parsed = try boundedDoubleValue(value, key: key, min: 0, max: 100)
                appliers.append { $0.sensitivity = Float(parsed) }
            case "window_fix_method":
                let parsed = try nonNegativeIntValue(value, key: key)
                appliers.append { $0.windowFixMethod = parsed }
            case "window_height":
                let parsed = try positiveIntValue(value, key: key)
                appliers.append { $0.windowHeight = parsed }
            case "window_width":
                let parsed = try positiveIntValue(value, key: key)
                appliers.append { $0.windowWidth = parsed }
            default:
                break
            }

            appliedFields.append(key)
        }

        guard !appliedFields.isEmpty else {
            throw HostToolError.preconditionFailed("Patch object must contain at least one supported field.")
        }

        return HostAppSettingsPatch(
            appliedFields: appliedFields,
            applicationCategoryType: applicationCategoryType
        ) { settings in
            appliers.forEach { $0(&settings) }
        }
    }

    private static func stringValue(_ value: HostMCPValue, key: String) throws -> String {
        guard let parsed = value.stringValue else {
            throw HostToolError.invalidArgument(name: "patch.\(key)", expected: "string", actual: value)
        }
        return parsed
    }

    private static func boolValue(_ value: HostMCPValue, key: String) throws -> Bool {
        guard let parsed = value.boolValue else {
            throw HostToolError.invalidArgument(name: "patch.\(key)", expected: "bool", actual: value)
        }
        return parsed
    }

    private static func intValue(_ value: HostMCPValue, key: String) throws -> Int {
        guard let parsed = value.intValue else {
            throw HostToolError.invalidArgument(name: "patch.\(key)", expected: "int", actual: value)
        }
        return parsed
    }

    private static func nonNegativeIntValue(_ value: HostMCPValue, key: String) throws -> Int {
        let parsed = try intValue(value, key: key)
        guard parsed >= 0 else {
            throw HostToolError.preconditionFailed(
                "patch.\(key) must be greater than or equal to 0.",
                details: ["argument": .string("patch.\(key)"), "actual": .int(parsed)]
            )
        }
        return parsed
    }

    private static func positiveIntValue(_ value: HostMCPValue, key: String) throws -> Int {
        let parsed = try intValue(value, key: key)
        guard parsed > 0 else {
            throw HostToolError.preconditionFailed(
                "patch.\(key) must be greater than 0.",
                details: ["argument": .string("patch.\(key)"), "actual": .int(parsed)]
            )
        }
        return parsed
    }

    private static func positiveDoubleValue(_ value: HostMCPValue, key: String) throws -> Double {
        guard let parsed = value.doubleValue else {
            throw HostToolError.invalidArgument(name: "patch.\(key)", expected: "double", actual: value)
        }
        guard parsed > 0 else {
            throw HostToolError.preconditionFailed(
                "patch.\(key) must be greater than 0.",
                details: ["argument": .string("patch.\(key)"), "actual": .double(parsed)]
            )
        }
        return parsed
    }

    private static func boundedDoubleValue(
        _ value: HostMCPValue,
        key: String,
        min: Double,
        max: Double
    ) throws -> Double {
        guard let parsed = value.doubleValue else {
            throw HostToolError.invalidArgument(name: "patch.\(key)", expected: "double", actual: value)
        }
        guard parsed >= min, parsed <= max else {
            throw HostToolError.preconditionFailed(
                "patch.\(key) must be between \(min) and \(max).",
                details: ["argument": .string("patch.\(key)"), "actual": .double(parsed)]
            )
        }
        return parsed
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
