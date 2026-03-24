// KeymapService.swift
// PlayCoverMCP

import Foundation

// MARK: - Keymap Data Types (lightweight, headless-compatible)

/// A lightweight keymap record suitable for MCP responses.
/// Does not import PlayCover's Keymap model — instead reads plist as raw dictionaries.
public struct KeymapInfo: Codable, Equatable, Sendable {
    public let name: String
    public let isDefault: Bool
    public let path: String

    public init(name: String, isDefault: Bool, path: String) {
        self.name = name
        self.isDefault = isDefault
        self.path = path
    }
}

/// Result of listing keymaps for an app.
public struct ListKeymapsResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymaps: [KeymapInfo]
    public let defaultKeymap: String

    public init(bundleIdentifier: String, keymaps: [KeymapInfo], defaultKeymap: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymaps = keymaps
        self.defaultKeymap = defaultKeymap
    }
}

/// Result of getting a single keymap's content.
/// Note: raw keymap data is returned as [String: Any] dictionary (not Codable),
/// so we don't define a dedicated result struct for get operations.

/// Result of creating a keymap.
public struct CreateKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymapName: String
    public let message: String

    public init(bundleIdentifier: String, keymapName: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymapName = keymapName
        self.message = message
    }
}

/// Result of renaming a keymap.
public struct RenameKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let oldName: String
    public let newName: String
    public let message: String

    public init(bundleIdentifier: String, oldName: String, newName: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.oldName = oldName
        self.newName = newName
        self.message = message
    }
}

/// Result of deleting a keymap.
public struct DeleteKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymapName: String
    public let message: String

    public init(bundleIdentifier: String, keymapName: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymapName = keymapName
        self.message = message
    }
}

/// Result of resetting a keymap.
public struct ResetKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymapName: String
    public let message: String

    public init(bundleIdentifier: String, keymapName: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymapName = keymapName
        self.message = message
    }
}

/// Result of importing a keymap from a file.
public struct ImportKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymapName: String
    public let sourcePath: String
    public let bundleIdMatched: Bool
    public let message: String

    public init(bundleIdentifier: String, keymapName: String, sourcePath: String, bundleIdMatched: Bool, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymapName = keymapName
        self.sourcePath = sourcePath
        self.bundleIdMatched = bundleIdMatched
        self.message = message
    }
}

/// Result of exporting a keymap to a file.
public struct ExportKeymapResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let keymapName: String
    public let outputPath: String
    public let message: String

    public init(bundleIdentifier: String, keymapName: String, outputPath: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.keymapName = keymapName
        self.outputPath = outputPath
        self.message = message
    }
}

// MARK: - Keymap Errors

public enum KeymapError: Error, LocalizedError, Equatable, Sendable {
    case appNotFound(String)
    case keymapNotFound(String)
    case keymapAlreadyExists(String)
    case defaultKeymapCannotBeDeleted(String)
    case invalidKeymapName(String)
    case readFailed(String)
    case writeFailed(String)
    case deleteFailed(String)
    case invalidKeymapFile(String)
    case bundleIdMismatch(sourceBundleId: String, targetBundleId: String)
    case exportFailed(String)
    case importSourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .keymapNotFound(let name): return "Keymap not found: \(name)"
        case .keymapAlreadyExists(let name): return "Keymap already exists: \(name)"
        case .defaultKeymapCannotBeDeleted(let name): return "Cannot delete default keymap: \(name)"
        case .invalidKeymapName(let name): return "Invalid keymap name: '\(name)'. Name must be non-empty and cannot contain '/' or '.'"
        case .readFailed(let reason): return "Failed to read keymap: \(reason)"
        case .writeFailed(let reason): return "Failed to write keymap: \(reason)"
        case .deleteFailed(let reason): return "Failed to delete keymap: \(reason)"
        case .invalidKeymapFile(let reason): return "Invalid keymap file: \(reason)"
        case .bundleIdMismatch(let source, let target): return "Keymap bundle identifier '\(source)' does not match target app '\(target)'. Use force=true to import anyway."
        case .exportFailed(let reason): return "Failed to export keymap: \(reason)"
        case .importSourceNotFound(let path): return "Import source file not found: \(path)"
        }
    }
}

// MARK: - KeymapService

/// A headless service for managing PlayCover keymaps.
///
/// Keymaps are stored as plist files under:
///   `<container>/Keymapping/<bundleId>/<name>.plist`
/// A `.config.plist` file tracks the default keymap and keymap order.
public final class KeymapService: Sendable {

    /// The PlayCover container directory.
    public let containerDirectory: URL

    /// The directory where PlayCover stores installed .app bundles (for app validation).
    public let appDirectory: URL

