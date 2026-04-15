// CaptureService.swift
// PlayCoverMCP

import Foundation

public struct TrackedCommandQueueActivityResult: Codable, Equatable, Sendable {
    public let source: String
    public let className: String
    public let label: String?
    public let deviceName: String
    public let firstSeenAt: String?
    public let lastSeenAt: String?
    public let discoveryCount: Int
    public let rankingScore: Int
    public let commandBufferCreationCount: Int
    public let commandBufferCommitCount: Int
    public let firstActivityAt: String?
    public let lastActivityAt: String?
    public let activityScore: Int
    public let lastCommandBufferClassName: String?
    public let summary: String?
    public let activitySummary: String?

    public init(
        source: String,
        className: String,
        label: String? = nil,
        deviceName: String,
        firstSeenAt: String? = nil,
        lastSeenAt: String? = nil,
        discoveryCount: Int,
        rankingScore: Int,
        commandBufferCreationCount: Int,
        commandBufferCommitCount: Int,
        firstActivityAt: String? = nil,
        lastActivityAt: String? = nil,
        activityScore: Int,
        lastCommandBufferClassName: String? = nil,
        summary: String? = nil,
        activitySummary: String? = nil
    ) {
        self.source = source
        self.className = className
        self.label = label
        self.deviceName = deviceName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.discoveryCount = discoveryCount
        self.rankingScore = rankingScore
        self.commandBufferCreationCount = commandBufferCreationCount
        self.commandBufferCommitCount = commandBufferCommitCount
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.activityScore = activityScore
        self.lastCommandBufferClassName = lastCommandBufferClassName
        self.summary = summary
        self.activitySummary = activitySummary
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "source": source,
            "class_name": className,
            "device_name": deviceName,
            "discovery_count": discoveryCount,
            "ranking_score": rankingScore,
            "command_buffer_creation_count": commandBufferCreationCount,
            "command_buffer_commit_count": commandBufferCommitCount,
            "activity_score": activityScore,
        ]
        if let label {
            dict["label"] = label
        }
        if let firstSeenAt {
            dict["first_seen_at"] = firstSeenAt
        }
        if let lastSeenAt {
            dict["last_seen_at"] = lastSeenAt
        }
        if let firstActivityAt {
            dict["first_activity_at"] = firstActivityAt
        }
        if let lastActivityAt {
            dict["last_activity_at"] = lastActivityAt
        }
        if let lastCommandBufferClassName {
            dict["last_command_buffer_class_name"] = lastCommandBufferClassName
        }
        if let summary {
            dict["summary"] = summary
        }
        if let activitySummary {
            dict["activity_summary"] = activitySummary
        }
        return dict
    }
}

// MARK: - Capture Command Parameters

public enum CaptureTarget: String, Codable, Equatable, Sendable {
    /// Capture all queues on the runtime-visible default Metal device.
    case device
    /// Capture through a temporary MTLCaptureScope bound to the default Metal device.
    case scope
    /// Capture the most recently discovered real runtime MTLCommandQueue.
    case queue
    /// Capture through a temporary MTLCaptureScope bound to the most recently discovered real runtime MTLCommandQueue.
    case queueScope = "queue_scope"
}

/// Parameters for a capture_metal_frame command.
public struct CaptureFrameParams: Codable, Equatable, Sendable {
    /// Optional custom output path for the .gputrace file.
    public let outputPath: String?
    /// Capture duration in milliseconds (default: 100, enough for 1-2 frames at 60fps).
    public let durationMs: Int
    /// Which capture target strategy to use for the runtime experiment. Defaults to queue_scope.
    public let captureTarget: CaptureTarget

    public init(
        outputPath: String? = nil,
        durationMs: Int = 100,
        captureTarget: CaptureTarget = .queueScope
    ) {
        self.outputPath = outputPath
        self.durationMs = durationMs
        self.captureTarget = captureTarget
    }
}

/// Result returned after a capture_metal_frame command completes.
public struct CaptureFrameResult: Codable, Equatable, Sendable {
    /// Whether the capture was initiated successfully.
    public let success: Bool
    /// The actual output path of the .gputrace file.
    public let outputPath: String?
    /// Human-readable status message.
    public let message: String

