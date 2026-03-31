// InstallerService.swift
// PlayCoverMCP

import Foundation
#if canImport(injection)
import injection
#endif

/// Result of an IPA install operation.
public struct InstallResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let appPath: String
    public let injectPlayTools: Bool

    public init(bundleIdentifier: String, appPath: String, injectPlayTools: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.injectPlayTools = injectPlayTools
    }
}

/// Result of an IPA export operation.
public struct ExportResult: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let ipaPath: String

    public init(bundleIdentifier: String, ipaPath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.ipaPath = ipaPath
    }
}

/// Errors specific to IPA install/export operations.
public enum InstallerError: Error, LocalizedError, Equatable {
    case ipaNotFound(String)
    case invalidIPA(String)
    case appEncrypted(String)
    case missingExecutable(String)
    case unsupportedArchitecture(String)
    case conversionFailed(String)
    case injectionFailed(String)
    case signingFailed(String)
    case exportFailed(String)
    case packFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ipaNotFound(let path): return "IPA not found: \(path)"
        case .invalidIPA(let msg): return "Invalid IPA: \(msg)"
        case .appEncrypted(let msg): return "App is encrypted: \(msg)"
        case .missingExecutable(let msg): return "Missing executable: \(msg)"
        case .unsupportedArchitecture(let msg): return "Unsupported architecture: \(msg)"
        case .conversionFailed(let msg): return "MachO conversion failed: \(msg)"
        case .injectionFailed(let msg): return "PlayTools injection failed: \(msg)"
        case .signingFailed(let msg): return "Signing failed: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .packFailed(let msg): return "IPA packing failed: \(msg)"
        }
    }
}

/// A headless service for installing and exporting iOS IPA files via PlayCover.
///
/// This service encapsulates the install/export logic without any UI framework
/// dependencies. All progress is reported through a callback closure.
///
/// Usage from MCP tool handlers:
/// ```swift
/// let result = service.install(ipaPath: "/path/to/app.ipa",
///                               injectPlayTools: true,
///                               progress: { total, current, message in
///     // report progress to TaskManager
/// })
/// ```
public final class InstallerService: Sendable {

    /// The directory where PlayCover stores installed .app bundles.
    public let appDirectory: URL

    /// The PlayTools framework path on the system.
    public let playToolsFrameworkPath: URL

    /// The PlayCover bundle path (for accessing bundled PlayTools).
    public let playCoverBundlePath: URL?

    /// Create an InstallerService with custom paths (useful for testing).
    public init(
        appDirectory: URL,
        playToolsFrameworkPath: URL? = nil,
        playCoverBundlePath: URL? = nil
    ) {
        self.appDirectory = appDirectory
        self.playToolsFrameworkPath = playToolsFrameworkPath ?? Self.defaultPlayToolsFrameworkPath()
        self.playCoverBundlePath = playCoverBundlePath
    }

    /// Create an InstallerService pointing to default PlayCover paths.
    public static func defaultService() -> InstallerService {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        let appDir = container.appendingPathComponent("Applications")

        // Try to find PlayCover.app bundle
        let playCoverBundle = Self.findPlayCoverBundle()

        return InstallerService(
            appDirectory: appDir,
            playCoverBundlePath: playCoverBundle
        )
    }

    // MARK: - Install

