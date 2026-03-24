//
//  MCPManager.swift
//  PlayCover
//
//  Manages the embedded MCP Server lifecycle.
//  Starts a TCP-based MCP server on app launch, stops on termination.
//

import Foundation
import SwiftUI

class MCPManager: ObservableObject {
    static let shared = MCPManager()

    // MARK: - Constants

    static let defaultPort: UInt16 = 19820
    static let defaultHost: TCPTransport.ListenHost = .loopback
    static let portRange: ClosedRange<UInt16> = 1024...65535
    private static let portKey = "MCPServerPort"
    private static let hostKey = "MCPServerHost"

    // MARK: - Published State

    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var port: UInt16 = MCPManager.defaultPort
    @Published var listenHost: TCPTransport.ListenHost = MCPManager.defaultHost
    @Published var lastError: String?

    // MARK: - Persisted Settings

    /// The user-configured port, persisted in UserDefaults.
    /// Falls back to `defaultPort` if not set.
    var savedPort: UInt16 {
        get {
            let stored = UserDefaults.standard.integer(forKey: MCPManager.portKey)
            return stored > 0 ? UInt16(clamping: stored) : MCPManager.defaultPort
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: MCPManager.portKey)
        }
    }

    /// The user-configured listen host, persisted in UserDefaults.
    /// Falls back to `defaultHost` (.loopback) if not set.
    var savedHost: TCPTransport.ListenHost {
        get {
            guard let stored = UserDefaults.standard.string(forKey: MCPManager.hostKey),
                  let host = TCPTransport.ListenHost(rawValue: stored) else {
                return MCPManager.defaultHost
            }
            return host
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: MCPManager.hostKey)
        }
    }

    private var server: MCPServer?
    private var transport: TCPTransport?
    private var logger: MCPLogger?
    private var taskManager: TaskManager?

    private init() {
        // Load persisted settings on init
        self.port = savedPort
        self.listenHost = savedHost
    }

    /// Validate whether a port number is in the allowed range (1024–65535).
    static func isValidPort(_ port: UInt16) -> Bool {
        return portRange.contains(port)
    }

    /// Start the embedded MCP Server with TCP transport.
    /// Safe to call from the main thread — TCP listening is asynchronous.
    func start() {
        guard !isRunning else { return }

        // Use the current port and host values (which should already reflect saved settings)
        let listenPort = port
        let host = listenHost

        // 1. Create infrastructure
        let logger = MCPLogger(minLevel: .info)
        let taskManager = TaskManager()

        let serverInfo = Implementation(
            name: "playcover-mcp-gui",
            version: "0.2.0"
        )
        let capabilities = ServerCapabilities(
            tools: ToolCapabilities(listChanged: false),
            resources: ResourceCapabilities(subscribe: false, listChanged: false),
            logging: true,
            tasks: true
        )

        // 2. Create server
        let server = MCPServer(
            serverInfo: serverInfo,
            capabilities: capabilities,
            logger: logger,
            taskManager: taskManager
        )

        // 3. Register all Services, Tools, Resources (mirrors main.swift bootstrap)
        registerServices(on: server, taskManager: taskManager)

        // 4. Create and start TCP transport
        let transport = TCPTransport(port: listenPort, host: host) { message in
            server.handle(message)
        }

        transport.onStateChange = { [weak self] newState in
            // This callback is dispatched to main queue by TCPTransport
            guard let self = self else { return }
            switch newState {
            case .running(let actualPort):
                self.port = actualPort
                self.isRunning = true
                self.lastError = nil
            case .failed(let message):
                self.isRunning = false
                self.lastError = message
            case .stopped:
                self.isRunning = false
            case .starting:
                break
            }
        }

        transport.onClientCountChanged = { [weak self] count in
            // This callback is dispatched to main queue by TCPTransport
            self?.connectedClients = count
        }

        transport.start()

        // 5. Save references
        self.server = server
        self.transport = transport
        self.logger = logger
        self.taskManager = taskManager
        // Note: isRunning will be set to true via onStateChange when listener is ready

        logger.log(.info, "MCP Server starting on \(host.rawValue):\(listenPort)...")
    }

    /// Stop the embedded MCP Server and release all resources.
    func stop() {
        transport?.stop()
        transport = nil
        server = nil
        logger = nil
        taskManager = nil
        isRunning = false
        connectedClients = 0
        lastError = nil
    }

    /// Restart the MCP Server with a new port and/or host.
    /// Saves the new settings to UserDefaults, stops the current server, and starts with the new configuration.
    func restart(withPort newPort: UInt16, host newHost: TCPTransport.ListenHost? = nil) {
        guard MCPManager.isValidPort(newPort) else {
            lastError = "Invalid port: \(newPort). Must be between \(MCPManager.portRange.lowerBound) and \(MCPManager.portRange.upperBound)."
            return
        }

        // Persist settings
        savedPort = newPort
        port = newPort

        if let newHost = newHost {
            savedHost = newHost
            listenHost = newHost
        }

        // Stop existing server and restart
        stop()
        start()
    }

    // MARK: - Service Registration

    /// Register all MCP services, tools, and resources on the server.
    /// This mirrors the bootstrap logic in PlayCoverMCP/main.swift.
    private func registerServices(on server: MCPServer, taskManager: TaskManager) {
        // App tools and resources
        let appService = AppService.defaultService()
        AppTools.register(on: server, appService: appService)

        // Settings service (needed by AppResources for settings resource routing)
        let settingsService = SettingsService.defaultService()

        // App resources (including settings resource via settingsService)
        AppResources.register(on: server, appService: appService, settingsService: settingsService)

        // Settings resource metadata and tools
        SettingsResources.register(on: server)
        SettingsTools.register(on: server, settingsService: settingsService)

        // Installer tools
        let installerService = InstallerService.defaultService()
        InstallerTools.register(on: server, installerService: installerService, taskManager: taskManager)

        // Launch tools
        let launchService = LaunchService.defaultService()
        LaunchTools.register(on: server, launchService: launchService)

        // Cleanup tools
        let cleanupService = CleanupService.defaultService()
        CleanupTools.register(on: server, cleanupService: cleanupService)

        // Signing tools
        let signingService = SigningService.defaultService()
        SigningTools.register(on: server, signingService: signingService, taskManager: taskManager)

        // Injection tools
        let injectionService = InjectionService.defaultService()
        InjectionTools.register(on: server, injectionService: injectionService)

        // Keymap tools
        let keymapService = KeymapService.defaultService()
        KeymapTools.register(on: server, keymapService: keymapService)

        // Session tools and resources
        let sessionRegistry = SessionRegistry()
        let sessionService = SessionService(registry: sessionRegistry)
        SessionTools.register(on: server, sessionService: sessionService)
        SessionResources.register(on: server, sessionService: sessionService)

        // Touch tools (tap, long_press, swipe, drag)
        let touchService = TouchService(registry: sessionRegistry)
        TouchTools.register(on: server, touchService: touchService)

        // Input tools (press_key, type_text, toggle_debug_overlay)
        let inputService = InputService(registry: sessionRegistry)
        InputTools.register(on: server, inputService: inputService)
    }
}
