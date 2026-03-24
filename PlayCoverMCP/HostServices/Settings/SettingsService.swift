// SettingsService.swift
// PlayCoverMCP

import Foundation

/// Errors specific to settings operations.
public enum SettingsError: Error, LocalizedError, Equatable, Sendable {
    case appNotFound(String)
    case settingsNotFound(String)
    case invalidField(String)
    case encodingFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .settingsNotFound(let id): return "Settings not found for: \(id)"
        case .invalidField(let field): return "Invalid settings field: \(field)"
        case .encodingFailed(let reason): return "Failed to encode settings: \(reason)"
        case .decodingFailed(let reason): return "Failed to decode settings: \(reason)"
        }
    }
}

/// Result of a settings update operation.
public struct SettingsUpdateResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let updatedFields: [String]
    public let message: String

    public init(bundleIdentifier: String, updatedFields: [String], message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.updatedFields = updatedFields
        self.message = message
    }
}

/// Result of a settings reset operation.
public struct SettingsResetResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let message: String

    public init(bundleIdentifier: String, message: String) {
        self.bundleIdentifier = bundleIdentifier
        self.message = message
    }
}

/// A headless service for reading, updating, and resetting PlayCover app settings.
///
/// This service operates directly on the property-list files stored in the
/// PlayCover container directory, avoiding any dependency on `PlayApp` or AppKit.
/// It uses `PropertyListSerialization` with `[String: Any]` dictionaries so it
/// does not depend on the `AppSettingsData` Codable struct from the PlayCover app.
public final class SettingsService: Sendable {

    /// The directory where PlayCover stores installed .app bundles (for app validation).
    public let appDirectory: URL

    /// The PlayCover container directory (parent of "App Settings/").
    public let containerDirectory: URL

    /// Create a SettingsService with custom directories (useful for testing).
    public init(appDirectory: URL, containerDirectory: URL) {
        self.appDirectory = appDirectory
        self.containerDirectory = containerDirectory
    }