    public init(success: Bool, outputPath: String? = nil, message: String) {
        self.success = success
        self.outputPath = outputPath
        self.message = message
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "success": success,
            "message": message,
        ]
        if let outputPath = outputPath {
            dict["output_path"] = outputPath
        }
        return dict
    }
}

/// Result returned after a get_capture_status command completes.
public struct CaptureStatusResult: Codable, Equatable, Sendable {
    /// Whether MTLCaptureManager is accessible.
    public let available: Bool
    /// Whether .gpuTraceDocument destination is supported.
    public let supportsGpuTrace: Bool
    /// Whether a capture is currently in progress.
    public let isCapturing: Bool
    /// Whether metalCaptureEnabled is ON in settings.
    public let enabled: Bool
    /// Whether capture can stream to Xcode / developer tools even if gpuTrace export is unavailable.
    public let supportsDeveloperTools: Bool?
    /// Whether a default Metal device is currently visible to the runtime process.
    public let hasDefaultDevice: Bool?
    /// The runtime-visible default Metal device name, if any.
    public let defaultDeviceName: String?
    /// A stable reason code describing why capture is not currently ready.
    public let failureReason: String?
    /// Human-readable flattened diagnostics for quick investigation.
    public let diagnosticSummary: String?
    /// Whether runtime-side command queue discovery hooks were installed.
    public let queueDiscoveryInstalled: Bool?
    /// Number of runtime command queues currently tracked.
    public let trackedCommandQueueCount: Int?
    /// Label of the latest tracked command queue, if any.
    public let latestCommandQueueLabel: String?
    /// Device name of the latest tracked command queue, if any.
    public let latestCommandQueueDeviceName: String?
    /// Concrete runtime class name of the latest tracked command queue, if any.
    public let latestCommandQueueClassName: String?
    /// Label of the queue currently preferred by runtime ranking, if any.
    public let preferredCommandQueueLabel: String?
    /// Device name of the queue currently preferred by runtime ranking, if any.
    public let preferredCommandQueueDeviceName: String?
    /// Concrete runtime class name of the queue currently preferred by runtime ranking, if any.
    public let preferredCommandQueueClassName: String?
    /// Human-readable summary of the queue currently preferred by runtime ranking, if any.
    public let preferredCommandQueueSummary: String?
    /// Label of MTLCaptureManager.defaultCaptureScope, if any.
    public let defaultCaptureScopeLabel: String?
    /// Label of the queue with strongest command-buffer activity, if any.
    public let mostActiveCommandQueueLabel: String?
    /// Device name of the queue with strongest command-buffer activity, if any.
    public let mostActiveCommandQueueDeviceName: String?
    /// Concrete runtime class name of the queue with strongest command-buffer activity, if any.
    public let mostActiveCommandQueueClassName: String?
    /// Human-readable summary of the strongest activity queue, if any.
    public let mostActiveCommandQueueSummary: String?
    /// Whether preferred queue selection currently matches the most-active queue identity.
    public let queueSelectionAlignment: String?
    /// Per-queue runtime activity snapshots ordered by activity strength.
    public let trackedCommandQueues: [TrackedCommandQueueActivityResult]?

