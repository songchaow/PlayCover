// BridgeListener.swift
// PlayTools - Runtime Bridge Implementation

import Foundation
import Network
import UIKit
import Darwin

enum RuntimeLaunchDiagnostics {
    private static let schemaVersion = 1
    private static let writeQueue = DispatchQueue(label: "com.playtools.runtime-launch-diagnostics")
    static let processLaunchId = "launch-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"

    private static var hostUserHomeDirectoryPath: String {
        let currentUID = getuid()
        if let pw = getpwuid(currentUID), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())").path
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "playtools.runtime.\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static var diagnosticsRootURL: URL {
        URL(fileURLWithPath: hostUserHomeDirectoryPath, isDirectory: true)
            .appendingPathComponent("Library/Containers/io.playcover.PlayCover", isDirectory: true)
            .appendingPathComponent("RuntimeLaunchDiagnostics", isDirectory: true)
    }

    private static func diagnosticsFileURL(bundleId: String) -> URL {
        diagnosticsRootURL
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("launch-events.jsonl")
    }

    static func record(event: String, bundleId: String? = nil, details: [String: String] = [:]) {
        let resolvedBundleId = bundleId ?? self.bundleIdentifier
        var entry: [String: Any] = [
            "schemaVersion": schemaVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "bundleId": resolvedBundleId,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "processLaunchId": processLaunchId,
            "isMainThread": Thread.isMainThread,
        ]
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            entry[key] = value
        }

        let logSuffix = details.isEmpty
            ? ""
            : " — " + details.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        NSLog("%@", "[PlayTools] RuntimeLaunchDiagnostics: \(event)\(logSuffix)")

        let entryData: Data
        do {
            entryData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        } catch {
            NSLog("%@", "[PlayTools] RuntimeLaunchDiagnostics: failed to encode \(event) — \(error.localizedDescription)")
            return
        }

        writeQueue.sync {
            do {
                let fileManager = FileManager.default
                let fileURL = diagnosticsFileURL(bundleId: resolvedBundleId)
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    _ = fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer {
                    try? handle.close()
                }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: entryData)
                try handle.write(contentsOf: Data("\n".utf8))
            } catch {
                NSLog("%@", "[PlayTools] RuntimeLaunchDiagnostics: failed to persist \(event) — \(error.localizedDescription)")
            }
        }
    }
}

/// Runtime-side bridge listener used by PlayTools inside the launched app process.
///
/// Responsibilities:
/// 1. Start a local TCP listener for host command connections.
/// 2. Register the runtime with the host on the well-known registration port.
/// 3. Keep the registration channel alive via heartbeat pings.
/// 4. Dispatch incoming commands to touch / input / capture handlers.
final class BridgeListener {

    // MARK: - Constants

    /// The well-known host registration port.
    static let defaultRegistrationPort: UInt16 = 52741
    static let shared = BridgeListener()
    private static let registrationConnectTimeout: TimeInterval = 5.0
    private static let registrationAckTimeout: TimeInterval = 5.0
    private static let registrationRetryDelay: TimeInterval = 1.0
    private static let sessionRegistrationPollIntervalMicros: useconds_t = 100_000

    private enum BridgeMessageType: String {
        case register
        case registerAck = "registerAck"
        case ping
        case pong
        case command
        case commandResponse = "commandResponse"
        case error
        case close
    }

