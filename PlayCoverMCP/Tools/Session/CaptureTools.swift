// CaptureTools.swift
// PlayCoverMCP

import Foundation

/// Registers Metal capture MCP tools on the server.
///
/// Tools registered:
/// - `capture_metal_frame`: Trigger a one-frame GPU capture from a running app
/// - `get_capture_status`: Query the Metal capture service status for a running app
public enum CaptureTools {

    /// Register all capture tool metadata and their handlers on the server.
    public static func register(
        on server: MCPServer,
        captureService: CaptureServiceProtocol
    ) {
        registerCaptureFrame(on: server, captureService: captureService)
        registerGetCaptureStatus(on: server, captureService: captureService)
    }

    // MARK: - Synchronous bridge helper

    /// Run an async block synchronously using a semaphore.
    /// ToolHandler is synchronous, so we need to bridge to async capture service calls.
    private static func runAsync<T>(_ block: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                let value = try await block()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()

        switch result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    // MARK: - capture_metal_frame

    private static func registerCaptureFrame(
        on server: MCPServer,
        captureService: CaptureServiceProtocol
    ) {
        let tool = Tool(
            name: "capture_metal_frame",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to capture from"
                    ] as Any),
                    "output_path": AnyCodable([
                        "type": "string",
                        "description": "Optional custom output path for the .gputrace file. If not provided, a default path will be used."
                    ] as Any),
                    "duration_ms": AnyCodable([
                        "type": "integer",
                        "description": "Capture duration in milliseconds. Default: 100 (enough for 1-2 frames at 60fps). Max: 30000."
                    ] as Any),
                    "capture_target": AnyCodable([
                        "type": "string",
                        "enum": ["device", "scope"],
                        "description": "Experimental capture target. 'device' captures all queues on the default Metal device; 'scope' uses a temporary MTLCaptureScope aligned to vsync boundaries. Default: 'device'."
                    ] as Any),
                ],
                required: ["sessionId"]
            ),
            description: "Capture a Metal GPU frame from a running PlayCover-managed iOS app. Produces a .gputrace file that can be opened in Xcode for render pipeline analysis. The app must have metalCaptureEnabled set to true in its settings and must have been reinstalled after enabling the setting.",
            title: "Capture Metal Frame"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "capture_metal_frame") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "capture_metal_frame requires a non-empty 'sessionId' parameter"
                )
            }

            let outputPath = args["output_path"] as? String

            let durationMs: Int
            if let d = args["duration_ms"] as? Int {
                durationMs = d
            } else if let d = args["duration_ms"] as? Double {
                durationMs = Int(d)
            } else {
                durationMs = 100 // default
            }

            let captureTarget: CaptureTarget
            if let rawCaptureTarget = args["capture_target"] as? String {
                guard let parsedTarget = CaptureTarget(rawValue: rawCaptureTarget) else {
                    throw PlayCoverMCPError(
                        code: JSONRPCError.invalidParams,
                        message: "capture_metal_frame received unsupported 'capture_target': \(rawCaptureTarget). Supported values: device, scope"
                    )
                }
                captureTarget = parsedTarget
            } else {
                captureTarget = .device
            }

            let params = CaptureFrameParams(
                outputPath: outputPath,
                durationMs: durationMs,
                captureTarget: captureTarget
            )
            let result = try runAsync {
                try await captureService.captureFrame(sessionId: sessionId, params: params)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }

    // MARK: - get_capture_status

    private static func registerGetCaptureStatus(
        on server: MCPServer,
        captureService: CaptureServiceProtocol
    ) {
        let tool = Tool(
            name: "get_capture_status",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "sessionId": AnyCodable([
                        "type": "string",
                        "description": "The session ID of the running app to query"
                    ] as Any),
                ],
                required: ["sessionId"]
            ),
            description: "Get the Metal capture service status for a running PlayCover-managed iOS app. Returns whether capture is available, whether GPU trace export is supported, whether a capture is in progress, whether metalCaptureEnabled is on in settings, and when needed includes extra runtime diagnostics such as developer-tools support, default-device visibility, and failure reason.",
            title: "Get Capture Status"
        )
        server.toolRegistry.register(tool)

        server.registerTool(name: "get_capture_status") { arguments in
            guard let args = arguments?.dictionary,
                  let sessionId = args["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "get_capture_status requires a non-empty 'sessionId' parameter"
                )
            }

            let result = try runAsync {
                try await captureService.getCaptureStatus(sessionId: sessionId)
            }

            let data = try JSONSerialization.data(
                withJSONObject: result.toDictionary(),
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return CallToolResult(content: [.text(content: text)])
        }
    }
}