    public init(
        available: Bool,
        supportsGpuTrace: Bool,
        isCapturing: Bool,
        enabled: Bool,
        supportsDeveloperTools: Bool? = nil,
        hasDefaultDevice: Bool? = nil,
        defaultDeviceName: String? = nil,
        failureReason: String? = nil,
        diagnosticSummary: String? = nil,
        queueDiscoveryInstalled: Bool? = nil,
        trackedCommandQueueCount: Int? = nil,
        latestCommandQueueLabel: String? = nil,
        latestCommandQueueDeviceName: String? = nil,
        latestCommandQueueClassName: String? = nil,
        preferredCommandQueueLabel: String? = nil,
        preferredCommandQueueDeviceName: String? = nil,
        preferredCommandQueueClassName: String? = nil,
        preferredCommandQueueSummary: String? = nil,
        defaultCaptureScopeLabel: String? = nil,
        mostActiveCommandQueueLabel: String? = nil,
        mostActiveCommandQueueDeviceName: String? = nil,
        mostActiveCommandQueueClassName: String? = nil,
        mostActiveCommandQueueSummary: String? = nil,
        queueSelectionAlignment: String? = nil,
        trackedCommandQueues: [TrackedCommandQueueActivityResult]? = nil
    ) {
        self.available = available
        self.supportsGpuTrace = supportsGpuTrace
        self.isCapturing = isCapturing
        self.enabled = enabled
        self.supportsDeveloperTools = supportsDeveloperTools
        self.hasDefaultDevice = hasDefaultDevice
        self.defaultDeviceName = defaultDeviceName
        self.failureReason = failureReason
        self.diagnosticSummary = diagnosticSummary
        self.queueDiscoveryInstalled = queueDiscoveryInstalled
        self.trackedCommandQueueCount = trackedCommandQueueCount
        self.latestCommandQueueLabel = latestCommandQueueLabel
        self.latestCommandQueueDeviceName = latestCommandQueueDeviceName
        self.latestCommandQueueClassName = latestCommandQueueClassName
        self.preferredCommandQueueLabel = preferredCommandQueueLabel
        self.preferredCommandQueueDeviceName = preferredCommandQueueDeviceName
        self.preferredCommandQueueClassName = preferredCommandQueueClassName
        self.preferredCommandQueueSummary = preferredCommandQueueSummary
        self.defaultCaptureScopeLabel = defaultCaptureScopeLabel
        self.mostActiveCommandQueueLabel = mostActiveCommandQueueLabel
        self.mostActiveCommandQueueDeviceName = mostActiveCommandQueueDeviceName
        self.mostActiveCommandQueueClassName = mostActiveCommandQueueClassName
        self.mostActiveCommandQueueSummary = mostActiveCommandQueueSummary
        self.queueSelectionAlignment = queueSelectionAlignment
        self.trackedCommandQueues = trackedCommandQueues
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "available": available,
            "supports_gpu_trace": supportsGpuTrace,
            "is_capturing": isCapturing,
            "enabled": enabled,
        ]
        if let supportsDeveloperTools {
            dict["supports_developer_tools"] = supportsDeveloperTools
        }
        if let hasDefaultDevice {
            dict["has_default_device"] = hasDefaultDevice
        }
        if let defaultDeviceName {
            dict["default_device_name"] = defaultDeviceName
        }
        if let failureReason {
            dict["failure_reason"] = failureReason
        }
        if let diagnosticSummary {
            dict["diagnostic_summary"] = diagnosticSummary
        }
        if let queueDiscoveryInstalled {
            dict["queue_discovery_installed"] = queueDiscoveryInstalled
        }
        if let trackedCommandQueueCount {
            dict["tracked_command_queue_count"] = trackedCommandQueueCount
        }
        if let latestCommandQueueLabel {
            dict["latest_command_queue_label"] = latestCommandQueueLabel
        }
        if let latestCommandQueueDeviceName {
            dict["latest_command_queue_device_name"] = latestCommandQueueDeviceName
        }
        if let latestCommandQueueClassName {
            dict["latest_command_queue_class_name"] = latestCommandQueueClassName
        }
        if let preferredCommandQueueLabel {
            dict["preferred_command_queue_label"] = preferredCommandQueueLabel
        }
        if let preferredCommandQueueDeviceName {
            dict["preferred_command_queue_device_name"] = preferredCommandQueueDeviceName
        }
        if let preferredCommandQueueClassName {
            dict["preferred_command_queue_class_name"] = preferredCommandQueueClassName
        }
        if let preferredCommandQueueSummary {
            dict["preferred_command_queue_summary"] = preferredCommandQueueSummary
        }
        if let defaultCaptureScopeLabel {
            dict["default_capture_scope_label"] = defaultCaptureScopeLabel
        }
        if let mostActiveCommandQueueLabel {
            dict["most_active_command_queue_label"] = mostActiveCommandQueueLabel
        }
        if let mostActiveCommandQueueDeviceName {
            dict["most_active_command_queue_device_name"] = mostActiveCommandQueueDeviceName
        }
        if let mostActiveCommandQueueClassName {
            dict["most_active_command_queue_class_name"] = mostActiveCommandQueueClassName
        }
        if let mostActiveCommandQueueSummary {
            dict["most_active_command_queue_summary"] = mostActiveCommandQueueSummary
        }
        if let queueSelectionAlignment {
            dict["queue_selection_alignment"] = queueSelectionAlignment
        }
        if let trackedCommandQueues {
            dict["tracked_command_queues"] = trackedCommandQueues.map { $0.toDictionary() }
        }
        return dict
    }
}

