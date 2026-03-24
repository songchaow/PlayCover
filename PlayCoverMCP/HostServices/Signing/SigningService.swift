// SigningService.swift
// PlayCoverMCP

import Foundation

// MARK: - Result Types

/// Result of a signing validation check.
public struct SigningValidationResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let valid: Bool
    public let signed: Bool
    public let infoPlistSigned: Bool
    public let entitlementsMatch: Bool
    public let message: String

    public init(
        bundleIdentifier: String,
        valid: Bool,
        signed: Bool,
        infoPlistSigned: Bool,
        entitlementsMatch: Bool,
        message: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.valid = valid
        self.signed = signed
        self.infoPlistSigned = infoPlistSigned
        self.entitlementsMatch = entitlementsMatch
        self.message = message
    }
}

/// Result of an entitlements preview operation.
public struct EntitlementsPreviewResult: Codable, Sendable {
    public let bundleIdentifier: String
    public let currentEntitlements: [String: String]
    public let appSandbox: Bool
    public let hasNetworkClient: Bool
    public let hasNetworkServer: Bool
    public let hasCamera: Bool
    public let hasMicrophone: Bool
    public let hasBluetooth: Bool
    public let hasUSB: Bool
    public let hasLocation: Bool
    public let hasContacts: Bool
    public let hasCalendars: Bool
    public let sandboxProfileRules: Int
    public let message: String

    public init(
        bundleIdentifier: String,
        currentEntitlements: [String: Any],
        message: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        // Convert all values to String for Codable/Equatable support
        var strDict: [String: String] = [:]
        for (key, value) in currentEntitlements {
            if let boolVal = value as? Bool {
                strDict[key] = boolVal ? "true" : "false"
            } else if let strVal = value as? String {
                strDict[key] = strVal
            } else if let arrVal = value as? [String] {
                strDict[key] = arrVal.joined(separator: ", ")
            } else {
                strDict[key] = "\(value)"
            }
        }
        self.currentEntitlements = strDict
        self.appSandbox = currentEntitlements["com.apple.security.app-sandbox"] as? Bool ?? false
        self.hasNetworkClient = currentEntitlements["com.apple.security.network.client"] as? Bool ?? false
        self.hasNetworkServer = currentEntitlements["com.apple.security.network.server"] as? Bool ?? false
        self.hasCamera = currentEntitlements["com.apple.security.device.camera"] as? Bool ?? false
        self.hasMicrophone = currentEntitlements["com.apple.security.device.microphone"] as? Bool ?? false
        self.hasBluetooth = currentEntitlements["com.apple.security.device.bluetooth"] as? Bool ?? false
        self.hasUSB = currentEntitlements["com.apple.security.device.usb"] as? Bool ?? false
        self.hasLocation = currentEntitlements["com.apple.security.personal-information.location"] as? Bool ?? false
        self.hasContacts = currentEntitlements["com.apple.security.personal-information.addressbook"] as? Bool ?? false
        self.hasCalendars = currentEntitlements["com.apple.security.personal-information.calendars"] as? Bool ?? false
        self.sandboxProfileRules = (currentEntitlements["com.apple.security.temporary-exception.sbpl"] as? [String])?.count ?? 0
        self.message = message
    }

