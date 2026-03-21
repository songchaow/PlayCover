import Foundation
import UIKit

public final class SessionMCPBridge {
    public static let shared = SessionMCPBridge()

    public let registry: SessionToolRegistry
    public let context: SessionToolContext

    private let dateFormatter = ISO8601DateFormatter()
    private let pointerTools = SessionPointerToolController()

    public private(set) var isStarted = false

    private init(
        registry: SessionToolRegistry = SessionToolRegistry(),
        context: SessionToolContext = SessionToolContext(
            sessionID: SessionMCPBridge.makeSessionID(bundleID: PlaySettings.shared.bundleIdentifier),
            startupDate: Date(),
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            bundleID: PlaySettings.shared.bundleIdentifier
        )
    ) {
        self.registry = registry
        self.context = context
        registerDefaultTools()
        registerStatusTools()
        registerPointerTools()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
    }

    public func execute(_ call: SessionToolCall) async -> SessionToolResult {
        await registry.execute(call, context: context)
    }

    public func registeredTools() -> [SessionToolDescriptor] {
        registry.registeredTools()
    }

    private static func makeSessionID(bundleID: String) -> String {
        let bundleComponent = bundleID.isEmpty ? "unknown-bundle" : bundleID
        let processID = ProcessInfo.processInfo.processIdentifier
        return "session.\(bundleComponent).\(processID).\(UUID().uuidString.lowercased())"
    }

    private func registerDefaultTools() {
        registry.register(
            SessionToolDefinition(
                name: "session.ping",
                summary: "Verify that the Session MCP bridge is reachable in the injected runtime."
            ) { _, context in
                .success(
                    message: "Session MCP bridge is ready.",
                    data: .object([
                        "server": .string("session"),
                        "session_id": .string(context.sessionID),
                        "started_at": .string(self.dateFormatter.string(from: context.startupDate)),
                        "registered_tool_count": .int(self.registry.registeredTools().count)
                    ])
                )
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "session.describe_tools",
                summary: "List the currently registered Session MCP tools."
            ) { _, _ in
                let toolObjects = self.registry.registeredTools().map { descriptor in
                    SessionMCPValue.object([
                        "name": .string(descriptor.name),
                        "summary": .string(descriptor.summary)
                    ])
                }

                return .success(
                    message: "Registered session tools listed.",
                    data: .array(toolObjects)
                )
            }
        )
    }

    private func registerStatusTools() {
        registry.register(
            SessionToolDefinition(
                name: "session_status",
                summary: "Return a best-effort snapshot of the injected session runtime state."
            ) { arguments, context in
                try arguments.validateKeys(allowed: [])
                return await self.sessionStatusResult(context: context)
            }
        )
    }

