// AppService.swift
// PlayCoverMCP

import Foundation

/// A lightweight, headless service for enumerating PlayCover-managed applications.
///
/// Unlike `AppsVM` (which carries UI lifecycle assumptions), this service
/// provides a synchronous, testable interface for scanning the Applications directory.
public final class AppService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// Create an AppService with a custom app directory (useful for testing).
    public init(appDirectory: URL) {
        self.appDirectory = appDirectory
    }

    /// Create an AppService pointing to the default PlayCover Applications directory.
    public static func defaultService() -> AppService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        let dir = container.appendingPathComponent("Applications")
        return AppService(appDirectory: dir)
    }

    // MARK: - Scanning

    /// Scan the Applications directory and return lightweight app records.
    public func listApps() throws -> [AppRecord] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: appDirectory.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        var records: [AppRecord] = []

        for url in contents where url.hasDirectoryPath {
            guard url.pathExtension.contains("app") else { continue }

            let infoPlistURL = url.appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: infoPlistURL.path) else { continue }

            if let info = NSDictionary(contentsOf: infoPlistURL) {
                let record = AppRecord(
                    bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
                    bundleName: info["CFBundleName"] as? String
                        ?? (info["CFBundleDisplayName"] as? String ?? ""),
                    displayName: info["CFBundleDisplayName"] as? String
                        ?? (info["CFBundleName"] as? String ?? ""),
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    executableName: info["CFBundleExecutable"] as? String ?? "",
                    url: url
                )
                records.append(record)
            }
        }

        records.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
        return records
    }

    /// Look up a single app by bundle ID.
    public func getApp(bundleId: String) throws -> AppRecord {
        let all = try listApps()
        guard let app = all.first(where: { $0.bundleIdentifier == bundleId }) else {
            throw PlayCoverMCPError(
                code: .appNotFound,
                message: "Application not found: \(bundleId)"
            )
        }
        return app
    }
}

// MARK: - AppRecord

/// A lightweight, Codable record describing an installed PlayCover app.
///
/// This is decoupled from `PlayApp`/`BaseApp` to avoid pulling in UI
/// dependencies, IOKit, and other side effects.
public struct AppRecord: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let bundleName: String
    public let displayName: String
    public let version: String
    public let executableName: String
    public let url: URL

    public init(
        bundleIdentifier: String,
        bundleName: String,
        displayName: String,
        version: String,
        executableName: String,
        url: URL
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.displayName = displayName
        self.version = version
        self.executableName = executableName
        self.url = url
    }

    /// Convert to a dictionary suitable for MCP JSON responses.
    public func toMCPDictionary() -> [String: String] {
        [
            "bundleIdentifier": bundleIdentifier,
            "bundleName": bundleName,
            "displayName": displayName,
            "version": version,
            "executableName": executableName,
            "path": url.path,
        ]
    }
}
