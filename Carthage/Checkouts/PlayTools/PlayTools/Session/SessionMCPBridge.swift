import Foundation
import UIKit

public final class SessionMCPBridge {
    public static let shared = SessionMCPBridge()

    public let registry: SessionToolRegistry
    public let context: SessionToolContext

    private let dateFormatter = ISO8601DateFormatter()

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
            "window_frame": windowFrame.map(Self.encode(rect:)) ?? .null,
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

    private static func encode(rect: CGRect) -> SessionMCPValue {
        .object([
            "x": .double(Double(rect.origin.x)),
            "y": .double(Double(rect.origin.y)),
            "width": .double(Double(rect.size.width)),
            "height": .double(Double(rect.size.height))
        ])
    }
}