    private enum BridgeRuntimeError: LocalizedError {
        case invalidPort(UInt16)
        case listenerStartTimeout
        case registrationTimeout
        case registrationFailed(String)
        case connectionClosed
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "Invalid bridge port: \(port)"
            case .listenerStartTimeout:
                return "Timed out waiting for bridge listener to start"
            case .registrationTimeout:
                return "Timed out waiting for bridge registration acknowledgement"
            case .registrationFailed(let message):
                return "Bridge registration failed: \(message)"
            case .connectionClosed:
                return "Bridge connection closed"
            case .missingField(let name):
                return "Bridge message missing field: \(name)"
            }
        }
    }

    // MARK: - State

    private let callbackQueue = DispatchQueue(label: "com.playcover.bridge-listener")
    private let registrationAttemptQueue = DispatchQueue(
        label: "com.playcover.bridge-listener.registration-attempt",
        qos: .userInitiated
    )
    private let lock = NSLock()

    private var commandListener: NWListener?
    private var commandConnections: [ObjectIdentifier: NWConnection] = [:]
    private var commandReadBuffers: [ObjectIdentifier: Data] = [:]

    private var registrationConnection: NWConnection?
    private var registrationReadBuffer = Data()
    private var heartbeatTimer: DispatchSourceTimer?
    private var registrationRetryTimer: DispatchSourceTimer?
    private var pendingSessionId: String?
    private var pendingBundleId: String?
    private var pendingRegistrationPort: UInt16?
    private var registrationAttemptInFlight = false

    private(set) var sessionId: String?
    private(set) var bundleId: String?
    private(set) var localPort: UInt16?
    private(set) var isRunning = false

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the bridge listener.
    ///
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the running app.
    ///   - registrationPort: The host's registration port.
    /// - Returns: The port this runtime is listening on for commands, or `0` on failure.
    @discardableResult
    func start(bundleId: String, registrationPort: UInt16 = defaultRegistrationPort) -> UInt16 {
        lock.lock()
        let existingPort = localPort
        let hasCommandListener = commandListener != nil
        let alreadyRegistered = sessionId != nil
        lock.unlock()

        if hasCommandListener, let existingPort {
            if alreadyRegistered {
                log("BridgeListener already running for \(bundleId) on port \(existingPort)")
                RuntimeLaunchDiagnostics.record(
                    event: "bridge_listener_start_reused",
                    bundleId: bundleId,
                    details: [
                        "localPort": String(existingPort),
                        "registrationState": "registered",
                    ]
                )
            } else {
                log("BridgeListener already has command listener on port \(existingPort); registration still pending, ensuring retry loop")
                RuntimeLaunchDiagnostics.record(
                    event: "bridge_listener_start_reused",
                    bundleId: bundleId,
                    details: [
                        "localPort": String(existingPort),
                        "registrationState": "pending",
                    ]
                )
                scheduleRegistrationRetry(reason: "start() called while registration pending")
            }
            return existingPort
        }

        log("BridgeListener starting for bundleId=\(bundleId), registrationPort=\(registrationPort)")
        RuntimeLaunchDiagnostics.record(
            event: "bridge_listener_starting",
            bundleId: bundleId,
            details: [
                "registrationPort": String(registrationPort),
            ]
        )

        do {
            let runtimePort = try startCommandListener()
            let runtimeSessionId = "runtime-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"

            lock.lock()
            self.bundleId = bundleId
            self.localPort = runtimePort
            self.pendingSessionId = runtimeSessionId
            self.pendingBundleId = bundleId
            self.pendingRegistrationPort = registrationPort
            self.isRunning = true
            lock.unlock()

            log("BridgeListener command listener ready on port \(runtimePort); sessionId=\(runtimeSessionId)")
            RuntimeLaunchDiagnostics.record(
                event: "bridge_listener_command_listener_ready",
                bundleId: bundleId,
                details: [
                    "localPort": String(runtimePort),
                    "sessionId": runtimeSessionId,
                ]
            )

            if !attemptRegistrationIfNeeded(trigger: "initial startup") {
                log("BridgeListener initial registration did not complete; keeping command listener alive and scheduling retries")
                RuntimeLaunchDiagnostics.record(
                    event: "bridge_registration_initial_attempt_incomplete",
                    bundleId: bundleId,
                    details: [
                        "localPort": String(runtimePort),
                        "sessionId": runtimeSessionId,
                    ]
                )
                scheduleRegistrationRetry(reason: "initial registration failed")
            }
            return runtimePort
        } catch {
            log("BridgeListener failed to start: \(error.localizedDescription)")
            RuntimeLaunchDiagnostics.record(
                event: "bridge_listener_start_failed",
                bundleId: bundleId,
                details: [
                    "error": error.localizedDescription,
                    "registrationPort": String(registrationPort),
                ]
            )
            stop()
            return 0
        }
    }

    func waitForRegisteredSession(timeout: TimeInterval) -> String? {
        lock.lock()
        if let sessionId {
            lock.unlock()
            return sessionId
        }
        let hasPendingRegistration = pendingSessionId != nil
        lock.unlock()

        guard hasPendingRegistration else {
            return nil
        }

        scheduleRegistrationRetry(reason: "host bridge request waiting for registration")
        registrationAttemptQueue.async { [weak self] in
            _ = self?.attemptRegistrationIfNeeded(trigger: "session wait")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let currentSessionId = sessionId
            let registrationStillPending = pendingSessionId != nil
            lock.unlock()

            if let currentSessionId {
                return currentSessionId
            }
            if !registrationStillPending {
                return nil
            }
            usleep(Self.sessionRegistrationPollIntervalMicros)
        }

        return nil
    }

    /// Stop the bridge listener.
    func stop() {
        lock.lock()
        let sessionId = self.sessionId
        let bundleId = self.bundleId
        let previousLocalPort = self.localPort
        let registrationConnection = self.registrationConnection
        let listener = self.commandListener
        let connections = Array(self.commandConnections.values)
        let heartbeatTimer = self.heartbeatTimer
        let registrationRetryTimer = self.registrationRetryTimer

        self.commandListener = nil
        self.commandConnections.removeAll()
        self.commandReadBuffers.removeAll()
        self.registrationConnection = nil
        self.registrationReadBuffer = Data()
        self.heartbeatTimer = nil
        self.registrationRetryTimer = nil
        self.pendingSessionId = nil
        self.pendingBundleId = nil
        self.pendingRegistrationPort = nil
        self.registrationAttemptInFlight = false
        self.localPort = nil
        self.bundleId = nil
        self.sessionId = nil
        self.isRunning = false
        lock.unlock()

        RuntimeLaunchDiagnostics.record(
            event: "bridge_listener_stopped",
            bundleId: bundleId,
            details: [
                "hadSessionId": sessionId ?? "",
                "hadLocalPort": previousLocalPort.map { String($0) } ?? "",
            ]
        )

        if let sessionId {
            sendSync(
                message: [
                    "type": BridgeMessageType.close.rawValue,
                    "sessionId": sessionId,
                    "reason": "runtime stopped",
                ],
                on: registrationConnection
            )
        }

        heartbeatTimer?.cancel()
        registrationRetryTimer?.cancel()
        registrationConnection?.cancel()
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    // MARK: - Registration

    private func connectAndRegister(
        sessionId: String,
        bundleId: String,
        registrationPort: UInt16,
        runtimePort: UInt16
    ) throws -> NWConnection {
        let host = NWEndpoint.Host("127.0.0.1")
        guard let nwPort = NWEndpoint.Port(rawValue: registrationPort) else {
            throw BridgeRuntimeError.invalidPort(registrationPort)
        }

        log("BridgeListener connecting to \(host):\(registrationPort) for sessionId=\(sessionId), runtimePort=\(runtimePort)")

        let connection = NWConnection(host: host, port: nwPort, using: .tcp)
        let readySemaphore = DispatchSemaphore(value: 0)
        var readyError: Error?

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("BridgeListener registration connection ready")
                readySemaphore.signal()
            case .failed(let error):
                self?.log("BridgeListener registration connection failed: \(error.localizedDescription)")
                readyError = error
                readySemaphore.signal()
            case .cancelled:
                self?.log("BridgeListener registration connection cancelled")
                readyError = BridgeRuntimeError.connectionClosed
                readySemaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: callbackQueue)

        if readySemaphore.wait(timeout: .now() + Self.registrationConnectTimeout) == .timedOut {
            log("BridgeListener timed out waiting for registration connection readiness")
            connection.cancel()
            throw BridgeRuntimeError.registrationTimeout
        }

        if let readyError {
            connection.cancel()
            throw readyError
        }

        let registerMessage: [String: Any] = [
            "type": BridgeMessageType.register.rawValue,
            "sessionId": sessionId,
            "bundleId": bundleId,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "runtimePort": Int(runtimePort),
        ]
        log("BridgeListener sending register message: \(registerMessage)")
        sendSync(message: registerMessage, on: connection)

        do {
            let ackMessage = try receiveSingleMessage(on: connection, timeout: Self.registrationAckTimeout)
            let ackType = stringValue("type", in: ackMessage)
            log("BridgeListener received registration response: \(ackMessage)")

            if ackType == BridgeMessageType.registerAck.rawValue {
                guard stringValue("sessionId", in: ackMessage) == sessionId else {
                    throw BridgeRuntimeError.registrationFailed("sessionId mismatch in registerAck")
                }
                let status = stringValue("status", in: ackMessage) ?? ""
                guard status == "ok" else {
                    throw BridgeRuntimeError.registrationFailed(status)
                }
                return connection
            }

            if ackType == BridgeMessageType.error.rawValue {
                let message = stringValue("message", in: ackMessage) ?? "unknown bridge error"
                throw BridgeRuntimeError.registrationFailed(message)
            }

            throw BridgeRuntimeError.registrationFailed("Unexpected registration response")
        } catch {
            connection.cancel()
            throw error
        }
    }

    private func startRegistrationReceiveLoop() {
        lock.lock()
        guard let connection = registrationConnection else {
            lock.unlock()
            return
        }
        lock.unlock()

        receiveRegistrationMessages(on: connection)
    }

    private func receiveRegistrationMessages(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if let data, !data.isEmpty {
                self.lock.lock()
                self.registrationReadBuffer.append(data)
                let (messages, remaining) = self.parseFramedMessages(self.registrationReadBuffer)
                self.registrationReadBuffer = remaining
                self.lock.unlock()

                messages.forEach(self.handleRegistrationMessage)
                self.receiveRegistrationMessages(on: connection)
                return
            }

            if isComplete || error != nil {
                let reason: String
                if let error {
                    reason = "registration channel error: \(error.localizedDescription)"
                } else {
                    reason = "registration channel closed"
                }
                self.handleRegistrationChannelDisconnect(connection: connection, reason: reason)
            }
        }
    }

    private func handleRegistrationMessage(_ message: [String: Any]) {
        guard let type = stringValue("type", in: message) else { return }

        switch type {
        case BridgeMessageType.pong.rawValue:
            break
        case BridgeMessageType.ping.rawValue:
            guard let sessionId = stringValue("sessionId", in: message) else { return }
            sendRegistrationMessage([
                "type": BridgeMessageType.pong.rawValue,
                "sessionId": sessionId,
                "timestamp": doubleValue("timestamp", in: message) ?? Date().timeIntervalSince1970,
            ])
        case BridgeMessageType.close.rawValue:
            stopHeartbeatLoop()
        case BridgeMessageType.error.rawValue:
            let text = stringValue("message", in: message) ?? "unknown"
            log("BridgeListener registration channel error: \(text)")
        default:
            break
        }
    }

    private func startHeartbeatLoop(interval: TimeInterval = 10.0) {
        stopHeartbeatLoop()

        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()

        lock.lock()
        heartbeatTimer = timer
        lock.unlock()
    }

    private func stopHeartbeatLoop() {
        lock.lock()
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func sendHeartbeat() {
        lock.lock()
        let sessionId = self.sessionId
        lock.unlock()

        guard let sessionId else { return }
        sendRegistrationMessage([
            "type": BridgeMessageType.ping.rawValue,
            "sessionId": sessionId,
            "timestamp": Date().timeIntervalSince1970,
        ])
    }

    private func sendRegistrationMessage(_ message: [String: Any]) {
        lock.lock()
        let connection = registrationConnection
        lock.unlock()
        sendSync(message: message, on: connection)
    }

    @discardableResult
    private func attemptRegistrationIfNeeded(trigger: String) -> Bool {
        lock.lock()
        if sessionId != nil {
            lock.unlock()
            return true
        }
        guard !registrationAttemptInFlight,
              commandListener != nil,
              let pendingSessionId,
              let pendingBundleId,
              let pendingRegistrationPort,
              let runtimePort = localPort else {
            lock.unlock()
            return false
        }
        registrationAttemptInFlight = true
        lock.unlock()

        defer {
            lock.lock()
            registrationAttemptInFlight = false
            lock.unlock()
        }

        do {
            log("BridgeListener attempting registration (trigger=\(trigger), sessionId=\(pendingSessionId), runtimePort=\(runtimePort))")
            RuntimeLaunchDiagnostics.record(
                event: "bridge_registration_attempt_started",
                bundleId: pendingBundleId,
                details: [
                    "trigger": trigger,
                    "sessionId": pendingSessionId,
                    "runtimePort": String(runtimePort),
                    "registrationPort": String(pendingRegistrationPort),
                ]
            )
            let connection = try connectAndRegister(
                sessionId: pendingSessionId,
                bundleId: pendingBundleId,
                registrationPort: pendingRegistrationPort,
                runtimePort: runtimePort
            )
            completeSuccessfulRegistration(
                connection: connection,
                sessionId: pendingSessionId,
                bundleId: pendingBundleId,
                runtimePort: runtimePort
            )
            return true
        } catch {
            log("BridgeListener registration attempt failed (trigger=\(trigger)): \(error.localizedDescription)")
            RuntimeLaunchDiagnostics.record(
                event: "bridge_registration_attempt_failed",
                bundleId: pendingBundleId,
                details: [
                    "trigger": trigger,
                    "sessionId": pendingSessionId,
                    "runtimePort": String(runtimePort),
                    "registrationPort": String(pendingRegistrationPort),
                    "error": error.localizedDescription,
                ]
            )
            return false
        }
    }

    private func completeSuccessfulRegistration(
        connection: NWConnection,
        sessionId: String,
        bundleId: String,
        runtimePort: UInt16
    ) {
        lock.lock()
        guard commandListener != nil,
              pendingSessionId == sessionId,
              pendingBundleId == bundleId,
              localPort == runtimePort else {
            lock.unlock()
            connection.cancel()
            return
        }
        let previousConnection = registrationConnection
        let previousRetryTimer = registrationRetryTimer
        registrationConnection = connection
        registrationReadBuffer = Data()
        registrationRetryTimer = nil
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.localPort = runtimePort
        self.isRunning = true
        lock.unlock()

        previousRetryTimer?.cancel()
        previousConnection?.cancel()
        startRegistrationReceiveLoop()
        startHeartbeatLoop()
        RuntimeLaunchDiagnostics.record(
            event: "bridge_registration_established",
            bundleId: bundleId,
            details: [
                "sessionId": sessionId,
                "runtimePort": String(runtimePort),
            ]
        )
        log("BridgeListener registration established for \(bundleId) on port \(runtimePort)")
    }

    private func scheduleRegistrationRetry(reason: String) {
        lock.lock()
        guard sessionId == nil,
              commandListener != nil,
              pendingSessionId != nil,
              pendingBundleId != nil,
              pendingRegistrationPort != nil,
              localPort != nil else {
            lock.unlock()
            return
        }
        if registrationRetryTimer != nil {
            lock.unlock()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + Self.registrationRetryDelay, repeating: Self.registrationRetryDelay)
        timer.setEventHandler { [weak self] in
            self?.registrationAttemptQueue.async {
                _ = self?.attemptRegistrationIfNeeded(trigger: "retry timer")
            }
        }
        registrationRetryTimer = timer
        lock.unlock()

        timer.resume()
        RuntimeLaunchDiagnostics.record(
            event: "bridge_registration_retry_scheduled",
            bundleId: pendingBundleId,
            details: [
                "reason": reason,
                "sessionId": pendingSessionId ?? "",
                "runtimePort": localPort.map { String($0) } ?? "",
            ]
        )
        log("BridgeListener scheduled registration retry: \(reason)")
    }

    private func handleRegistrationChannelDisconnect(connection: NWConnection, reason: String) {
        lock.lock()
        guard registrationConnection === connection else {
            lock.unlock()
            return
        }
        let heartbeatTimer = self.heartbeatTimer
        registrationConnection = nil
        registrationReadBuffer = Data()
        self.heartbeatTimer = nil
        sessionId = nil
        let shouldRetry = commandListener != nil
            && pendingSessionId != nil
            && pendingBundleId != nil
            && pendingRegistrationPort != nil
            && localPort != nil
        lock.unlock()

        heartbeatTimer?.cancel()
        RuntimeLaunchDiagnostics.record(
            event: "bridge_registration_channel_lost",
            bundleId: bundleId,
            details: [
                "reason": reason,
                "shouldRetry": shouldRetry ? "true" : "false",
            ]
        )
        log("BridgeListener lost registration channel: \(reason)")

        if shouldRetry {
            scheduleRegistrationRetry(reason: reason)
        }
    }

    // MARK: - Command Listener

    private func startCommandListener() throws -> UInt16 {
        guard let anyPort = NWEndpoint.Port(rawValue: 0) else {
            throw BridgeRuntimeError.invalidPort(0)
        }

        let listener = try NWListener(using: .tcp, on: anyPort)
        let readySemaphore = DispatchSemaphore(value: 0)
        var localPort: UInt16?
        var listenerError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                localPort = listener.port?.rawValue
                readySemaphore.signal()
            case .failed(let error):
                listenerError = error
                readySemaphore.signal()
            case .cancelled:
                if listenerError == nil && localPort == nil {
                    listenerError = BridgeRuntimeError.connectionClosed
                    readySemaphore.signal()
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleCommandConnection(connection)
        }

        listener.start(queue: callbackQueue)

        if readySemaphore.wait(timeout: .now() + 2.0) == .timedOut {
            listener.cancel()
            throw BridgeRuntimeError.listenerStartTimeout
        }

        if let listenerError {
            listener.cancel()
            throw listenerError
        }

        guard let localPort else {
            listener.cancel()
            throw BridgeRuntimeError.listenerStartTimeout
        }

        lock.lock()
        commandListener = listener
        self.localPort = localPort
        lock.unlock()

        return localPort
    }

    private func handleCommandConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)

        lock.lock()
        commandConnections[connectionId] = connection
        commandReadBuffers[connectionId] = Data()
        lock.unlock()

        connection.start(queue: callbackQueue)
        receiveCommandMessages(on: connection)
    }

    private func receiveCommandMessages(on connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }

            if let data, !data.isEmpty {
                self.lock.lock()
                self.commandReadBuffers[connectionId, default: Data()].append(data)
                let buffer = self.commandReadBuffers[connectionId] ?? Data()
                let (messages, remaining) = self.parseFramedMessages(buffer)
                self.commandReadBuffers[connectionId] = remaining
                self.lock.unlock()

                for message in messages {
                    self.handleCommandMessage(message, connection: connection)
                }

                self.receiveCommandMessages(on: connection)
                return
            }

            if isComplete || error != nil {
                self.removeCommandConnection(connection)
                connection.cancel()
            }
        }
    }

    private func handleCommandMessage(_ message: [String: Any], connection: NWConnection) {
        guard let type = stringValue("type", in: message) else {
            sendSync(message: errorMessage(message: "Missing message type"), on: connection)
            return
        }

        switch type {
        case BridgeMessageType.command.rawValue:
            guard
                let sessionId = stringValue("sessionId", in: message),
                let commandId = stringValue("commandId", in: message),
                let command = stringValue("command", in: message)
            else {
                sendSync(message: errorMessage(message: "Malformed command payload"), on: connection)
                return
            }

            let params = message["params"] as? [String: Any]
            let response = handleCommand(command, params: params)
            sendSync(
                message: [
                    "type": BridgeMessageType.commandResponse.rawValue,
                    "sessionId": sessionId,
                    "commandId": commandId,
                    "status": response.status,
                    "result": response.result ?? [:],
                ],
                on: connection
            )

        case BridgeMessageType.ping.rawValue:
            guard let sessionId = stringValue("sessionId", in: message) else {
                sendSync(message: errorMessage(message: "Ping missing sessionId"), on: connection)
                return
            }
            sendSync(
                message: [
                    "type": BridgeMessageType.pong.rawValue,
                    "sessionId": sessionId,
                    "timestamp": doubleValue("timestamp", in: message) ?? Date().timeIntervalSince1970,
                ],
                on: connection
            )

        case BridgeMessageType.close.rawValue:
            let sessionId = stringValue("sessionId", in: message) ?? (self.sessionId ?? "unknown")
            sendSync(
                message: [
                    "type": BridgeMessageType.close.rawValue,
                    "sessionId": sessionId,
                    "reason": "acknowledged",
                ],
                on: connection
            )
            removeCommandConnection(connection)
            connection.cancel()

        default:
            sendSync(message: errorMessage(message: "Unsupported command channel message: \(type)"), on: connection)
        }
    }

    private func removeCommandConnection(_ connection: NWConnection) {
        let connectionId = ObjectIdentifier(connection)
        lock.lock()
        commandConnections.removeValue(forKey: connectionId)
        commandReadBuffers.removeValue(forKey: connectionId)
        lock.unlock()
    }

    // MARK: - Command Dispatch

    /// Handle an incoming command from the host.
    private func handleCommand(_ command: String, params: [String: Any]?) -> (status: String, result: [String: Any]?) {
        switch command {
        case "tap":
            guard let x = doubleValue("x", in: params), let y = doubleValue("y", in: params) else {
                return errorResult("tap requires numeric 'x' and 'y' parameters")
            }
            return performTap(at: CGPoint(x: x, y: y))

        case "long_press":
            guard let x = doubleValue("x", in: params), let y = doubleValue("y", in: params) else {
                return errorResult("long_press requires numeric 'x' and 'y' parameters")
            }
            let durationMs = intValue("durationMs", in: params) ?? 500
            return performLongPress(at: CGPoint(x: x, y: y), durationMs: durationMs)

        case "swipe":
            guard
                let startX = doubleValue("startX", in: params),
                let startY = doubleValue("startY", in: params),
                let endX = doubleValue("endX", in: params),
                let endY = doubleValue("endY", in: params)
            else {
                return errorResult("swipe requires startX, startY, endX, endY parameters")
            }
            let durationMs = intValue("durationMs", in: params) ?? 300
            let steps = max(2, intValue("steps", in: params) ?? 10)
            return performSwipe(
                commandName: "swipe",
                start: CGPoint(x: startX, y: startY),
                end: CGPoint(x: endX, y: endY),
                durationMs: durationMs,
                steps: steps,
                holdDelayMs: 0
            )

        case "drag":
            guard
                let startX = doubleValue("startX", in: params),
                let startY = doubleValue("startY", in: params),
                let endX = doubleValue("endX", in: params),
                let endY = doubleValue("endY", in: params)
            else {
                return errorResult("drag requires startX, startY, endX, endY parameters")
            }
            let durationMs = intValue("durationMs", in: params) ?? 500
            let holdDelayMs = intValue("holdDelayMs", in: params) ?? 100
            let steps = max(2, intValue("steps", in: params) ?? 10)
            return performSwipe(
                commandName: "drag",
                start: CGPoint(x: startX, y: startY),
                end: CGPoint(x: endX, y: endY),
                durationMs: durationMs,
                steps: steps,
                holdDelayMs: holdDelayMs
            )

        case "press_key":
            guard let key = stringValue("key", in: params), !key.isEmpty else {
                return errorResult("press_key requires a 'key' parameter")
            }
            let modifiers = stringArrayValue("modifiers", in: params)
            return handlePressKey(key: key, modifiers: modifiers)

        case "type_text":
            guard let text = stringValue("text", in: params), !text.isEmpty else {
                return errorResult("type_text requires a 'text' parameter")
            }
            let delivered = valueOnMainSync {
                UIApplication.shared.sendAction(NSSelectorFromString("insertText:"), to: nil, from: text, for: nil)
            }
            return ("ok", ["length": text.count, "delivered": delivered])

        case "toggle_debug_overlay":
            executeOnMainSync {
                DebugController.instance.toggleDebugOverlay()
            }
            return ("ok", ["toggled": true])

        case "capture_frame":
            let outputPath = stringValue("output_path", in: params)
            let outputURL = outputPath.map(URL.init(fileURLWithPath:))
            let durationMs = intValue("duration_ms", in: params) ?? 100
            let captureTarget = stringValue("capture_target", in: params)
            let result = valueOnMainSync {
                MetalCaptureService.shared.captureFrame(
                    outputURL: outputURL,
                    durationMs: durationMs,
                    captureTargetRawValue: captureTarget
                )
            }

            if result.success {
                return ("ok", [
                    "output_path": result.outputPath ?? "",
                    "message": result.message,
                ])
            }
            return errorResult(result.message)

        case "get_capture_status":
            log("BridgeListener get_capture_status begin; querying runtime status without forcing main thread")
            let status = MetalCaptureService.shared.getStatus(allowLazyLoad: false)
            log("BridgeListener get_capture_status completed; onMain=\(Thread.isMainThread). \(status.diagnosticSummary)")
            var result: [String: Any] = [
                "available": status.available,
                "supports_gpu_trace": status.supportsGPUTrace,
                "supports_developer_tools": status.supportsDeveloperTools,
                "has_default_device": status.hasDefaultDevice,
                "is_capturing": status.isCapturing,
                "enabled": status.enabled,
                "diagnostic_summary": status.diagnosticSummary,
                "queue_discovery_installed": status.queueDiscoveryInstalled,
                "tracked_command_queue_count": status.trackedCommandQueueCount,
            ]
            if let defaultDeviceName = status.defaultDeviceName {
                result["default_device_name"] = defaultDeviceName
            }
            if let failureReason = status.failureReason {
                result["failure_reason"] = failureReason
            }
            if let latestCommandQueueLabel = status.latestCommandQueueLabel {
                result["latest_command_queue_label"] = latestCommandQueueLabel
            }
            if let latestCommandQueueDeviceName = status.latestCommandQueueDeviceName {
                result["latest_command_queue_device_name"] = latestCommandQueueDeviceName
            }
            if let latestCommandQueueClassName = status.latestCommandQueueClassName {
                result["latest_command_queue_class_name"] = latestCommandQueueClassName
            }
            if let defaultCaptureScopeLabel = status.defaultCaptureScopeLabel {
                result["default_capture_scope_label"] = defaultCaptureScopeLabel
            }
            return ("ok", result)

        default:
            return errorResult("Unknown command: \(command)")
        }
    }

    private func performTap(at point: CGPoint) -> (status: String, result: [String: Any]?) {
        executeOnMainSync {
            var touchId: Int?
            Toucher.touchcam(point: point, phase: .began, tid: &touchId, actionName: "bridge", keyName: "tap")
            Toucher.touchcam(point: point, phase: .ended, tid: &touchId, actionName: "bridge", keyName: "tap")
        }
        return ("ok", [
            "success": true,
            "command": "tap",
            "x": Double(point.x),
            "y": Double(point.y),
        ])
    }

    private func performLongPress(at point: CGPoint, durationMs: Int) -> (status: String, result: [String: Any]?) {
        var touchId: Int?
        executeOnMainSync {
            Toucher.touchcam(point: point, phase: .began, tid: &touchId, actionName: "bridge", keyName: "long_press")
        }
        sleepFor(milliseconds: durationMs)
        executeOnMainSync {
            Toucher.touchcam(point: point, phase: .ended, tid: &touchId, actionName: "bridge", keyName: "long_press")
        }
        return ("ok", [
            "success": true,
            "command": "long_press",
            "x": Double(point.x),
            "y": Double(point.y),
            "durationMs": durationMs,
        ])
    }

    private func performSwipe(
        commandName: String,
        start: CGPoint,
        end: CGPoint,
        durationMs: Int,
        steps: Int,
        holdDelayMs: Int
    ) -> (status: String, result: [String: Any]?) {
        var touchId: Int?

        executeOnMainSync {
            Toucher.touchcam(point: start, phase: .began, tid: &touchId, actionName: "bridge", keyName: commandName)
        }

        if holdDelayMs > 0 {
            sleepFor(milliseconds: holdDelayMs)
        }

        let clampedSteps = max(2, steps)
        let stepDelayMs = clampedSteps > 0 ? max(1, durationMs / clampedSteps) : 1

        for step in 1...clampedSteps {
            sleepFor(milliseconds: stepDelayMs)
            let progress = Double(step) / Double(clampedSteps)
            let point = CGPoint(
                x: start.x + CGFloat(progress) * (end.x - start.x),
                y: start.y + CGFloat(progress) * (end.y - start.y)
            )
            let phase: UITouch.Phase = step == clampedSteps ? .ended : .moved
            executeOnMainSync {
                Toucher.touchcam(point: point, phase: phase, tid: &touchId, actionName: "bridge", keyName: commandName)
            }
        }

        return ("ok", [
            "success": true,
            "command": commandName,
            "startX": Double(start.x),
            "startY": Double(start.y),
            "endX": Double(end.x),
            "endY": Double(end.y),
            "durationMs": durationMs,
            "steps": clampedSteps,
            "holdDelayMs": holdDelayMs,
        ])
    }

    private func handlePressKey(key: String, modifiers: [String]) -> (status: String, result: [String: Any]?) {
        let normalizedKey = key.lowercased()

        if modifiers.isEmpty {
            let delivered = valueOnMainSync {
                switch normalizedKey {
                case "space":
                    return UIApplication.shared.sendAction(NSSelectorFromString("insertText:"), to: nil, from: " ", for: nil)
                case "enter", "return":
                    return UIApplication.shared.sendAction(NSSelectorFromString("insertText:"), to: nil, from: "\n", for: nil)
                case "tab":
                    return UIApplication.shared.sendAction(NSSelectorFromString("insertText:"), to: nil, from: "\t", for: nil)
                case "backspace", "delete":
                    return UIApplication.shared.sendAction(NSSelectorFromString("deleteBackward"), to: nil, from: nil, for: nil)
                default:
                    if key.count == 1 {
                        return UIApplication.shared.sendAction(NSSelectorFromString("insertText:"), to: nil, from: key, for: nil)
                    }
                    return false
                }
            }

            return ("ok", [
                "key": key,
                "modifiers": modifiers,
                "delivered": delivered,
            ])
        }

        // Rich modifier-based key synthesis is not wired yet, but the runtime can still
        // acknowledge the command so the bridge protocol and session path remain usable.
        return ("ok", [
            "key": key,
            "modifiers": modifiers,
            "delivered": false,
        ])
    }

    // MARK: - Message Helpers

    private func sendSync(message: [String: Any], on connection: NWConnection?) {
        guard let connection else { return }
        guard let framedData = try? frame(message: message) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: framedData, completion: .contentProcessed { _ in
            semaphore.signal()
        })
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    private func frame(message: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        var framed = data
        framed.append("\n".data(using: .utf8)!)
        return framed
    }

    private func receiveSingleMessage(on connection: NWConnection, timeout: TimeInterval) throws -> [String: Any] {
        var localBuffer = Data()
        let semaphore = DispatchSemaphore(value: 0)
        var receivedMessage: [String: Any]?
        var receiveError: Error?

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else {
                    receiveError = BridgeRuntimeError.connectionClosed
                    semaphore.signal()
                    return
                }

                if let data, !data.isEmpty {
                    localBuffer.append(data)
                    let (messages, remaining) = self.parseFramedMessages(localBuffer)
                    localBuffer = remaining
                    if let first = messages.first {
                        receivedMessage = first
                        semaphore.signal()
                    } else {
                        receiveNextChunk()
                    }
                    return
                }

                if let error {
                    receiveError = error
                } else if isComplete {
                    receiveError = BridgeRuntimeError.connectionClosed
                }
                semaphore.signal()
            }
        }

        receiveNextChunk()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw BridgeRuntimeError.registrationTimeout
        }

        if let receiveError {
            throw receiveError
        }

        lock.lock()
        registrationReadBuffer = localBuffer
        lock.unlock()

        if let receivedMessage {
            return receivedMessage
        }
        throw BridgeRuntimeError.registrationFailed("No registration response received")
    }

    private func parseFramedMessages(_ data: Data) -> ([[String: Any]], Data) {
        var messages: [[String: Any]] = []
        var remaining = data
        let newline = Data("\n".utf8)

        while let newlineRange = remaining.range(of: newline) {
            let line = Data(remaining[..<newlineRange.lowerBound])
            remaining = Data(remaining[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: line, options: []),
               let dictionary = object as? [String: Any] {
                messages.append(dictionary)
            }
        }

        return (messages, remaining)
    }

    private func errorMessage(message: String) -> [String: Any] {
        var payload: [String: Any] = [
            "type": BridgeMessageType.error.rawValue,
            "code": -1,
            "message": message,
        ]

        lock.lock()
        if let sessionId {
            payload["sessionId"] = sessionId
        }
        lock.unlock()

        return payload
    }

    private func errorResult(_ message: String) -> (status: String, result: [String: Any]?) {
        ("error", ["message": message])
    }

    private func log(_ message: String) {
        NSLog("%@", "[PlayTools] \(message)")
    }

    // MARK: - Value Helpers

    private func stringValue(_ key: String, in dictionary: [String: Any]?) -> String? {
        dictionary?[key] as? String
    }

    private func stringArrayValue(_ key: String, in dictionary: [String: Any]?) -> [String] {
        if let values = dictionary?[key] as? [String] {
            return values
        }
        if let values = dictionary?[key] as? [Any] {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private func doubleValue(_ key: String, in dictionary: [String: Any]?) -> Double? {
        if let value = dictionary?[key] as? Double {
            return value
        }
        if let value = dictionary?[key] as? Int {
            return Double(value)
        }
        if let value = dictionary?[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private func intValue(_ key: String, in dictionary: [String: Any]?) -> Int? {
        if let value = dictionary?[key] as? Int {
            return value
        }
        if let value = dictionary?[key] as? Double {
            return Int(value)
        }
        if let value = dictionary?[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    // MARK: - Threading Helpers

    private func executeOnMainSync(_ work: () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func valueOnMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private func sleepFor(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000.0)
    }
}
