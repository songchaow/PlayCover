import AppKit
import Foundation

struct HostPlayToolsStatus {
    let hasPlayTools: Bool
    let detectionWarning: String?
}

struct HostRuntimeStateSnapshot {
    let isRunning: Bool
    let isActive: Bool
    let matchedProcessCount: Int
}

final class HostAppResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func listInstalledApps() throws -> [PlayApp] {
        if !fileManager.fileExists(atPath: AppsVM.appDirectory.path) {
            try fileManager.createDirectory(
                at: AppsVM.appDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let directoryContents = try fileManager.contentsOfDirectory(
            at: AppsVM.appDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        return directoryContents
            .filter(isInstalledAppDirectory)
            .map { PlayApp(appUrl: $0.standardizedFileURL) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func resolveApp(bundleID: String? = nil, appPath: String? = nil) throws -> PlayApp {
        if let bundleID, let appPath {
            throw HostToolError.preconditionFailed(
                "Use either 'bundle_id' or 'app_path', not both.",
                details: [
                    "bundle_id": .string(bundleID),
                    "app_path": .string(appPath)
                ]
            )
        }

        if let bundleID {
            return try resolveApp(bundleID: bundleID)
        }

        if let appPath {
            let appURL = try resolveAppURL(path: appPath)
            return PlayApp(appUrl: appURL)
        }

        throw HostToolError.preconditionFailed(
            "One of 'bundle_id' or 'app_path' is required."
        )
    }

    func resolveApp(bundleID: String) throws -> PlayApp {
        if let app = try listInstalledApps().first(where: { $0.info.bundleIdentifier == bundleID }) {
            return app
        }

        throw HostToolError.appNotFound(bundleID: bundleID)
    }

    func resolveAppURL(path: String) throws -> URL {
        let fileURL = try resolveExistingURL(path: path)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostToolError.preconditionFailed(
                "App path must point to an existing .app bundle.",
                details: ["path": .string(fileURL.path)]
            )
        }

        guard fileURL.pathExtension == "app" else {
            throw HostToolError.preconditionFailed(
                "App path must use the .app extension.",
                details: ["path": .string(fileURL.path)]
            )
        }

        let infoPlistURL = fileURL.appendingPathComponent("Info").appendingPathExtension("plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw HostToolError.preconditionFailed(
                "App bundle is missing Info.plist.",
                details: ["path": .string(fileURL.path)]
            )
        }

        return fileURL
    }

    func resolveIPAURL(path: String) throws -> URL {
        let fileURL = try resolveExistingURL(path: path)

        guard fileURL.pathExtension.lowercased() == "ipa" else {
            throw HostToolError.preconditionFailed(
                "IPA path must use the .ipa extension.",
                details: ["path": .string(fileURL.path)]
            )
        }

        return fileURL
    }

    func resolveExistingURL(path: String) throws -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let resolvedPath: String
        if expandedPath.hasPrefix("/") {
            resolvedPath = expandedPath
        } else {
            resolvedPath = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(expandedPath)
                .path
        }

        let fileURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw HostToolError.fileNotFound(path: fileURL.path)
        }

        return fileURL
    }

    func playToolsStatus(for app: PlayApp) -> HostPlayToolsStatus {
        do {
            return HostPlayToolsStatus(hasPlayTools: try app.detectPlayToolsInstallation(), detectionWarning: nil)
        } catch {
            Log.shared.error(error)
            return HostPlayToolsStatus(
                hasPlayTools: true,
                detectionWarning: "Failed to inspect PlayTools for \(app.info.bundleIdentifier); reporting has_playtools=true conservatively."
            )
        }
    }

    func debugCapable(for app: PlayApp) -> Bool {
        fileManager.fileExists(atPath: app.executable.path)
    }

    func bestEffortRuntimeState(bundleID: String) async -> HostRuntimeStateSnapshot {
        await MainActor.run {
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            }

            return HostRuntimeStateSnapshot(
                isRunning: !matches.isEmpty,
                isActive: matches.contains(where: \.isActive),
                matchedProcessCount: matches.count
            )
        }
    }

    private func isInstalledAppDirectory(_ url: URL) -> Bool {
        guard url.hasDirectoryPath, url.pathExtension == "app" else {
            return false
        }

        let infoPlistURL = url.appendingPathComponent("Info").appendingPathExtension("plist")
        return fileManager.fileExists(atPath: infoPlistURL.path)
    }
}