    /// Install an IPA file into the PlayCover Applications directory.
    ///
    /// - Parameters:
    ///   - ipaPath: Path to the .ipa file.
    ///   - injectPlayTools: Whether to inject PlayTools into the app.
    ///   - applicationCategory: Optional LSApplicationCategoryType value.
    ///   - progress: Callback for progress updates (total, current, message).
    /// - Returns: `InstallResult` with bundle ID and installed path.
    public func install(
        ipaPath: String,
        injectPlayTools: Bool = true,
        applicationCategory: String? = nil,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)? = nil
    ) throws -> InstallResult {
        let ipaURL = URL(fileURLWithPath: ipaPath)

        // Validate IPA exists
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw InstallerError.ipaNotFound(ipaPath)
        }

        progress?(100, 0, "begin")

        // Create temp directory
        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/Users"),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Unzip
        progress?(100, 10, "unzip")
        try MCPShell.run("/usr/bin/unzip", "-oq", ipaURL.path, "-d", tmpDir.path)

        // Find the .app bundle in Payload
        let payloadDir = tmpDir.appendingPathComponent("Payload")
        let appURL = try findAppBundle(in: payloadDir)

        // Read Info.plist
        progress?(100, 20, "reading Info.plist")
        let info = try readInfoPlist(from: appURL)
        let bundleId = info["CFBundleIdentifier"] as? String ?? "unknown"
        let execName = info["CFBundleExecutable"] as? String ?? ""
        guard !execName.isEmpty else {
            throw InstallerError.missingExecutable("No CFBundleExecutable in Info.plist")
        }
        let execURL = appURL.appendingPathComponent(execName)
        try validatePrimaryExecutable(execURL, executableName: execName)

        // Find and preflight MachO binaries before mutating anything.
        progress?(100, 30, "checking MachO binaries")
        let machos = try findMachOBinaries(in: appURL)
        try validateMachOBinaries(machos, primaryExecutable: execURL)

        // Save entitlements after executable / architecture preflight succeeds.
        progress?(100, 40, "saving entitlements")
        let entitlementsDir = Self.entitlementsDirectory()
        try FileManager.default.createDirectory(at: entitlementsDir, withIntermediateDirectories: true)
        let entPath = entitlementsDir
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
        let entString = try MCPShell.dumpEntitlements(execURL)
        if !entString.isEmpty {
            try entString.write(to: entPath, atomically: true, encoding: .utf8)
        }

        for macho in machos {
            if try isMachoEncrypted(at: macho) {
                throw InstallerError.appEncrypted(macho.lastPathComponent)
            }

            // Convert MachO for macOS (replace version command with Mac Catalyst)
            progress?(100, 50, "converting \(macho.lastPathComponent)")
            try convertMacho(macho)

            // Ad-hoc sign each MachO
            try MCPShell.signMacho(macho)
        }

        // Inject PlayTools if requested
        progress?(100, 60, injectPlayTools ? "injecting PlayTools" : "skipping PlayTools")
        if injectPlayTools {
            try injectPlayToolsInstall(exec: execURL, payload: appURL)
        }

        // Set application category
        if let category = applicationCategory {
            let infoPlistPath = appURL.appendingPathComponent("Info.plist")
            let infoPath = appURL.appendingPathComponent("Info").appendingPathExtension("plist")
            let infoFile = FileManager.default.fileExists(atPath: infoPath.path) ? infoPath : infoPlistPath
            try setApplicationCategory(infoFile: infoFile, category: category)
        }

        // Set executable permissions
        progress?(100, 70, "setting permissions")
        try MCPShell.setExecutable(execURL)

        // Remove embedded.mobileprovision
        let provision = appURL.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }

        // Ensure minimum iOS version
        progress?(100, 75, "asserting minimum version")
        try assertMinimumVersion(infoFile: appURL.appendingPathComponent("Info.plist"))

        // Wrap: move to PlayCover Applications directory
        progress?(100, 80, "installing to Applications")
        let installDir = appDirectory.appendingPathComponent(bundleId).appendingPathExtension("app")
        if FileManager.default.fileExists(atPath: installDir.path) {
            try FileManager.default.removeItem(at: installDir)
        }
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: appURL, to: installDir)

        // Sign the installed app
        progress?(100, 90, "signing")
        let installedExec = installDir.appendingPathComponent(execName)
#if PLAYCOVER_GUI
        try signInstalledAppForGUI(at: installDir, executable: installedExec, fallbackEntitlements: entPath)
#else
        if FileManager.default.fileExists(atPath: entPath.path) {
            try MCPShell.signAppWith(installedExec, entitlements: entPath)
        } else {
            try MCPShell.signApp(installedExec)
        }
