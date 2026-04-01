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
    ///   - timeout: Download timeout in seconds. Default: 1800 (30 minutes).
    ///   - maxSize: Maximum file size in bytes. Default: 50 GB.
    public init(
        downloadDirectory: URL? = nil,
        timeout: TimeInterval = 1800,
        maxSize: Int64 = 50 * 1024 * 1024 * 1024
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
    ///   - progress: Progress callback (totalPercent, currentPercent, message).
    /// - Returns: Local file URL of the downloaded IPA.
    public func download(
        url: URL,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let prefix = UUID().uuidString.prefix(8).lowercased()
        let originalName = url.lastPathComponent.isEmpty ? "downloaded.ipa" : url.lastPathComponent
        let sanitizedName = sanitizeFilename(originalName)
        let localName = "download-\(prefix)-\(sanitizedName)"
        let localURL = downloadDirectory.appendingPathComponent(localName)

        progress?(100, 0, "downloading from \(url.host ?? url.absoluteString)")

        let delegate = DownloadDelegate(
            maxSize: maxSize,
            progress: progress
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.downloadTask(with: request)
        task.resume()

        let waitResult = delegate.semaphore.wait(timeout: .now() + timeout)
        session.invalidateAndCancel()

        if waitResult == .timedOut {
            throw IPADownloadError.downloadTimeout(Int(timeout))
        }

        if let error = delegate.error {
            if let dlError = error as? IPADownloadError {
                throw dlError
            }
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost {
                throw IPADownloadError.downloadTimeout(Int(timeout))
            }
            if nsError.code == NSURLErrorCancelled {
                throw IPADownloadError.downloadFailed("Download was cancelled")
            }
            throw IPADownloadError.downloadFailed(error.localizedDescription)
        }

        guard let tempFileURL = delegate.downloadedFileURL else {
            throw IPADownloadError.downloadFailed("Download completed but no file available")
        }

        // Move to our download directory
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempFileURL, to: localURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
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

    func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

// MARK: - URLSession Download Delegate

/// Delegate that provides real-time download progress and handles completion.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    let maxSize: Int64
    let progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)?
    let semaphore = DispatchSemaphore(value: 0)

    var downloadedFileURL: URL?
    var error: Error?

    private let downloader = IPADownloader(downloadDirectory: nil, timeout: 0, maxSize: 0)
    private var lastReportedPercent: Int = -1

    init(
        maxSize: Int64,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)?
    ) {
        self.maxSize = maxSize
        self.progress = progress
    }

    // Called periodically as data is received
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Check max size early if server reported Content-Length
        if totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maxSize {
            downloadTask.cancel()
            error = IPADownloadError.fileTooLarge(Int(maxSize / (1024 * 1024)))
            return
        }

        // Also check actual bytes written against limit
        if totalBytesWritten > maxSize {
            downloadTask.cancel()
            error = IPADownloadError.fileTooLarge(Int(maxSize / (1024 * 1024)))
            return
        }

        guard let progress = progress else { return }

        if totalBytesExpectedToWrite > 0 {
            let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
            // Throttle: only report when percent changes
            if percent != lastReportedPercent {
                lastReportedPercent = percent
                let written = formatBytesStatic(totalBytesWritten)
                let total = formatBytesStatic(totalBytesExpectedToWrite)
                progress(100, percent, "downloading (\(written) / \(total))")
            }
        } else {
            // Unknown total size — report bytes downloaded
            let written = formatBytesStatic(totalBytesWritten)
            let newPercent = Int(totalBytesWritten / (1024 * 1024)) // change every ~1 MB
            if newPercent != lastReportedPercent {
                lastReportedPercent = newPercent
                progress(100, 50, "downloading (\(written))")
            }
        }
    }

    // Called when download finishes successfully
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Check HTTP status code
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            error = IPADownloadError.httpError(httpResponse.statusCode)
            // Don't signal yet — didCompleteWithError will be called
            return
        }

        // Copy file to a safe location before the delegate returns
        // (the temp file at `location` is deleted after this method returns)
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ipa")
        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)
            downloadedFileURL = safeCopy
        } catch {
            self.error = IPADownloadError.downloadFailed("Failed to copy downloaded file: \(error.localizedDescription)")
        }
    }

    // Called when the task completes (success or failure)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError completionError: Error?
    ) {
        if error == nil, let completionError = completionError {
            error = completionError
        }
        semaphore.signal()
    }

    private func formatBytesStatic(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
