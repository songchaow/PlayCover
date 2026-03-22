// StdioTransport.swift
// PlayCoverMCPCore

import Foundation

/// Reads JSON-RPC messages from stdin (line-delimited), dispatches to a handler,
/// and writes response messages to stdout.
///
/// - Server logs are written to stderr so they never interfere with the protocol stream.
public final class StdioTransport {

    /// Called for every incoming message. May return a response (or nil for notifications).
    public typealias MessageHandler = @Sendable (JSONRPCMessage) -> JSONRPCMessage?

    private let handler: MessageHandler
    private let input: FileHandle
    private let output: FileHandle
    private let logOutput: FileHandle

    public init(
        handler: @escaping MessageHandler,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        logOutput: FileHandle = .standardError
    ) {
        self.handler = handler
        self.input = input
        self.output = output
        self.logOutput = logOutput
    }

    // MARK: - Run loop

    /// Start the transport loop. This method blocks until stdin is closed.
    public func run() {
        log("PlayCoverMCP: stdio transport started")
        input.readabilityHandler = { [weak self] _ in
            self?.processAvailableData()
        }
        // Keep the run loop alive.
        RunLoop.main.run()
    }

    /// Process one batch of available data (until the read returns empty).
    private func processAvailableData() {
        let data = input.availableData
        guard !data.isEmpty else {
            // stdin closed
            log("PlayCoverMCP: stdin closed, exiting")
            exit(0)
        }
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !line.isEmpty else {
            return
        }

        do {
            let jsonData = line.data(using: .utf8) ?? Data()
            let message = try JSONRPCMessage.parse(jsonData)

            if let response = handler(message) {
                let responseData = try response.encode()
                let responseLine = String(data: responseData, encoding: .utf8) ?? ""
                output.write(responseLine.data(using: .utf8) ?? Data())
                output.write("\n".data(using: .utf8) ?? Data())
            }
        } catch {
            log("PlayCoverMCP: error processing message: \(error.localizedDescription)")
        }
    }

    // MARK: - Sending (for notifications from server to client)

    /// Send a JSON-RPC message (notification) to the client.
    public func send(_ message: JSONRPCMessage) throws {
        let data = try message.encode()
        guard let line = String(data: data, encoding: .utf8) else { return }
        output.write(line.data(using: .utf8)!)
        output.write("\n".data(using: .utf8)!)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        logOutput.write(data)
    }
}