    private func registerPointerTools() {
        registry.register(
            SessionToolDefinition(
                name: "tap",
                summary: "Inject a quick tap in the current key UIWindow coordinate space (origin at the top-left corner)."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["x", "y"])
                let x = try Self.requiredFiniteDouble(named: "x", from: arguments)
                let y = try Self.requiredFiniteDouble(named: "y", from: arguments)
                return try await self.pointerTools.tap(x: x, y: y)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "pointer_down",
                summary: "Begin a persistent pointer by external id in current key UIWindow coordinates."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["id", "x", "y"])
                let pointerID = try Self.requiredInt(named: "id", from: arguments)
                let x = try Self.requiredFiniteDouble(named: "x", from: arguments)
                let y = try Self.requiredFiniteDouble(named: "y", from: arguments)
                return try await self.pointerTools.pointerDown(pointerID: pointerID, x: x, y: y)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "pointer_move",
                summary: "Move an existing pointer id inside the current key UIWindow coordinate space."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["id", "x", "y"])
                let pointerID = try Self.requiredInt(named: "id", from: arguments)
                let x = try Self.requiredFiniteDouble(named: "x", from: arguments)
                let y = try Self.requiredFiniteDouble(named: "y", from: arguments)
                return try await self.pointerTools.pointerMove(pointerID: pointerID, x: x, y: y)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "pointer_up",
                summary: "End an existing pointer id inside the current key UIWindow coordinate space."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["id", "x", "y"])
                let pointerID = try Self.requiredInt(named: "id", from: arguments)
                let x = try Self.requiredFiniteDouble(named: "x", from: arguments)
                let y = try Self.requiredFiniteDouble(named: "y", from: arguments)
                return try await self.pointerTools.pointerUp(pointerID: pointerID, x: x, y: y)
            }
        )
    }

    private static func requiredInt(named key: String, from arguments: SessionToolArguments) throws -> Int {
        guard let value = try arguments.optionalInt(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return value
    }

    private static func requiredFiniteDouble(named key: String, from arguments: SessionToolArguments) throws -> Double {
        guard let value = try arguments.optionalDouble(key) else {
            throw SessionToolError.missingArgument(key)
        }
        guard value.isFinite else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Argument '\(key)' must be a finite number.",
                details: ["argument": .string(key)]
            )
        }
        return value
    }

    @MainActor
    private func sessionStatusResult(context: SessionToolContext) -> SessionToolResult {
        let keyWindow = PlayScreen.shared.keyWindow
        let foregroundWindow = PlayScreen.shared.window
        let bestWindow = keyWindow ?? foregroundWindow
        let windowFrame = bestWindow?.frame
        let bundleID = context.bundleID

        var warnings: [String] = []
        if bundleID.isEmpty {
            warnings.append("Bundle identifier is empty in PlaySettings; session reporting uses a fallback id.")
        }
        if !isStarted {
            warnings.append("Session MCP bridge has not been marked as started yet.")
        }
        if keyWindow == nil {
            warnings.append("No key UIWindow is available yet; window-related fields are best-effort.")
        }
        if bestWindow == nil {
            warnings.append("No foreground UIWindow is available yet; window_frame is null.")
        }

        let payload: [String: SessionMCPValue] = [
            "session_id": .string(context.sessionID),
            "bundle_id": bundleID.isEmpty ? .null : .string(bundleID),
            "mode": .string(mode.currentMode.rawValue),
            "has_key_window": .bool(keyWindow != nil),
            "window_frame": windowFrame.map(encodeRect) ?? .null,
            "playtools_loaded": .bool(isStarted)
        ]

        let frameSource: String
        if keyWindow != nil {
            frameSource = "key_window"
        } else if foregroundWindow != nil {
            frameSource = "foreground_window"
        } else {
            frameSource = "none"
        }

        return .success(
            message: "Session status retrieved.",
            data: .object(payload),
            warnings: warnings,
            debug: [
                "status_source": .string("UIApplication.shared.connectedScenes + PlayScreen.shared"),
                "started_at": .string(dateFormatter.string(from: context.startupDate)),
                "process_id": .int(context.processID),
                "registered_tool_count": .int(registry.registeredTools().count),
                "window_frame_source": .string(frameSource)
            ]
        )
    }
}

/// Session pointer tools use the current key UIWindow's coordinate space:
/// origin at top-left, x grows right, y grows down.
/// External pointer ids map 1:1 to Session-managed fake touch ids until `pointer_up` succeeds.
private final class SessionPointerToolController {
    private struct ActivePointer {
        var touchID: Int
        var lastPoint: CGPoint
    }

    private struct ValidatedPoint {
        let point: CGPoint
        let windowBounds: CGRect
        let coordinateSpace: SessionMCPValue
    }

    private let tapUpDelay: TimeInterval = 0.03
    private var activePointers: [Int: ActivePointer] = [:]

