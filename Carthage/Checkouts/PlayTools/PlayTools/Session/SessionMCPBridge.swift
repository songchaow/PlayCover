import Foundation
import UIKit

public final class SessionMCPBridge {
    public static let shared = SessionMCPBridge()

    public let registry: SessionToolRegistry
    public let context: SessionToolContext

    private let dateFormatter = ISO8601DateFormatter()
    private let pointerTools = SessionPointerToolController()
    private let mappedInputTools = SessionMappedInputToolController()

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
        registerAdvancedTools()
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

    private func registerAdvancedTools() {
        registry.register(
            SessionToolDefinition(
                name: "drag",
                summary: "Drag from one UIWindow point to another over a caller-provided duration in seconds."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["from", "to", "duration"])
                let from = try Self.requiredPoint(named: "from", from: arguments)
                let to = try Self.requiredPoint(named: "to", from: arguments)
                let duration = try Self.requiredPositiveDouble(named: "duration", from: arguments)
                return try await self.pointerTools.drag(from: from, to: to, duration: duration)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "swipe",
                summary: "Inject a swipe by following an ordered path of UIWindow points."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["path"])
                let path = try Self.requiredPointArray(named: "path", from: arguments)
                return try await self.pointerTools.swipe(path: path)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "pinch",
                summary: "Inject a best-effort two-finger pinch around a center point using a scale factor."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["center", "scale"])
                let center = try Self.requiredPoint(named: "center", from: arguments)
                let scale = try Self.requiredPositiveDouble(named: "scale", from: arguments)
                return try await self.pointerTools.pinch(center: center, scale: scale)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "button",
                summary: "Dispatch a named keymap button press or release through the existing ActionDispatcher."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["name", "pressed"])
                let name = try Self.requiredNonEmptyString(named: "name", from: arguments)
                let pressed = try Self.requiredBool(named: "pressed", from: arguments)
                return try self.mappedInputTools.button(name: name, pressed: pressed)
            }
        )

        registry.register(
            SessionToolDefinition(
                name: "thumbstick",
                summary: "Dispatch a normalized analog thumbstick vector in the range [-1, 1]. Positive y moves upward."
            ) { arguments, _ in
                try arguments.validateKeys(allowed: ["name", "x", "y"])
                let name = try Self.requiredNonEmptyString(named: "name", from: arguments)
                let x = try Self.requiredFiniteDoubleInRange(named: "x", from: arguments, allowedRange: -1.0...1.0)
                let y = try Self.requiredFiniteDoubleInRange(named: "y", from: arguments, allowedRange: -1.0...1.0)
                return try self.mappedInputTools.thumbstick(name: name, x: x, y: y)
            }
        )
    }

    private static func requiredInt(named key: String, from arguments: SessionToolArguments) throws -> Int {
        guard let value = try arguments.optionalInt(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return value
    }

    private static func requiredBool(named key: String, from arguments: SessionToolArguments) throws -> Bool {
        guard let value = try arguments.optionalBool(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return value
    }

    private static func requiredNonEmptyString(named key: String, from arguments: SessionToolArguments) throws -> String {
        let value = try arguments.requiredString(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Argument '\(key)' must not be empty.",
                details: ["argument": .string(key)]
            )
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

    private static func requiredPositiveDouble(named key: String, from arguments: SessionToolArguments) throws -> Double {
        let value = try requiredFiniteDouble(named: key, from: arguments)
        guard value > 0 else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Argument '\(key)' must be greater than zero.",
                details: ["argument": .string(key)]
            )
        }
        return value
    }

    private static func requiredFiniteDoubleInRange(
        named key: String,
        from arguments: SessionToolArguments,
        allowedRange: ClosedRange<Double>
    ) throws -> Double {
        let value = try requiredFiniteDouble(named: key, from: arguments)
        guard allowedRange.contains(value) else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Argument '\(key)' must be between \(allowedRange.lowerBound) and \(allowedRange.upperBound).",
                details: [
                    "argument": .string(key),
                    "min": .double(allowedRange.lowerBound),
                    "max": .double(allowedRange.upperBound),
                    "actual": .double(value)
                ]
            )
        }
        return value
    }

    private static func requiredPoint(named key: String, from arguments: SessionToolArguments) throws -> CGPoint {
        guard let object = try arguments.optionalObject(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return try point(from: .object(object), label: key)
    }

    private static func requiredPointArray(named key: String, from arguments: SessionToolArguments) throws -> [CGPoint] {
        guard let array = try arguments.optionalArray(key) else {
            throw SessionToolError.missingArgument(key)
        }
        return try array.enumerated().map { index, value in
            try point(from: value, label: "\(key)[\(index)]")
        }
    }

    private static func point(from value: SessionMCPValue, label: String) throws -> CGPoint {
        guard let object = value.objectValue else {
            throw SessionToolError.invalidArgument(name: label, expected: "object{x,y}", actual: value)
        }

        let unexpectedKeys = object.keys.filter { $0 != "x" && $0 != "y" }.sorted()
        guard unexpectedKeys.isEmpty else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Point '\(label)' contains unexpected keys: \(unexpectedKeys.joined(separator: ", ")).",
                details: [
                    "argument": .string(label),
                    "unexpected_keys": .array(unexpectedKeys.map { .string($0) })
                ]
            )
        }

        guard let rawX = object["x"] else {
            throw SessionToolError.missingArgument("\(label).x")
        }
        guard let rawY = object["y"] else {
            throw SessionToolError.missingArgument("\(label).y")
        }
        guard let x = rawX.doubleValue, x.isFinite else {
            throw SessionToolError.invalidArgument(name: "\(label).x", expected: "double", actual: rawX)
        }
        guard let y = rawY.doubleValue, y.isFinite else {
            throw SessionToolError.invalidArgument(name: "\(label).y", expected: "double", actual: rawY)
        }

        return CGPoint(x: x, y: y)
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

    fileprivate struct ValidatedPoint {
        let point: CGPoint
        let windowBounds: CGRect
        let coordinateSpace: SessionMCPValue
    }

    private let tapUpDelay: TimeInterval = 0.03
    private let gestureFrameInterval: TimeInterval = 1.0 / 60.0
    private let defaultPinchSteps = 8
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

    func drag(from: CGPoint, to: CGPoint, duration: Double) async throws -> SessionToolResult {
        let start = try await validatedPoint(point: from)
        let end = try await validatedPoint(point: to)

        let segmentCount = max(1, min(120, Int(ceil(duration / gestureFrameInterval))))
        let path = interpolatedPoints(from: start.point, to: end.point, segmentCount: segmentCount)
        let stepInterval = duration / Double(segmentCount)

        try await performPath(
            path,
            actionName: "SessionGesture",
            keyName: "drag",
            stepInterval: stepInterval,
            coordinateSpace: start.coordinateSpace
        )

        return .success(
            message: "Drag injected.",
            data: .object([
                "accepted": .bool(true),
                "from": encodePoint(start.point),
                "to": encodePoint(end.point),
                "duration_seconds": .double(duration),
                "coordinate_space": start.coordinateSpace
            ]),
            debug: [
                "gesture_impl": .string("pointer_path"),
                "path_point_count": .int(path.count),
                "segment_count": .int(segmentCount),
                "step_interval_ms": .int(Int(stepInterval * 1000.0))
            ]
        )
    }

    func swipe(path: [CGPoint]) async throws -> SessionToolResult {
        guard path.count >= 2 else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Swipe path must contain at least two points.",
                details: ["point_count": .int(path.count)]
            )
        }

        var validatedPath: [ValidatedPoint] = []
        validatedPath.reserveCapacity(path.count)
        for point in path {
            validatedPath.append(try await self.validatedPoint(point: point))
        }
        let coordinateSpace = validatedPath[0].coordinateSpace
        let points = validatedPath.map(\.point)

        try await performPath(
            points,
            actionName: "SessionGesture",
            keyName: "swipe",
            stepInterval: gestureFrameInterval,
            coordinateSpace: coordinateSpace
        )

        return .success(
            message: "Swipe injected.",
            data: .object([
                "accepted": .bool(true),
                "path": .array(points.map(encodePoint)),
                "coordinate_space": coordinateSpace
            ]),
            debug: [
                "gesture_impl": .string("pointer_path"),
                "path_point_count": .int(points.count),
                "step_interval_ms": .int(Int(gestureFrameInterval * 1000.0))
            ]
        )
    }

    func pinch(center: CGPoint, scale: Double) async throws -> SessionToolResult {
        let centerPoint = try await validatedPoint(point: center)

        let safeHorizontalRadius = min(
            centerPoint.point.x - centerPoint.windowBounds.minX,
            centerPoint.windowBounds.maxX - centerPoint.point.x
        ) - 1

        guard safeHorizontalRadius >= 12 else {
            throw SessionToolError.preconditionFailed(
                "Pinch center is too close to the window edge.",
                details: [
                    "center": encodePoint(centerPoint.point),
                    "coordinate_space": centerPoint.coordinateSpace
                ]
            )
        }

        let minimumRadius: CGFloat = 12
        let nominalRadius = min(CGFloat(60), safeHorizontalRadius)
        var warnings: [String] = []

        var startRadius: CGFloat
        var endRadius: CGFloat
        if scale >= 1 {
            startRadius = max(minimumRadius, min(nominalRadius / CGFloat(scale), safeHorizontalRadius))
            endRadius = min(safeHorizontalRadius, startRadius * CGFloat(scale))
        } else {
            startRadius = min(nominalRadius, safeHorizontalRadius)
            endRadius = max(minimumRadius, startRadius * CGFloat(scale))
        }

        startRadius = min(startRadius, safeHorizontalRadius)
        endRadius = min(endRadius, safeHorizontalRadius)

        if abs((endRadius / startRadius) - CGFloat(scale)) > 0.01 {
            warnings.append("Pinch scale was clamped to stay inside the current key UIWindow bounds.")
        }
        if scale == 1 {
            warnings.append("Requested pinch scale is 1, so only a minimal two-finger gesture was injected.")
        }

        let startLeft = CGPoint(x: centerPoint.point.x - startRadius, y: centerPoint.point.y)
        let startRight = CGPoint(x: centerPoint.point.x + startRadius, y: centerPoint.point.y)
        let endLeft = CGPoint(x: centerPoint.point.x - endRadius, y: centerPoint.point.y)
        let endRight = CGPoint(x: centerPoint.point.x + endRadius, y: centerPoint.point.y)

        let validatedStartLeft = try await validatedPoint(point: startLeft)
        let validatedStartRight = try await validatedPoint(point: startRight)
        let validatedEndLeft = try await validatedPoint(point: endLeft)
        let validatedEndRight = try await validatedPoint(point: endRight)

        let leftPath = interpolatedPoints(from: validatedStartLeft.point, to: validatedEndLeft.point, segmentCount: defaultPinchSteps)
        let rightPath = interpolatedPoints(from: validatedStartRight.point, to: validatedEndRight.point, segmentCount: defaultPinchSteps)

        try await performDualPath(
            leftPath: leftPath,
            rightPath: rightPath,
            actionName: "SessionGesture",
            keyName: "pinch",
            stepInterval: gestureFrameInterval,
            coordinateSpace: centerPoint.coordinateSpace
        )

        let effectiveScale = Double(endRadius / startRadius)
        return .success(
            message: "Pinch injected.",
            data: .object([
                "accepted": .bool(true),
                "center": encodePoint(centerPoint.point),
                "scale_requested": .double(scale),
                "scale_effective": .double(effectiveScale),
                "start_points": .array([encodePoint(validatedStartLeft.point), encodePoint(validatedStartRight.point)]),
                "end_points": .array([encodePoint(validatedEndLeft.point), encodePoint(validatedEndRight.point)]),
                "coordinate_space": centerPoint.coordinateSpace
            ]),
            warnings: warnings,
            debug: [
                "gesture_impl": .string("dual_pointer_path"),
                "path_point_count": .int(leftPath.count),
                "step_interval_ms": .int(Int(gestureFrameInterval * 1000.0))
            ]
        )
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
        try await validatedPoint(point: CGPoint(x: x, y: y))
    }

    fileprivate func validatedPoint(point: CGPoint) async throws -> ValidatedPoint {
        let snapshot = try await MainActor.run { try self.coordinateSpaceSnapshot() }

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

    fileprivate func runOnTouchQueue<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
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

    private func performPath(
        _ points: [CGPoint],
        actionName: String,
        keyName: String,
        stepInterval: TimeInterval,
        coordinateSpace: SessionMCPValue
    ) async throws {
        guard points.count >= 2 else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Gesture path must contain at least two points.",
                details: ["coordinate_space": coordinateSpace]
            )
        }

        var touchID: Int?
        try await runOnTouchQueue {
            Toucher.touchcam(point: points[0], phase: .began, tid: &touchID, actionName: actionName, keyName: keyName)
            guard touchID != nil else {
                throw SessionToolError.executionFailed(
                    "Failed to begin \(keyName) gesture.",
                    details: [
                        "point": encodePoint(points[0]),
                        "coordinate_space": coordinateSpace
                    ]
                )
            }
        }

        for point in points.dropFirst().dropLast() {
            try await sleepIfNeeded(stepInterval)
            try await runOnTouchQueue {
                Toucher.touchcam(point: point, phase: .moved, tid: &touchID, actionName: actionName, keyName: keyName)
                guard touchID != nil else {
                    throw SessionToolError.executionFailed(
                        "\(keyName) gesture became inactive during move.",
                        details: [
                            "point": encodePoint(point),
                            "coordinate_space": coordinateSpace
                        ]
                    )
                }
            }
        }

        try await sleepIfNeeded(stepInterval)
        let finalPoint = points[points.count - 1]
        try await runOnTouchQueue {
            Toucher.touchcam(point: finalPoint, phase: .ended, tid: &touchID, actionName: actionName, keyName: keyName)
            guard touchID == nil else {
                throw SessionToolError.executionFailed(
                    "\(keyName) gesture failed to release cleanly.",
                    details: [
                        "point": encodePoint(finalPoint),
                        "touch_id": .int(touchID ?? -1),
                        "coordinate_space": coordinateSpace
                    ]
                )
            }
        }
    }

    private func performDualPath(
        leftPath: [CGPoint],
        rightPath: [CGPoint],
        actionName: String,
        keyName: String,
        stepInterval: TimeInterval,
        coordinateSpace: SessionMCPValue
    ) async throws {
        guard leftPath.count == rightPath.count, leftPath.count >= 2 else {
            throw SessionToolError(
                code: .invalidArguments,
                message: "Pinch gesture paths must contain the same number of points.",
                details: ["coordinate_space": coordinateSpace]
            )
        }

        var leftTouchID: Int?
        var rightTouchID: Int?
        try await runOnTouchQueue {
            Toucher.touchcam(point: leftPath[0], phase: .began, tid: &leftTouchID, actionName: actionName, keyName: keyName + ".left")
            Toucher.touchcam(point: rightPath[0], phase: .began, tid: &rightTouchID, actionName: actionName, keyName: keyName + ".right")
            guard leftTouchID != nil, rightTouchID != nil else {
                throw SessionToolError.executionFailed(
                    "Failed to begin pinch gesture.",
                    details: [
                        "left_point": encodePoint(leftPath[0]),
                        "right_point": encodePoint(rightPath[0]),
                        "coordinate_space": coordinateSpace
                    ]
                )
            }
        }

        for index in 1..<(leftPath.count - 1) {
            try await sleepIfNeeded(stepInterval)
            try await runOnTouchQueue {
                Toucher.touchcam(point: leftPath[index], phase: .moved, tid: &leftTouchID, actionName: actionName, keyName: keyName + ".left")
                Toucher.touchcam(point: rightPath[index], phase: .moved, tid: &rightTouchID, actionName: actionName, keyName: keyName + ".right")
                guard leftTouchID != nil, rightTouchID != nil else {
                    throw SessionToolError.executionFailed(
                        "Pinch gesture became inactive during move.",
                        details: [
                            "left_point": encodePoint(leftPath[index]),
                            "right_point": encodePoint(rightPath[index]),
                            "coordinate_space": coordinateSpace
                        ]
                    )
                }
            }
        }

        try await sleepIfNeeded(stepInterval)
        let finalLeft = leftPath[leftPath.count - 1]
        let finalRight = rightPath[rightPath.count - 1]
        try await runOnTouchQueue {
            Toucher.touchcam(point: finalLeft, phase: .ended, tid: &leftTouchID, actionName: actionName, keyName: keyName + ".left")
            Toucher.touchcam(point: finalRight, phase: .ended, tid: &rightTouchID, actionName: actionName, keyName: keyName + ".right")
            guard leftTouchID == nil, rightTouchID == nil else {
                throw SessionToolError.executionFailed(
                    "Pinch gesture failed to release cleanly.",
                    details: [
                        "left_point": encodePoint(finalLeft),
                        "right_point": encodePoint(finalRight),
                        "left_touch_id": .int(leftTouchID ?? -1),
                        "right_touch_id": .int(rightTouchID ?? -1),
                        "coordinate_space": coordinateSpace
                    ]
                )
            }
        }
    }

    private func interpolatedPoints(from start: CGPoint, to end: CGPoint, segmentCount: Int) -> [CGPoint] {
        let segments = max(1, segmentCount)
        return (0...segments).map { index in
            let progress = CGFloat(index) / CGFloat(segments)
            return CGPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
        }
    }

    private func sleepIfNeeded(_ duration: TimeInterval) async throws {
        guard duration > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000.0))
    }
}

