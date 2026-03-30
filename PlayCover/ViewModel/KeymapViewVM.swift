//
//  KeymapViewVM.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 6/20/25.
//

import SwiftUI
import DataCache

class KeymapViewVM: ObservableObject {

    public let app: PlayApp
    public let cache = DataCache.instance

    private var keymapsChangedObserver: NSObjectProtocol?

    @Published var selectedKeymap: URL?
    @Published var kmName = ""

    @Published var defaultKm: URL

    @Published var showKeymapImport = false
    @Published var showKeymapRename = false
    @Published var showCreateKeymap = false

    @Published var appIcon: NSImage?

    @Published var keymapURLS: [URL] = [] {
        didSet {
            app.keymapping.keymapConfig.keymapOrder = keymapURLS
        }
    }

    init(app: PlayApp) {
        self.app = app

        self.defaultKm = app.keymapping.keymapConfig.defaultKm

        self.reloadKeymapCache()
        self.keymapsChangedObserver = NotificationCenter.default.addObserver(
            forName: .mcpKeymapsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            if let bundleID = notification.userInfo?["bundleID"] as? String,
               bundleID != self.app.info.bundleIdentifier {
                return
            }

            self.reloadKeymapCache()
        }
    }

    deinit {
        if let keymapsChangedObserver {
            NotificationCenter.default.removeObserver(keymapsChangedObserver)
        }
    }

    func reloadKeymapCache() {
        app.keymapping.reloadKeymapCache()

        keymapURLS = app.keymapping.keymapConfig.keymapOrder
        defaultKm = app.keymapping.keymapConfig.defaultKm
    }

    func setDefaultKeymap(keymap: URL) {
        app.keymapping.keymapConfig.defaultKm = keymap
        defaultKm = keymap
    }

}
