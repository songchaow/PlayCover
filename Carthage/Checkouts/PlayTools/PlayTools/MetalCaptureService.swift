//
//  MetalCaptureService.swift
//  PlayTools
//

import Foundation
import Metal
import ObjectiveC
import QuartzCore

// MARK: - RC-013: SIGSEGV-safe stopCapture wrapper
//
// GPUToolsCapture's internal `GTTraceContextDumpEmptyCapture` crashes with SIGSEGV
// when `stopCapture` is called on a trace context with no captured GPU commands
// (which happens in delayed dlopen mode for apps like Genshin Impact whose Metal
// objects were created before GPUToolsCapture was loaded).
//
// The actual signal handling (sigsetjmp/siglongjmp) is implemented in GuardedCapture.m
// because Swift forbids functions annotated with `returns_twice` (like sigsetjmp).
// See GuardedCapture.h for the C API.

@_silgen_name("PlayTools_installGPUToolsCaptureEarlyStubs")
private func playToolsInstallGPUToolsCaptureEarlyStubsCShim()

@_silgen_name("PlayTools_guardedStopCapture")
private func playToolsGuardedStopCaptureCShim(_ block: @escaping @convention(block) () -> Void) -> Bool

@_silgen_name("PlayTools_logGPUToolsCaptureClasses")
private func playToolsLogGPUToolsCaptureClassesCShim()

private final class CommandQueueDiscoverySwizzles: NSObject {
    @objc dynamic func pc_newCommandQueue() -> AnyObject? {
        let queue = self.pc_newCommandQueue()
        // RC-015: Log deep class info to diagnose GPUToolsCapture proxy wrapping
        if let obj = queue {
            let isaClass = NSStringFromClass(object_getClass(obj)!)
            let typeClass = NSStringFromClass(type(of: obj) as! AnyClass)
            let respondsToTraceStream = obj.responds(to: NSSelectorFromString("traceStream"))
            let classHierarchy = MetalCaptureService.classHierarchyString(of: obj)
            NSLog("[PlayTools] RC-015 newCommandQueue: isa=%@, type=%@, traceStream=%d, hierarchy=[%@]",
                  isaClass, typeClass, respondsToTraceStream ? 1 : 0, classHierarchy)
        }
        MetalCaptureService.shared.recordObservedCommandQueue(queue, source: "newCommandQueue")
        return queue
    }

    @objc dynamic func pc_newCommandQueueWithMaxCommandBufferCount(_ maxCommandBufferCount: UInt) -> AnyObject? {
        let queue = self.pc_newCommandQueueWithMaxCommandBufferCount(maxCommandBufferCount)
        // RC-015: Same deep diagnostics
        if let obj = queue {
            let isaClass = NSStringFromClass(object_getClass(obj)!)
            let typeClass = NSStringFromClass(type(of: obj) as! AnyClass)
            let respondsToTraceStream = obj.responds(to: NSSelectorFromString("traceStream"))
            let classHierarchy = MetalCaptureService.classHierarchyString(of: obj)
            NSLog("[PlayTools] RC-015 newCommandQueueWithMaxCount(%lu): isa=%@, type=%@, traceStream=%d, hierarchy=[%@]",
                  maxCommandBufferCount, isaClass, typeClass, respondsToTraceStream ? 1 : 0, classHierarchy)
        }
        MetalCaptureService.shared.recordObservedCommandQueue(
            queue,
            source: "newCommandQueueWithMaxCommandBufferCount(\(maxCommandBufferCount))"
        )
        return queue
    }
}

/// 封装 MTLCaptureManager 的编程式截帧服务
@objc public class MetalCaptureService: NSObject {
    @objc public static let shared = MetalCaptureService()

    private enum CaptureTarget: String {
        case device
        case scope
        case queue
        case queueScope = "queue_scope"

        var usesCaptureScopeLifecycle: Bool {
            switch self {
            case .scope, .queueScope:
                return true
            case .device, .queue:
                return false
            }
        }
    }

    private struct TrackedCommandQueue {
        let queue: MTLCommandQueue
        let source: String
        let className: String
        var label: String?
        var deviceName: String
        let firstSeenAt: Date
        var lastSeenAt: Date
        var discoveryCount: Int

        var summary: String {
            [
                "class=\(className)",
                "label=\(MetalCaptureService.describeOptionalString(label))",
                "device=\(deviceName)",
                "source=\(source)",
                "discoveries=\(discoveryCount)",
            ].joined(separator: ", ")
        }
    }

