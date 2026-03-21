//
//  Keymapping.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/15/25.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum KeymappingError: LocalizedError {
    case emptyName
    case invalidName(String)
    case keymapNotFound(String)
    case keymapAlreadyExists(String)
    case cannotDeleteDefaultKeymap(String)
    case bundleIDMismatch(expected: String, actual: String)
    case invalidKeymapFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Keymap name cannot be empty."
        case let .invalidName(name):
            return "Keymap name '\(name)' contains unsupported characters."
        case let .keymapNotFound(name):
            return "Keymap '\(name)' was not found."
        case let .keymapAlreadyExists(name):
            return "Keymap '\(name)' already exists."
        case let .cannotDeleteDefaultKeymap(name):
            return "Keymap '\(name)' is the default keymap and cannot be deleted."
        case let .bundleIDMismatch(expected, actual):
            return "Imported keymap bundle id '\(actual)' does not match expected bundle id '\(expected)'."
        case let .invalidKeymapFile(path):
            return "Keymap file at '\(path)' is not a valid PlayCover keymap."
        }
    }
}

struct ImportedKeymapResult {
    let storedURL: URL
    let importedBundleIdentifier: String
    let usedLegacyConversion: Bool
}

private struct DecodedKeymapImport {
    let keymap: Keymap
    let usedLegacyConversion: Bool
}

