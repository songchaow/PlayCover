// IPADownloader.swift
// PlayCoverMCP — Downloads IPA files from HTTP/HTTPS URLs

import Foundation

/// Error types for IPA download operations.
public enum IPADownloadError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case unsupportedScheme(String)
    case downloadFailed(String)
    case downloadTimeout(Int)
    case fileTooLarge(Int)
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme). Only http and https are allowed."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .downloadTimeout(let seconds):
            return "Download timed out after \(seconds) seconds"
        case .fileTooLarge(let maxMB):
            return "File exceeds maximum download size of \(maxMB) MB"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}

/// Downloads IPA files from remote URLs to a local temporary directory.
///
/// Used by `install_ipa` and `export_patched_ipa` when an `ipaURL` parameter
/// is provided instead of a local `ipaPath`.
public final class IPADownloader: @unchecked Sendable {

    /// Download timeout in seconds.
    public let timeout: TimeInterval

    /// Maximum download size in bytes.
    public let maxSize: Int64

    /// Directory for downloaded files.
    public let downloadDirectory: URL

    // MARK: - Init

    /// Create an IPADownloader.
    /// - Parameters:
    ///   - downloadDirectory: Where to store downloads. Default: ~/Library/Containers/.../tmp/mcp-downloads/
    ///   - timeout: Download timeout in seconds. Default: 600 (10 minutes).
    ///   - maxSize: Maximum file size in bytes. Default: 2 GB.
    public init(
        downloadDirectory: URL? = nil,
        timeout: TimeInterval = 600,
        maxSize: Int64 = 2 * 1024 * 1024 * 1024
    ) {
        if let dir = downloadDirectory {
            self.downloadDirectory = dir
        } else {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent("io.playcover.PlayCover")
            self.downloadDirectory = container
                .appendingPathComponent("tmp")
                .appendingPathComponent("mcp-downloads")
        }
        self.timeout = timeout
        self.maxSize = maxSize
    }

    /// Default instance for production use.
    public static func defaultDownloader() -> IPADownloader {
        IPADownloader()
    }

    // MARK: - Validate

    /// Validate a URL string and return a parsed URL.
    public func validateURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw IPADownloadError.invalidURL(urlString)
        }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw IPADownloadError.unsupportedScheme(url.scheme ?? "none")
        }
        return url
    }

    // MARK: - Download

    /// Download an IPA from a URL to a local file.
    /// - Parameters:
    ///   - url: The HTTP/HTTPS URL to download from.
    ///   - progress: Progress callback (totalBytes, downloadedBytes, message).
    /// - Returns: Local file URL of the downloaded IPA.
    public func download(
        url: URL,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)? = nil
    ) throws -> URL {
        // Create download directory
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        // Generate local filename
        let prefix = UUID().uuidString.prefix(8).lowercased()
        let originalName = url.lastPathComponent.isEmpty ? "downloaded.ipa" : url.lastPathComponent
        let sanitizedName = sanitizeFilename(originalName)
        let localName = "download-\(prefix)-\(sanitizedName)"
        let localURL = downloadDirectory.appendingPathComponent(localName)

        progress?(100, 0, "downloading from \(url.host ?? url.absoluteString)")

        // Configure URLSession with timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Synchronous download using semaphore (we're already on a background queue)
        var downloadError: Error?
        var downloadedFileURL: URL?
        var httpStatusCode: Int = 0

        let semaphore = DispatchSemaphore(value: 0)

        let task = session.downloadTask(with: request) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error = error {
                downloadError = error
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                httpStatusCode = httpResponse.statusCode
                if httpStatusCode >= 400 {
                    downloadError = IPADownloadError.httpError(httpStatusCode)
                    return
                }
            }

            guard let tempURL = tempURL else {
                downloadError = IPADownloadError.downloadFailed("No file received")
                return
            }

            downloadedFileURL = tempURL
        }

        task.resume()

        // Wait with timeout
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            task.cancel()
            throw IPADownloadError.downloadTimeout(Int(timeout))
        }

        // Check errors
        if let error = downloadError {
            if let dlError = error as? IPADownloadError {
                throw dlError
            }
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                throw IPADownloadError.downloadTimeout(Int(timeout))
            }
            throw IPADownloadError.downloadFailed(error.localizedDescription)
        }

        guard let tempFileURL = downloadedFileURL else {
            throw IPADownloadError.downloadFailed("Download completed but no file available")
        }

        // Check file size
        let attrs = try FileManager.default.attributesOfItem(atPath: tempFileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        if fileSize > maxSize {
            try? FileManager.default.removeItem(at: tempFileURL)
            throw IPADownloadError.fileTooLarge(Int(maxSize / (1024 * 1024)))
        }

        // Move to our download directory
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempFileURL, to: localURL)

        progress?(100, 100, "download complete (\(formatBytes(fileSize)))")

        return localURL
    }

    // MARK: - Cleanup

    /// Remove the entire download directory.
    public func cleanupAll() {
        try? FileManager.default.removeItem(at: downloadDirectory)
    }

    /// Remove a specific downloaded file.
    public func cleanup(file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Helpers

    private func sanitizeFilename(_ filename: String) -> String {
        var name = (filename as NSString).lastPathComponent
        name = name.replacingOccurrences(of: "..", with: "")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        name = String(name.unicodeScalars.filter { allowed.contains($0) })
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 200 { name = String(name.prefix(200)) }
        if name.isEmpty || name.allSatisfy({ $0 == "." }) { return "downloaded.ipa" }
        return name
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
