//
//  MCPManager.swift
//  PlayCover
//
//  Manages the embedded MCP Server lifecycle.
//  Starts the GUI MCP server on app launch and stops it on termination.
//

import Foundation
import SwiftUI

class MCPManager: ObservableObject {
    static let shared = MCPManager()

    // MARK: - Runtime Session Snapshot (GUI-visible)

    /// Lightweight snapshot of a runtime session, suitable for GUI display.
    /// Decoupled from PlayCoverMCP's `SessionInfo` to avoid cross-target dependency.
    struct RuntimeSessionSnapshot: Identifiable, Equatable {
        let id: String          // sessionId
        let bundleId: String
        let status: String      // "starting" | "ready" | "disconnected" | "closed"
        let pid: Int32
    }

    // MARK: - Constants

    enum TransportType: String, CaseIterable {
        case http
        case tcp
    }

    static let defaultPort: UInt16 = 19820
    static let defaultHost: TCPTransport.ListenHost = .loopback
    static let defaultTransportType: TransportType = .http
    static let portRange: ClosedRange<UInt16> = 1024...65535
    private static let portKey = "MCPServerPort"
    private static let hostKey = "MCPServerHost"
    private static let transportTypeKey = "MCPServerTransportType"

    // MARK: - Published State

    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var port: UInt16 = MCPManager.defaultPort
    @Published var listenHost: TCPTransport.ListenHost = MCPManager.defaultHost
    @Published var transportType: TransportType = MCPManager.defaultTransportType
    @Published var lastError: String?

    /// Runtime sessions grouped by bundleId, updated reactively from SessionRegistry.
    @Published var runtimeSessions: [String: [RuntimeSessionSnapshot]] = [:]

    /// Bundle IDs currently performing a capture (for UI busy state).
    @Published var capturingBundleIds: Set<String> = []

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

