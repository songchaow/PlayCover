//
//  LLVMToolManager.swift
//  PlayCover
//
//  Manages downloading, extracting, and verifying the LLVM toolchain (llvm-dis)
//  for shader source extraction from metallib files.
//

import Foundation

/// Manages the LLVM toolchain (specifically `llvm-dis`) used by PlayTools
/// to disassemble LLVM bitcode extracted from metallib files.
///
/// Installation directory: `~/Library/Containers/io.playcover.PlayCover/llvm-tools/`
///
/// The manager downloads the LLVM prebuilt package from GitHub Releases,
/// extracts only `bin/llvm-dis`, and stores it locally. Subsequent launches
/// skip the download if the binary already exists and passes a version check.
class LLVMToolManager: ObservableObject {

    // MARK: - Singleton

    static let shared = LLVMToolManager()

    // MARK: - Constants

    /// LLVM version known to work (verified on macOS ARM64).
    static let defaultLLVMVersion = "19.1.0"

    /// GitHub Releases URL template for LLVM prebuilt packages.
    private static func downloadURL(version: String) -> URL {
        URL(string: "https://github.com/llvm/llvm-project/releases/download/llvmorg-\(version)/LLVM-\(version)-macOS-ARM64.tar.xz")!
    }

    /// The directory where LLVM tools are installed.
    static var toolsDirectory: URL {
        PlayTools.playCoverContainer.appendingPathComponent("llvm-tools")
    }

    /// Full path to the installed `llvm-dis` binary.
    static var llvmDisPath: URL {
        toolsDirectory.appendingPathComponent("llvm-dis")
    }

    /// File that records the installed LLVM version.
    private static var versionFilePath: URL {
        toolsDirectory.appendingPathComponent(".llvm-version")
    }

    // MARK: - Published State

    /// Whether `llvm-dis` is installed and ready to use.
    @Published var isInstalled: Bool = false

    /// The installed LLVM version string, or nil if not installed.
    @Published var installedVersion: String?

    /// Whether a download/install operation is currently in progress.
    @Published var isDownloading: Bool = false

    /// Download progress (0.0 – 1.0).
    @Published var downloadProgress: Double = 0.0

    /// Human-readable status message for UI display.
    @Published var statusMessage: String = ""

    /// Last error message, if any.
    @Published var lastError: String?

    // MARK: - Init

    private init() {
        refreshInstallStatus()
    }

    // MARK: - Public API

    /// Check whether `llvm-dis` is installed and update published state.
    func refreshInstallStatus() {
        let fm = FileManager.default
        let path = Self.llvmDisPath.path

        if fm.fileExists(atPath: path), fm.isExecutableFile(atPath: path) {
            isInstalled = true
            installedVersion = readInstalledVersion()
        } else {
            isInstalled = false
            installedVersion = nil
        }
    }