    public init(containerDirectory: URL, appDirectory: URL) {
        self.containerDirectory = containerDirectory
        self.appDirectory = appDirectory
    }

    public static func defaultService() -> KeymapService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        return KeymapService(
            containerDirectory: container,
            appDirectory: container.appendingPathComponent("Applications")
        )
    }

    // MARK: - Path Helpers

    private func keymappingBaseDir(for bundleId: String) -> URL {
        containerDirectory
            .appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleId)
    }

    private func keymapURL(for bundleId: String, name: String) -> URL {
        keymappingBaseDir(for: bundleId)
            .appendingPathComponent(name)
            .appendingPathExtension("plist")
    }

    private func configURL(for bundleId: String) -> URL {
        keymappingBaseDir(for: bundleId)
            .appendingPathComponent(".config")
            .appendingPathExtension("plist")
    }

    // MARK: - App Validation

    private func validateAppExists(_ bundleId: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appDirectory.path) else {
            throw KeymapError.appNotFound(bundleId)
        }
        let contents = try fm.contentsOfDirectory(
            at: appDirectory, includingPropertiesForKeys: nil, options: []
        )
        let found = contents.contains { url in
            guard url.pathExtension.contains("app") else { return false }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            return info?["CFBundleIdentifier"] as? String == bundleId
        }
        guard found else {
            throw KeymapError.appNotFound(bundleId)
        }
    }

    // MARK: - Name Validation

    private func validateKeymapName(_ name: String) throws {
        guard !name.isEmpty else {
            throw KeymapError.invalidKeymapName(name)
        }
        guard !name.contains("/") && !name.contains(".") && !name.hasPrefix(".") else {
            throw KeymapError.invalidKeymapName(name)
        }
    }

    // MARK: - Config Read/Write

    private func readConfig(bundleId: String) throws -> (defaultKm: URL, keymapOrder: [URL]) {
        let fm = FileManager.default
        let baseDir = keymappingBaseDir(for: bundleId)

        // Ensure keymapping directory exists
        if !fm.fileExists(atPath: baseDir.path) {
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }

        let cfgURL = configURL(for: bundleId)
        guard fm.fileExists(atPath: cfgURL.path) else {
            // No config yet — create default keymap file and config
            let defaultURL = keymapURL(for: bundleId, name: "default")
            let emptyKeymap: [String: Any] = [
                "bundleIdentifier": bundleId,
                "buttonModels": [],
                "draggableButtonModels": [],
                "joystickModel": [],
                "mouseAreaModel": [],
                "version": "2.0.0"
            ]
            try (emptyKeymap as NSDictionary).write(to: defaultURL)
            let config: [String: Any] = [
                "defaultKm": defaultURL.path,
                "keymapOrder": [defaultURL.path]
            ]
            try (config as NSDictionary).write(to: cfgURL)
            return (defaultURL, [defaultURL])
        }

        guard let dict = NSDictionary(contentsOf: cfgURL) as? [String: Any] else {
            throw KeymapError.readFailed("Cannot parse config plist for \(bundleId)")
        }

        let defaultKmPath = dict["defaultKm"] as? String ?? keymapURL(for: bundleId, name: "default").path
        let defaultKm = URL(fileURLWithPath: defaultKmPath)
        let orderPaths = dict["keymapOrder"] as? [String] ?? [defaultKmPath]
        let keymapOrder = orderPaths.map { URL(fileURLWithPath: $0) }
        return (defaultKm, keymapOrder)
    }

    private func writeConfig(bundleId: String, defaultKm: URL, keymapOrder: [URL]) throws {
        let cfgURL = configURL(for: bundleId)
        let config: [String: Any] = [
            "defaultKm": defaultKm.path,
            "keymapOrder": keymapOrder.map(\.path)
        ]
        try (config as NSDictionary).write(to: cfgURL)
    }

    // MARK: - List Keymaps

    public func listKeymaps(bundleId: String) throws -> ListKeymapsResult {
        try validateAppExists(bundleId)

        let fm = FileManager.default
        let baseDir = keymappingBaseDir(for: bundleId)
        let config = try readConfig(bundleId: bundleId)

        // Ensure base dir exists
        if !fm.fileExists(atPath: baseDir.path) {
            return ListKeymapsResult(
                bundleIdentifier: bundleId,
                keymaps: [KeymapInfo(name: "default", isDefault: true, path: config.defaultKm.path)],
                defaultKeymap: "default"
            )
        }

        let defaultName = config.defaultKm.deletingPathExtension().lastPathComponent

        // Read config's keymapOrder first, then scan for any plist files not in order
        var keymaps: [KeymapInfo] = []
        var seenNames = Set<String>()

        for url in config.keymapOrder {
            let fileName = url.lastPathComponent
            seenNames.insert(fileName)
            let name = url.deletingPathExtension().lastPathComponent
            keymaps.append(KeymapInfo(
                name: name,
                isDefault: name == defaultName,
                path: url.path
            ))
        }

        // Scan for additional plist files (skip .config.plist)
        if let contents = try? fm.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for url in contents where url.pathExtension == "plist"
                && !url.lastPathComponent.hasPrefix(".config")
                && !seenNames.contains(url.lastPathComponent) {
                let name = url.deletingPathExtension().lastPathComponent
                keymaps.append(KeymapInfo(
                    name: name,
                    isDefault: name == defaultName,
                    path: url.path
                ))
            }
        }

        return ListKeymapsResult(
            bundleIdentifier: bundleId,
            keymaps: keymaps,
            defaultKeymap: defaultName
        )
    }

    // MARK: - Get Keymap

    public func getKeymap(bundleId: String, name: String) throws -> [String: Any] {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let url = keymapURL(for: bundleId, name: name)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw KeymapError.keymapNotFound(name)
        }

        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            throw KeymapError.readFailed("Cannot parse keymap plist: \(name)")
        }

        return dict
    }

    // MARK: - Create Keymap

    public func createKeymap(bundleId: String, name: String) throws -> CreateKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let config = try readConfig(bundleId: bundleId)
        let url = keymapURL(for: bundleId, name: name)

        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else {
            throw KeymapError.keymapAlreadyExists(name)
        }

        // Create empty keymap
        let baseDir = keymappingBaseDir(for: bundleId)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let emptyKeymap: [String: Any] = [
            "bundleIdentifier": bundleId,
            "buttonModels": [],
            "draggableButtonModels": [],
            "joystickModel": [],
            "mouseAreaModel": [],
            "version": "2.0.0"
        ]
        try (emptyKeymap as NSDictionary).write(to: url)

        // Update config
        var order = config.keymapOrder
        if !order.contains(url) {
            order.append(url)
        }
        try writeConfig(bundleId: bundleId, defaultKm: config.defaultKm, keymapOrder: order)

        // Notify GUI that keymaps have changed
        MCPNotificationPoster.postKeymapsChanged(bundleID: bundleId)

        return CreateKeymapResult(
            bundleIdentifier: bundleId,
            keymapName: name,
            message: "Keymap '\(name)' created for \(bundleId)"
        )
    }

    // MARK: - Rename Keymap

    public func renameKeymap(bundleId: String, oldName: String, newName: String) throws -> RenameKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(oldName)
        try validateKeymapName(newName)

        let config = try readConfig(bundleId: bundleId)
        let oldURL = keymapURL(for: bundleId, name: oldName)
        let newURL = keymapURL(for: bundleId, name: newName)

        let fm = FileManager.default
        guard fm.fileExists(atPath: oldURL.path) else {
            throw KeymapError.keymapNotFound(oldName)
        }

        guard !fm.fileExists(atPath: newURL.path) else {
            throw KeymapError.keymapAlreadyExists(newName)
        }

        // Move the file
        try fm.moveItem(at: oldURL, to: newURL)

        // Update config: replace old URL with new URL in keymapOrder
        var order = config.keymapOrder
        if let idx = order.firstIndex(of: oldURL) {
            order[idx] = newURL
        }

        // Also update defaultKm if renaming the default
        let newDefault = (config.defaultKm == oldURL) ? newURL : config.defaultKm
        try writeConfig(bundleId: bundleId, defaultKm: newDefault, keymapOrder: order)

        return RenameKeymapResult(
            bundleIdentifier: bundleId,
            oldName: oldName,
            newName: newName,
            message: "Keymap renamed from '\(oldName)' to '\(newName)'"
        )
    }

    // MARK: - Delete Keymap

    public func deleteKeymap(bundleId: String, name: String) throws -> DeleteKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let config = try readConfig(bundleId: bundleId)
        let url = keymapURL(for: bundleId, name: name)

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw KeymapError.keymapNotFound(name)
        }

        // Cannot delete the default keymap
        let defaultName = config.defaultKm.deletingPathExtension().lastPathComponent
        if name == defaultName {
            throw KeymapError.defaultKeymapCannotBeDeleted(name)
        }

        // Delete the file
        try fm.removeItem(at: url)

        // Update config: remove from keymapOrder
        var order = config.keymapOrder
        order.removeAll { $0 == url }
        try writeConfig(bundleId: bundleId, defaultKm: config.defaultKm, keymapOrder: order)

        return DeleteKeymapResult(
            bundleIdentifier: bundleId,
            keymapName: name,
            message: "Keymap '\(name)' deleted"
        )
    }

    // MARK: - Reset Keymap

    public func resetKeymap(bundleId: String, name: String) throws -> ResetKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let url = keymapURL(for: bundleId, name: name)

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw KeymapError.keymapNotFound(name)
        }

        // Write empty keymap (reset to defaults)
        let resetContent: [String: Any] = [
            "bundleIdentifier": bundleId,
            "buttonModels": [],
            "draggableButtonModels": [],
            "joystickModel": [],
            "mouseAreaModel": [],
            "version": "2.0.0"
        ]
        try (resetContent as NSDictionary).write(to: url)

        return ResetKeymapResult(
            bundleIdentifier: bundleId,
            keymapName: name,
            message: "Keymap '\(name)' reset to defaults"
        )
    }

    // MARK: - Import Keymap

    /// Import a keymap from an external plist file.
    ///
    /// - Parameters:
    ///   - bundleId: The target app's bundle identifier.
    ///   - name: The name for the imported keymap (will be created or overwritten).
    ///   - filePath: Absolute path to the source plist file.
    ///   - force: If true, override the bundleId field in the keymap data when it doesn't match.
    /// - Returns: Import result with details about the operation.
    public func importKeymap(bundleId: String, name: String, filePath: String, force: Bool = false) throws -> ImportKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let sourceURL = URL(fileURLWithPath: filePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw KeymapError.importSourceNotFound(filePath)
        }

        // Read and validate the source plist
        guard let sourceDict = NSDictionary(contentsOf: sourceURL) as? [String: Any] else {
            throw KeymapError.invalidKeymapFile("Cannot parse plist at '\(filePath)'")
        }

        // Check bundleId match
        let sourceBundleId = sourceDict["bundleIdentifier"] as? String
        let bundleIdMatched = (sourceBundleId == bundleId)

        if !bundleIdMatched {
            if !force {
                throw KeymapError.bundleIdMismatch(
                    sourceBundleId: sourceBundleId ?? "<missing>",
                    targetBundleId: bundleId
                )
            }
        }

        // Prepare the keymap data (overwrite bundleId if force and mismatched)
        var keymapData = sourceDict
        if !bundleIdMatched && force {
            keymapData["bundleIdentifier"] = bundleId
        }

        // Write the keymap
        let config = try readConfig(bundleId: bundleId)
        let targetURL = keymapURL(for: bundleId, name: name)
        let baseDir = keymappingBaseDir(for: bundleId)

        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try (keymapData as NSDictionary).write(to: targetURL)

        // Update config: add to keymapOrder if new
        var order = config.keymapOrder
        if !order.contains(where: { $0.lastPathComponent == targetURL.lastPathComponent }) {
            order.append(targetURL)
            try writeConfig(bundleId: bundleId, defaultKm: config.defaultKm, keymapOrder: order)
        }

        let mismatchNote = (!bundleIdMatched && force) ? " (bundleId overwritten from '\(sourceBundleId ?? "<missing>")' to '\(bundleId)')" : ""

        // Notify GUI that keymaps have changed
        MCPNotificationPoster.postKeymapsChanged(bundleID: bundleId)

        return ImportKeymapResult(
            bundleIdentifier: bundleId,
            keymapName: name,
            sourcePath: filePath,
            bundleIdMatched: bundleIdMatched,
            message: "Keymap imported to '\(name)'\(mismatchNote)"
        )
    }

    // MARK: - Export Keymap

    /// Export a keymap to an external plist file.
    ///
    /// - Parameters:
    ///   - bundleId: The app's bundle identifier.
    ///   - name: The name of the keymap to export.
    ///   - outputPath: Absolute path where the keymap plist will be written.
    /// - Returns: Export result with details about the operation.
    public func exportKeymap(bundleId: String, name: String, outputPath: String) throws -> ExportKeymapResult {
        try validateAppExists(bundleId)
        try validateKeymapName(name)

        let sourceURL = keymapURL(for: bundleId, name: name)
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw KeymapError.keymapNotFound(name)
        }

        guard let sourceDict = NSDictionary(contentsOf: sourceURL) else {
            throw KeymapError.readFailed("Cannot parse keymap plist: \(name)")
        }

        let outputURL = URL(fileURLWithPath: outputPath)

        // Create parent directory if needed
        let parentDir = outputURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        do {
            try (sourceDict as NSDictionary).write(to: outputURL)
        } catch {
            throw KeymapError.exportFailed("Cannot write to '\(outputPath)': \(error.localizedDescription)")
        }

        return ExportKeymapResult(
            bundleIdentifier: bundleId,
            keymapName: name,
            outputPath: outputPath,
            message: "Keymap '\(name)' exported to '\(outputPath)'"
        )
    }
}