private final class SessionMappedInputToolController {
    func button(name: String, pressed: Bool) throws -> SessionToolResult {
        if ActionDispatcher.dispatch(key: name, pressed: pressed) {
            return .success(
                message: "Button dispatched.",
                data: .object([
                    "accepted": .bool(true),
                    "name": .string(name),
                    "pressed": .bool(pressed),
                    "resolved_dispatch_keys": .array([.string(name)])
                ]),
                debug: ["resolved_via": .string("dispatch_key")]
            )
        }

        let fallbackKeys = logicalButtonDispatchKeys(named: name)
        let acceptedKeys = fallbackKeys.filter { ActionDispatcher.dispatch(key: $0, pressed: pressed) }
        guard !acceptedKeys.isEmpty else {
            throw SessionToolError.preconditionFailed(
                "Button '\(name)' is not mapped in the current keymap.",
                details: [
                    "requested_name": .string(name),
                    "available_button_names": .array(availableButtonNames().map { .string($0) })
                ]
            )
        }

        return .success(
            message: "Button dispatched through current keymap resolution.",
            data: .object([
                "accepted": .bool(true),
                "name": .string(name),
                "pressed": .bool(pressed),
                "resolved_dispatch_keys": .array(acceptedKeys.map { .string($0) })
            ]),
            warnings: ["Resolved button name through the current keymap because no direct dispatch handler matched the requested name."],
            debug: ["resolved_via": .string("current_keymap")]
        )
    }

