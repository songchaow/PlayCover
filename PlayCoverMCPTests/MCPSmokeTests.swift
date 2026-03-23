import XCTest
import Foundation

/// Stdio-level smoke tests: spawn the PlayCoverMCP process, send JSON-RPC
/// messages via stdin, and verify responses on stdout.
final class MCPSmokeTests: XCTestCase {

    private var process: Process?

    private func buildMCP() throws {
        // Build the PlayCoverMCP target
        let project = "/Users/songdogwang/Codes/PlayCover/PlayCover.xcodeproj"
        let buildDir = NSTemporaryDirectory() + "PlayCoverMCPBuild"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        task.arguments = [
            "-project", project,
            "-scheme", "PlayCoverMCP",
            "-configuration", "Release",
            "-derivedDataPath", buildDir,
            "build"
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            XCTFail("Build failed with exit code \(task.terminationStatus)")
            return
        }
    }

    private func findMCPBinary() -> String? {
        let buildDir = NSTemporaryDirectory() + "PlayCoverMCPBuild"
        let path = buildDir + "/Build/Products/Release/PlayCoverMCP"
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Also check for arm64 variant
        let path2 = buildDir + "/Build/Products/Release-arm64/PlayCoverMCP"
        if FileManager.default.isExecutableFile(atPath: path2) {
            return path2
        }
        return nil
    }

    private func sendMessage(_ json: String, to stdin: FileHandle) throws -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        stdin.write(data)
        return nil
    }

    /// End-to-end smoke test: send initialize + ping + tools/list + resources/list
    /// via stdin and verify each response on stdout.
    ///
    /// NOTE: This test is skipped by default because it requires the PlayCoverMCP
    /// binary to be built separately. Run manually with:
    ///   xcodebuild -scheme PlayCoverMCP build
    ///   SKIP_SMOKE=0 xcodebuild -scheme PlayCoverMCP test
    func testStdioSmokeFullHandshake() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKIP_SMOKE"] == "0",
            "Smoke test requires separate binary build. Use SKIP_SMOKE=0 to enable."
        )

        // Build first
        try buildMCP()

        guard let binary = findMCPBinary() else {
            XCTFail("Could not find PlayCoverMCP binary")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Give the process a moment to start
        Thread.sleep(forTimeInterval: 0.2)

        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": "smoke-1",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "smoke-test", "version": "1.0"]
                ] as [String: Any]
            ],
            [
                "jsonrpc": "2.0",
                "id": "smoke-2",
                "method": "ping"
            ],
            [
                "jsonrpc": "2.0",
                "id": "smoke-3",
                "method": "tools/list"
            ],
            [
                "jsonrpc": "2.0",
                "id": "smoke-4",
                "method": "resources/list"
            ],
            [
                "jsonrpc": "2.0",
                "id": "smoke-5",
                "method": "unknown/method"
            ]
        ]

        for msg in messages {
            let data = try JSONSerialization.data(withJSONObject: msg)
            let line = data + "\n".data(using: .utf8)!
            stdinPipe.fileHandleForWriting.write(line)
        }

        // Close stdin to signal end of input
        try stdinPipe.fileHandleForWriting.close()

        // Wait for process to finish (it should exit when stdin closes)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        // Read all output
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            XCTFail("Could not read stdout")
            return
        }

        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // We should have exactly 5 responses (one per request)
        XCTAssertEqual(lines.count, 5, "Expected 5 response lines, got \(lines.count): \(output)")

        // Verify initialize response
        let initResp = try JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(initResp["id"] as? String, "smoke-1")
        let initResult = initResp["result"] as! [String: Any]
        XCTAssertEqual(initResult["protocolVersion"] as? String, MCPProtocolVersion.latest)
        let serverInfo = initResult["serverInfo"] as! [String: Any]
        XCTAssertEqual(serverInfo["name"] as? String, "PlayCoverMCP")

        // Verify ping response
        let pingResp = try JSONSerialization.jsonObject(with: lines[1].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(pingResp["id"] as? String, "smoke-2")
        XCTAssertNotNil(pingResp["result"])

        // Verify tools/list response
        let toolsResp = try JSONSerialization.jsonObject(with: lines[2].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(toolsResp["id"] as? String, "smoke-3")
        let toolsResult = toolsResp["result"] as! [String: Any]
        let tools = toolsResult["tools"] as? [Any]
        XCTAssertNotNil(tools)
        // Expected tools: list_installed_apps, get_app_info, install_ipa, export_patched_ipa,
        //                launch_app, launch_app_with_lldb, uninstall_app, clear_app_data,
        //                clear_playchain_data, clear_app_settings, clear_app_entitlements, clear_app_keymaps
        XCTAssertEqual(tools?.count, 12, "Expected 12 registered tools, got \(tools?.count ?? 0): \(tools ?? [])")

        // Verify resources/list response
        let resResp = try JSONSerialization.jsonObject(with: lines[3].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(resResp["id"] as? String, "smoke-4")
        let resResult = resResp["result"] as! [String: Any]
        XCTAssertEqual((resResult["resources"] as? [Any])?.count, 0)

        // Verify unknown method error
        let errResp = try JSONSerialization.jsonObject(with: lines[4].data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(errResp["id"] as? String, "smoke-5")
        let error = errResp["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? Int, -32601)
    }
}
