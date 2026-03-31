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

    private var captureManager: MTLCaptureManager?
    private var isCapturing = false

    /// CADisplayLink 用于对齐 vsync 边界停止截帧
    private var displayLink: CADisplayLink?
    /// vsync 回调计数，用于确保至少截取完整 1 帧
    private var vsyncCount = 0
    /// 在第几个 vsync 后停止截帧（至少等 2 个 vsync 确保覆盖完整 1 帧）
    private let vsyncStopThreshold = 2

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
    /// - Parameter outputURL: 输出文件路径（.gputrace），传 nil 则使用默认路径
    /// - Returns: 截帧结果
    @objc public func captureFrame(outputURL: URL? = nil) -> CaptureResult {
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

        guard manager.supportsDestination(.gpuTraceDocument) else {
            let status = makeStatus(manager: manager)
            return CaptureResult(
                success: false,
                message: "GPU trace document not supported. \(status.diagnosticSummary)",
                outputPath: nil
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

        // 截取默认 Metal device 上的命令
        if let device = MTLCreateSystemDefaultDevice() {
            descriptor.captureObject = device
        }

        do {
            isCapturing = true
            try manager.startCapture(with: descriptor)
            print("[PlayTools] MetalCaptureService: capture started, output: \(url.path)")

            // 策略 B：CADisplayLink 对齐 vsync 边界停止截帧
            // 等待若干个 vsync 信号后自动停止，精确截取 1-2 帧
            vsyncCount = 0
            let link = CADisplayLink(target: self, selector: #selector(onVsync(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link

            return CaptureResult(success: true, message: "Capture started", outputPath: url.path)
        } catch {
            isCapturing = false
            return CaptureResult(
                success: false,
                message: "startCapture failed: \(error.localizedDescription)",
                outputPath: nil
            )
        }
    }

    /// vsync 回调：在达到阈值后停止截帧
    @objc private func onVsync(_ link: CADisplayLink) {
        vsyncCount += 1
        guard vsyncCount >= vsyncStopThreshold else { return }

        // 到达阈值，停止截帧并清理 displayLink
        if isCapturing, let manager = captureManager {
            manager.stopCapture()
            isCapturing = false
            print("[PlayTools] MetalCaptureService: capture stopped (vsync #\(vsyncCount))")
        }
        invalidateDisplayLink()
    }

    /// 手动停止当前截帧（通常不需要，CADisplayLink 会自动停止）
    @objc public func stopCapture() -> CaptureResult {
        guard let manager = captureManager, isCapturing else {
            return CaptureResult(success: false, message: "No capture in progress", outputPath: nil)
        }

        manager.stopCapture()
        isCapturing = false
        invalidateDisplayLink()
        print("[PlayTools] MetalCaptureService: capture stopped (manual)")
        return CaptureResult(success: true, message: "Capture stopped", outputPath: nil)
    }

    /// 清理 CADisplayLink
    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
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
