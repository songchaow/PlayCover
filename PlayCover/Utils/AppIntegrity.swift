//
//  AppIntegrity.swift
//  PlayCover
//

import Foundation

class AppIntegrity: ObservableObject {

    @Published var integrityOff: Bool = !AppIntegrity.insideAppsFolder

    func verifyAppIntegrity() {
        integrityOff = !AppIntegrity.insideAppsFolder
    }

    func moveToApps() {
        guard let sourceURL = AppIntegrity.appUrl else {
            return
        }

        for destinationURL in AppIntegrity.installDestinations {
            do {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                destinationURL.openInFinder()
                FileManager.default.delete(at: sourceURL)
                exit(0)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    private static var appUrl: URL? {
        Bundle.main.resourceURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static var installDestinations: [URL] {
        [
            URL(fileURLWithPath: "/Applications/PlayCover.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("PlayCover.app", isDirectory: true)
        ]
    }

    private static var insideAppsFolder: Bool {
        guard let url = appUrl else {
            return false
        }

        return url.path.contains("Xcode") || installDestinations.contains { destination in
            url.standardizedFileURL.path == destination.standardizedFileURL.path
        }
    }

}