    func thumbstick(name: String, x: Double, y: Double) throws -> SessionToolResult {
        let candidateKeys = thumbstickDispatchCandidates(for: name)
        let acceptedKey = candidateKeys.first { ActionDispatcher.dispatch(key: $0, valueX: CGFloat(x), valueY: CGFloat(y)) }
        guard let acceptedKey else {
            throw SessionToolError.preconditionFailed(
                "Thumbstick '\(name)' is not available in the current keymap.",
                details: [
                    "requested_name": .string(name),
                    "available_thumbsticks": .array(availableAnalogThumbsticks().map { .string($0) })
                ]
            )
        }

        return .success(
            message: "Thumbstick dispatched.",
            data: .object([
                "accepted": .bool(true),
                "name": .string(name),
                "x": .double(x),
                "y": .double(y),
                "resolved_dispatch_key": .string(acceptedKey)
            ]),
            warnings: acceptedKey == name ? [] : ["Resolved thumbstick name through known aliases or current keymap names."],
            debug: [
                "resolved_via": .string(acceptedKey == name ? "dispatch_key" : "alias_or_keymap"),
                "y_axis": .string("positive_up")
            ]
        )
    }

    private func logicalButtonDispatchKeys(named requestedName: String) -> [String] {
        let matchedButtons = keymap.currentKeymap.buttonModels + keymap.currentKeymap.draggableButtonModels
        let exactMatches = matchedButtons.filter { $0.keyName == requestedName }
        let caseInsensitiveMatches = exactMatches.isEmpty
            ? matchedButtons.filter { $0.keyName.caseInsensitiveCompare(requestedName) == .orderedSame }
            : []
        let matches = exactMatches.isEmpty ? caseInsensitiveMatches : exactMatches
        return uniqued(matches.map(buttonDispatchKey(for:)))
    }

