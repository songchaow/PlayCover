//
//  MetalCaptureService.swift
//  PlayTools
//

import Foundation
import Metal
import QuartzCore

/// 封装 MTLCaptureManager 的编程式截帧服务
@objc public class MetalCaptureService: NSObject {
    @objc public static let shared = MetalCaptureService()

    private enum CaptureTarget: String {
        case device
        case scope
    }

    private enum CapturePreparationError: LocalizedError {
        case defaultDeviceUnavailable(target: CaptureTarget)

        var errorDescription: String? {
            switch self {
            case .defaultDeviceUnavailable(let target):
                return "No default Metal device available for capture_target=\(target.rawValue)"
            }
        }
    }

    private var captureManager: MTLCaptureManager?
    private var isCapturing = false

    /// CADisplayLink 用于对齐 vsync 边界停止截帧
    private var displayLink: CADisplayLink?
    /// watchdog，避免长时间没有 vsync 时一直处于 capture 中
    private var stopWorkItem: DispatchWorkItem?
    /// vsync 回调计数，用于确保至少截取完整 1 帧
    private var vsyncCount = 0
    /// capture 开始时间，用于把 `durationMs` 真正接入 stop 语义
    private var captureStartTime: CFTimeInterval = 0
    /// 本次 capture 至少持续多久后才允许停止
    private var minimumCaptureDurationMs = 100
    /// 在第几个 vsync 后才允许停止（至少等 2 个 vsync 确保覆盖完整 1 帧）
    private let minimumVsyncStopThreshold = 2
    /// 本次 capture 使用的 target 策略
    private var activeCaptureTarget: CaptureTarget = .device
    /// scope 模式下的临时 capture scope
    private var activeCaptureScope: MTLCaptureScope?
    /// scope 模式是否已经在某个 vsync 上进入 beginScope
    private var hasBegunActiveCaptureScope = false

    /// 初始化截帧服务
    /// 当前实现的直接开关是 `PlaySettings.shared.metalCaptureEnabled`。
    /// 注意：安装包 `Info.plist` 中是否存在 `MetalCaptureEnabled` key 仍然值得单独观测，
    /// 但它并不是这里的直接 runtime guard。
    @objc public func initialize() {
        guard PlaySettings.shared.metalCaptureEnabled else {
            print("[PlayTools] MetalCaptureService: disabled by settings")
            return
        }

        captureManager = MTLCaptureManager.shared()

        let status = makeStatus(manager: captureManager)
        print("[PlayTools] MetalCaptureService initialized. \(status.diagnosticSummary)")
    }

