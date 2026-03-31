// UploadManager.swift
// PlayCoverMCP — Manages file uploads for HTTP transport

import Foundation
import CommonCrypto

/// Result of a successful file upload.
public struct UploadResult: Codable, Equatable, Sendable {
    public let filename: String
    public let storedName: String
    public let size: Int
    public let sha256: String
    public let expiresIn: TimeInterval
    public let reference: String
    public let localPath: String
}

/// Error types for upload operations.
public enum UploadError: Error, LocalizedError, Equatable {
    case missingFilename
    case invalidFilename(String)
    case fileTooLarge(Int)
    case checksumMismatch(expected: String, actual: String)
    case diskWriteFailed(String)
    case fileNotFound(String)
    case sessionRequired

    public var errorDescription: String? {
        switch self {
        case .missingFilename:
            return "Missing X-Filename header"
        case .invalidFilename(let msg):
            return "Invalid filename: \(msg)"
        case .fileTooLarge(let maxMB):
            return "File exceeds maximum size of \(maxMB) MB"
        case .checksumMismatch(let expected, let actual):
            return "SHA256 mismatch: expected \(expected), got \(actual)"
        case .diskWriteFailed(let msg):
            return "Failed to write file: \(msg)"
        case .fileNotFound(let ref):
            return "Uploaded file not found: \(ref)"
        case .sessionRequired:
            return "File references (@filename) require an active MCP session"
        }
    }
}

/// Manages uploaded files in a session-scoped temporary directory.
///
/// Files are stored under:
/// ```
/// ~/Library/Containers/io.playcover.PlayCover/tmp/mcp-uploads/<session-id>/
/// ```
///
/// Each file gets a unique prefix to avoid collisions. Files are cleaned up
/// when their session terminates, when the server stops, or when their TTL expires.
public final class UploadManager: @unchecked Sendable {

    /// Root directory for all uploads.
    public let uploadRoot: URL

    /// Default time-to-live for uploaded files (seconds).
    public let defaultTTL: TimeInterval

    /// Maximum allowed file size in bytes.
    public let maxFileSize: Int

    private var fileMetadata: [String: FileEntry] = [:]  // storedName -> entry
    private let lock = NSLock()

    private struct FileEntry {
        let sessionId: String
        let storedName: String
        let localPath: URL
        let createdAt: Date
        let ttl: TimeInterval
    }

    // MARK: - Init

    /// Create an UploadManager.
    /// - Parameters:
    ///   - uploadRoot: Root directory for uploads.
    ///   - defaultTTL: File TTL in seconds. Default: 3600 (1 hour).
    ///   - maxFileSize: Maximum file size in bytes. Default: 500 MB.
    public init(
        uploadRoot: URL? = nil,
        defaultTTL: TimeInterval = 3600,
        maxFileSize: Int = 500 * 1024 * 1024
    ) {
        if let root = uploadRoot {
            self.uploadRoot = root
        } else {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent("io.playcover.PlayCover")
            self.uploadRoot = container
                .appendingPathComponent("tmp")
                .appendingPathComponent("mcp-uploads")
        }
        self.defaultTTL = defaultTTL
        self.maxFileSize = maxFileSize
    }

    /// Default instance for production use.
    public static func defaultManager() -> UploadManager {
        UploadManager()
    }

    // MARK: - Store

    /// Store uploaded data to disk.
    /// - Parameters:
    ///   - data: Raw file data.
    ///   - filename: Original filename from client.
    ///   - sessionId: MCP HTTP session ID.
    ///   - expectedSHA256: Optional SHA256 checksum for verification.
    /// - Returns: Upload result with metadata.
    public func store(
        data: Data,
        filename: String,
        sessionId: String,
        expectedSHA256: String? = nil
    ) throws -> UploadResult {
        // Validate filename
        let sanitized = sanitizeFilename(filename)
        guard !sanitized.isEmpty else {
            throw UploadError.invalidFilename(filename)
        }

        // Validate size
        guard data.count <= maxFileSize else {
            throw UploadError.fileTooLarge(maxFileSize / (1024 * 1024))
        }

        // Compute SHA256
        let sha256 = computeSHA256(data)

        // Verify checksum if provided
        if let expected = expectedSHA256, !expected.isEmpty {
            guard sha256.lowercased() == expected.lowercased() else {
                throw UploadError.checksumMismatch(expected: expected, actual: sha256)
            }
        }

        // Generate stored name
        let prefix = UUID().uuidString.prefix(8).lowercased()
        let storedName = "\(prefix)-\(sanitized)"

        // Create session directory
        let sessionDir = uploadRoot.appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Write file
        let filePath = sessionDir.appendingPathComponent(storedName)
        do {
            try data.write(to: filePath)
        } catch {
            throw UploadError.diskWriteFailed(error.localizedDescription)
        }

        // Track metadata
        let entry = FileEntry(
            sessionId: sessionId,
            storedName: storedName,
            localPath: filePath,
            createdAt: Date(),
            ttl: defaultTTL
        )
        lock.lock()
        fileMetadata[storedName] = entry
        lock.unlock()

        return UploadResult(
            filename: filename,
            storedName: storedName,
            size: data.count,
            sha256: sha256,
            expiresIn: defaultTTL,
            reference: "@\(storedName)",
            localPath: filePath.path
        )
    }