// MARK: - Capture Error

/// Errors specific to capture commands.
public enum CaptureError: Error, LocalizedError, Equatable {
    case invalidDuration(String)
    case sessionNotReady(String)
    case commandFailed(String)
    case captureNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDuration(let detail): return "Invalid capture duration: \(detail)"
        case .sessionNotReady(let detail): return "Session not ready for capture: \(detail)"
        case .commandFailed(let detail): return "Capture command failed: \(detail)"
        case .captureNotAvailable(let detail): return "Metal capture not available: \(detail)"
        }
    }
}

// MARK: - Capture Service Protocol

/// Protocol for capture services, enabling fake implementations for testing.
public protocol CaptureServiceProtocol {
    func captureFrame(sessionId: String, params: CaptureFrameParams) async throws -> CaptureFrameResult
    func getCaptureStatus(sessionId: String) async throws -> CaptureStatusResult
}

// MARK: - Capture Service

/// Service that sends Metal capture commands to a runtime through the bridge.
///
/// The service validates parameters, then sends capture commands through a
/// `BridgeClient` connected to the session's runtime port.
public final class CaptureService: CaptureServiceProtocol, Sendable {

    // MARK: - Dependencies

    private let registry: SessionRegistry
    private let clientFactory: (String, UInt16) -> BridgeClient

    // MARK: - Init

    public init(
        registry: SessionRegistry,
        clientFactory: @escaping (String, UInt16) -> BridgeClient = { sessionId, port in
            BridgeClient(sessionId: sessionId, port: port)
        }
    ) {
        self.registry = registry
        self.clientFactory = clientFactory
    }

    // MARK: - Capture Frame

    /// Trigger a one-frame GPU capture on the target app.
    ///
    /// - Parameters:
    ///   - sessionId: The target session identifier.
    ///   - params: Capture parameters (optional output path, duration).
    /// - Returns: A `CaptureFrameResult` describing the outcome.
    /// - Throws: `CaptureError` or `BridgeProtocolError`.
    public func captureFrame(sessionId: String, params: CaptureFrameParams) async throws -> CaptureFrameResult {
        try validateDuration(params.durationMs)

        let session = try getReadySession(sessionId)

        var bridgeDict: [String: Any] = [
            "duration_ms": params.durationMs,
            "capture_target": params.captureTarget.rawValue,
        ]
        if let outputPath = params.outputPath {
            bridgeDict["output_path"] = outputPath
        }
        let bridgeParams = AnyCodable(bridgeDict)

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        // Allow time for capture duration plus buffer
        let timeoutSec = Double(params.durationMs) / 1000.0 + 10.0
        let response = try await client.sendCommand(
            BridgeCommandName.captureFrame,
            params: bridgeParams,
            timeout: timeoutSec
        )

        // Extract result from response
        let resultDict = response.result?.dictionary
        let outputPath = resultDict?["output_path"] as? String
        let message = resultDict?["message"] as? String ?? "Capture completed"

        return CaptureFrameResult(
            success: true,
            outputPath: outputPath,
            message: message
        )
    }

    // MARK: - Get Capture Status