    /// The user-configured transport type, persisted in UserDefaults.
    /// Falls back to Streamable HTTP when available.
    var savedTransportType: TransportType {
        get {
            guard let stored = UserDefaults.standard.string(forKey: MCPManager.transportTypeKey),
                  let type = TransportType(rawValue: stored) else {
                return MCPManager.defaultTransportType
            }
            return type
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: MCPManager.transportTypeKey)
        }
    }

    // MARK: - Computed State

    /// Get session snapshots for a given bundleId.
    func sessions(for bundleId: String) -> [RuntimeSessionSnapshot] {
        runtimeSessions[bundleId] ?? []
    }

    /// Whether any active (starting/ready) session exists for a given bundleId.
    func hasActiveSession(for bundleId: String) -> Bool {
        sessions(for: bundleId).contains { $0.status == "ready" || $0.status == "starting" }
    }

    /// Whether a ready session exists and capture is not already in progress for this bundleId.
    func canCapture(bundleId: String) -> Bool {
        sessions(for: bundleId).contains { $0.status == "ready" }
            && !capturingBundleIds.contains(bundleId)
    }

    /// Whether a capture is currently in progress for this bundleId.
    func isCapturing(bundleId: String) -> Bool {
        capturingBundleIds.contains(bundleId)
    }

    /// Trigger a Metal frame capture for the first ready session of the given bundleId.
    /// Updates `capturingBundleIds` for UI feedback. Returns the output path on success.
    @discardableResult
    func captureFrame(bundleId: String) async -> Result<String, String> {
        guard let captureService = captureService else {
            return .failure("MCP Server not running")
        }

        // Find first ready session for this bundleId
        guard let session = sessions(for: bundleId).first(where: { $0.status == "ready" }) else {
            return .failure("No ready session for \(bundleId)")
        }

        await MainActor.run { capturingBundleIds.insert(bundleId) }

        do {
            let params = CaptureFrameParams()
            let result = try await captureService.captureFrame(sessionId: session.id, params: params)
            await MainActor.run { capturingBundleIds.remove(bundleId) }
            if result.success, let path = result.outputPath {
                return .success(path)
            } else {
                return .failure(result.message)
            }
        } catch {
            await MainActor.run { capturingBundleIds.remove(bundleId) }
            return .failure(error.localizedDescription)
        }
    }

    var isHTTPTransportSupported: Bool {
        if #available(macOS 14, *) {
            return true
        }
        return false
    }

    var runtimeDefaultTransportType: TransportType {
        isHTTPTransportSupported ? .http : .tcp
    }

    var effectiveTransportType: TransportType {
        normalizedTransportType(transportType)
    }

    var endpointURLString: String {
        switch effectiveTransportType {
        case .http:
            return "http://\(endpointHost):\(port)/mcp"
        case .tcp:
            return "tcp://\(endpointHost):\(port)"
        }
    }

    var bindAddressString: String {
        "\(listenHost.rawValue):\(port)"
    }

    private var endpointHost: String {
        switch listenHost {
        case .loopback, .allInterfaces:
            return "127.0.0.1"
        }
    }

    private var server: MCPServer?
    private var logger: MCPLogger?
    private var taskManager: TaskManager?
    private var uploadManager: UploadManager?
    private var activeTransportStorage: AnyObject?
    private var activeTransportStop: (() -> Void)?
    private var registrationListener: RegistrationListener?
    private var healthMonitor: SessionHealthMonitor?
    private var captureService: CaptureService?

    private init() {
        port = savedPort
        listenHost = savedHost
        transportType = normalizedTransportType(savedTransportType)

        if transportType != savedTransportType {
            savedTransportType = transportType
        }
    }

    /// Validate whether a port number is in the allowed range (1024–65535).
    static func isValidPort(_ port: UInt16) -> Bool {
        portRange.contains(port)
    }

    /// Start the embedded MCP Server with the selected transport.
    func start() {
        guard !isRunning else { return }

        let effectiveTransportType = normalizedTransportType(transportType)
        if effectiveTransportType != transportType {
            transportType = effectiveTransportType
            savedTransportType = effectiveTransportType
        }

        let listenPort = port
        let host = listenHost

        let logger = MCPLogger(minLevel: .info)
        let taskManager = TaskManager()
        let uploadManager = UploadManager.defaultManager()
        let server = createServer(logger: logger, taskManager: taskManager, uploadManager: uploadManager)

        self.server = server
        self.logger = logger
        self.taskManager = taskManager
        self.uploadManager = uploadManager

        switch effectiveTransportType {
        case .http:
            if #available(macOS 14, *) {
                startHTTPTransport(server: server, logger: logger, port: listenPort, host: host)
            } else {
                startTCPTransport(server: server, logger: logger, port: listenPort, host: host)
            }
        case .tcp:
            startTCPTransport(server: server, logger: logger, port: listenPort, host: host)
        }

        logger.log(.info, "MCP Server starting with \(effectiveTransportType.rawValue.uppercased()) transport on \(host.rawValue):\(listenPort)...")
    }

    /// Stop the embedded MCP Server and release all resources.
    func stop() {
        activeTransportStop?()
        activeTransportStop = nil
        activeTransportStorage = nil
        server = nil
        logger = nil
        taskManager = nil
        uploadManager?.cleanupAll()
        uploadManager = nil
        captureService = nil
        healthMonitor?.stop()
        healthMonitor = nil
        registrationListener?.stop()
        registrationListener = nil
        isRunning = false
        connectedClients = 0
        runtimeSessions = [:]
        capturingBundleIds = []
        lastError = nil
    }

    /// Restart the MCP Server with a new port, host, and/or transport type.
    /// Saves the new settings to UserDefaults, stops the current server, and starts with the new configuration.
    func restart(
        withPort newPort: UInt16,
        host newHost: TCPTransport.ListenHost? = nil,
        transportType newTransportType: TransportType? = nil
    ) {
        guard MCPManager.isValidPort(newPort) else {
            lastError = "Invalid port: \(newPort). Must be between \(MCPManager.portRange.lowerBound) and \(MCPManager.portRange.upperBound)."
            return
        }

        savedPort = newPort
        port = newPort

        if let newHost = newHost {
            savedHost = newHost
            listenHost = newHost
        }

        if let newTransportType = newTransportType {
            let normalizedTransportType = normalizedTransportType(newTransportType)
            savedTransportType = normalizedTransportType
            transportType = normalizedTransportType
        }

        stop()
        start()
    }

    // MARK: - Transport Startup

    private func startTCPTransport(server: MCPServer, logger: MCPLogger, port: UInt16, host: TCPTransport.ListenHost) {
        let transport = TCPTransport(port: port, host: host) { message in
            server.handle(message)
        }

        transport.onStateChange = { [weak self] newState in
            self?.handleTransportStateChange(newState)
        }

        transport.onClientCountChanged = { [weak self] count in
            self?.connectedClients = count
        }

        transport.start()
        activeTransportStorage = transport
        activeTransportStop = { transport.stop() }
    }

    @available(macOS 14, *)
    private func startHTTPTransport(server: MCPServer, logger: MCPLogger, port: UInt16, host: TCPTransport.ListenHost) {
        let transport = StreamableHTTPTransport(
            port: port,
            host: streamableHTTPHost(from: host),
            handler: { message in
                server.handle(message)
            },
            mcpServer: server,
            uploadManager: self.uploadManager
        )

        transport.onStateChange = { [weak self] newState in
            self?.handleTransportStateChange(newState)
        }

        transport.onSessionCountChanged = { [weak self] count in
            self?.connectedClients = count
        }

        transport.start()
        activeTransportStorage = transport
        activeTransportStop = { transport.stop() }
    }

    // MARK: - Service Registration

    /// Register all MCP services, tools, and resources on the server.
    /// This mirrors the bootstrap logic in PlayCoverMCP/main.swift.
    private func registerServices(on server: MCPServer, taskManager: TaskManager, uploadManager: UploadManager?) {
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

        // Task inspection tools for long-running operations
        TaskTools.register(on: server, taskManager: taskManager)

        // Installer tools
        let installerService = InstallerService.defaultService()
        InstallerTools.register(on: server, installerService: installerService, taskManager: taskManager, uploadManager: uploadManager)

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
        sessionRegistry.onChange = { [weak self] allSessions in
            guard let self = self else { return }
            // Build grouped snapshot by bundleId, excluding pending sessions
            var grouped: [String: [RuntimeSessionSnapshot]] = [:]
            for session in allSessions where !session.sessionId.hasPrefix("pending-") {
                let snapshot = RuntimeSessionSnapshot(
                    id: session.sessionId,
                    bundleId: session.bundleId,
                    status: session.status.rawValue,
                    pid: session.pid
                )
                grouped[session.bundleId, default: []].append(snapshot)
            }
            self.runtimeSessions = grouped
        }
        let registrationListener = RegistrationListener(port: RegistrationListener.defaultPort, registry: sessionRegistry)
        do {
            let boundPort = try registrationListener.start()
            self.logger?.log(.info, "Registration listener started on port \(boundPort)")
        } catch {
            self.logger?.log(.error, "Failed to start registration listener: \(error.localizedDescription)")
        }
        self.registrationListener = registrationListener

        let healthMonitor = SessionHealthMonitor(registry: sessionRegistry, staleTimeout: 30.0)
        healthMonitor.onStaleSessions = { [weak self] staleSessions in
            self?.logger?.log(.info, "Removed \(staleSessions.count) stale session(s): \(staleSessions.map(\.sessionId).joined(separator: ", "))")
        }
        healthMonitor.start(interval: 10.0)
        self.healthMonitor = healthMonitor

        let sessionService = SessionService(registry: sessionRegistry)
        SessionTools.register(on: server, sessionService: sessionService)
        SessionResources.register(on: server, sessionService: sessionService)

        // Touch tools (tap, long_press, swipe, drag)
        let touchService = TouchService(registry: sessionRegistry)
        TouchTools.register(on: server, touchService: touchService)

        // Input tools (press_key, type_text, toggle_debug_overlay)
        let inputService = InputService(registry: sessionRegistry)
        InputTools.register(on: server, inputService: inputService)

        // Capture tools (capture_metal_frame, get_capture_status)
        let captureService = CaptureService(registry: sessionRegistry)
        self.captureService = captureService
        CaptureTools.register(on: server, captureService: captureService)
    }

    // MARK: - Private Helpers

    private func createServer(logger: MCPLogger, taskManager: TaskManager, uploadManager: UploadManager?) -> MCPServer {
        let serverInfo = Implementation(
            name: "playcover-mcp-gui",
            version: "0.2.0"
        )
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

        registerServices(on: server, taskManager: taskManager, uploadManager: uploadManager)
        return server
    }

    private func normalizedTransportType(_ requestedType: TransportType) -> TransportType {
        guard requestedType == .http, !isHTTPTransportSupported else {
            return requestedType
        }
        return .tcp
    }

    @available(macOS 14, *)
    private func streamableHTTPHost(from host: TCPTransport.ListenHost) -> StreamableHTTPTransport.ListenHost {
        switch host {
        case .loopback:
            return .loopback
        case .allInterfaces:
            return .allInterfaces
        }
    }

    private func handleTransportStateChange(_ newState: TCPTransport.State) {
        switch newState {
        case .running(let actualPort):
            port = actualPort
            isRunning = true
            lastError = nil
        case .failed(let message):
            isRunning = false
            lastError = message
        case .stopped:
            isRunning = false
        case .starting:
            break
        }
    }

    @available(macOS 14, *)
    private func handleTransportStateChange(_ newState: StreamableHTTPTransport.State) {
        switch newState {
        case .running(let actualPort):
            port = actualPort
            isRunning = true
            lastError = nil
        case .failed(let message):
            isRunning = false
            lastError = message
        case .stopped:
            isRunning = false
        case .starting:
            break
        }
    }
}