#endif

        // Remove quarantine
        progress?(100, 95, "removing quarantine")
        try MCPShell.removeQuarantine(installDir)

        progress?(100, 100, "finish")

        // Notify GUI that the app list has changed
        MCPNotificationPoster.postAppsChanged()

        return InstallResult(
            bundleIdentifier: bundleId,
            appPath: installDir.path,
            injectPlayTools: injectPlayTools
        )
    }

    // MARK: - Export

    /// Export a patched IPA with PlayTools embedded.
    ///
    /// - Parameters:
    ///   - ipaPath: Path to the source .ipa file.
    ///   - outputDirectory: Directory for the output .ipa (default: ~/Documents).
    ///   - applicationCategory: Optional LSApplicationCategoryType value.
    ///   - progress: Callback for progress updates.
    /// - Returns: `ExportResult` with bundle ID and output IPA path.
    public func export(
        ipaPath: String,
        outputDirectory: String? = nil,
        applicationCategory: String? = nil,
        progress: (@Sendable (_ total: Int, _ current: Int, _ message: String) -> Void)? = nil
    ) throws -> ExportResult {
        let ipaURL = URL(fileURLWithPath: ipaPath)

        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw InstallerError.ipaNotFound(ipaPath)
        }

        progress?(100, 0, "begin")

        let tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: "/Users"),
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Unzip
        progress?(100, 10, "unzip")
        try MCPShell.run("/usr/bin/unzip", "-oq", ipaURL.path, "-d", tmpDir.path)

        // Find .app bundle
        let payloadDir = tmpDir.appendingPathComponent("Payload")
        let appURL = try findAppBundle(in: payloadDir)

        // Read Info.plist
        progress?(100, 20, "reading Info.plist")
        let info = try readInfoPlist(from: appURL)
        let bundleId = info["CFBundleIdentifier"] as? String ?? "unknown"
        let execName = info["CFBundleExecutable"] as? String ?? ""
        guard !execName.isEmpty else {
            throw InstallerError.missingExecutable("No CFBundleExecutable in Info.plist")
        }
        let execURL = appURL.appendingPathComponent(execName)
        try validatePrimaryExecutable(execURL, executableName: execName)

        // Check MachO binaries and architecture compatibility before export work.
        progress?(100, 30, "checking MachO binaries")
        let machos = try findMachOBinaries(in: appURL)
        try validateMachOBinaries(machos, primaryExecutable: execURL)

        // Save entitlements after preflight succeeds.
        progress?(100, 40, "saving entitlements")
        let entitlementsDir = Self.entitlementsDirectory()
        try FileManager.default.createDirectory(at: entitlementsDir, withIntermediateDirectories: true)
        let entPath = entitlementsDir
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
        let entString = try MCPShell.dumpEntitlements(execURL)
        if !entString.isEmpty {
            try entString.write(to: entPath, atomically: true, encoding: .utf8)
        }

        for macho in machos {
            if try isMachoEncrypted(at: macho) {
                throw InstallerError.appEncrypted(macho.lastPathComponent)
            }
        }

        // Inject PlayTools into the IPA (copies dylib into Frameworks/)
        progress?(100, 60, "injecting PlayTools into IPA")
        try injectPlayToolsExport(exec: execURL, payload: appURL)

        // Set application category
        if let category = applicationCategory {
            let infoPlistPath = appURL.appendingPathComponent("Info.plist")
            let infoPath = appURL.appendingPathComponent("Info").appendingPathExtension("plist")
            let infoFile = FileManager.default.fileExists(atPath: infoPath.path) ? infoPath : infoPlistPath
            try setApplicationCategory(infoFile: infoFile, category: category)
        }

        // Ensure minimum iOS version
        progress?(100, 75, "asserting minimum version")
        try assertMinimumVersion(infoFile: appURL.appendingPathComponent("Info.plist"))

        // Pack back to IPA
        progress?(100, 85, "packing IPA")
        let outputDir = outputDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleId
        let outputIPA = outputDir.appendingPathComponent(outputName).appendingPathExtension("ipa")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputIPA.path) {
            try FileManager.default.removeItem(at: outputIPA)
        }
        try MCPShell.run("/usr/bin/zip", "-r", outputIPA.path, payloadDir.path)

        // Remove quarantine
        progress?(100, 95, "removing quarantine")
        try MCPShell.removeQuarantine(outputIPA)

        progress?(100, 100, "finish")
        return ExportResult(
            bundleIdentifier: bundleId,
            ipaPath: outputIPA.path
        )
    }

    // MARK: - Private Helpers

    /// Find the .app bundle inside a Payload directory.
    private func findAppBundle(in payloadDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: payloadDir.path) else {
            throw InstallerError.invalidIPA("Payload directory not found")
        }

        let contents = try fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallerError.invalidIPA("No .app bundle found in Payload")
        }
        return appURL
    }

    /// Read Info.plist from an .app bundle.
    private func readInfoPlist(from appURL: URL) throws -> [String: Any] {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            throw InstallerError.invalidIPA("Cannot read Info.plist")
        }
        return dict
    }

    /// Find all MachO binaries (including dylibs) within the .app bundle.
    private func findMachOBinaries(in appURL: URL) throws -> [URL] {
        var machos: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            guard let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = attrs.fileSize, fileSize > 4 else {
                continue
            }

            // Skip non-executable extensions (but include .dylib)
            let ext = fileURL.pathExtension
            if !ext.isEmpty && ext != "dylib" && ext != "" {
                // Check for common executable extensions
                let executableExts = ["", "dylib", "so", "0"]
                if !executableExts.contains(ext.lowercased()) {
                    continue
                }
            }

            if try isMachoFile(at: fileURL) {
                machos.append(fileURL)
            }
        }

        return machos
    }

    /// Check if a file is a MachO binary by reading magic bytes.
    private func isMachoFile(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return false }

        let bytes = [UInt8](data)
        // MH_MAGIC_64 (64-bit LE): 0xFEEDFACF
        // MH_CIGAM_64 (64-bit BE): 0xCFFAEDFE
        // MH_MAGIC (32-bit LE): 0xFEEDFACE
        // MH_CIGAM (32-bit BE): 0xCEFAEDFE
        // FAT_MAGIC (fat BE): 0xCAFEBABE
        // FAT_CIGAM (fat LE): 0xBEBAFECA
        switch bytes {
        case [0xCF, 0xFA, 0xED, 0xFE], // MH_MAGIC_64
             [0xFE, 0xED, 0xFA, 0xCF], // MH_CIGAM_64
             [0xCE, 0xFA, 0xED, 0xFE], // MH_MAGIC
             [0xFE, 0xED, 0xFA, 0xCE], // MH_CIGAM
             [0xCA, 0xFE, 0xBA, 0xBE], // FAT_MAGIC
             [0xBE, 0xBA, 0xFE, 0xCA]: // FAT_CIGAM
            return true
        default:
            return false
        }
    }

    private func validatePrimaryExecutable(_ executableURL: URL, executableName: String) throws {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw InstallerError.missingExecutable(executableURL.path)
        }

        guard try isMachoFile(at: executableURL) else {
            throw InstallerError.invalidIPA(
                "Main executable '\(executableName)' is not a valid Mach-O binary"
            )
        }
    }

    private func validateMachOBinaries(_ machos: [URL], primaryExecutable: URL) throws {
        guard !machos.isEmpty else {
            throw InstallerError.invalidIPA("No Mach-O binaries found in app bundle")
        }

        for macho in machos {
            let architectures = try inspectMachOArchitectures(at: macho)
            guard !architectures.isEmpty else {
                throw InstallerError.invalidIPA(
                    "Mach-O binary '\(macho.lastPathComponent)' does not contain a recognizable architecture header"
                )
            }

            guard architectures.contains("arm64") else {
                let binaryLabel = macho.standardizedFileURL == primaryExecutable.standardizedFileURL
                    ? "Main executable"
                    : "Binary"
                let archList = architectures.joined(separator: ", ")
                throw InstallerError.unsupportedArchitecture(
                    "\(binaryLabel) '\(macho.lastPathComponent)' contains [\(archList)] but PlayCover requires an arm64 slice"
                )
            }
        }
    }

    private func inspectMachOArchitectures(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else {
            return []
        }

        let magic = Array(data.prefix(4))
        switch magic {
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            return try parseFatArchitectures(data, bigEndian: true)
        case [0xBE, 0xBA, 0xFE, 0xCA]:
            return try parseFatArchitectures(data, bigEndian: false)
        case [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE]:
            let cputype = try readUInt32(from: data, offset: 4, bigEndian: false)
            return [architectureName(for: cputype)]
        case [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE]:
            let cputype = try readUInt32(from: data, offset: 4, bigEndian: true)
            return [architectureName(for: cputype)]
        default:
            return []
        }
    }

    private func parseFatArchitectures(_ data: Data, bigEndian: Bool) throws -> [String] {
        let archCount = try readUInt32(from: data, offset: 4, bigEndian: bigEndian)
        var architectures: [String] = []
        var offset = 8

        for _ in 0..<archCount {
            guard data.count >= offset + 20 else {
                throw InstallerError.invalidIPA("Fat Mach-O header is truncated")
            }

            let cputype = try readUInt32(from: data, offset: offset, bigEndian: bigEndian)
            let name = architectureName(for: cputype)
            if !architectures.contains(name) {
                architectures.append(name)
            }
            offset += 20
        }

        return architectures
    }

    private func readUInt32(from data: Data, offset: Int, bigEndian: Bool) throws -> UInt32 {
        guard data.count >= offset + 4 else {
            throw InstallerError.invalidIPA("Mach-O header is truncated")
        }

        let bytes = Array(data[offset..<(offset + 4)])
        if bigEndian {
            return bytes.reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
        }

        return bytes.enumerated().reduce(UInt32(0)) { partial, element in
            partial | (UInt32(element.element) << (8 * element.offset))
        }
    }

    private func architectureName(for cputype: UInt32) -> String {
        switch cputype {
        case 0x0100_000C:
            return "arm64"
        case 0x0100_0007:
            return "x86_64"
        case 0x0000_000C:
            return "arm"
        case 0x0000_0007:
            return "x86"
        case 0x0000_0012:
            return "ppc"
        default:
            return String(format: "cputype_0x%08X", cputype)
        }
    }

    /// Check if a MachO binary is encrypted by looking for LC_ENCRYPTION_INFO.
    private func isMachoEncrypted(at url: URL) throws -> Bool {
        // Use codesign to check encryption
        // An encrypted binary will have cryptid != 0 in its encryption info
        // We use `codesign -d -vvv` and look for "flags=0x... (encrypted)"
        do {
            let output = try MCPShell.run("/usr/bin/codesign", "-d", "-vvv", url.path)
            // codesign output contains "cryptid" info for encrypted binaries
            return output.contains("encrypted")
        } catch {
            // If codesign fails, try a binary-level check
            return false
        }
    }

    /// Convert a MachO binary for macOS.
    ///
    /// In GUI builds, defer to PlayCover's long-lived `Macho.convertMacho` implementation
    /// so the embedded MCP path stays aligned with the original installer behavior.
    /// CLI builds keep a local fallback implementation with equivalent structure.
    private func convertMacho(_ machoURL: URL) throws {
#if PLAYCOVER_GUI
        try Macho.convertMacho(machoURL)
#else
        var binary = try Data(contentsOf: machoURL)

        // Strip fat binary to ARM64 only
        try stripFatBinary(&binary)

        // Replace version command with Mac Catalyst
        try replaceVersionCommand(&binary)

        // Replace @rpath dylib references with system paths
        try replaceLibraries(&binary)

        // Write modified binary back
        try FileManager.default.removeItem(at: machoURL)
        try binary.write(to: machoURL)
#endif
    }

    /// Strip fat binary to extract ARM64 slice only.
    private func stripFatBinary(_ binary: inout Data) throws {
        guard binary.count >= 4 else { return }

        let magic = Array(binary.prefix(4))
        let bigEndian: Bool
        switch magic {
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            bigEndian = true
        case [0xBE, 0xBA, 0xFE, 0xCA]:
            bigEndian = false
        default:
            return // Not a fat binary, nothing to strip
        }

        guard binary.count >= 8 else {
            throw InstallerError.invalidIPA("Fat Mach-O header is truncated")
        }

        let nfatArch = try readUInt32(from: binary, offset: 4, bigEndian: bigEndian)
        var offset = 8 // sizeof(fat_header)
        let archSize = 20 // sizeof(fat_arch)

        for _ in 0..<nfatArch {
            guard binary.count >= offset + archSize else {
                throw InstallerError.invalidIPA("Fat Mach-O header is truncated")
            }

            // Parse fat_arch: cputype(4) + cpusubtype(4) + offset(4) + size(4) + align(4)
            let cputype = try readUInt32(from: binary, offset: offset, bigEndian: bigEndian)
            let sliceOffset = try readUInt32(from: binary, offset: offset + 8, bigEndian: bigEndian)
            let sliceSize = try readUInt32(from: binary, offset: offset + 12, bigEndian: bigEndian)

            let start = Int(sliceOffset)
            let end = start + Int(sliceSize)
            guard start >= 0, sliceSize > 0, end <= binary.count else {
                throw InstallerError.invalidIPA("Fat Mach-O slice is truncated")
            }

            // CPU_TYPE_ARM64 = 0x0100000C
            if cputype == 0x0100000C {
                binary = binary.subdata(in: start..<end)
                return
            }

            offset += archSize
        }

        throw InstallerError.conversionFailed("No ARM64 architecture found in fat binary")
    }

    private let dylibReplacements = [
        ("@rpath/libswiftUIKit.dylib", "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib")
    ]
    private let frameworkReplacementPrefixes = [
        ("/System/Library/Frameworks/", "/System/iOSSupport/System/Library/Frameworks/"),
        ("/System/Library/PrivateFrameworks/", "/System/iOSSupport/System/Library/PrivateFrameworks/")
    ]

    /// Replace version-related load commands with Mac Catalyst platform markers.
    private func replaceVersionCommand(_ binary: inout Data) throws {
        var macCatalystCommand = build_version_command(
            cmd: UInt32(LC_BUILD_VERSION),
            cmdsize: 24,
            platform: UInt32(PLATFORM_MACCATALYST),
            minos: 0x000b0000,
            sdk: 0x000e0000,
            ntools: 0
        )

        try replaceLastCommand(&binary, satisfy: { data, shouldSwap in
            let loadCommand = data.extract(
                load_command.self,
                offset: data.startIndex,
                swap: shouldSwap ? swap_load_command : nil
            )
            return [UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_MACOSX), UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)
        }, with: { shouldSwap in
            if shouldSwap {
                swap_build_version_command(&macCatalystCommand, NX_BigEndian)
            }
            return Data(bytes: &macCatalystCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true)
    }

    /// Replace known dylib references with system iOS support paths.
    private func replaceLibraries(_ binary: inout Data) throws {
        for (originalPath, replacementPath) in dylibReplacements {
            try replaceLibrary(&binary, originalPath, replacementPath)
        }

        for loadPath in try linkedDylibPaths(in: binary) {
            guard let replacementPath = mappedIOSSupportPath(for: loadPath),
                  replacementPath != loadPath else {
                continue
            }
            try replaceLibrary(&binary, loadPath, replacementPath)
        }
    }

    private func linkedDylibPaths(in binary: Data) throws -> [String] {
        var result: [String] = []
        try _ = iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(
                load_command.self,
                offset: offset,
                swap: shouldSwap ? swap_load_command : nil
            )
            guard [LC_LOAD_WEAK_DYLIB, UInt32(LC_LOAD_DYLIB)].contains(loadCommand.cmd) else {
                return false
            }

            let dylibCommand = binary.extract(
                dylib_command.self,
                offset: offset,
                swap: shouldSwap ? swap_dylib_command : nil
            )
            let dylibName = String(
                data: binary,
                offset: offset,
                commandSize: Int(dylibCommand.cmdsize),
                loadCommandString: dylibCommand.dylib.name
            )
            if !dylibName.isEmpty {
                result.append(dylibName)
            }
            return false
        }
        return result
    }

    private func mappedIOSSupportPath(for loadPath: String) -> String? {
        for (sourcePrefix, targetPrefix) in frameworkReplacementPrefixes {
            guard loadPath.hasPrefix(sourcePrefix) else {
                continue
            }

            let suffix = String(loadPath.dropFirst(sourcePrefix.count))
            let candidate = targetPrefix + suffix
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func replaceLibrary(_ binary: inout Data, _ sourcePath: String, _ targetPath: String) throws {
        var dylibCommandType: UInt32 = 0
        var originalDylib: dylib?

        try replaceLastCommand(&binary, satisfy: { commandData, shouldSwap in
            let loadCommand = commandData.extract(
                load_command.self,
                offset: commandData.startIndex,
                swap: shouldSwap ? swap_load_command : nil
            )
            if ![LC_LOAD_WEAK_DYLIB, UInt32(LC_LOAD_DYLIB)].contains(loadCommand.cmd) {
                return false
            }

            let dylibCommand = commandData.extract(
                dylib_command.self,
                offset: commandData.startIndex,
                swap: shouldSwap ? swap_dylib_command : nil
            )
            if String(
                data: commandData,
                offset: commandData.startIndex,
                commandSize: Int(dylibCommand.cmdsize),
                loadCommandString: dylibCommand.dylib.name
            ) != sourcePath {
                return false
            }

            dylibCommandType = dylibCommand.cmd
            originalDylib = dylibCommand.dylib
            return true
        }, with: { shouldSwap in
            guard var newDylib = originalDylib else {
                return nil
            }

            let fixedSize = MemoryLayout<dylib_command>.size
            let stringLength = targetPath.lengthOfBytes(using: .utf8)
            let padding = 8 - (stringLength % 8)
            let commandSize = fixedSize + stringLength + padding

            newDylib.name = lc_str(offset: UInt32(fixedSize))
            var command = dylib_command(
                cmd: dylibCommandType,
                cmdsize: UInt32(commandSize),
                dylib: newDylib
            )
            guard let stringData = targetPath.data(using: .utf8) else {
                return nil
            }
            if shouldSwap {
                swap_dylib_command(&command, NX_BigEndian)
            }
            var commandData = Data(bytes: &command, count: fixedSize)
            commandData.append(stringData)
            commandData.append(Data(count: padding))
            return commandData
        }, atEnd: false)
    }

    private func replaceLastCommand(
        _ binary: inout Data,
        satisfy isTargetCommand: (Data, Bool) -> Bool,
        with getNewCommandData: (Bool) -> Data?,
        atEnd shouldAppend: Bool
    ) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var shouldSwap = false

        var oldCommandStart = headerSize
        var oldCommandSize: UInt32 = 0

        let movedCommandsEnd = try iterateLoadCommands(binary: binary) { offset, needSwap in
            let loadCommand = binary.extract(
                load_command.self,
                offset: offset,
                swap: needSwap ? swap_load_command : nil
            )
            if isTargetCommand(binary[offset ..< offset + Int(loadCommand.cmdsize)], needSwap) {
                oldCommandStart = offset
                oldCommandSize = loadCommand.cmdsize
                shouldSwap = needSwap
            }
            return false
        }

        let oldCommandEnd = oldCommandStart + Int(oldCommandSize)
        guard let newCommandData = getNewCommandData(shouldSwap) else {
            return
        }
        let newCommandSize = UInt32(newCommandData.count)

        var resultingCommandsData = binary[oldCommandEnd..<movedCommandsEnd]
        if shouldAppend {
            resultingCommandsData.append(newCommandData)
        } else {
            resultingCommandsData.insert(contentsOf: newCommandData, at: resultingCommandsData.startIndex)
        }

        let injectionEnd = movedCommandsEnd - Int(oldCommandSize) + Int(newCommandSize)
        if injectionEnd <= movedCommandsEnd {
            binary.replaceSubrange(
                injectionEnd..<movedCommandsEnd,
                with: Data(count: movedCommandsEnd - injectionEnd)
            )
        }
        binary.replaceSubrange(oldCommandStart..<injectionEnd, with: resultingCommandsData)

        header.sizeofcmds -= oldCommandSize
        header.sizeofcmds += newCommandSize
        let newHeaderData = Data(bytes: &header, count: headerSize)
        binary.replaceSubrange(0..<headerSize, with: newHeaderData)
    }

    private func iterateLoadCommands(binary: Data, _ evaluate: (Int, Bool) -> Bool) throws -> Int {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        var offset = headerSize
        let shouldSwap = header.magic == MH_CIGAM_64
        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        let allCommandsEnd = headerSize + Int(header.sizeofcmds)
        if allCommandsEnd >= binary.count || allCommandsEnd <= headerSize {
            throw InstallerError.invalidIPA("Mach-O file is corrupted")
        }
        for index in 0..<header.ncmds {
            let loadCommand = binary.extract(
                load_command.self,
                offset: offset,
                swap: shouldSwap ? swap_load_command : nil
            )
            let commandEnd = offset + Int(loadCommand.cmdsize)
            if commandEnd > allCommandsEnd || commandEnd <= offset {
                throw InstallerError.invalidIPA("Mach-O file is corrupted at load command \(index)")
            }
            let terminated = evaluate(offset, shouldSwap)
            offset = commandEnd
            if terminated {
                break
            }
        }
        return offset
    }

    // MARK: - PlayTools Injection

    /// Inject PlayTools for install mode (system path reference).
    private func injectPlayToolsInstall(exec: URL, payload: URL) throws {
        let playToolsDylib = playToolsFrameworkPath
            .appendingPathComponent("PlayTools")

        guard FileManager.default.fileExists(atPath: playToolsDylib.path) else {
            throw InstallerError.injectionFailed(
                "PlayTools not installed at \(playToolsFrameworkPath.path)"
            )
        }

#if canImport(injection)
        var didInject = false
        Inject.injectMachO(
            machoPath: exec.path,
            cmdType: .loadDylib,
            backup: false,
            injectPath: playToolsDylib.path,
            finishHandle: { result in
                didInject = result
            }
        )

        guard didInject else {
            throw InstallerError.injectionFailed(
                "Failed to inject PlayTools dylib load command into \(exec.lastPathComponent)"
            )
        }

        do {
            try installPlayToolsResources(in: payload)
        } catch {
            throw InstallerError.injectionFailed(
                "Failed to install PlayTools resources: \(error.localizedDescription)"
            )
        }

        try MCPShell.signApp(exec)
#else
        // CLI target currently lacks the GUI injection framework linkage.
        // Keep the previous fallback semantics there until install internals are fully shared.
        do {
            try MCPShell.run("/usr/bin/install_name_tool",
                             "-add_rpath", playToolsFrameworkPath.deletingLastPathComponent().path,
                             exec.path)
        } catch {
            // install_name_tool might already have this rpath, ignore the error
        }

        try MCPShell.signApp(exec)
#endif
    }

    /// Inject PlayTools for export mode (embed dylib in IPA).
    private func injectPlayToolsExport(exec: URL, payload: URL) throws {
        // Find PlayTools dylib source
        let sourceDylib: URL
        if let bundle = playCoverBundlePath {
            sourceDylib = bundle
                .appendingPathComponent("Contents/Frameworks/PlayTools.framework/PlayTools")
        } else {
            sourceDylib = playToolsFrameworkPath.appendingPathComponent("PlayTools")
        }

        guard FileManager.default.fileExists(atPath: sourceDylib.path) else {
            throw InstallerError.injectionFailed(
                "PlayTools dylib not found at \(sourceDylib.path)"
            )
        }

        // Create Frameworks directory in the app
        let frameworksDir = payload.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        // Copy PlayTools dylib
        let destDylib = frameworksDir.appendingPathComponent("PlayTools.dylib")
        if FileManager.default.fileExists(atPath: destDylib.path) {
            try FileManager.default.removeItem(at: destDylib)
        }
        try FileManager.default.copyItem(at: sourceDylib, to: destDylib)
        try MCPShell.setExecutable(destDylib)

        // Add load command for the embedded dylib
        try MCPShell.run("/usr/bin/install_name_tool",
                      "-change", sourceDylib.path,
                      "@executable_path/Frameworks/PlayTools.dylib",
                      exec.path)

        // Sign the app
        try MCPShell.signApp(exec)
    }

    private func installPlayToolsResources(in payload: URL) throws {
        let sourceFramework = try resolvePlayToolsResourceFramework()
        try copyPlayToolsLocalizations(from: sourceFramework, to: payload)

        let bundleTarget = try copyPlayToolsAsset(
            source: sourceFramework,
            target: payload,
            directoryName: "PlugIns",
            component: "AKInterface",
            pathExtension: "bundle"
        )
        try MCPShell.setExecutable(bundleTarget)
        try MCPShell.signMacho(bundleTarget)
    }

    private func resolvePlayToolsResourceFramework() throws -> URL {
        let candidates = [
            playCoverBundlePath?.appendingPathComponent("Contents/Frameworks/PlayTools.framework"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/PlayTools.framework"),
            playToolsFrameworkPath,
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw InstallerError.injectionFailed(
            "PlayTools framework resources not found in bundled or system locations"
        )
    }

    private func copyPlayToolsLocalizations(from sourceFramework: URL, to payload: URL) throws {
        let topLevelEntries = try FileManager.default.contentsOfDirectory(
            at: sourceFramework,
            includingPropertiesForKeys: nil
        )

        for localizationDirectory in topLevelEntries where localizationDirectory.pathExtension == "lproj" {
            _ = try copyPlayToolsAsset(
                source: sourceFramework,
                target: payload,
                directoryName: localizationDirectory.lastPathComponent,
                component: "Playtools",
                pathExtension: "strings"
            )
        }

        let resourcesDirectory = sourceFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: resourcesDirectory.path) {
            let resourceEntries = try FileManager.default.contentsOfDirectory(
                at: resourcesDirectory,
                includingPropertiesForKeys: nil
            )
            for localizationDirectory in resourceEntries where localizationDirectory.pathExtension == "lproj" {
                _ = try copyPlayToolsAsset(
                    source: resourcesDirectory,
                    target: payload,
                    directoryName: localizationDirectory.lastPathComponent,
                    component: "Playtools",
                    pathExtension: "strings"
                )
            }
        }
    }

    private func copyPlayToolsAsset(
        source: URL,
        target: URL,
        directoryName: String,
        component: String,
        pathExtension: String
    ) throws -> URL {
        let directory = target.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceAsset = source
            .appendingPathComponent(directoryName)
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)
        let targetAsset = directory
            .appendingPathComponent(component)
            .appendingPathExtension(pathExtension)

        if FileManager.default.fileExists(atPath: targetAsset.path) {
            try FileManager.default.removeItem(at: targetAsset)
        }
        try FileManager.default.copyItem(at: sourceAsset, to: targetAsset)
        return targetAsset
    }

#if PLAYCOVER_GUI
    private func signInstalledAppForGUI(at installDir: URL, executable: URL, fallbackEntitlements: URL) throws {
        let installedApp = PlayApp(appUrl: installDir)
        let tmpEntitlements = FileManager.default.temporaryDirectory
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: tmpEntitlements) }

        do {
            let composed = try Entitlements.composeEntitlements(installedApp)
            try composed.store(tmpEntitlements)
            try MCPShell.signAppWith(executable, entitlements: tmpEntitlements)
        } catch {
            if FileManager.default.fileExists(atPath: fallbackEntitlements.path) {
                try MCPShell.signAppWith(executable, entitlements: fallbackEntitlements)
            } else {
                try MCPShell.signApp(executable)
            }
        }
    }