    // MARK: - Resolve

    /// Resolve a `@storedName` reference to an absolute local path.
    ///
    /// If the value does not start with `@`, returns it unchanged.
    /// If it starts with `@`, looks up the stored file in the given session.
    ///
    /// - Parameters:
    ///   - value: The parameter value, possibly a `@filename` reference.
    ///   - sessionId: MCP HTTP session ID for scoping.
    /// - Returns: Resolved absolute path.
    public func resolveReference(_ value: String, sessionId: String) throws -> String {
        guard value.hasPrefix("@") else {
            return value
        }

        let storedName = String(value.dropFirst())
        guard !storedName.isEmpty else {
            throw UploadError.fileNotFound(value)
        }

        lock.lock()
        let entry = fileMetadata[storedName]
        lock.unlock()

        guard let entry = entry else {
            throw UploadError.fileNotFound(value)
        }

        // Verify session ownership
        guard entry.sessionId == sessionId else {
            throw UploadError.fileNotFound(value)
        }

        // Verify file still exists
        guard FileManager.default.fileExists(atPath: entry.localPath.path) else {
            throw UploadError.fileNotFound(value)
        }

        // Check TTL
        if Date().timeIntervalSince(entry.createdAt) > entry.ttl {
            try? FileManager.default.removeItem(at: entry.localPath)
            lock.lock()
            fileMetadata.removeValue(forKey: storedName)
            lock.unlock()
            throw UploadError.fileNotFound(value)
        }

        return entry.localPath.path
    }

    /// Resolve a path value — if it starts with `@`, resolve the upload reference.
    /// Otherwise, return the value as-is.
    ///
    /// - Parameters:
    ///   - value: Path or `@reference`.
    ///   - sessionId: Session ID, or nil for CLI mode.
    /// - Returns: Resolved path.
    public func resolvePathParameter(_ value: String, sessionId: String?) throws -> String {
        guard value.hasPrefix("@") else {
            return value
        }
        guard let sessionId = sessionId else {
            throw UploadError.sessionRequired
        }
        return try resolveReference(value, sessionId: sessionId)
    }

    // MARK: - Cleanup

    /// Remove all uploaded files for a given session.
    public func cleanupSession(_ sessionId: String) {
        lock.lock()
        let sessionEntries = fileMetadata.filter { $0.value.sessionId == sessionId }
        for key in sessionEntries.keys {
            fileMetadata.removeValue(forKey: key)
        }
        lock.unlock()

        let sessionDir = uploadRoot.appendingPathComponent(sessionId)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    /// Remove all files whose TTL has expired.
    public func cleanupExpired() {
        let now = Date()
        lock.lock()
        let expired = fileMetadata.filter { now.timeIntervalSince($0.value.createdAt) > $0.value.ttl }
        for (key, entry) in expired {
            try? FileManager.default.removeItem(at: entry.localPath)
            fileMetadata.removeValue(forKey: key)
        }
        lock.unlock()
    }

    /// Remove the entire upload directory and all tracked metadata.
    public func cleanupAll() {
        lock.lock()
        fileMetadata.removeAll()
        lock.unlock()

        try? FileManager.default.removeItem(at: uploadRoot)
    }

    // MARK: - Private Helpers

    /// Sanitize a filename: remove path separators, `..`, and non-safe characters.
    /// Returns an empty string if the result is invalid.
    func sanitizeFilename(_ filename: String) -> String {
        var name = filename

        // Remove path components
        name = (name as NSString).lastPathComponent

        // Remove ..
        name = name.replacingOccurrences(of: "..", with: "")

        // Keep only safe characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        name = String(name.unicodeScalars.filter { allowed.contains($0) })

        // Trim and limit length
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 200 {
            name = String(name.prefix(200))
        }

        // Reject empty or dot-only names
        if name.isEmpty || name.allSatisfy({ $0 == "." }) {
            return ""
        }

        return name
    }

    /// Compute SHA256 hex digest.
    func computeSHA256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