    private enum CapturePreparationError: LocalizedError {
        case defaultDeviceUnavailable(target: CaptureTarget)
        case trackedCommandQueueUnavailable(target: CaptureTarget, trackedQueueCount: Int, queueDiscoveryInstalled: Bool)

        var errorDescription: String? {
            switch self {
            case .defaultDeviceUnavailable(let target):
                return "No default Metal device available for capture_target=\(target.rawValue)"
            case .trackedCommandQueueUnavailable(let target, let trackedQueueCount, let queueDiscoveryInstalled):
                return "No tracked Metal command queue available for capture_target=\(target.rawValue). tracked_queue_count=\(trackedQueueCount), queue_discovery_installed=\(queueDiscoveryInstalled). Relaunch the app with this build and wait until real Metal rendering has started."
            }
        }
    }

    private static let maxTrackedCommandQueues = 8

    private var captureManager: MTLCaptureManager?
    private var gpuToolsCaptureLoaded = false
    private var isCapturing = false
    private let trackedQueueLock = NSLock()
    private var trackedCommandQueues: [ObjectIdentifier: TrackedCommandQueue] = [:]
    private var trackedCommandQueueOrder: [ObjectIdentifier] = []
    private var queueDiscoveryInstalled = false

    /// RC-013: Set to true when stopCapture recovered from SIGSEGV,
    /// indicating the .gputrace file is empty/invalid due to pre-existing
    /// Metal objects not being wrapped by GPUToolsCapture Capture* proxies.
    private var lastCaptureWasEmptyTrace = false

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

    // MARK: - Delayed GPU Tools Capture Loading (RC-009 / RC-012)

    /// Attempt to load `/usr/lib/libmtlcapture.dylib` at runtime via `dlopen`.
    ///
    /// **Why**: `DYLD_INSERT_LIBRARIES` injection at launch causes some apps (e.g. Genshin Impact)
    /// to crash with `SIGABRT` because `GPUToolsCapture` globally hooks `CAMetalLayer` init at
    /// dyld stage. Delayed `dlopen` avoids this by loading the library only when capture is needed.
    ///
    /// **Important**: After `dlopen`, `MTLCaptureManager.shared()` must be re-acquired because
    /// the singleton caches `supportsDestination` at first access. A fresh `shared()` call after
    /// the library is loaded returns a new instance with the correct capability (verified by RC-010).
    ///
    /// **RC-012**: After `dlopen`, `GPUToolsCapture` hooks `CAMetalLayer.nextDrawable` with
    /// `CAMetalLayer_shimDrawable`. When the hook fires, `OpenLayerStream` → `MakeLayerInfos`
    /// iterates all tracked layers and calls `streamReference` on each. Layers created *before*
    /// `dlopen` were never instrumented by `GPUToolsCapture` and lack `streamReference`, causing
    /// `doesNotRecognizeSelector` → crash. We preemptively install a nil-returning fallback
    /// `streamReference` on `CAMetalLayer` before `dlopen` so that pre-existing layers survive
    /// the hook. `GPUToolsCapture` will overwrite this with its real implementation for layers
    /// created *after* loading.
    private func ensureGPUToolsCaptureLoaded() -> Bool {
        guard !gpuToolsCaptureLoaded else { return true }

        // Check if GPUToolsCapture was already loaded via DYLD_INSERT_LIBRARIES
        // at dyld time. If CaptureMTLDevice exists, the library is already active
        // and all Metal objects are already wrapped — no need for delayed dlopen.
        if NSClassFromString("CaptureMTLDevice") != nil {
            gpuToolsCaptureLoaded = true
            captureManager = MTLCaptureManager.shared()
            logStatusProbe("ensureGPUToolsCaptureLoaded: already loaded via DYLD_INSERT (CaptureMTLDevice exists)")
            return true
        }

        let libPath = "/usr/lib/libmtlcapture.dylib"
        guard FileManager.default.fileExists(atPath: libPath) else {
            logStatusProbe("ensureGPUToolsCaptureLoaded: library not found at \(libPath)")
            return false
        }

        // RC-012: Install a nil-returning fallback for selectors that GPUToolsCapture's
        // MakeLayerInfos expects on every tracked CAMetalLayer but only adds to layers
        // created after it loads. This prevents crashes for pre-existing layer instances.
        installGPUToolsCaptureCompatStubs()

        // RC-012: Set an uncaught exception handler to log full details before crash
        let previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? "nil"
            let name = exception.name.rawValue
            let callStack = exception.callStackSymbols.joined(separator: "\n")
            NSLog("[PlayTools] RC-012 UNCAUGHT EXCEPTION: name=%@ reason=%@ stack:\n%@", name, reason, callStack)
        }

