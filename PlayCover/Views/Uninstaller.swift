//
//  Uninstaller.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/26/22.
//

import SwiftUI

struct CheckBoxHelper {
    var view: NSView
    var button: NSButton
    var buttonvar: String
}

struct UninstallOptions {
    let removeAppData: Bool
    let removeAppKeymap: Bool
    let removeAppSettings: Bool
    let removeAppEntitlements: Bool
    let removePlayChain: Bool

    init(
        removeAppData: Bool = false,
        removeAppKeymap: Bool = false,
        removeAppSettings: Bool = false,
        removeAppEntitlements: Bool = false,
        removePlayChain: Bool = false
    ) {
        self.removeAppData = removeAppData
        self.removeAppKeymap = removeAppKeymap
        self.removeAppSettings = removeAppSettings
        self.removeAppEntitlements = removeAppEntitlements
        self.removePlayChain = removePlayChain
    }

    static func fromPreferences(_ preferences: UninstallPreferences = .shared) -> UninstallOptions {
        UninstallOptions(
            removeAppData: preferences.clearAppData,
            removeAppKeymap: preferences.removeAppKeymap,
            removeAppSettings: preferences.removeAppSettings,
            removeAppEntitlements: preferences.removeAppEntitlements,
            removePlayChain: preferences.removePlayChain
        )
    }

    var removesAllManagedArtifacts: Bool {
        removeAppData && removeAppKeymap && removeAppSettings && removeAppEntitlements && removePlayChain
    }
}

struct UninstallResult {
    let bundleID: String
    let removedApp: Bool
    let removedAppData: Bool
    let removedSettings: Bool
    let removedKeymap: Bool
    let removedPlaychain: Bool
    let removedEntitlements: Bool
}

class Uninstaller {
    private static let libraryUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    private static let pruneURLs: [URL] = [
        PlayTools.playCoverContainer.appendingPathComponent("App Settings"),
        PlayTools.playCoverContainer.appendingPathComponent("Entitlements"),
        PlayTools.playCoverContainer.appendingPathComponent("Keymapping"),
        PlayTools.playCoverContainer.appendingPathComponent("PlayChain")
    ]
    private static let cacheURLs: [URL] = [
        Uninstaller.libraryUrl.appendingPathComponent("Containers"),
        Uninstaller.libraryUrl.appendingPathComponent("Application Scripts"),
        Uninstaller.libraryUrl.appendingPathComponent("Caches"),
        Uninstaller.libraryUrl.appendingPathComponent("HTTPStorages"),
        Uninstaller.libraryUrl.appendingPathComponent("Saved Application State")
    ]

    private static func createButtonView(_ yaxis: CGFloat, _ text: String, _ varname: String) -> CheckBoxHelper {
        let button = NSButton(checkboxWithTitle: text, target: self, action: nil)

        if UninstallPreferences.shared.value(forKey: varname) as? Bool ?? true {
            button.animator().setNextState()
        }

        let view = NSView(frame: NSRect(x: 0, y: yaxis,
                                        width: button.fittingSize.width,
                                        height: button.fittingSize.height))

        view.addSubview(button)

        return CheckBoxHelper(view: view, button: button, buttonvar: varname)
    }