    func tap(x: Double, y: Double) async throws -> SessionToolResult {
        let request = try await validatedPoint(x: x, y: y)

        return try await withCheckedThrowingContinuation { continuation in
            PlayInput.touchQueue.async(qos: .userInteractive) {
                do {
                    var touchID: Int?
                    Toucher.touchcam(
                        point: request.point,
                        phase: .began,
                        tid: &touchID,
                        actionName: "SessionPointer",
                        keyName: "tap"
                    )
                    guard let activeTouchID = touchID else {
                        throw SessionToolError.executionFailed(
                            "Failed to begin tap injection.",
                            details: [
                                "point": encodePoint(request.point),
                                "coordinate_space": request.coordinateSpace
                            ]
                        )
                    }

                    PlayInput.touchQueue.asyncAfter(deadline: .now() + self.tapUpDelay, qos: .userInteractive) {
                        var endingTouchID: Int? = activeTouchID
                        Toucher.touchcam(
                            point: request.point,
                            phase: .ended,
                            tid: &endingTouchID,
                            actionName: "SessionPointer",
                            keyName: "tap"
                        )

                        guard endingTouchID == nil else {
                            continuation.resume(
                                throwing: SessionToolError.executionFailed(
                                    "Tap began successfully but failed to release cleanly.",
                                    details: [
                                        "touch_id": .int(activeTouchID),
                                        "point": encodePoint(request.point),
                                        "coordinate_space": request.coordinateSpace
                                    ]
                                )
                            )
                            return
                        }

                        continuation.resume(
                            returning: .success(
                                message: "Tap injected.",
                                data: .object([
                                    "phase": .string("tap"),
                                    "point": encodePoint(request.point),
                                    "coordinate_space": request.coordinateSpace
                                ]),
                                debug: [
                                    "touch_phase_sequence": .array([.string("began"), .string("ended")]),
                                    "tap_up_delay_ms": .int(Int(self.tapUpDelay * 1000.0))
                                ]
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pointerDown(pointerID: Int, x: Double, y: Double) async throws -> SessionToolResult {
        let request = try await validatedPoint(x: x, y: y)

        return try await runOnTouchQueue {
            guard let existingPointer = self.activePointers[pointerID] else {
                var touchID: Int?
                Toucher.touchcam(
                    point: request.point,
                    phase: .began,
                    tid: &touchID,
                    actionName: "SessionPointer",
                    keyName: "pointer_down"
                )
                guard let activeTouchID = touchID else {
                    throw SessionToolError.executionFailed(
                        "Failed to begin pointer \(pointerID).",
                        details: [
                            "id": .int(pointerID),
                            "point": encodePoint(request.point),
                            "coordinate_space": request.coordinateSpace
                        ]
                    )
                }

                self.activePointers[pointerID] = ActivePointer(touchID: activeTouchID, lastPoint: request.point)
                return .success(
                    message: "Pointer \(pointerID) pressed.",
                    data: .object([
                        "id": .int(pointerID),
                        "touch_id": .int(activeTouchID),
                        "phase": .string("began"),
                        "point": encodePoint(request.point),
                        "coordinate_space": request.coordinateSpace
                    ])
                )
            }

            throw SessionToolError.preconditionFailed(
                "Pointer \(pointerID) is already active.",
                details: [
                    "id": .int(pointerID),
                    "touch_id": .int(existingPointer.touchID),
                    "last_point": encodePoint(existingPointer.lastPoint),
                    "coordinate_space": request.coordinateSpace
                ]
            )
        }
    }

    func pointerMove(pointerID: Int, x: Double, y: Double) async throws -> SessionToolResult {
        let request = try await validatedPoint(x: x, y: y)

        return try await runOnTouchQueue {
            guard var pointer = self.activePointers[pointerID] else {
                throw SessionToolError.preconditionFailed(
                    "Pointer \(pointerID) is not active.",
                    details: [
                        "id": .int(pointerID),
                        "point": encodePoint(request.point),
                        "coordinate_space": request.coordinateSpace
                    ]
                )
            }

            var touchID: Int? = pointer.touchID
            Toucher.touchcam(
                point: request.point,
                phase: .moved,
                tid: &touchID,
                actionName: "SessionPointer",
                keyName: "pointer_move"
            )

            guard let updatedTouchID = touchID else {
                self.activePointers.removeValue(forKey: pointerID)
                throw SessionToolError.executionFailed(
                    "Pointer \(pointerID) became inactive during move.",
                    details: [
                        "id": .int(pointerID),
                        "point": encodePoint(request.point),
                        "coordinate_space": request.coordinateSpace
                    ]
                )
            }

            pointer.touchID = updatedTouchID
            pointer.lastPoint = request.point
            self.activePointers[pointerID] = pointer

            return .success(
                message: "Pointer \(pointerID) moved.",
                data: .object([
                    "id": .int(pointerID),
                    "touch_id": .int(updatedTouchID),
                    "phase": .string("moved"),
                    "point": encodePoint(request.point),
                    "coordinate_space": request.coordinateSpace
                ])
            )
        }
    }

    func pointerUp(pointerID: Int, x: Double, y: Double) async throws -> SessionToolResult {
        let request = try await validatedPoint(x: x, y: y)

        return try await runOnTouchQueue {
            guard let pointer = self.activePointers[pointerID] else {
                throw SessionToolError.preconditionFailed(
                    "Pointer \(pointerID) is not active.",
                    details: [
                        "id": .int(pointerID),
                        "point": encodePoint(request.point),
                        "coordinate_space": request.coordinateSpace
                    ]
                )
            }

            var touchID: Int? = pointer.touchID
            Toucher.touchcam(
                point: request.point,
                phase: .ended,
                tid: &touchID,
                actionName: "SessionPointer",
                keyName: "pointer_up"
            )

            guard touchID == nil else {
                self.activePointers[pointerID] = ActivePointer(touchID: touchID ?? pointer.touchID, lastPoint: request.point)
                throw SessionToolError.executionFailed(
                    "Pointer \(pointerID) failed to release cleanly.",
                    details: [
                        "id": .int(pointerID),
                        "touch_id": .int(touchID ?? pointer.touchID),
                        "point": encodePoint(request.point),
                        "coordinate_space": request.coordinateSpace
                    ]
                )
            }

            self.activePointers.removeValue(forKey: pointerID)
            return .success(
                message: "Pointer \(pointerID) released.",
                data: .object([
                    "id": .int(pointerID),
                    "phase": .string("ended"),
                    "point": encodePoint(request.point),
                    "coordinate_space": request.coordinateSpace
                ])
            )
        }
    }

    @MainActor
    private func coordinateSpaceSnapshot() throws -> ValidatedPoint {
        guard let keyWindow = screen.keyWindow else {
            throw SessionToolError.preconditionFailed(
                "No key UIWindow is available for session touch injection yet."
            )
        }

        let bounds = keyWindow.bounds
        return ValidatedPoint(
            point: .zero,
            windowBounds: bounds,
            coordinateSpace: .object([
                "space": .string("key_window"),
                "origin": .string("top_left"),
                "x_axis": .string("right"),
                "y_axis": .string("down"),
                "window_bounds": encodeRect(bounds)
            ])
        )
    }

    private func validatedPoint(x: Double, y: Double) async throws -> ValidatedPoint {
        let snapshot = try await MainActor.run { try self.coordinateSpaceSnapshot() }
        let point = CGPoint(x: x, y: y)

        guard point.x >= snapshot.windowBounds.minX,
              point.y >= snapshot.windowBounds.minY,
              point.x <= snapshot.windowBounds.maxX,
              point.y <= snapshot.windowBounds.maxY else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Point is outside the current key UIWindow bounds.",
                details: [
                    "point": encodePoint(point),
                    "coordinate_space": snapshot.coordinateSpace
                ]
            )
        }

        return ValidatedPoint(
            point: point,
            windowBounds: snapshot.windowBounds,
            coordinateSpace: snapshot.coordinateSpace
        )
    }

    private func runOnTouchQueue(
        _ operation: @escaping () throws -> SessionToolResult
    ) async throws -> SessionToolResult {
        try await withCheckedThrowingContinuation { continuation in
            PlayInput.touchQueue.async(qos: .userInteractive) {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func encodePoint(_ point: CGPoint) -> SessionMCPValue {
    .object([
        "x": .double(Double(point.x)),
        "y": .double(Double(point.y))
    ])
}

private func encodeRect(_ rect: CGRect) -> SessionMCPValue {
    .object([
        "x": .double(Double(rect.origin.x)),
        "y": .double(Double(rect.origin.y)),
        "width": .double(Double(rect.size.width)),
        "height": .double(Double(rect.size.height))
    ])
}