    /// Download and install `llvm-dis` from LLVM GitHub Releases.
    ///
    /// This is a long-running operation. Progress is reported via published properties.
    /// The method runs the download on a background thread and updates UI state on the main thread.
    ///
    /// - Parameter version: LLVM version to download. Defaults to `defaultLLVMVersion`.
    func install(version: String = LLVMToolManager.defaultLLVMVersion) {
        guard !isDownloading else {
            Log.shared.log("LLVM tool installation already in progress")
            return
        }

        Task(priority: .userInitiated) {
            await MainActor.run {
                isDownloading = true
                downloadProgress = 0.0
                statusMessage = "Preparing download..."
                lastError = nil
            }

            do {
                try await performInstall(version: version)
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = 1.0
                    statusMessage = "llvm-dis installed successfully"
                    refreshInstallStatus()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    lastError = error.localizedDescription
                    statusMessage = "Installation failed"
                    Log.shared.error(error)
                }
            }
        }
    }

    /// Remove the installed LLVM tools.
    func uninstall() {
        let fm = FileManager.default
        fm.delete(at: Self.toolsDirectory)
        refreshInstallStatus()
        statusMessage = "LLVM tools removed"
    }

    // MARK: - Private Implementation

    private func performInstall(version: String) async throws {
        let fm = FileManager.default
        let downloadURL = Self.downloadURL(version: version)

        // 1. Create tools directory
        try fm.createDirectory(at: Self.toolsDirectory, withIntermediateDirectories: true)

        // 2. Create temporary directory for download
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("llvm-download-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // 3. Download the tar.xz archive
        await MainActor.run {
            statusMessage = "Downloading LLVM \(version) (~1.4 GB)..."
            downloadProgress = 0.01
        }

        let archivePath = tmpDir.appendingPathComponent("llvm.tar.xz")
        try await downloadFile(from: downloadURL, to: archivePath)

        // 4. Extract only llvm-dis from the archive
        await MainActor.run {
            statusMessage = "Extracting llvm-dis..."
            downloadProgress = 0.85
        }

        try extractLLVMDis(from: archivePath, to: tmpDir, version: version)

        // 5. Move llvm-dis to final location
        await MainActor.run {
            statusMessage = "Installing llvm-dis..."
            downloadProgress = 0.95
        }

        let extractedBinary = tmpDir.appendingPathComponent("llvm-dis")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw LLVMToolError.binaryNotFound(
                "llvm-dis not found in extracted archive. "
                + "Expected at bin/llvm-dis within LLVM-\(version)-macOS-ARM64/"
            )
        }

        // Remove old binary if it exists
        if fm.fileExists(atPath: Self.llvmDisPath.path) {
            try fm.removeItem(at: Self.llvmDisPath)
        }
        try fm.moveItem(at: extractedBinary, to: Self.llvmDisPath)

        // 6. Set executable permissions and ad-hoc sign
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.llvmDisPath.path)
        try Shell.signMacho(Self.llvmDisPath)

        // 7. Verify the binary works
        await MainActor.run {
            statusMessage = "Verifying llvm-dis..."
            downloadProgress = 0.98
        }

        try verifyBinary()

        // 8. Write version file
        try version.write(to: Self.versionFilePath, atomically: true, encoding: .utf8)
    }

    /// Download a file using URLSession with progress tracking.
    private func downloadFile(from url: URL, to destination: URL) async throws {
        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                // Map download progress to 0.01–0.85 range
                self?.downloadProgress = 0.01 + progress * 0.84
            }
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600 // 1 hour for large file
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.downloadTask(with: request)
        task.resume()

        let result = delegate.semaphore.wait(timeout: .now() + 3600)
        session.invalidateAndCancel()

        if result == .timedOut {
            throw LLVMToolError.downloadTimeout
        }

        if let error = delegate.error {
            throw LLVMToolError.downloadFailed(error.localizedDescription)
        }

        guard let tempFile = delegate.downloadedFileURL else {
            throw LLVMToolError.downloadFailed("Download completed but no file available")
        }

        // Move to destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempFile, to: destination)
    }

    /// Extract `llvm-dis` from the downloaded tar.xz archive.
    ///
    /// The archive structure is: `LLVM-{version}-macOS-ARM64/bin/llvm-dis`
    /// We use `tar` to extract only the specific file we need.
    private func extractLLVMDis(from archive: URL, to outputDir: URL, version: String) throws {
        let expectedPath = "LLVM-\(version)-macOS-ARM64/bin/llvm-dis"

        // Try extracting the specific file first
        do {
            try Shell.run(print: false,
                          "/usr/bin/tar", "xf", archive.path,
                          "-C", outputDir.path,
                          "--strip-components=2",
                          expectedPath)
        } catch {
            // If specific path fails, try with a wildcard approach:
            // Extract all, then find llvm-dis
            Log.shared.log("Specific extraction failed, trying full extraction...")
            try Shell.run(print: false,
                          "/usr/bin/tar", "xf", archive.path,
                          "-C", outputDir.path,
                          "--strip-components=2",
                          "--include=*/bin/llvm-dis")
        }
    }

    /// Verify the installed `llvm-dis` binary works by running `--version`.
    private func verifyBinary() throws {
        let output = try Shell.run(print: false, Self.llvmDisPath.path, "--version")
        guard output.contains("LLVM") else {
            throw LLVMToolError.verificationFailed(
                "llvm-dis --version output does not contain 'LLVM': \(output.prefix(200))"
            )
        }
        Log.shared.log("llvm-dis verified: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Read the installed version from the version file.
    private func readInstalledVersion() -> String? {
        guard let content = try? String(contentsOf: Self.versionFilePath, encoding: .utf8) else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error Types

enum LLVMToolError: Error, LocalizedError {
    case downloadFailed(String)
    case downloadTimeout
    case extractionFailed(String)
    case binaryNotFound(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg):
            return "LLVM download failed: \(msg)"
        case .downloadTimeout:
            return "LLVM download timed out (1 hour limit)"
        case .extractionFailed(let msg):
            return "LLVM extraction failed: \(msg)"
        case .binaryNotFound(let msg):
            return "llvm-dis binary not found: \(msg)"
        case .verificationFailed(let msg):
            return "llvm-dis verification failed: \(msg)"
        }
    }
}

// MARK: - Download Progress Delegate

/// URLSession delegate that tracks download progress and signals completion via a semaphore.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {

    let onProgress: (Double) -> Void
    let semaphore = DispatchSemaphore(value: 0)

    var downloadedFileURL: URL?
    var error: Error?

    private var lastReportedPercent: Int = -1

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        if percent != lastReportedPercent {
            lastReportedPercent = percent
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Check HTTP status
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            error = LLVMToolError.downloadFailed("HTTP \(httpResponse.statusCode)")
            return
        }

        // Copy to a safe location before delegate returns
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tar.xz")
        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)
            downloadedFileURL = safeCopy
        } catch {
            self.error = LLVMToolError.downloadFailed("Failed to copy: \(error.localizedDescription)")
        }
    }

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
}
