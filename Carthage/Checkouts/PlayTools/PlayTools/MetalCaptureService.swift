//
//  MetalCaptureService.swift
//  PlayTools
//

import Foundation
import Metal

/// 封装 MTLCaptureManager 的编程式截帧服务
@objc public class MetalCaptureService: NSObject {
    @objc public static let shared = MetalCaptureService()

    private var captureManager: MTLCaptureManager?
    private var isCapturing = false

    /// 截帧后自动停止的延迟时间（秒），覆盖 1-2 帧
    private let captureDelaySeconds: Double = 0.1

    /// 初始化截帧服务
    /// 仅当 Info.plist 中 MetalCaptureEnabled = YES 且 PlaySettings.metalCaptureEnabled 时生效
    @objc public func initialize() {
        guard PlaySettings.shared.metalCaptureEnabled else {
            print("[PlayTools] MetalCaptureService: disabled by settings")
            return
        }

        captureManager = MTLCaptureManager.shared()

        if let manager = captureManager {
            let supportsTrace = manager.supportsDestination(.gpuTraceDocument)
            print("[PlayTools] MetalCaptureService initialized. supportsGPUTrace: \(supportsTrace)")
        } else {
            print("[PlayTools] MetalCaptureService: MTLCaptureManager not available")
        }
    }

    /// 执行一次帧截取，输出 .gputrace 到指定路径
    /// - Parameter outputURL: 输出文件路径（.gputrace），传 nil 则使用默认路径
    /// - Returns: 截帧结果
    @objc public func captureFrame(outputURL: URL? = nil) -> CaptureResult {
        guard let manager = captureManager else {
            return CaptureResult(
                success: false,
                message: "MTLCaptureManager not available. "
                    + "Ensure metalCaptureEnabled is ON and app was reinstalled.",
                outputPath: nil
            )
        }

        guard !isCapturing else {
            return CaptureResult(success: false, message: "Capture already in progress", outputPath: nil)
        }

        guard manager.supportsDestination(.gpuTraceDocument) else {
            return CaptureResult(success: false, message: "GPU trace document not supported", outputPath: nil)
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

            // 策略 A：定时截帧 —— 等待一段时间后自动停止，覆盖 1-2 帧
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelaySeconds) { [weak self] in
                guard let self = self, self.isCapturing else { return }
                manager.stopCapture()
                self.isCapturing = false
                print("[PlayTools] MetalCaptureService: capture stopped (auto)")
            }

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

    /// 手动停止当前截帧（通常不需要，定时策略会自动停止）
    @objc public func stopCapture() -> CaptureResult {
        guard let manager = captureManager, isCapturing else {
            return CaptureResult(success: false, message: "No capture in progress", outputPath: nil)
        }

        manager.stopCapture()
        isCapturing = false
        print("[PlayTools] MetalCaptureService: capture stopped (manual)")
        return CaptureResult(success: true, message: "Capture stopped", outputPath: nil)
    }

    /// 查询截帧状态
    @objc public func getStatus() -> CaptureStatus {
        let available = captureManager != nil
        let supportsTrace = captureManager?.supportsDestination(.gpuTraceDocument) ?? false
        return CaptureStatus(
            available: available,
            supportsGPUTrace: supportsTrace,
            isCapturing: isCapturing,
            enabled: PlaySettings.shared.metalCaptureEnabled
        )
    }

    // MARK: - Private

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
    @objc public let isCapturing: Bool
    @objc public let enabled: Bool

    @objc public init(available: Bool, supportsGPUTrace: Bool, isCapturing: Bool, enabled: Bool) {
        self.available = available
        self.supportsGPUTrace = supportsGPUTrace
        self.isCapturing = isCapturing
        self.enabled = enabled
    }
}