        let handle = dlopen(libPath, RTLD_NOW)
        if handle != nil {
            gpuToolsCaptureLoaded = true
            // Re-acquire the singleton so supportsDestination reflects the newly loaded library.
            captureManager = MTLCaptureManager.shared()
            logStatusProbe("ensureGPUToolsCaptureLoaded: SUCCESS — captureManager re-acquired")

            // RC-012: Re-install compat stubs AFTER dlopen, because GPUToolsCapture may
            // have swizzled methods during its +load / __attribute__((constructor)).
            // Also install on any dynamically-created subclass of CAMetalLayer.
            installGPUToolsCaptureCompatStubsPostLoad()
        } else {
            let errMsg = dlerror().map { String(cString: $0) } ?? "unknown"
            logStatusProbe("ensureGPUToolsCaptureLoaded: dlopen FAILED — \(errMsg)")
        }

        // Restore previous handler
        NSSetUncaughtExceptionHandler(previousHandler)

        return gpuToolsCaptureLoaded
    }

    /// RC-012: Install nil-returning fallback implementations for selectors that
    /// `GPUToolsCapture`'s `MakeLayerInfos` calls on `CAMetalLayer` instances.
    ///
    /// When `GPUToolsCapture` is loaded at dyld time, it hooks `CAMetalLayer` init
    /// and adds associated state (including `streamReference`) to each new layer.
    /// With delayed `dlopen`, layers created before loading lack these methods.
    /// `MakeLayerInfos` calls: `device`, `streamReference`, `frame`, `name` on each
    /// layer — `device`/`frame`/`name` are standard `CAMetalLayer` properties, but
    /// `streamReference` is private to `GPUToolsCapture`.
    ///
    /// We add `streamReference` (returning nil) only if it doesn't already exist.
    /// After `dlopen`, `GPUToolsCapture` may overwrite or extend the layer class
    /// for newly created layers.
    private var compatStubsInstalled = false

    /// RC-012: Private selectors that GPUToolsCapture calls on various Metal objects
    /// (MTLDevice, MTLTexture, MTLDrawable, CAMetalLayer, etc.) through its Capture* proxy
    /// classes. When using delayed dlopen, pre-existing Metal objects are NOT wrapped in
    /// Capture* proxies and lack these methods → doesNotRecognizeSelector → SIGABRT.
    ///
    /// **Solution**: Install nil-returning fallback stubs on `NSObject` itself, so that
    /// ANY object will respond to these selectors with nil/NULL instead of crashing.
    /// GPUToolsCapture's Capture* proxies provide real implementations that override
    /// these stubs for properly wrapped objects.
    ///
    /// Selectors identified via disassembly of GPUToolsCapture:
    ///   - `traceStream` — called on MTLDevice, MTLTexture, CAMetalLayer, self (CaptureMTLDrawable)
    ///   - `streamReference` — called on CAMetalLayer, MTLDevice
    private static let gpuToolsPrivateSelectors = ["streamReference", "traceStream"]

    private func installGPUToolsCaptureCompatStubs() {
        guard !compatStubsInstalled else { return }
        compatStubsInstalled = true

        // RC-014: Early stubs are now installed via __attribute__((constructor)) in
        // GuardedCapture.m, which runs at dyld load time — before GPUToolsCapture's
        // CAMetalLayer hooks can trigger. This call is kept as a safety net in case
        // the constructor didn't run (e.g. if GuardedCapture.m is not compiled in).
        playToolsInstallGPUToolsCaptureEarlyStubsCShim()

        // Verify stubs exist on NSObject (they should already be there from RC-014)
        let nsObjectClass: AnyClass = NSObject.self
        for sel in Self.gpuToolsPrivateSelectors {
            addNilReturningStubIfNeeded(to: nsObjectClass, selector: sel, tag: "NSObject-pre")
        }
    }

    /// RC-012: After dlopen, GPUToolsCapture's Capture* classes are now loaded and
    /// provide real implementations. We don't need to patch them — our NSObject stubs
    /// are only hit for non-wrapped pre-existing objects.
    private func installGPUToolsCaptureCompatStubsPostLoad() {
        logStatusProbe("installGPUToolsCaptureCompatStubsPostLoad: NSObject fallback stubs active")
    }

    /// Add a nil/0-returning stub for the given selector if the class doesn't already respond.
    @discardableResult
    private func addNilReturningStubIfNeeded(to cls: AnyClass, selector selName: String, tag: String) -> Bool {
        let sel = NSSelectorFromString(selName)

        if class_getInstanceMethod(cls, sel) == nil {
            // IMP that returns nil/NULL — works for both id and pointer return types
            let nilIMP: @convention(c) (AnyObject, Selector) -> UnsafeRawPointer? = { _, _ in nil }
            let added = class_addMethod(cls, sel,
                                        unsafeBitCast(nilIMP, to: IMP.self), "^v@:")
            logStatusProbe("addStub[\(tag)]: \(NSStringFromClass(cls)).\(selName) — added=\(added)")
            return added
        }
        return false
    }

    /// 初始化截帧服务
    /// 当前实现的直接开关是 `PlaySettings.shared.metalCaptureEnabled`。
    /// 注意：安装包 `Info.plist` 中是否存在 `MetalCaptureEnabled` key 仍然值得单独观测，
    /// 但它并不是这里的直接 runtime guard。
    @objc public func initialize() {
        guard PlaySettings.shared.metalCaptureEnabled else {
            print("[PlayTools] MetalCaptureService: disabled by settings")
            return
        }

        // NOTE: captureManager is NOT acquired here. It will be lazily initialized
        // when ensureGPUToolsCaptureLoaded() is called during captureFrame() or getStatus().
        // This avoids the MTLCaptureManager singleton caching supportsDestination=false
        // before libmtlcapture.dylib is loaded via dlopen (RC-009).
        installQueueDiscoveryIfNeeded()

        print("[PlayTools] MetalCaptureService initialized (delayed capture library loading enabled)")
    }

    /// 执行一次帧截取，输出 .gputrace 到指定路径
    /// - Parameters:
    ///   - outputURL: 输出文件路径（.gputrace），传 nil 则使用默认路径
    ///   - durationMs: 最少持续截帧多久后才允许停止，默认 100ms
    ///   - captureTargetRawValue: runtime capture target，支持 `device` / `scope` / `queue` / `queue_scope`
    /// - Returns: 截帧结果
    @objc public func captureFrame(
        outputURL: URL? = nil,
        durationMs: Int = 100,
        captureTargetRawValue: String? = nil
    ) -> CaptureResult {
        // RC-013: Reset empty trace flag at the start of each capture attempt
        lastCaptureWasEmptyTrace = false

        // Lazily load libmtlcapture.dylib and re-acquire MTLCaptureManager (RC-009)
        _ = ensureGPUToolsCaptureLoaded()

        // RC-015: One-time deep diagnostics at capture time
        logRC015CaptureFrameDiagnostics()

        guard let manager = captureManager else {
            let status = makeStatus(manager: nil)
            return CaptureResult(
                success: false,
                message: "MTLCaptureManager not available. \(status.diagnosticSummary). Ensure metalCaptureEnabled is ON and app was reinstalled.",
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
                    message: "Unsupported capture_target '\(rawValue)'. Supported values: device, scope, queue, queue_scope",
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

            if captureTarget.usesCaptureScopeLifecycle {
                logStatusProbe(
                    "capture started with scope-based target; waiting for first vsync to enter beginScope. target=\(captureTarget.rawValue), captureObject=\(captureObjectSummary), output=\(url.path), durationMs=\(normalizedDurationMs)"
                )
            } else {
                logStatusProbe(
                    "capture started with direct target. target=\(captureTarget.rawValue), captureObject=\(captureObjectSummary), output=\(url.path), durationMs=\(normalizedDurationMs)"
                )
            }

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

        if activeCaptureTarget.usesCaptureScopeLifecycle,
           !hasBegunActiveCaptureScope,
           let scope = activeCaptureScope {
            scope.begin()
            hasBegunActiveCaptureScope = true
            captureStartTime = CACurrentMediaTime()
            vsyncCount = 0
            let queueText = scope.commandQueue.map(queueSummary(for:)) ?? "nil"
            logStatusProbe(
                "scope begin on first vsync; target=\(activeCaptureTarget.rawValue), queue=\(queueText)"
            )
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

    /// 给 swizzle 回调记录真实渲染 command queue。
    fileprivate func recordObservedCommandQueue(_ candidate: AnyObject?, source: String) {
        guard let queue = candidate as? MTLCommandQueue else {
            logStatusProbe("queue discovery ignored non-command-queue object from \(source): \(String(describing: candidate))")
            return
        }
        recordTrackedCommandQueue(queue, source: source)
    }

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
        if captureTarget.usesCaptureScopeLifecycle,
           hasBegunActiveCaptureScope,
           let scope = activeCaptureScope {
            scope.end()
            logStatusProbe("scope end before manager.stopCapture(); target=\(captureTarget.rawValue), reason=\(reason)")
        }

        // RC-013: Use SIGSEGV-guarded stopCapture to handle the case where
        // GPUToolsCapture's internal GTTraceContextDumpEmptyCapture crashes
        // when the trace context has no captured data (delayed dlopen mode
        // with apps whose Metal objects were created before library loading).
        if manager.isCapturing {
            let stoppedCleanly = playToolsGuardedStopCaptureCShim {
                manager.stopCapture()
            }
            if stoppedCleanly {
                logStatusProbe("stopActiveCapture: manager.stopCapture() completed normally; target=\(captureTarget.rawValue), reason=\(reason)")
            } else {
                logStatusProbe("stopActiveCapture: SIGSEGV recovered during manager.stopCapture() — empty trace context (pre-existing Metal objects not wrapped by GPUToolsCapture); target=\(captureTarget.rawValue), reason=\(reason)")
                // Mark that this capture produced an empty/invalid result
                lastCaptureWasEmptyTrace = true
            }
        } else {
            logStatusProbe("stopActiveCapture: manager.isCapturing is false, skipping stopCapture(); target=\(captureTarget.rawValue), reason=\(reason)")
        }

        invalidateStopTriggers()
        resetActiveCaptureState()
        print("[PlayTools] MetalCaptureService: capture stopped (target=\(captureTarget.rawValue), \(reason))")
    }

    private func makeCaptureObject(
        target: CaptureTarget,
        manager: MTLCaptureManager
    ) -> Result<(captureObject: Any, scope: MTLCaptureScope?, summary: String), CapturePreparationError> {
        switch target {
        case .device, .scope:
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
                    captureObject: scope as Any,
                    scope: scope,
                    summary: "scope(device=\(device.name), queue=nil, label=\(MetalCaptureService.describeOptionalString(scope.label)))"
                ))
            case .queue, .queueScope:
                fatalError("unreachable")
            }

        case .queue, .queueScope:
            guard let trackedQueue = latestTrackedCommandQueue() else {
                return .failure(
                    .trackedCommandQueueUnavailable(
                        target: target,
                        trackedQueueCount: trackedCommandQueueCount(),
                        queueDiscoveryInstalled: queueDiscoveryInstalled
                    )
                )
            }

            switch target {
            case .queue:
                return .success((
                    captureObject: trackedQueue.queue,
                    scope: nil,
                    summary: "queue(\(trackedQueue.summary))"
                ))
            case .queueScope:
                let scope = manager.makeCaptureScope(commandQueue: trackedQueue.queue)
                scope.label = "PlayCover.capture.queue-scope.\(UUID().uuidString.lowercased())"
                return .success((
                    captureObject: scope as Any,
                    scope: scope,
                    summary: "scope(queue=\(trackedQueue.summary), label=\(MetalCaptureService.describeOptionalString(scope.label)))"
                ))
            case .device, .scope:
                fatalError("unreachable")
            }
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
        // Note: lastCaptureWasEmptyTrace is NOT reset here — it persists
        // so that getStatus() can report the empty trace condition.
    }

    /// 查询截帧状态
    @objc public func getStatus() -> CaptureStatus {
        // Lazily load libmtlcapture.dylib and re-acquire MTLCaptureManager (RC-009)
        _ = ensureGPUToolsCaptureLoaded()
        return makeStatus(manager: captureManager)
    }

    private func installQueueDiscoveryIfNeeded() {
        guard !queueDiscoveryInstalled else { return }

        queueDiscoveryInstalled = true
        guard let device = MTLCreateSystemDefaultDevice() else {
            logStatusProbe("queue discovery skipped because default Metal device is unavailable")
            return
        }

        let deviceClass: AnyClass = object_getClass(device) ?? NSClassFromString(NSStringFromClass(type(of: device)))!

        // RC-015: Pre-swizzle diagnostics — check if GPUToolsCapture already hooked newCommandQueue
        logRC015PreSwizzleDiagnostics(deviceClass: deviceClass, device: device)

        let installedNewCommandQueue = swizzleInstanceMethod(
            on: deviceClass,
            original: NSSelectorFromString("newCommandQueue"),
            swizzled: #selector(CommandQueueDiscoverySwizzles.pc_newCommandQueue)
        )
        let installedNewCommandQueueWithMaxCount = swizzleInstanceMethod(
            on: deviceClass,
            original: NSSelectorFromString("newCommandQueueWithMaxCommandBufferCount:"),
            swizzled: #selector(CommandQueueDiscoverySwizzles.pc_newCommandQueueWithMaxCommandBufferCount(_:))
        )

        // RC-015: Post-swizzle diagnostics
        logRC015PostSwizzleDiagnostics(deviceClass: deviceClass)

        logStatusProbe(
            "queue discovery install finished. deviceClass=\(NSStringFromClass(deviceClass)), newCommandQueue=\(installedNewCommandQueue), newCommandQueueWithMaxCommandBufferCount=\(installedNewCommandQueueWithMaxCount)"
        )
    }

    private func swizzleInstanceMethod(
        on targetClass: AnyClass,
        original originalSelector: Selector,
        swizzled swizzledSelector: Selector
    ) -> Bool {
        guard
            let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
            let swizzledMethod = class_getInstanceMethod(CommandQueueDiscoverySwizzles.self, swizzledSelector)
        else {
            logStatusProbe(
                "queue discovery swizzle skipped. class=\(NSStringFromClass(targetClass)), original=\(NSStringFromSelector(originalSelector)), swizzled=\(NSStringFromSelector(swizzledSelector))"
            )
            return false
        }

        let didAddMethod = class_addMethod(
            targetClass,
            swizzledSelector,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )

        if didAddMethod {
            guard let addedMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
                return false
            }
            method_exchangeImplementations(originalMethod, addedMethod)
            return true
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
        return true
    }

    private func recordTrackedCommandQueue(_ queue: MTLCommandQueue, source: String) {
        let now = Date()
        let identifier = ObjectIdentifier(queue as AnyObject)
        let summary: String

        trackedQueueLock.lock()
        if var existing = trackedCommandQueues[identifier] {
            existing.lastSeenAt = now
            existing.discoveryCount += 1
            existing.label = queue.label
            existing.deviceName = queue.device.name
            trackedCommandQueues[identifier] = existing
            summary = existing.summary
        } else {
            let trackedQueue = TrackedCommandQueue(
                queue: queue,
                source: source,
                className: NSStringFromClass(type(of: queue)),
                label: queue.label,
                deviceName: queue.device.name,
                firstSeenAt: now,
                lastSeenAt: now,
                discoveryCount: 1
            )
            trackedCommandQueues[identifier] = trackedQueue
            trackedCommandQueueOrder.append(identifier)
            trimTrackedQueuesIfNeeded()
            summary = trackedQueue.summary
        }
        trackedQueueLock.unlock()

        logStatusProbe("tracked command queue observed. \(summary)")
    }

    private func trimTrackedQueuesIfNeeded() {
        while trackedCommandQueueOrder.count > Self.maxTrackedCommandQueues {
            let removedIdentifier = trackedCommandQueueOrder.removeFirst()
            trackedCommandQueues.removeValue(forKey: removedIdentifier)
        }
    }

    private func trackedCommandQueueCount() -> Int {
        trackedQueueLock.lock()
        defer { trackedQueueLock.unlock() }
        return trackedCommandQueues.count
    }

    private func latestTrackedCommandQueue() -> TrackedCommandQueue? {
        trackedQueueLock.lock()
        defer { trackedQueueLock.unlock() }

        for identifier in trackedCommandQueueOrder.reversed() {
            if let trackedQueue = trackedCommandQueues[identifier] {
                return trackedQueue
            }
        }
        return nil
    }

    private func queueSummary(for queue: MTLCommandQueue) -> String {
        let identifier = ObjectIdentifier(queue as AnyObject)
        trackedQueueLock.lock()
        let trackedQueue = trackedCommandQueues[identifier]
        trackedQueueLock.unlock()

        if let trackedQueue {
            return trackedQueue.summary
        }

        return [
            "class=\(NSStringFromClass(type(of: queue)))",
            "label=\(MetalCaptureService.describeOptionalString(queue.label))",
            "device=\(queue.device.name)",
            "source=untracked",
        ].joined(separator: ", ")
    }

    private func makeStatus(manager: MTLCaptureManager?) -> CaptureStatus {
        let enabled = PlaySettings.shared.metalCaptureEnabled
        let available = manager != nil
        let supportsGPUTrace = manager?.supportsDestination(.gpuTraceDocument) ?? false
        let supportsDeveloperTools = manager?.supportsDestination(.developerTools) ?? false
        let defaultDevice = MTLCreateSystemDefaultDevice()
        let hasDefaultDevice = defaultDevice != nil
        let defaultDeviceName = defaultDevice?.name
        let defaultCaptureScope = manager?.defaultCaptureScope
        let latestTrackedQueue = latestTrackedCommandQueue()
        let trackedQueueCount = trackedCommandQueueCount()
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
            "defaultDeviceName=\(Self.describeOptionalString(defaultDeviceName))",
            "queueDiscoveryInstalled=\(queueDiscoveryInstalled)",
            "trackedCommandQueues=\(trackedQueueCount)",
            "latestTrackedQueue=\(Self.describeOptionalString(latestTrackedQueue?.summary))",
            "defaultCaptureScopeLabel=\(Self.describeOptionalString(defaultCaptureScope?.label))",
            "lastCaptureWasEmptyTrace=\(lastCaptureWasEmptyTrace)",
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
            diagnosticSummary: diagnosticSummary,
            queueDiscoveryInstalled: queueDiscoveryInstalled,
            trackedCommandQueueCount: trackedQueueCount,
            latestCommandQueueLabel: latestTrackedQueue?.label,
            latestCommandQueueDeviceName: latestTrackedQueue?.deviceName,
            latestCommandQueueClassName: latestTrackedQueue?.className,
            defaultCaptureScopeLabel: defaultCaptureScope?.label
        )
    }

    private func logStatusProbe(_ message: String) {
        print("[PlayTools] MetalCaptureService: \(message)")
    }

    private static func describeOptionalString(_ value: String?) -> String {
        value ?? "nil"
    }

    // MARK: - RC-015: Deep diagnostics for GPUToolsCapture proxy investigation

    /// Walk the class hierarchy of an object and return as a string "ClassName -> SuperClass -> ..."
    static func classHierarchyString(of obj: AnyObject) -> String {
        var hierarchy: [String] = []
        var cls: AnyClass? = object_getClass(obj)
        while let current = cls {
            hierarchy.append(NSStringFromClass(current))
            cls = class_getSuperclass(current)
        }
        return hierarchy.joined(separator: " -> ")
    }

    /// RC-015: Log IMP address of newCommandQueue before PlayTools swizzle,
    /// to determine if GPUToolsCapture has already hooked it.
    private func logRC015PreSwizzleDiagnostics(deviceClass: AnyClass, device: MTLDevice) {
        let sel = NSSelectorFromString("newCommandQueue")
        let selMax = NSSelectorFromString("newCommandQueueWithMaxCommandBufferCount:")

        let method = class_getInstanceMethod(deviceClass, sel)
        let methodMax = class_getInstanceMethod(deviceClass, selMax)

        let impAddr = method.map { unsafeBitCast(method_getImplementation($0), to: UInt.self) } ?? 0
        let impMaxAddr = methodMax.map { unsafeBitCast(method_getImplementation($0), to: UInt.self) } ?? 0

        // Check if CaptureMTLCommandQueue class exists (indicates GPUToolsCapture loaded)
        let captureQueueClass = NSClassFromString("CaptureMTLCommandQueue")
        let captureDeviceClass = NSClassFromString("CaptureMTLDevice")
        let gpuToolsCaptureLoaded = captureQueueClass != nil

        // Check the device's class hierarchy
        let deviceHierarchy = Self.classHierarchyString(of: device as AnyObject)

        // Check if the device is a Capture* proxy
        let deviceIsaClassName = NSStringFromClass(object_getClass(device as AnyObject)!)

        // Try creating a queue to see what class it produces BEFORE our swizzle
        let probeQueue = device.makeCommandQueue()
        let probeQueueClass = probeQueue.map { NSStringFromClass(object_getClass($0 as AnyObject)!) } ?? "nil"
        let probeQueueHierarchy = probeQueue.map { Self.classHierarchyString(of: $0 as AnyObject) } ?? "nil"

        NSLog("[PlayTools] RC-015 PRE-SWIZZLE: deviceClass=%@, deviceIsa=%@, deviceHierarchy=[%@]",
              NSStringFromClass(deviceClass), deviceIsaClassName, deviceHierarchy)
        NSLog("[PlayTools] RC-015 PRE-SWIZZLE: newCommandQueue IMP=0x%lx, newCommandQueueWithMax IMP=0x%lx",
              impAddr, impMaxAddr)
        NSLog("[PlayTools] RC-015 PRE-SWIZZLE: CaptureMTLCommandQueue exists=%d, CaptureMTLDevice exists=%d, gpuToolsCaptureLoaded=%d",
              captureQueueClass != nil ? 1 : 0, captureDeviceClass != nil ? 1 : 0, gpuToolsCaptureLoaded ? 1 : 0)
        NSLog("[PlayTools] RC-015 PRE-SWIZZLE probe: queue class=%@, hierarchy=[%@]",
              probeQueueClass, probeQueueHierarchy)

        // Enumerate all loaded Capture* classes from GPUToolsCapture
        logRC015CaptureClasses()
    }

    /// RC-015: Log IMP address of newCommandQueue after PlayTools swizzle
    private func logRC015PostSwizzleDiagnostics(deviceClass: AnyClass) {
        let sel = NSSelectorFromString("newCommandQueue")
        let method = class_getInstanceMethod(deviceClass, sel)
        let impAddr = method.map { unsafeBitCast(method_getImplementation($0), to: UInt.self) } ?? 0
        NSLog("[PlayTools] RC-015 POST-SWIZZLE: newCommandQueue IMP=0x%lx (should be pc_newCommandQueue)", impAddr)
    }

    /// RC-015: Enumerate all ObjC classes that start with "Capture" (from GPUToolsCapture)
    /// Delegates to C implementation to avoid Swift runtime crashes during class enumeration
    private func logRC015CaptureClasses() {
        playToolsLogGPUToolsCaptureClassesCShim()
    }

    /// RC-015: Detailed diagnostics run once per captureFrame call
    private var rc015CaptureFrameDiagnosticsDone = false

    func logRC015CaptureFrameDiagnostics() {
        guard !rc015CaptureFrameDiagnosticsDone else { return }
        rc015CaptureFrameDiagnosticsDone = true

        // 1. Enumerate all tracked queues with deep class info
        trackedQueueLock.lock()
        let queuesCopy = trackedCommandQueues
        let orderCopy = trackedCommandQueueOrder
        trackedQueueLock.unlock()

        NSLog("[PlayTools] RC-015 CAPTURE DIAG: %d tracked queues", queuesCopy.count)
        for (idx, id) in orderCopy.enumerated() {
            guard let tq = queuesCopy[id] else { continue }
            let hierarchy = Self.classHierarchyString(of: tq.queue as AnyObject)
            let respondsTraceStream = (tq.queue as AnyObject).responds(to: NSSelectorFromString("traceStream"))
            let isCaptureProxy = NSStringFromClass(object_getClass(tq.queue as AnyObject)!).hasPrefix("Capture")
            NSLog("[PlayTools] RC-015 CAPTURE DIAG: queue[%d] class=%@, isCaptureProxy=%d, traceStream=%d, hierarchy=[%@], label=%@, device=%@",
                  idx, tq.className, isCaptureProxy ? 1 : 0, respondsTraceStream ? 1 : 0,
                  hierarchy, tq.label ?? "nil", tq.deviceName)
        }

        // 2. Check the device being used for capture
        if let device = MTLCreateSystemDefaultDevice() {
            let deviceIsa = NSStringFromClass(object_getClass(device as AnyObject)!)
            let deviceHierarchy = Self.classHierarchyString(of: device as AnyObject)
            let isDeviceProxy = deviceIsa.hasPrefix("Capture")
            NSLog("[PlayTools] RC-015 CAPTURE DIAG: device isa=%@, isProxy=%d, hierarchy=[%@]",
                  deviceIsa, isDeviceProxy ? 1 : 0, deviceHierarchy)
        }
    }

    private func defaultOutputURL() -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let capturesDir = documentsURL.appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)

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
    @objc public let queueDiscoveryInstalled: Bool
    @objc public let trackedCommandQueueCount: Int
    @objc public let latestCommandQueueLabel: String?
    @objc public let latestCommandQueueDeviceName: String?
    @objc public let latestCommandQueueClassName: String?
    @objc public let defaultCaptureScopeLabel: String?

    @objc public init(
        available: Bool,
        supportsGPUTrace: Bool,
        supportsDeveloperTools: Bool,
        isCapturing: Bool,
        enabled: Bool,
        hasDefaultDevice: Bool,
        defaultDeviceName: String?,
        failureReason: String?,
        diagnosticSummary: String,
        queueDiscoveryInstalled: Bool,
        trackedCommandQueueCount: Int,
        latestCommandQueueLabel: String?,
        latestCommandQueueDeviceName: String?,
        latestCommandQueueClassName: String?,
        defaultCaptureScopeLabel: String?
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
        self.queueDiscoveryInstalled = queueDiscoveryInstalled
        self.trackedCommandQueueCount = trackedCommandQueueCount
        self.latestCommandQueueLabel = latestCommandQueueLabel
        self.latestCommandQueueDeviceName = latestCommandQueueDeviceName
        self.latestCommandQueueClassName = latestCommandQueueClassName
        self.defaultCaptureScopeLabel = defaultCaptureScopeLabel
    }
}