    /// 执行一次帧截取，输出 .gputrace 到指定路径
    /// - Parameters:
    ///   - outputURL: 输出文件路径（.gputrace），传 nil 则使用默认路径
    ///   - durationMs: 最少持续截帧多久后才允许停止，默认 100ms
    ///   - captureTargetRawValue: runtime capture target，支持 `device` / `scope`
    /// - Returns: 截帧结果
    @objc public func captureFrame(
        outputURL: URL? = nil,
        durationMs: Int = 100,
        captureTargetRawValue: String? = nil
    ) -> CaptureResult {
        guard let manager = captureManager else {
            let status = makeStatus(manager: nil)
            return CaptureResult(
                success: false,
                message: "MTLCaptureManager not available. \(status.diagnosticSummary). "
                    + "Ensure metalCaptureEnabled is ON and app was reinstalled.",
                outputPath: nil
            )
        }

        guard !isCapturing else {
            return CaptureResult(success: false, message: "Capture already in progress", outputPath: nil)
        }

        let captureTarget: CaptureTarget
        if let rawValue = captureTargetRawValue, !rawValue.isEmpty {
            guard let parsedTarget = CaptureTarget(rawValue: rawValue) else {
                return CaptureResult(
                    success: false,
                    message: "Unsupported capture_target '\(rawValue)'. Supported values: device, scope",
                    outputPath: nil
                )
            }
            captureTarget = parsedTarget
        } else {
            captureTarget = .device
        }

        let normalizedDurationMs = max(1, durationMs)
        let preflightStatus = makeStatus(manager: manager)
        if !preflightStatus.supportsGPUTrace {
            logStatusProbe(
                "captureFrame preflight reports supportsGPUTrace=false; will still attempt startCapture for parity with in-app successful path. target=\(captureTarget.rawValue). \(preflightStatus.diagnosticSummary)"
            )
        }

        let url = outputURL ?? defaultOutputURL()

        // 如果目标文件已存在，先删除（MTLCaptureManager 不会覆盖）
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let descriptor = MTLCaptureDescriptor()
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url

        let captureObjectSummary: String
        switch makeCaptureObject(target: captureTarget, manager: manager) {
        case .success(let preparedTarget):
            descriptor.captureObject = preparedTarget.captureObject
            captureObjectSummary = preparedTarget.summary
            activeCaptureTarget = captureTarget
            activeCaptureScope = preparedTarget.scope
            hasBegunActiveCaptureScope = false
        case .failure(let error):
            return CaptureResult(
                success: false,
                message: error.localizedDescription,
                outputPath: nil
            )
        }

        do {
            try manager.startCapture(with: descriptor)
            isCapturing = true
            captureStartTime = CACurrentMediaTime()
            minimumCaptureDurationMs = normalizedDurationMs
            vsyncCount = 0

            if captureTarget == .scope {
                logStatusProbe(
                    "capture started with scope target; waiting for first vsync to enter beginScope. captureObject=\(captureObjectSummary), output=\(url.path), durationMs=\(normalizedDurationMs)"
                )
            } else {
                logStatusProbe(
                    "capture started with device target. captureObject=\(captureObjectSummary), output=\(url.path), durationMs=\(normalizedDurationMs)"
                )
            }

            // 对齐 vsync 停止，但不再忽略 host 传入的 duration_ms。
            let link = CADisplayLink(target: self, selector: #selector(onVsync(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            scheduleStopWatchdog(durationMs: normalizedDurationMs)

            return CaptureResult(
                success: true,
                message: "Capture started (target=\(captureTarget.rawValue), captureObject=\(captureObjectSummary))",
                outputPath: url.path
            )
        } catch {
            resetActiveCaptureState()
            invalidateStopTriggers()
            return CaptureResult(
                success: false,
                message: "startCapture failed: \(error.localizedDescription). target=\(captureTarget.rawValue), captureObject=\(captureObjectSummary), preflight=\(preflightStatus.diagnosticSummary)",
                outputPath: nil
            )
        }
    }

    /// vsync 回调：在达到阈值后停止截帧
    @objc private func onVsync(_ link: CADisplayLink) {
        guard isCapturing else {
            invalidateStopTriggers()
            return
        }

        if activeCaptureTarget == .scope,
           !hasBegunActiveCaptureScope,
           let scope = activeCaptureScope {
            scope.begin()
            hasBegunActiveCaptureScope = true
            captureStartTime = CACurrentMediaTime()
            vsyncCount = 0
            logStatusProbe("scope begin on first vsync; queue=\(scope.commandQueue.map { String(describing: $0) } ?? "nil")")
            return
        }

        vsyncCount += 1
        guard vsyncCount >= minimumVsyncStopThreshold else { return }

        let elapsedMs = Int((CACurrentMediaTime() - captureStartTime) * 1000.0)
        guard elapsedMs >= minimumCaptureDurationMs else { return }

        stopActiveCapture(reason: "vsync #\(vsyncCount), elapsed=\(elapsedMs)ms")
    }

    /// 手动停止当前截帧（通常不需要，CADisplayLink 会自动停止）
    @objc public func stopCapture() -> CaptureResult {
        guard isCapturing else {
            return CaptureResult(success: false, message: "No capture in progress", outputPath: nil)
        }

        stopActiveCapture(reason: "manual")
        return CaptureResult(success: true, message: "Capture stopped", outputPath: nil)
    }

    /// 清理 stop 触发器
    private func invalidateStopTriggers() {
        displayLink?.invalidate()
        displayLink = nil
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    private func scheduleStopWatchdog(durationMs: Int) {
        stopWorkItem?.cancel()

        let watchdogDelayMs = max(durationMs + 2_000, 3_000)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isCapturing else { return }
            self.logStatusProbe("capture watchdog fired after \(watchdogDelayMs)ms")
            self.stopActiveCapture(reason: "watchdog after \(watchdogDelayMs)ms")
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(watchdogDelayMs), execute: workItem)
    }

    private func stopActiveCapture(reason: String) {
        guard let manager = captureManager, isCapturing else {
            invalidateStopTriggers()
            resetActiveCaptureState()
            return
        }

        let captureTarget = activeCaptureTarget
        if captureTarget == .scope,
           hasBegunActiveCaptureScope,
           let scope = activeCaptureScope {
            scope.end()
            logStatusProbe("scope end before manager.stopCapture(); reason=\(reason)")
        }

        manager.stopCapture()
        invalidateStopTriggers()
        resetActiveCaptureState()
        print("[PlayTools] MetalCaptureService: capture stopped (target=\(captureTarget.rawValue), \(reason))")
    }

    private func makeCaptureObject(
        target: CaptureTarget,
        manager: MTLCaptureManager
    ) -> Result<(captureObject: Any, scope: MTLCaptureScope?, summary: String), CapturePreparationError> {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .failure(.defaultDeviceUnavailable(target: target))
        }

        switch target {
        case .device:
            return .success((
                captureObject: device,
                scope: nil,
                summary: "device(name=\(device.name))"
            ))
        case .scope:
            let scope = manager.makeCaptureScope(device: device)
            scope.label = "PlayCover.capture.scope.\(UUID().uuidString.lowercased())"
            return .success((
                captureObject: scope,
                scope: scope,
                summary: "scope(device=\(device.name), queue=nil, label=\(scope.label ?? "nil"))"
            ))
        }
    }