    /// Query the Metal capture status for the target app.
    ///
    /// - Parameter sessionId: The target session identifier.
    /// - Returns: A `CaptureStatusResult` describing the current status.
    /// - Throws: `CaptureError` or `BridgeProtocolError`.
    public func getCaptureStatus(sessionId: String) async throws -> CaptureStatusResult {
        let session = try getReadySession(sessionId)

        let client = clientFactory(sessionId, session.runtimePort)
        defer { client.close() }
        try await client.connect(timeout: 5.0)

        let response = try await client.sendCommand(
            BridgeCommandName.getCaptureStatus,
            timeout: 5.0
        )

        // Extract status fields from response
        let resultDict = response.result?.dictionary
        let available = resultDict?["available"] as? Bool ?? false
        let supportsGpuTrace = resultDict?["supports_gpu_trace"] as? Bool ?? false
        let isCapturing = resultDict?["is_capturing"] as? Bool ?? false
        let enabled = resultDict?["enabled"] as? Bool ?? false
        let supportsDeveloperTools = resultDict?["supports_developer_tools"] as? Bool
        let hasDefaultDevice = resultDict?["has_default_device"] as? Bool
        let defaultDeviceName = resultDict?["default_device_name"] as? String
        let failureReason = resultDict?["failure_reason"] as? String
        let diagnosticSummary = resultDict?["diagnostic_summary"] as? String
        let queueDiscoveryInstalled = resultDict?["queue_discovery_installed"] as? Bool
        let trackedCommandQueueCount = resultDict?["tracked_command_queue_count"] as? Int
        let latestCommandQueueLabel = resultDict?["latest_command_queue_label"] as? String
        let latestCommandQueueDeviceName = resultDict?["latest_command_queue_device_name"] as? String
        let latestCommandQueueClassName = resultDict?["latest_command_queue_class_name"] as? String
        let preferredCommandQueueLabel = resultDict?["preferred_command_queue_label"] as? String
        let preferredCommandQueueDeviceName = resultDict?["preferred_command_queue_device_name"] as? String
        let preferredCommandQueueClassName = resultDict?["preferred_command_queue_class_name"] as? String
        let preferredCommandQueueSummary = resultDict?["preferred_command_queue_summary"] as? String
        let defaultCaptureScopeLabel = resultDict?["default_capture_scope_label"] as? String
        let mostActiveCommandQueueLabel = resultDict?["most_active_command_queue_label"] as? String
        let mostActiveCommandQueueDeviceName = resultDict?["most_active_command_queue_device_name"] as? String
        let mostActiveCommandQueueClassName = resultDict?["most_active_command_queue_class_name"] as? String
        let mostActiveCommandQueueSummary = resultDict?["most_active_command_queue_summary"] as? String
        let queueSelectionAlignment = resultDict?["queue_selection_alignment"] as? String
        let trackedCommandQueues = (resultDict?["tracked_command_queues"] as? [[String: Any]])?.map { item in
            TrackedCommandQueueActivityResult(
                source: item["source"] as? String ?? "unknown",
                className: item["class_name"] as? String ?? "unknown",
                label: item["label"] as? String,
                deviceName: item["device_name"] as? String ?? "unknown",
                firstSeenAt: item["first_seen_at"] as? String,
                lastSeenAt: item["last_seen_at"] as? String,
                discoveryCount: item["discovery_count"] as? Int ?? 0,
                rankingScore: item["ranking_score"] as? Int ?? 0,
                commandBufferCreationCount: item["command_buffer_creation_count"] as? Int ?? 0,
                commandBufferCommitCount: item["command_buffer_commit_count"] as? Int ?? 0,
                firstActivityAt: item["first_activity_at"] as? String,
                lastActivityAt: item["last_activity_at"] as? String,
                activityScore: item["activity_score"] as? Int ?? 0,
                lastCommandBufferClassName: item["last_command_buffer_class_name"] as? String,
                summary: item["summary"] as? String,
                activitySummary: item["activity_summary"] as? String
            )
        }

        return CaptureStatusResult(
            available: available,
            supportsGpuTrace: supportsGpuTrace,
            isCapturing: isCapturing,
            enabled: enabled,
            supportsDeveloperTools: supportsDeveloperTools,
            hasDefaultDevice: hasDefaultDevice,
            defaultDeviceName: defaultDeviceName,
            failureReason: failureReason,
            diagnosticSummary: diagnosticSummary,
            queueDiscoveryInstalled: queueDiscoveryInstalled,
            trackedCommandQueueCount: trackedCommandQueueCount,
            latestCommandQueueLabel: latestCommandQueueLabel,
            latestCommandQueueDeviceName: latestCommandQueueDeviceName,
            latestCommandQueueClassName: latestCommandQueueClassName,
            preferredCommandQueueLabel: preferredCommandQueueLabel,
            preferredCommandQueueDeviceName: preferredCommandQueueDeviceName,
            preferredCommandQueueClassName: preferredCommandQueueClassName,
            preferredCommandQueueSummary: preferredCommandQueueSummary,
            defaultCaptureScopeLabel: defaultCaptureScopeLabel,
            mostActiveCommandQueueLabel: mostActiveCommandQueueLabel,
            mostActiveCommandQueueDeviceName: mostActiveCommandQueueDeviceName,
            mostActiveCommandQueueClassName: mostActiveCommandQueueClassName,
            mostActiveCommandQueueSummary: mostActiveCommandQueueSummary,
            queueSelectionAlignment: queueSelectionAlignment,
            trackedCommandQueues: trackedCommandQueues
        )
    }