    /// Create a SettingsService pointing to the default PlayCover directories.
    public static func defaultService() -> SettingsService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        return SettingsService(
            appDirectory: container.appendingPathComponent("Applications"),
            containerDirectory: container
        )
    }

    // MARK: - Path Helpers

    private func settingsURL(for bundleId: String) -> URL {
        containerDirectory
            .appendingPathComponent("App Settings")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
    }

    // MARK: - App Validation

    /// Verify that an app with the given bundleId exists in the Applications directory.
    private func validateAppExists(_ bundleId: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appDirectory.path) else {
            throw SettingsError.appNotFound(bundleId)
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
            throw SettingsError.appNotFound(bundleId)
        }
    }

    // MARK: - Read

    /// Read the settings for a given app as a dictionary.
    ///
    /// - Returns: A dictionary representing all settings fields.
    public func getSettings(bundleId: String) throws -> [String: Any] {
        try validateAppExists(bundleId)

        let url = settingsURL(for: bundleId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultSettings(bundleId: bundleId)
        }

        let data = try Data(contentsOf: url)
        var props: Any?
        do {
            props = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
        } catch {
            throw SettingsError.decodingFailed(error.localizedDescription)
        }
        guard let dict = props as? [String: Any] else {
            throw SettingsError.decodingFailed("Settings file is not a dictionary")
        }
        return dict
    }

    // MARK: - Update (Patch)

    /// Update one or more settings fields for a given app using patch semantics.
    ///
    /// Only the fields provided in `changes` will be modified; all other fields
    /// are preserved from the existing settings file. If no settings file exists,
    /// a new one is created from defaults and then patched.
    public func updateSettings(bundleId: String, changes: [String: Any]) throws -> SettingsUpdateResult {
        try validateAppExists(bundleId)

        let url = settingsURL(for: bundleId)
        var settings: [String: Any]

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            var props: Any?
            do {
                props = try PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                )
            } catch {
                throw SettingsError.decodingFailed(error.localizedDescription)
            }
            guard var dict = props as? [String: Any] else {
                throw SettingsError.decodingFailed("Settings file is not a dictionary")
            }
            settings = dict
        } else {
            settings = defaultSettings(bundleId: bundleId)
        }

        // Define valid patchable fields with their expected types
        let validBoolFields: Set<String> = [
            "keymapping", "disableTimeout", "notch", "bypass", "playChain",
            "playChainDebugging", "inverseScreenValues", "metalHUD",
            "injectIntrospection", "rootWorkDir", "noKMOnInput",
            "enableScrollWheel", "hideTitleBar", "floatingWindow",
            "checkMicPermissionSync", "limitMotionUpdateFrequency",
            "disableBuiltinMouse", "blockSleepSpamming",
            "metalCaptureEnabled",
        ]
        let validIntFields: Set<String> = [
            "windowWidth", "windowHeight", "resolution", "aspectRatio",
            "windowFixMethod", "resizableAspectRatioType",
            "resizableAspectRatioWidth", "resizableAspectRatioHeight",
        ]
        let validFloatFields: Set<String> = ["sensitivity"]
        let validDoubleFields: Set<String> = ["customScaler"]
        let validStringFields: Set<String> = ["iosDeviceModel"]

        // Fields that cannot be patched
        let nonPatchable: Set<String> = ["bundleIdentifier", "version", "discordActivity"]

        var updatedFields: [String] = []

        for (key, value) in changes {
            if nonPatchable.contains(key) {
                throw SettingsError.invalidField("'\(key)' cannot be modified via update")
            }

            if validBoolFields.contains(key), let boolVal = value as? Bool {
                settings[key] = boolVal
                updatedFields.append(key)
            } else if validIntFields.contains(key), let intVal = value as? Int {
                settings[key] = intVal
                updatedFields.append(key)
            } else if validFloatFields.contains(key) {
                let floatVal: Float
                if let d = value as? Double { floatVal = Float(d) }
                else if let i = value as? Int { floatVal = Float(i) }
                else { throw SettingsError.invalidField("'\(key)' expects a number, got \(type(of: value))") }
                settings[key] = floatVal
                updatedFields.append(key)
            } else if validDoubleFields.contains(key) {
                let doubleVal: Double
                if let d = value as? Double { doubleVal = d }
                else if let i = value as? Int { doubleVal = Double(i) }
                else { throw SettingsError.invalidField("'\(key)' expects a number, got \(type(of: value))") }
                settings[key] = doubleVal
                updatedFields.append(key)
            } else if validStringFields.contains(key), let strVal = value as? String {
                settings[key] = strVal
                updatedFields.append(key)
            } else {
                throw SettingsError.invalidField("'\(key)' is not a recognized patchable settings field")
            }
        }

        settings["bundleIdentifier"] = bundleId

        // Write back as XML plist
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: settings, format: .xml, options: 0
            )
            let settingsDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            throw SettingsError.encodingFailed(error.localizedDescription)
        }

        // Notify GUI that settings have changed
        MCPNotificationPoster.postSettingsChanged(bundleID: bundleId)

        return SettingsUpdateResult(
            bundleIdentifier: bundleId,
            updatedFields: updatedFields,
            message: "Updated \(updatedFields.count) setting(s) for \(bundleId): \(updatedFields.joined(separator: ", "))"
        )
    }

    // MARK: - Reset

    /// Reset all settings for a given app to their default values.
    public func resetSettings(bundleId: String) throws -> SettingsResetResult {
        try validateAppExists(bundleId)

        let defaults = defaultSettings(bundleId: bundleId)
        let url = settingsURL(for: bundleId)
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: defaults, format: .xml, options: 0
            )
            let settingsDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            throw SettingsError.encodingFailed(error.localizedDescription)
        }

        // Notify GUI that settings have changed
        MCPNotificationPoster.postSettingsChanged(bundleID: bundleId)

        return SettingsResetResult(
            bundleIdentifier: bundleId,
            message: "Settings reset to defaults for \(bundleId)"
        )
    }

    // MARK: - Default Settings

    /// Return a default settings dictionary matching `AppSettingsData` defaults.
    ///
    /// These values mirror the defaults declared in PlayCover's `AppSettingsData`
    /// struct so that MCP reset produces the same result as the GUI.
    private func defaultSettings(bundleId: String) -> [String: Any] {
        [
            "bundleIdentifier": bundleId,
            "keymapping": true,
            "sensitivity": Float(50),
            "disableTimeout": false,
            "iosDeviceModel": "iPad13,8",
            "windowWidth": 1920,
            "windowHeight": 1080,
            "customScaler": 2.0,
            "resolution": 1,
            "aspectRatio": 1,
            "notch": false,
            "bypass": false,
            "discordActivity": [
                "enable": true,
                "applicationID": "",
                "details": "",
                "state": "",
                "image": "",
            ],
            "version": "3.0.0",
            "playChain": true,
            "playChainDebugging": false,
            "inverseScreenValues": false,
            "metalHUD": false,
            "windowFixMethod": 0,
            "injectIntrospection": false,
            "rootWorkDir": true,
            "noKMOnInput": true,
            "enableScrollWheel": true,
            "hideTitleBar": false,
            "floatingWindow": false,
            "checkMicPermissionSync": false,
            "limitMotionUpdateFrequency": false,
            "disableBuiltinMouse": false,
            "resizableAspectRatioType": 0,
            "resizableAspectRatioWidth": 0,
            "resizableAspectRatioHeight": 0,
            "blockSleepSpamming": false,
            "metalCaptureEnabled": false,
        ]
    }
}