    private func buttonDispatchKey(for button: Button) -> String {
        if button.keyCode == KeyCodeNames.defaultCode {
            return button.keyName
        }
        return KeyCodeNames.keyCodes[button.keyCode] ?? button.keyName
    }

    private func thumbstickDispatchCandidates(for requestedName: String) -> [String] {
        let keymapMatches = availableAnalogThumbsticks().filter { $0.caseInsensitiveCompare(requestedName) == .orderedSame }
        let alias = canonicalThumbstickAlias(for: requestedName)
        return uniqued([requestedName] + keymapMatches + [alias].compactMap { $0 })
    }

    private func canonicalThumbstickAlias(for requestedName: String) -> String? {
        switch requestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "") {
        case "left", "leftstick", "leftthumbstick":
            return "Left Thumbstick"
        case "right", "rightstick", "rightthumbstick":
            return "Right Thumbstick"
        case "mouse":
            return "Mouse"
        default:
            return nil
        }
    }

    private func availableButtonNames() -> [String] {
        uniqued((keymap.currentKeymap.buttonModels + keymap.currentKeymap.draggableButtonModels).map(\.keyName))
    }

    private func availableAnalogThumbsticks() -> [String] {
        uniqued(keymap.currentKeymap.joystickModel.filter(JoystickModel.isAnalog).map(\.keyName))
    }

    private func uniqued(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
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