    // MARK: - Validation

    private func validateDuration(_ durationMs: Int) throws {
        if durationMs <= 0 {
            throw CaptureError.invalidDuration("Duration must be positive (got \(durationMs)ms)")
        }
        if durationMs > 30_000 {
            throw CaptureError.invalidDuration("Duration must be at most 30000ms (got \(durationMs)ms)")
        }
    }

    private func getReadySession(_ sessionId: String) throws -> SessionInfo {
        guard let session = registry.get(sessionId) else {
            throw SessionError.sessionNotFound(sessionId)
        }
        guard session.status == .ready else {
            throw CaptureError.sessionNotReady("Session '\(sessionId)' is in '\(session.status.rawValue)' state, expected 'ready'")
        }
        return session
    }
}

// MARK: - Fake Capture Service (for testing)

/// A fake capture service that records commands without making real bridge connections.
/// Useful for testing MCP tool handlers in isolation.
public final class FakeCaptureService: CaptureServiceProtocol, Sendable {

    private let lock = NSLock()
    private var _captureFrameCalls: [(sessionId: String, params: CaptureFrameParams)] = []
    private var _getCaptureStatusCalls: [String] = []
    private var _shouldFail: Bool = false
    private var _failureMessage: String = "Fake failure"
    private var _statusResult: CaptureStatusResult = CaptureStatusResult(
        available: true, supportsGpuTrace: true, isCapturing: false, enabled: true
    )

    public init() {}

    /// All recorded captureFrame calls.
    public var captureFrameCalls: [(sessionId: String, params: CaptureFrameParams)] {
        lock.lock()
        defer { lock.unlock() }
        return _captureFrameCalls
    }

    /// All recorded getCaptureStatus calls.
    public var getCaptureStatusCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _getCaptureStatusCalls
    }

    /// Configure the fake to throw errors.
    public func setShouldFail(_ fail: Bool, message: String = "Fake failure") {
        lock.lock()
        _shouldFail = fail
        _failureMessage = message
        lock.unlock()
    }

    /// Configure the fake capture status result.
    public func setStatusResult(_ result: CaptureStatusResult) {
        lock.lock()
        _statusResult = result
        lock.unlock()
    }

    public func captureFrame(sessionId: String, params: CaptureFrameParams) async throws -> CaptureFrameResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        _captureFrameCalls.append((sessionId: sessionId, params: params))
        lock.unlock()

        if shouldFail {
            throw CaptureError.commandFailed(message)
        }

        return CaptureFrameResult(
            success: true,
            outputPath: params.outputPath ?? "/tmp/capture.gputrace",
            message: "Frame captured successfully"
        )
    }

    public func getCaptureStatus(sessionId: String) async throws -> CaptureStatusResult {
        lock.lock()
        let shouldFail = _shouldFail
        let message = _failureMessage
        let result = _statusResult
        _getCaptureStatusCalls.append(sessionId)
        lock.unlock()

        if shouldFail {
            throw CaptureError.commandFailed(message)
        }

        return result
    }
}
