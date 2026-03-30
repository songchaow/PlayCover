// Shell.swift
// PlayCoverMCP

import Foundation

/// Lightweight shell execution utility for PlayCoverMCP.
///
/// Provides a headless interface for running external commands without
/// any UI framework dependencies (no ObservableObject, no Log.shared).
public enum MCPShell {

    struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var combinedOutput: String {
            switch (stdout.isEmpty, stderr.isEmpty) {
            case (true, true):
                return ""
            case (false, true):
                return stdout
            case (true, false):
                return stderr
            case (false, false):
                return stdout + stderr
            }
        }
    }

    /// Run an external command and return its stdout/stderr output.
    ///
    /// - Parameters:
    ///   - binary: Absolute path to the executable.
    ///   - args: Command-line arguments.
    /// - Returns: Combined stdout + stderr output.
    /// - Throws: `ShellError` with the command output if the process exits non-zero.
    @discardableResult
    public static func run(_ binary: String, _ args: String...) throws -> String {
        let output = try capture(binary, args)
        guard output.exitCode == 0 else {
            throw ShellError(
                command: binary,
                arguments: args,
                exitCode: output.exitCode,
                output: output.combinedOutput
            )
        }
        return output.combinedOutput
    }

    /// Run an external command and return its stdout/stderr output.
    ///
    /// Overload that accepts an array of arguments.
    @discardableResult
    public static func run(_ binary: String, _ args: [String]) throws -> String {
        let output = try capture(binary, args)
        guard output.exitCode == 0 else {
            throw ShellError(
                command: binary,
                arguments: args,
                exitCode: output.exitCode,
                output: output.combinedOutput
            )
        }
        return output.combinedOutput
    }

    static func extractEmbeddedPropertyList(from output: String) -> String? {
        guard !output.isEmpty else { return nil }

        let start = ["<?xml", "<plist"]
            .compactMap { output.range(of: $0)?.lowerBound }
            .min()
        guard let start else { return nil }

        guard let end = output.range(of: "</plist>", options: .backwards)?.upperBound,
              start < end else {
            return nil
        }

        return String(output[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capture(_ binary: String, _ args: [String]) throws -> ProcessOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

        process.waitUntilExit()

        return ProcessOutput(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Signing

    /// Ad-hoc sign a single MachO binary.
    public static func signMacho(_ url: URL) throws {
        try run("/usr/bin/codesign", "-fs-", url.path)
    }

    /// Deep sign an app bundle, preserving existing entitlements.
    public static func signApp(_ exec: URL) throws {
        let appDir = exec.deletingLastPathComponent()
        try run("/usr/bin/codesign", "-fs-", appDir.path,
                "--deep", "--preserve-metadata=entitlements")
    }

    /// Deep sign an app bundle with a specific entitlements file.
    public static func signAppWith(_ exec: URL, entitlements: URL) throws {
        let appDir = exec.deletingLastPathComponent()
        try run("/usr/bin/codesign", "-fs-", appDir.path,
                "--deep", "--entitlements", entitlements.path)
    }

    // MARK: - Utilities

    /// Remove quarantine attribute from a path (recursive).
    public static func removeQuarantine(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try run("/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", url.path)
    }

    /// Dump entitlements from a signed binary as XML plist string.
    ///
    /// Returns empty string if the binary has no entitlements or is unsigned.
    public static func dumpEntitlements(_ exec: URL) throws -> String {
        let arguments = ["-d", "--entitlements", "-", "--xml", exec.path]
        let output = try capture("/usr/bin/codesign", arguments)
        let combinedOutput = output.combinedOutput

        if combinedOutput.contains("Document is empty") ||
            combinedOutput.contains("code object is not signed at all") {
            return ""
        }

        if let plist = extractEmbeddedPropertyList(from: output.stdout)
            ?? extractEmbeddedPropertyList(from: combinedOutput) {
            return plist
        }

        guard output.exitCode == 0 else {
            throw ShellError(
                command: "/usr/bin/codesign",
                arguments: arguments,
                exitCode: output.exitCode,
                output: combinedOutput
            )
        }

        if combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }

        throw ShellError(
            command: "/usr/bin/codesign",
            arguments: arguments,
            exitCode: output.exitCode,
            output: "Failed to locate entitlements plist in codesign output: \(combinedOutput)"
        )
    }

    /// Set executable permissions on a file.
    public static func setExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - ShellError

/// Error thrown when a shell command exits with a non-zero status.
public struct ShellError: Error, LocalizedError, Equatable {
    public let command: String
    public let arguments: [String]
    public let exitCode: Int32
    public let output: String

    public init(command: String, arguments: [String] = [], exitCode: Int32, output: String) {
        self.command = command
        self.arguments = arguments
        self.exitCode = exitCode
        self.output = output
    }

    public var errorDescription: String? {
        let args = arguments.joined(separator: " ")
        return "\(command) \(args) (exit \(exitCode)): \(output)"
    }
}