class Keymapping {
    static var keymappingDir: URL {
        let keymappingFolder = PlayTools.playCoverContainer.appendingPathComponent("Keymapping")
        if !FileManager.default.fileExists(atPath: keymappingFolder.path) {
            do {
                try FileManager.default.createDirectory(at: keymappingFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return keymappingFolder
    }

    static func validateName(_ name: String) throws {
        if name.isEmpty {
            throw KeymappingError.emptyName
        }

        if name == "." || name == ".." || name != name.esc || name.contains("/") || name.contains(":") {
            throw KeymappingError.invalidName(name)
        }
    }

    let info: AppInfo
    let baseKeymapURL: URL
    let configURL: URL

    let encoder: PropertyListEncoder

    var keymapConfig: KeymapConfig {
        get {
            do {
                let data = try Data(contentsOf: configURL)
                let map = try PropertyListDecoder().decode(KeymapConfig.self, from: data)
                return map
            } catch {
                print(error)
                return resetConfig()
            }
        }
        set {
            do {
                let data = try encoder.encode(newValue)
                try data.write(to: configURL)
            } catch {
                print(error)
            }
        }
    }

    init(_ info: AppInfo) {
        self.info = info

        self.baseKeymapURL = Keymapping.keymappingDir.appendingPathComponent(info.bundleIdentifier)
        self.configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        if !FileManager.default.fileExists(atPath: self.baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(at: self.baseKeymapURL,
                                                        withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        self.encoder = PropertyListEncoder()
        self.encoder.outputFormat = .xml

        self.reloadKeymapCache()

    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    public func keymapURL(name: String) -> URL {
        constructKeymapPath(name: name)
    }

    public func orderedKeymapURLs() -> [URL] {
        reloadKeymapCache()
        return keymapConfig.keymapOrder
    }

    public func defaultKeymapURL() -> URL {
        reloadKeymapCache()
        return keymapConfig.defaultKm
    }

    public func isDefaultKeymap(name: String) -> Bool {
        defaultKeymapURL() == constructKeymapPath(name: name)
    }

    public func reloadKeymapCache() {
        guard FileManager.default.fileExists(atPath: baseKeymapURL.path) else {
            return
        }

        do {
            let directoryContents = try FileManager.default
                .contentsOfDirectory(at: baseKeymapURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var keymaps: [URL] = []

            if directoryContents.count > 0 {
                for keymap in directoryContents where keymap.pathExtension.contains("plist") {
                    if !keymapConfig.keymapOrder.contains(keymap) {
                        keymapConfig.keymapOrder.append(keymap)
                    }

                    keymaps.append(keymap)
                }

                for keymap in keymapConfig.keymapOrder where !keymaps.contains(keymap) {
                    setKeymap(name: keymap.deletingPathExtension().lastPathComponent,
                              map: Keymap(bundleIdentifier: info.bundleIdentifier))
                }

                return
            }
        } catch {
            print("failed to get keymapping directory")
            Log.shared.error(error)
        }

        setKeymap(name: "default", map: Keymap(bundleIdentifier: info.bundleIdentifier))
        reloadKeymapCache()
    }

    public func getKeymap(name: String) -> Keymap {
        do {
            let data = try Data(contentsOf: constructKeymapPath(name: name))
            let map = try PropertyListDecoder().decode(Keymap.self, from: data)
            return map
        } catch {
            print(error)
            return reset(name: name)
        }
    }

    public func createKeymap(name: String) throws -> URL {
        reloadKeymapCache()
        try Self.validateName(name)
        guard !hasKeymap(name: name) else {
            throw KeymappingError.keymapAlreadyExists(name)
        }

        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))

        guard hasKeymap(name: name) else {
            throw KeymappingError.keymapNotFound(name)
        }

        return constructKeymapPath(name: name)
    }

    public func createEmptyKeymap(name: String) -> Bool {
        do {
            _ = try createKeymap(name: name)
            return true
        } catch {
            Log.shared.error(error)
            return false
        }
    }

    private func setKeymap(name: String, map: Keymap) {
        let keymapPath = constructKeymapPath(name: name)

        do {
            let data = try encoder.encode(map)
            try data.write(to: keymapPath)

            if !keymapConfig.keymapOrder.contains(keymapPath) {
                keymapConfig.keymapOrder.append(keymapPath)
            }
        } catch {
            print(error)
        }
    }

    public func renameKeymapOrThrow(prevName: String, newName: String) throws -> URL {
        reloadKeymapCache()
        try Self.validateName(newName)

        let oldPath = constructKeymapPath(name: prevName)
        let newPath = constructKeymapPath(name: newName)

        guard prevName != newName else {
            return oldPath
        }

        guard let oldKeymapIndex = keymapConfig.keymapOrder.firstIndex(of: oldPath) else {
            throw KeymappingError.keymapNotFound(prevName)
        }

        guard !hasKeymap(name: newName) else {
            throw KeymappingError.keymapAlreadyExists(newName)
        }

        do {
            try FileManager.default.moveItem(at: oldPath, to: newPath)
            keymapConfig.keymapOrder[oldKeymapIndex] = newPath

            if keymapConfig.defaultKm == oldPath {
                keymapConfig.defaultKm = newPath
            }

            return newPath
        } catch {
            throw error
        }
    }

    public func renameKeymap(prevName: String, newName: String) -> Bool {
        do {
            _ = try renameKeymapOrThrow(prevName: prevName, newName: newName)
            return true
        } catch {
            Log.shared.error(error)
            return false
        }
    }

    public func deleteKeymapOrThrow(name: String) throws -> URL {
        reloadKeymapCache()
        let keymapURL = constructKeymapPath(name: name)

        guard let keymapIndex = keymapConfig.keymapOrder.firstIndex(of: keymapURL) else {
            throw KeymappingError.keymapNotFound(name)
        }

        guard keymapConfig.defaultKm != keymapURL else {
            throw KeymappingError.cannotDeleteDefaultKeymap(name)
        }

        do {
            try FileManager.default.trashItem(at: keymapURL, resultingItemURL: nil)
            keymapConfig.keymapOrder.remove(at: keymapIndex)
            return keymapURL
        } catch {
            throw error
        }
    }

    public func deleteKeymap(name: String) -> Bool {
        do {
            _ = try deleteKeymapOrThrow(name: name)
            return true
        } catch {
            Log.shared.error(error)
            return false
        }
    }

    public func hasKeymap(name: String) -> Bool {
        keymapConfig.keymapOrder.contains(constructKeymapPath(name: name))
    }

    @discardableResult
    public func reset(name: String) -> Keymap {
        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))
        return getKeymap(name: name)
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")

        keymapConfig = KeymapConfig(defaultKm: defaultURL,
                                    keymapOrder: [defaultURL])

        return keymapConfig
    }

    public func importKeymap(
        from sourceURL: URL,
        name: String,
        allowBundleIDMismatch: Bool = false,
        allowLegacyConversion: Bool = true
    ) throws -> ImportedKeymapResult {
        reloadKeymapCache()
        try Self.validateName(name)

        guard !hasKeymap(name: name) else {
            throw KeymappingError.keymapAlreadyExists(name)
        }

        let decodedImport = try loadImportedKeymap(from: sourceURL, allowLegacyConversion: allowLegacyConversion)
        let importedKeymap = decodedImport.keymap

        if importedKeymap.bundleIdentifier != info.bundleIdentifier && !allowBundleIDMismatch {
            throw KeymappingError.bundleIDMismatch(expected: info.bundleIdentifier, actual: importedKeymap.bundleIdentifier)
        }

        setKeymap(name: name, map: importedKeymap)
        let storedURL = constructKeymapPath(name: name)

        return ImportedKeymapResult(
            storedURL: storedURL,
            importedBundleIdentifier: importedKeymap.bundleIdentifier,
            usedLegacyConversion: decodedImport.usedLegacyConversion
        )
    }

    public func importKeymap(name: String, success: @escaping (Bool) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = true
        openPanel.allowedContentTypes = [UTType(exportedAs: "io.playcover.PlayCover-playmap")]
        openPanel.title = NSLocalizedString("playapp.importKm", comment: "")

        openPanel.begin { result in
            if result == .OK {
                do {
                    if let selectedPath = openPanel.url {
                        let decodedImport = try self.loadImportedKeymap(from: selectedPath, allowLegacyConversion: true)
                        if decodedImport.keymap.bundleIdentifier == self.info.bundleIdentifier {
                            _ = try self.importKeymap(
                                from: selectedPath,
                                name: name,
                                allowBundleIDMismatch: false,
                                allowLegacyConversion: true
                            )
                            success(true)
                        } else if self.differentBundleIdKeymapAlert() {
                            _ = try self.importKeymap(
                                from: selectedPath,
                                name: name,
                                allowBundleIDMismatch: true,
                                allowLegacyConversion: true
                            )
                            success(true)
                        } else {
                            success(false)
                        }
                    }
                } catch {
                    Log.shared.error(error)
                    success(false)
                }
                openPanel.close()
            }
        }
    }

    public func exportKeymap(name: String, to destinationURL: URL) throws -> URL {
        reloadKeymapCache()

        guard hasKeymap(name: name) else {
            throw KeymappingError.keymapNotFound(name)
        }

        let resolvedDestination = destinationURL.standardizedFileURL
        let destinationDirectory = resolvedDestination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        let data = try encoder.encode(getKeymap(name: name))
        if FileManager.default.fileExists(atPath: resolvedDestination.path) {
            try FileManager.default.removeItem(at: resolvedDestination)
        }
        try data.write(to: resolvedDestination)
        return resolvedDestination
    }

    public func exportKeymap(name: String) {
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("playapp.exportKm", comment: "")
        savePanel.nameFieldLabel = NSLocalizedString("playapp.exportKmPanel.fieldLabel", comment: "")
        savePanel.nameFieldStringValue = info.displayName
        savePanel.allowedContentTypes = [UTType(exportedAs: "io.playcover.PlayCover-playmap")]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        savePanel.begin { result in
            if result == .OK {
                do {
                    if let selectedPath = savePanel.url {
                        let exportedURL = try self.exportKeymap(name: name, to: selectedPath)
                        exportedURL.openInFinder()
                    }
                } catch {
                    savePanel.close()
                    Log.shared.error(error)
                }
                savePanel.close()
            }
        }
    }

    private func loadImportedKeymap(from sourceURL: URL, allowLegacyConversion: Bool) throws -> DecodedKeymapImport {
        do {
            let data = try Data(contentsOf: sourceURL)
            return DecodedKeymapImport(
                keymap: try PropertyListDecoder().decode(Keymap.self, from: data),
                usedLegacyConversion: false
            )
        } catch {
            if allowLegacyConversion, let legacyKeymap = LegacySettings.convertLegacyKeymapFile(sourceURL) {
                return DecodedKeymapImport(keymap: legacyKeymap, usedLegacyConversion: true)
            }

            throw KeymappingError.invalidKeymapFile(sourceURL.path)
        }
    }

    private func differentBundleIdKeymapAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.differentBundleIdKeymap.message", comment: "")
        alert.informativeText = NSLocalizedString("alert.differentBundleIdKeymap.text", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        return alert.runModal() == .alertFirstButtonReturn
    }
}
