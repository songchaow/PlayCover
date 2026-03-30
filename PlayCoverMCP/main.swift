import Foundation

/// PlayCoverMCP server entry point.
///
/// Bootstraps the MCP server with stdio transport, logging, and task management.
/// Logs are written to stderr to avoid interfering with the JSON-RPC protocol on stdout.

let serverInfo = Implementation(
    name: "playcover-mcp",
    version: "0.2.0"
)

let logger = MCPLogger(minLevel: .info)

let taskManager = TaskManager()

let capabilities = ServerCapabilities(
    tools: ToolCapabilities(listChanged: false),
    resources: ResourceCapabilities(subscribe: false, listChanged: false),
    logging: EmptyCapability(),
    tasks: TaskCapabilities(
        list: EmptyCapability(),
        cancel: EmptyCapability()
    )
)

let server = MCPServer(
    serverInfo: serverInfo,
    capabilities: capabilities,
    logger: logger,
    taskManager: taskManager
)

// Register app tools and resources
let appService = AppService.defaultService()
AppTools.register(on: server, appService: appService)

// Register settings service (needed by AppResources for settings resource routing)
let settingsService = SettingsService.defaultService()

// Register app resources (including settings resource via settingsService)
AppResources.register(on: server, appService: appService, settingsService: settingsService)

// Register settings resource metadata and tools
SettingsResources.register(on: server)
SettingsTools.register(on: server, settingsService: settingsService)

// Register task inspection tools for long-running operations
TaskTools.register(on: server, taskManager: taskManager)

// Register installer tools
let installerService = InstallerService.defaultService()
InstallerTools.register(on: server, installerService: installerService, taskManager: taskManager)

// Register launch tools
let launchService = LaunchService.defaultService()
LaunchTools.register(on: server, launchService: launchService)

// Register cleanup tools
let cleanupService = CleanupService.defaultService()
CleanupTools.register(on: server, cleanupService: cleanupService)

// Register signing tools
let signingService = SigningService.defaultService()
SigningTools.register(on: server, signingService: signingService, taskManager: taskManager)

// Register injection tools
let injectionService = InjectionService.defaultService()
InjectionTools.register(on: server, injectionService: injectionService)

// Register keymap tools
let keymapService = KeymapService.defaultService()
KeymapTools.register(on: server, keymapService: keymapService)

// Register session tools and resources
let sessionRegistry = SessionRegistry()
let registrationListener = RegistrationListener(port: RegistrationListener.defaultPort, registry: sessionRegistry)
do {
    let boundPort = try registrationListener.start()
    logger.log(.info, "Registration listener started on port \(boundPort)")
} catch {
    logger.log(.error, "Failed to start registration listener: \(error.localizedDescription)")
}

let healthMonitor = SessionHealthMonitor(registry: sessionRegistry, staleTimeout: 30.0)
healthMonitor.onStaleSessions = { staleSessions in
    logger.log(.info, "Removed \(staleSessions.count) stale session(s): \(staleSessions.map(\.sessionId).joined(separator: ", "))")
}
healthMonitor.start(interval: 10.0)

let sessionService = SessionService(registry: sessionRegistry)
SessionTools.register(on: server, sessionService: sessionService)
SessionResources.register(on: server, sessionService: sessionService)

// Register touch tools (tap, long_press, swipe, drag)
let touchService = TouchService(registry: sessionRegistry)
TouchTools.register(on: server, touchService: touchService)

// Register input tools (press_key, type_text, toggle_debug_overlay)
let inputService = InputService(registry: sessionRegistry)
InputTools.register(on: server, inputService: inputService)

// Register capture tools (capture_metal_frame, get_capture_status)
let captureService = CaptureService(registry: sessionRegistry)
CaptureTools.register(on: server, captureService: captureService)

let transport = StdioTransport { message in
    server.handle(message)
}

// Set up signal handling for graceful shutdown
let shutdownHandler = {
    healthMonitor.stop()
    registrationListener.stop()
}

signal(SIGINT) { _ in
    shutdownHandler()
    exit(0)
}
signal(SIGTERM) { _ in
    shutdownHandler()
    exit(0)
}

transport.run()