    // Custom Codable since we want clean JSON serialization
    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, appSandbox, hasNetworkClient, hasNetworkServer
        case hasCamera, hasMicrophone, hasBluetooth, hasUSB
        case hasLocation, hasContacts, hasCalendars
        case sandboxProfileRules, message, currentEntitlements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        currentEntitlements = try c.decodeIfPresent([String: String].self, forKey: .currentEntitlements) ?? [:]
        appSandbox = try c.decode(Bool.self, forKey: .appSandbox)
        hasNetworkClient = try c.decode(Bool.self, forKey: .hasNetworkClient)
        hasNetworkServer = try c.decode(Bool.self, forKey: .hasNetworkServer)
        hasCamera = try c.decode(Bool.self, forKey: .hasCamera)
        hasMicrophone = try c.decode(Bool.self, forKey: .hasMicrophone)
        hasBluetooth = try c.decode(Bool.self, forKey: .hasBluetooth)
        hasUSB = try c.decode(Bool.self, forKey: .hasUSB)
        hasLocation = try c.decode(Bool.self, forKey: .hasLocation)
        hasContacts = try c.decode(Bool.self, forKey: .hasContacts)
        hasCalendars = try c.decode(Bool.self, forKey: .hasCalendars)
        sandboxProfileRules = try c.decode(Int.self, forKey: .sandboxProfileRules)
        message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encode(currentEntitlements, forKey: .currentEntitlements)
        try c.encode(appSandbox, forKey: .appSandbox)
        try c.encode(hasNetworkClient, forKey: .hasNetworkClient)
        try c.encode(hasNetworkServer, forKey: .hasNetworkServer)
        try c.encode(hasCamera, forKey: .hasCamera)
        try c.encode(hasMicrophone, forKey: .hasMicrophone)
        try c.encode(hasBluetooth, forKey: .hasBluetooth)
        try c.encode(hasUSB, forKey: .hasUSB)
        try c.encode(hasLocation, forKey: .hasLocation)
        try c.encode(hasContacts, forKey: .hasContacts)
        try c.encode(hasCalendars, forKey: .hasCalendars)
        try c.encode(sandboxProfileRules, forKey: .sandboxProfileRules)
        try c.encode(message, forKey: .message)
    }
}

/// Result of a re-signing operation.
public struct ResignResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let resigned: Bool
    public let taskId: String?
    public let message: String

    public init(
        bundleIdentifier: String,
        displayName: String,
        resigned: Bool,
        taskId: String? = nil,
        message: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.resigned = resigned
        self.taskId = taskId
        self.message = message
    }
}

// MARK: - Error Types

/// Errors specific to signing operations.
public enum SigningServiceError: Error, LocalizedError, Equatable, Sendable {
    case appNotFound(String)
    case executableNotFound(String)
    case signingFailed(String)
    case entitlementsDumpFailed(String)
    case resignFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let id): return "Application not found: \(id)"
        case .executableNotFound(let path): return "Executable not found at: \(path)"
        case .signingFailed(let reason): return "Code signing failed: \(reason)"
        case .entitlementsDumpFailed(let reason): return "Failed to dump entitlements: \(reason)"
        case .resignFailed(let reason): return "Re-signing failed: \(reason)"
        }
    }
}

// MARK: - SigningService

