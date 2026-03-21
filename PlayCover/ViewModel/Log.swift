//
//  Logger.swift
//  PlayCover
//

import Foundation
import SwiftUI

class Log: ObservableObject {

    static let shared = Log()
    private static let bootHeader = "\(ProcessInfo.processInfo.operatingSystemVersionString)\n"

    func error(_ err: Error) {
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: err.localizedDescription,
                style: NSAlert.Style.critical)
        }
    }

    func error(localized str: String, args: [String] = []) {
        error(String(format: NSLocalizedString(str, comment: ""), arguments: args))
    }

    func msg(_ msg: String) {
        Task { @MainActor in
            self.log(msg)
            self.dialog(
                question: NSLocalizedString("alert.success", comment: ""),
                text: msg,
                style: NSAlert.Style.informational)
        }
    }

    private(set) var logdata = Log.bootHeader

    func log(_ str: String, isError: Bool = false) {
        print(str)
        if isError {
            logdata.append("ERROR: ")
        }
        logdata.append(str)
        logdata.append("\n")
    }

    @MainActor
    func read(tailLines: Int? = nil, tailCharacters: Int? = nil) -> String {
        var output = logdata

        if let tailLines {
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            output = lines.suffix(tailLines).joined(separator: "\n")
        }

        if let tailCharacters {
            output = String(output.suffix(tailCharacters))
        }

        return output
    }

    @discardableResult
    @MainActor
    func clear(retainSystemHeader: Bool = false) -> Int {
        let removedCharacterCount = logdata.count
        logdata = retainSystemHeader ? Log.bootHeader : ""
        return removedCharacterCount
    }

    private func dialog(question: String, text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
        alert.runModal()
    }

    required init() { }
}