    private func resetActiveCaptureState() {
        isCapturing = false
        captureStartTime = 0
        vsyncCount = 0
        minimumCaptureDurationMs = 100
        activeCaptureTarget = .device
        activeCaptureScope = nil
        hasBegunActiveCaptureScope = false
    }

    /// 查询截帧状态
    @objc public func getStatus() -> CaptureStatus {
        makeStatus(manager: captureManager)
    }

    // MARK: - Private

    private func makeStatus(manager: MTLCaptureManager?) -> CaptureStatus {
        let enabled = PlaySettings.shared.metalCaptureEnabled
        let available = manager != nil
        let supportsGPUTrace = manager?.supportsDestination(.gpuTraceDocument) ?? false
        let supportsDeveloperTools = manager?.supportsDestination(.developerTools) ?? false
        let defaultDevice = MTLCreateSystemDefaultDevice()
        let hasDefaultDevice = defaultDevice != nil
        let defaultDeviceName = defaultDevice?.name

        let failureReason: String?
        if !enabled {
            failureReason = "disabled_by_settings"
        } else if !available {
            failureReason = "capture_manager_unavailable"
        } else if !supportsGPUTrace {
            failureReason = "gpu_trace_document_unsupported"
        } else if !hasDefaultDevice {
            failureReason = "default_metal_device_unavailable"
        } else {
            failureReason = nil
        }

        let diagnosticSummary = [
            "enabled=\(enabled)",
            "captureManagerAvailable=\(available)",
            "supportsGPUTrace=\(supportsGPUTrace)",
            "supportsDeveloperTools=\(supportsDeveloperTools)",
            "hasDefaultDevice=\(hasDefaultDevice)",
            "defaultDeviceName=\(defaultDeviceName ?? "nil")",
            "failureReason=\(failureReason ?? "none")",
        ].joined(separator: ", ")
        logStatusProbe("makeStatus end. \(diagnosticSummary)")

        return CaptureStatus(
            available: available,
            supportsGPUTrace: supportsGPUTrace,
            supportsDeveloperTools: supportsDeveloperTools,
            isCapturing: isCapturing,
            enabled: enabled,
            hasDefaultDevice: hasDefaultDevice,
            defaultDeviceName: defaultDeviceName,
            failureReason: failureReason,
            diagnosticSummary: diagnosticSummary
        )
    }

    private func logStatusProbe(_ message: String) {
        print("[PlayTools] MetalCaptureService: \(message)")
    }

    private func defaultOutputURL() -> URL {
        // 输出到 app 自己的 Documents/Captures 目录
        // Documents 目录在沙箱内一定可写，无需担心跨 container 的权限问题
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let capturesDir = documentsURL.appendingPathComponent("Captures")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

        // 用时间戳作为文件名
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        return capturesDir
            .appendingPathComponent("capture_\(timestamp)")
            .appendingPathExtension("gputrace")
    }
}

/// 截帧操作结果
@objc public class CaptureResult: NSObject {
    @objc public let success: Bool
    @objc public let message: String
    @objc public let outputPath: String?

    @objc public init(success: Bool, message: String, outputPath: String?) {
        self.success = success
        self.message = message
        self.outputPath = outputPath
    }
}

/// 截帧服务状态
@objc public class CaptureStatus: NSObject {
    @objc public let available: Bool
    @objc public let supportsGPUTrace: Bool
    @objc public let supportsDeveloperTools: Bool
    @objc public let isCapturing: Bool
    @objc public let enabled: Bool
    @objc public let hasDefaultDevice: Bool
    @objc public let defaultDeviceName: String?
    @objc public let failureReason: String?
    @objc public let diagnosticSummary: String

    @objc public init(
        available: Bool,
        supportsGPUTrace: Bool,
        supportsDeveloperTools: Bool,
        isCapturing: Bool,
        enabled: Bool,
        hasDefaultDevice: Bool,
        defaultDeviceName: String?,
        failureReason: String?,
        diagnosticSummary: String
    ) {
        self.available = available
        self.supportsGPUTrace = supportsGPUTrace
        self.supportsDeveloperTools = supportsDeveloperTools
        self.isCapturing = isCapturing
        self.enabled = enabled
        self.hasDefaultDevice = hasDefaultDevice
        self.defaultDeviceName = defaultDeviceName
        self.failureReason = failureReason
        self.diagnosticSummary = diagnosticSummary
    }
}