/// A headless service for validating, previewing, and re-signing PlayCover-managed apps.
///
/// Provides three main capabilities:
/// - **preview_entitlements**: Read and summarize the current entitlements of an app
/// - **validate_app_signing**: Check if an app's signing is valid (signed, Info.plist signed, entitlements match)
/// - **resign_app**: Re-sign an app bundle (ad-hoc, deep sign with entitlement preservation)
public final class SigningService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// The PlayCover container directory (holds Entitlements/).
    public let containerDirectory: URL

    /// Create a SigningService with custom paths (useful for testing).
    public init(appDirectory: URL, containerDirectory: URL) {
        self.appDirectory = appDirectory
        self.containerDirectory = containerDirectory
    }

    /// Create a SigningService pointing to default PlayCover paths.
    public static func defaultService() -> SigningService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        return SigningService(
            appDirectory: container.appendingPathComponent("Applications"),
            containerDirectory: container
        )
    }

    // MARK: - Preview Entitlements

    /// Read and preview the current entitlements of an app.
    ///
    /// Dumps entitlements from the signed executable using `codesign`, then
    /// returns a structured summary of key capability flags.
    ///
    /// - Parameter bundleId: The bundle identifier of the app.
    /// - Returns: An `EntitlementsPreviewResult` with structured entitlement info.
    public func previewEntitlements(bundleId: String) throws -> EntitlementsPreviewResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw SigningServiceError.executableNotFound(executableURL.path)
        }

        let entitlements = try dumpEntitlementsFromBinary(executableURL)

        let message = entitlements.isEmpty
            ? "App \(app.displayName) (\(bundleId)) has no entitlements or is unsigned."
            : "Entitlements preview for \(app.displayName) (\(bundleId)): \(entitlements.count) key(s)."

        return EntitlementsPreviewResult(
            bundleIdentifier: bundleId,
            currentEntitlements: entitlements,
            message: message
        )
    }

    // MARK: - Validate Signing

    /// Validate the signing state of an app.
    ///
    /// Checks three aspects:
    /// 1. Whether the app is signed at all
    /// 2. Whether the Info.plist is signed (included in the code signature)
    /// 3. Whether entitlements are present and consistent
    ///
    /// - Parameter bundleId: The bundle identifier of the app.
    /// - Returns: A `SigningValidationResult` with detailed signing state.
    public func validateSigning(bundleId: String) throws -> SigningValidationResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw SigningServiceError.executableNotFound(executableURL.path)
        }

        // Check if the binary is signed
        let signed = isSigned(executableURL)

        // Check if Info.plist is included in the signature
        let infoPlistSigned = isInfoPlistSigned(executableURL)

        // Check entitlements
        let entitlements = (try? dumpEntitlementsFromBinary(executableURL)) ?? [:]
        let entitlementsMatch = !entitlements.isEmpty

        // Overall validity: all checks pass
        let valid = signed && infoPlistSigned && entitlementsMatch

        var issues: [String] = []
        if !signed { issues.append("binary is not signed") }
        if !infoPlistSigned { issues.append("Info.plist is not signed") }
        if !entitlementsMatch { issues.append("no entitlements found") }

        let message: String
        if valid {
            message = "App \(app.displayName) (\(bundleId)) signing is valid."
        } else {
            message = "App \(app.displayName) (\(bundleId)) has signing issues: \(issues.joined(separator: ", "))."
        }

        return SigningValidationResult(
            bundleIdentifier: bundleId,
            valid: valid,
            signed: signed,
            infoPlistSigned: infoPlistSigned,
            entitlementsMatch: entitlementsMatch,
            message: message
        )
    }

    // MARK: - Resign App

    /// Re-sign an app bundle using ad-hoc signing.
    ///
    /// Performs a deep re-sign of the app bundle, preserving existing entitlements.
    /// This is useful when code signature has become invalid (e.g. after modification).
    ///
    /// - Parameter bundleId: The bundle identifier of the app.
    /// - Returns: A `ResignResult` indicating success or failure.
    public func resignApp(bundleId: String) throws -> ResignResult {
        let app = try resolveApp(bundleId: bundleId)
        let executableURL = app.url.appendingPathComponent(app.executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw SigningServiceError.executableNotFound(executableURL.path)
        }

        do {
            try MCPShell.signApp(executableURL)
        } catch {
            throw SigningServiceError.resignFailed(error.localizedDescription)
        }

        return ResignResult(
            bundleIdentifier: bundleId,
            displayName: app.displayName,
            resigned: true,
            message: "Successfully re-signed \(app.displayName) (\(bundleId))."
        )
    }

    /// Re-sign an app with a specific entitlements file, integrated with TaskManager.
    ///
    /// - Parameters:
    ///   - bundleId: The bundle identifier of the app.
    ///   - taskManager: The task manager for progress tracking.
    /// - Returns: A `ResignResult` with the task ID for progress monitoring.
    public func resignAppWithTask(
        bundleId: String,
        taskManager: TaskManager
    ) -> ResignResult {
        let createResult = taskManager.executeTask(
            title: "Re-sign \(bundleId)"
        ) { taskId, progress in
            progress.update(message: "Resolving app...")
            let app: AppRecord
            do {
                app = try self.resolveApp(bundleId: bundleId)
            } catch {
                throw TaskError(code: PlayCoverErrorCode.appNotFound.rawValue, message: error.localizedDescription)
            }

            let executableURL = app.url.appendingPathComponent(app.executableName)
            guard FileManager.default.fileExists(atPath: executableURL.path) else {
                throw TaskError(
                    code: PlayCoverErrorCode.signingFailed.rawValue,
                    message: "Executable not found: \(executableURL.path)"
                )
            }

            progress.update(message: "Re-signing \(app.displayName)...")

            do {
                try MCPShell.signApp(executableURL)
            } catch {
                throw TaskError(
                    code: PlayCoverErrorCode.signingFailed.rawValue,
                    message: "Re-signing failed: \(error.localizedDescription)"
                )
            }

            progress.update(message: "Re-signing complete")
            return TaskResult(content: [
                TaskContentItem(kind: .text, text: "Successfully re-signed \(app.displayName) (\(bundleId)).")
            ])
        }

        return ResignResult(
            bundleIdentifier: bundleId,
            displayName: bundleId,
            resigned: createResult.status.state == .completed,
            taskId: createResult.id,
            message: createResult.status.state == .completed
                ? "Re-signing task completed for \(bundleId)."
                : "Re-signing task \(createResult.id) created for \(bundleId), state: \(createResult.status.state.rawValue)."
        )
    }

    // MARK: - Internal Helpers

    /// Resolve a bundle ID to an app record by scanning the Applications directory.
    private func resolveApp(bundleId: String) throws -> AppRecord {
        let fm = FileManager.default

        guard fm.fileExists(atPath: appDirectory.path) else {
            throw SigningServiceError.appNotFound(bundleId)
        }

        let contents = try fm.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )

        for url in contents where url.hasDirectoryPath {
            guard url.pathExtension.contains("app") else { continue }

            let infoPlistURL = url.appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: infoPlistURL.path) else { continue }

            if let info = NSDictionary(contentsOf: infoPlistURL),
               let id = info["CFBundleIdentifier"] as? String,
               id == bundleId {
                return AppRecord(
                    bundleIdentifier: id,
                    bundleName: info["CFBundleName"] as? String
                        ?? (info["CFBundleDisplayName"] as? String ?? ""),
                    displayName: info["CFBundleDisplayName"] as? String
                        ?? (info["CFBundleName"] as? String ?? ""),
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    executableName: info["CFBundleExecutable"] as? String ?? "",
                    url: url
                )
            }
        }

        throw SigningServiceError.appNotFound(bundleId)
    }

    /// Check whether a binary is signed by attempting `codesign -dv`.
    private func isSigned(_ executable: URL) -> Bool {
        do {
            _ = try MCPShell.run("/usr/bin/codesign", "-dv", executable.path)
            return true
        } catch {
            return false
        }
    }

    /// Check whether the Info.plist is included in the code signature.
    private func isInfoPlistSigned(_ executable: URL) -> Bool {
        do {
            let output = try MCPShell.run("/usr/bin/codesign", "-dv", executable.path)
            return output.contains("Info.plist entries")
        } catch {
            return false
        }
    }

    /// Dump entitlements from a signed binary as a dictionary.
    ///
    /// Uses `codesign -d --entitlements - --xml` and parses the XML plist output.
    private func dumpEntitlementsFromBinary(_ executable: URL) throws -> [String: Any] {
        let xmlString = try MCPShell.dumpEntitlements(executable)
        guard !xmlString.isEmpty else { return [:] }

        guard let data = xmlString.data(using: .utf8) else {
            throw SigningServiceError.entitlementsDumpFailed("Failed to convert entitlements to data")
        }

        var format = PropertyListSerialization.PropertyListFormat.xml
        do {
            let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
            guard let dict = plist as? [String: Any] else {
                throw SigningServiceError.entitlementsDumpFailed("Entitlements plist is not a dictionary")
            }
            return dict
        } catch let error as SigningServiceError {
            throw error
        } catch {
            throw SigningServiceError.entitlementsDumpFailed(error.localizedDescription)
        }
    }
}
