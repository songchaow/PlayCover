// BridgeListener.swift
// PlayTools - Runtime Bridge Skeleton

import Foundation

/// Skeleton for the runtime-side bridge listener.
///
/// When PlayTools is loaded into an iOS app process, this listener:
/// 1. Starts a TCP server on a local port for receiving commands from the host
/// 2. Registers with the host MCP server via the well-known registration port
/// 3. Handles incoming commands (tap, swipe, etc.)
///
/// NOTE: This is a skeleton for S00. Full implementation will be in subsequent tasks.
/// The actual networking (NWConnection/NWListener) and command dispatch will be
/// implemented in S01+ when the session lifecycle is fleshed out.
class BridgeListener {

    /// The well-known host registration port.
    static let defaultRegistrationPort: UInt16 = 52741

    /// Start the bridge listener.
    ///
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the running app.
    ///   - registrationPort: The host's registration port.
    /// - Returns: The port this runtime is listening on for commands.
    func start(bundleId: String, registrationPort: UInt16 = defaultRegistrationPort) -> UInt16 {
        // TODO: S01 - Create NWListener on an ephemeral port for receiving commands
        // TODO: S01 - Connect to host registration port (NWConnection to 127.0.0.1:registrationPort)
        // TODO: S01 - Send BridgeMessage.register with sessionId, bundleId, pid, runtimePort
        // TODO: S01 - Verify BridgeMessage.registerAck response
        // TODO: S01 - Start heartbeat loop (ping/pong every N seconds)
        // TODO: S02 - Handle "tap" command -> Toucher.touchcam(...)
        // TODO: S02 - Handle "long_press" command -> Toucher.touchcam(...) with delay
        // TODO: S03 - Handle "swipe" / "drag" commands
        // TODO: S04 - Handle "press_key" / "type_text" / "toggle_debug_overlay" commands
        return 0
    }

    /// Stop the bridge listener.
    func stop() {
        // TODO: Send BridgeMessage.close to host
        // TODO: Cancel NWListener and NWConnection
        // TODO: Clean up heartbeat timer
    }

    /// Handle an incoming command from the host.
    ///
    /// This method will be called by the command listener when a command message arrives.
    /// - Parameter command: The command payload from the host.
    /// - Returns: A command response payload to send back.
    private func handleCommand(_ command: String, params: [String: Any]?) -> (status: String, result: [String: Any]?) {
        // TODO: S02+ - Implement actual command dispatch
        switch command {
        case "tap":
            // TODO: Extract x, y from params; call Toucher.touchcam
            return ("ok", nil)
        case "long_press":
            // TODO: Extract x, y, duration from params
            return ("ok", nil)
        case "swipe":
            // TODO: S03
            return ("error", ["message": "Not implemented"])
        case "drag":
            // TODO: S03
            return ("error", ["message": "Not implemented"])
        case "press_key":
            // S04: Simulate a key press event
            // Extract key and optional modifiers from params
            guard let key = params?["key"] as? String, !key.isEmpty else {
                return ("error", ["message": "press_key requires a 'key' parameter"])
            }
            // Note: Full keyboard simulation would require GCKeyboard or IOKit.
            // For now, we acknowledge the command. The runtime side implementation
            // depends on the app's key handling and may need to be extended
            // once a reliable key injection mechanism is established.
            return ("ok", ["key": key, "modifiers": params?["modifiers"] ?? []])
        case "type_text":
            // S04: Simulate typing a text string
            guard let text = params?["text"] as? String, !text.isEmpty else {
                return ("error", ["message": "type_text requires a 'text' parameter"])
            }
            // Note: Full text input simulation would require inserting text into
            // the first responder's UITextInput. For now, we acknowledge the command.
            // A future enhancement could use UITextInput.insertText() via the main thread.
            return ("ok", ["length": text.count])
        case "toggle_debug_overlay":
            // S04: Toggle the debug overlay
            DispatchQueue.main.async {
                DebugController.instance.toggleDebugOverlay()
            }
            return ("ok", ["toggled": true])

        // -- Metal Capture (R03) --
        case "capture_frame":
            // Trigger a one-frame GPU capture via MetalCaptureService.
            // Optional params: output_path (String), duration_ms (Int, unused – service auto-stops).
            let outputPath = params?["output_path"] as? String
            let outputURL = outputPath.flatMap { URL(fileURLWithPath: $0) }

            let result = MetalCaptureService.shared.captureFrame(outputURL: outputURL)
            if result.success {
                return ("ok", [
                    "output_path": result.outputPath ?? "",
                    "message": result.message
                ])
            } else {
                return ("error", ["message": result.message])
            }

        case "get_capture_status":
            // Return the current Metal capture status.
            let status = MetalCaptureService.shared.getStatus()
            return ("ok", [
                "available": status.available,
                "supports_gpu_trace": status.supportsGPUTrace,
                "is_capturing": status.isCapturing,
                "enabled": status.enabled
            ])
        default:
            return ("error", ["message": "Unknown command: \(command)"])
        }
    }
}