#endif

    // MARK: - Info.plist Helpers

    /// Set LSApplicationCategoryType in Info.plist.
    private func setApplicationCategory(infoFile: URL, category: String) throws {
        guard let plist = NSMutableDictionary(contentsOf: infoFile) else { return }
        plist["LSApplicationCategoryType"] = category
        plist.write(to: infoFile, atomically: true)
    }

    /// Assert minimum iOS version in Info.plist.
    private func assertMinimumVersion(infoFile: URL) throws {
        guard let plist = NSMutableDictionary(contentsOf: infoFile) else { return }
        if let minVersion = plist["MinimumOSVersion"] as? String {
            let parts = minVersion.split(separator: ".").compactMap { Int($0) }
            if parts.first ?? 0 < 11 {
                plist["MinimumOSVersion"] = "11.0"
                plist.write(to: infoFile, atomically: true)
            }
        } else {
            plist["MinimumOSVersion"] = "11.0"
            plist.write(to: infoFile, atomically: true)
        }
    }

    // MARK: - Path Utilities

    private static func entitlementsDirectory() -> URL {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        return container.appendingPathComponent("Entitlements")
    }

    private static func defaultPlayToolsFrameworkPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Frameworks/PlayTools.framework")
    }

    private static func findPlayCoverBundle() -> URL? {
        // Search common locations for PlayCover.app
        let searchPaths = [
            "/Applications/PlayCover.app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/PlayCover.app").path
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

#if !PLAYCOVER_GUI
private extension String {
    init(data: Data, offset: Int, commandSize: Int, loadCommandString: lc_str) {
        let loadCommandStringOffset = Int(loadCommandString.offset)
        let stringOffset = offset + loadCommandStringOffset
        let length = commandSize - loadCommandStringOffset
        self = String(
            data: data[stringOffset..<(stringOffset + length)],
            encoding: .utf8
        )?.trimmingCharacters(in: .controlCharacters) ?? ""
    }
}

private extension Data {
    func extract<T>(
        _ type: T.Type,
        offset: Int = 0,
        swap: ((UnsafeMutablePointer<T>, NXByteOrder) -> Void)? = nil
    ) -> T {
        let data = self[offset..<offset + MemoryLayout<T>.size]
        var result = data.withUnsafeBytes { dataBytes in
            dataBytes.baseAddress!
                .assumingMemoryBound(to: UInt8.self)
                .withMemoryRebound(to: T.self, capacity: 1) { pointer in
                    pointer.pointee
                }
        }
        swap?(&result, NXHostByteOrder())
        return result
    }
}
#endif