    @MainActor
    static func uninstallPopup(_ app: PlayApp) async {
        if UninstallPreferences.shared.showUninstallPopup {
            let boxmakers: [(String, String)] = [
                ("removePlayChain", NSLocalizedString("preferences.toggle.removePlayChain", comment: "")),
                ("removeAppEntitlements", NSLocalizedString("preferences.toggle.removeEntitlements", comment: "")),
                ("removeAppSettings", NSLocalizedString("preferences.toggle.removeSetting", comment: "")),
                ("removeAppKeymap", NSLocalizedString("preferences.toggle.removeKeymap", comment: "")),
                ("clearAppData", NSLocalizedString("preferences.toggle.clearAppData", comment: ""))
            ]

            var checkboxes: [CheckBoxHelper] = []

            var viewY = 0.0

            for (buttonvar, buttontitle) in boxmakers {
                checkboxes.append(createButtonView(viewY, buttontitle, buttonvar))
                viewY += checkboxes[checkboxes.count - 1].view.frame.height
            }

            let viewWidth = checkboxes.max(by: { $0.view.frame.width < $1.view.frame.width })?.view.frame.width

            let settingsView = NSStackView(frame: NSRect(x: 0, y: 0, width: viewWidth ?? 0, height: viewY))

            for checkboxhelper in checkboxes {
                settingsView.addSubview(checkboxhelper.view)
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("playapp.delete", comment: "")
            alert.informativeText = String(format: NSLocalizedString("playapp.deleteMessage",
                                                                     comment: ""),
                                           arguments: [app.name])

            alert.alertStyle = .warning
            alert.accessoryView = settingsView

            let delete = alert.addButton(withTitle: NSLocalizedString("playapp.deleteConfirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "")

            delete.hasDestructiveAction = true

            NSApplication.shared.requestUserAttention(.criticalRequest)
            guard let window = NSApplication.shared.windows.first,
                  await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            for checkboxhelper in checkboxes {
                UninstallPreferences.shared.setValue(checkboxhelper.button.state == .on,
                                                     forKey: checkboxhelper.buttonvar)
            }

            if alert.suppressionButton?.state == .on {
                UninstallPreferences.shared.showUninstallPopup = false
            }

            await uninstall(app)
        } else {
            await uninstall(app)
        }
    }

    static func uninstall(_ app: PlayApp) async {
        _ = await uninstall(app, options: .fromPreferences())
    }

    static func uninstall(_ app: PlayApp, options: UninstallOptions) async -> UninstallResult {
        let bundleID = app.info.bundleIdentifier
        let appURL = app.url
        let aliasURL = app.aliasURL
        let keymapURL = app.keymapping.baseKeymapURL
        let settingsURL = app.settings.settingsUrl
        let entitlementsURL = app.entitlements
        let playChainURLs = [
            app.playChainURL,
            app.playChainURL.appendingPathExtension("keyCover"),
            app.playChainURL.appendingPathExtension("db")
        ]

        let hadAppData = !matchingExternalCacheURLs(bundleID: bundleID).isEmpty
        if options.removeAppData {
            await app.clearAllCache()
        }
        let removedAppData = options.removeAppData
            && hadAppData
            && matchingExternalCacheURLs(bundleID: bundleID).isEmpty

        let hadKeymap = FileManager.default.fileExists(atPath: keymapURL.path)
        if options.removeAppKeymap {
            FileManager.default.delete(at: keymapURL)
        }
        let removedKeymap = options.removeAppKeymap
            && hadKeymap
            && !FileManager.default.fileExists(atPath: keymapURL.path)

        let hadSettings = FileManager.default.fileExists(atPath: settingsURL.path)
        if options.removeAppSettings {
            FileManager.default.delete(at: settingsURL)
        }
        let removedSettings = options.removeAppSettings
            && hadSettings
            && !FileManager.default.fileExists(atPath: settingsURL.path)

        let hadEntitlements = FileManager.default.fileExists(atPath: entitlementsURL.path)
        if options.removeAppEntitlements {
            FileManager.default.delete(at: entitlementsURL)
        }
        let removedEntitlements = options.removeAppEntitlements
            && hadEntitlements
            && !FileManager.default.fileExists(atPath: entitlementsURL.path)

        let hadPlayChain = playChainURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
        if options.removePlayChain {
            app.clearPlayChain()
        }
        let removedPlaychain = options.removePlayChain
            && hadPlayChain
            && playChainURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }

        let hadAlias = FileManager.default.fileExists(atPath: aliasURL.path)
        let hadApp = FileManager.default.fileExists(atPath: appURL.path)
        app.removeAlias()
        app.deleteApp()

        let removedApp = hadApp && !FileManager.default.fileExists(atPath: appURL.path)
        let removedAlias = hadAlias && !FileManager.default.fileExists(atPath: aliasURL.path)
        if !removedAlias && hadAlias {
            Log.shared.log("Failed to remove alias for \(bundleID) during uninstall.")
        }

        if options.removesAllManagedArtifacts {
            removeBundleIDCacheEntry(for: bundleID)
        }

        return UninstallResult(
            bundleID: bundleID,
            removedApp: removedApp,
            removedAppData: removedAppData,
            removedSettings: removedSettings,
            removedKeymap: removedKeymap,
            removedPlaychain: removedPlaychain,
            removedEntitlements: removedEntitlements
        )
    }

    @MainActor
    static func clearCachePopup(_ app: PlayApp) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.app.delete", comment: "")
        alert.alertStyle = .warning

        let proceed = alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        proceed.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        NSApplication.shared.requestUserAttention(.criticalRequest)
        guard let window = NSApplication.shared.windows.first,
              await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        await clearCache(of: app)
    }

    static func clearCache(of app: PlayApp) async {
        await app.clearAllCache()
    }

    static func clearExternalCache(_ bundleId: String) {
        do {
            for cache in cacheURLs {
                cache.enumerateContents(options: [.skipsSubdirectoryDescendants]) { file, _ in
                    if file.path.contains(bundleId) {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                    }
                }
            }
        }
    }

    static func matchingExternalCacheURLs(bundleID: String) -> [URL] {
        cacheURLs.flatMap { cacheURL in
            guard FileManager.default.fileExists(atPath: cacheURL.path) else {
                return [URL]()
            }

            do {
                return try FileManager.default.contentsOfDirectory(
                    at: cacheURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
                .filter { $0.path.contains(bundleID) }
            } catch {
                Log.shared.error(error)
                return []
            }
        }
    }

    private static func removeBundleIDCacheEntry(for bundleID: String) {
        do {
            let apps = (try PlayApp.bundleIDCache).filter({ $0 != bundleID })
                .joined(separator: "\n") + "\n"
            try apps.write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }

    static func pruneFiles() {
        do {
            let bundleIds = AppsVM.shared.apps.map { $0.info.bundleIdentifier }
            let danglingItems = try PlayApp.bundleIDCache.filter { !bundleIds.contains($0) }

            var fullPruneURLs = pruneURLs
            fullPruneURLs.append(contentsOf: cacheURLs)

            var prunedIds: [String] = []

            for url in fullPruneURLs {
                url.enumerateContents(options: [.skipsSubdirectoryDescendants]) { file, _ in
                    let bundleId = file.deletingPathExtension().lastPathComponent
                    if danglingItems.contains(bundleId) {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                        prunedIds.append(bundleId)
                    }
                }
            }

            try "\(PlayApp.bundleIDCache.filter({ !Set(prunedIds).contains($0) }).joined(separator: "\n"))\n"
                .write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }
}
