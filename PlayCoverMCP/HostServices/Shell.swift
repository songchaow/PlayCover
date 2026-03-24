// Shell.swift
// PlayCoverMCP

import Foundation

/// Lightweight shell execution utility for PlayCoverMCP.
///
/// Provides a headless interface for running external commands without
/// any UI framework dependencies (no ObservableObject, no Log.shared).
public enum MCPShell {

    /// Run an external command and return its stdout/stderr output.
    ///
    /// - Parameters:
    ///   - binary: Absolute path to the executable.
    ///   - args: Command-line arguments.
    /// - Returns: Combined stdout + stderr output.
    /// - Throws: `ShellError` with the command output if the process exits non-zero.
    @discardableResult
    public static func run(_ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let outputString = String(data: output, encoding: .utf8) ?? ""

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ShellError(
                command: binary,
                arguments: args,
                exitCode: process.terminationStatus,
                output: outputString
            )
        }

        return outputString
    }

    /// Run an external command and return its stdout/stderr output.
    ///
    /// Overload that accepts an array of arguments.
    @discardableResult
    public static func run(_ binary: String, _ args: [String]) throws -> String {
        try run(binary, args.map { $0 })
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
        do {
            return try run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch let error as ShellError {
            if error.output.contains("Document is empty") ||
               error.output.contains("code object is not signed at all") {
                return ""
            }
            throw error
        }
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
