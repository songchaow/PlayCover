//
//  PlayAppView.swift
//  PlayCover
//

import SwiftUI
import DataCache

struct PlayAppView: View {
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: PlayApp?
    @Binding var isList: Bool

    @StateObject var viewModel: PlayAppVM

    var body: some View {
        PlayAppConditionalView(selectedBackgroundColor: $selectedBackgroundColor,
                               selectedTextColor: $selectedTextColor,
                               selected: $selected,
                               showStartingProgress: $viewModel.showStartingProgress,
                               app: viewModel.app,
                               isList: isList)
            .gesture(TapGesture(count: 2).onEnded {
                // Launch the app from a separate thread (allow us to Sayori it if needed)
                Task(priority: .userInitiated) {
                    if !viewModel.app.isStarting {
                        viewModel.showStartingProgress = true
                        await viewModel.app.launch()
                        viewModel.showStartingProgress = false
                    }
                }
            })
            .simultaneousGesture(TapGesture().onEnded {
                selected = viewModel.app
            })
            .contextMenu {
                Button("playapp.settings", systemImage: "gear", action: {
                    viewModel.showSettings.toggle()
                })
                Button("playapp.openCache", systemImage: "folder", action: {
                    viewModel.app.openAppCache()
                })
                Button("playapp.showInFinder", systemImage: "finder", action: {
                    viewModel.app.showInFinder()
                })
                Divider()
                Group {
                    Button("playapp.keymap", systemImage: "keyboard", action: {
                        viewModel.showKeymapSheet.toggle()
                    })
                }
                Divider()
                Group {
                    Button("playapp.clearCache", systemImage: "clear", action: {
                        selected = nil
                        Task { await Uninstaller.clearCachePopup(viewModel.app) }
                    })
                    Button("playapp.clearPreferences", systemImage: "clear", action: {
                        viewModel.showClearPreferencesAlert.toggle()
                    })
                    Button("playapp.clearPlayChain", systemImage: "clear", action: {
                        viewModel.showClearPlayChainAlert.toggle()
                    })
                }
                Divider()
                Button("playapp.delete", systemImage: "trash", action: {
                    selected = nil
                    Task { await Uninstaller.uninstallPopup(viewModel.app) }
                })
            }
            .alert("alert.app.preferences", isPresented: $viewModel.showClearPreferencesAlert) {
                Button("button.Proceed", role: .destructive) {
                    deletePreferences(app: viewModel.app.info.bundleIdentifier)
                    viewModel.showClearPreferencesAlert.toggle()
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .alert("alert.app.clearPlayChain", isPresented: $viewModel.showClearPlayChainAlert) {
                Button("button.Proceed", role: .destructive) {
                    viewModel.app.clearPlayChain()
                    viewModel.showClearPlayChainAlert.toggle()
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                AppSettingsView(viewModel: AppSettingsVM(app: viewModel.app),
                                showKeymapSheet: $viewModel.showKeymapSheet)
            }
            .sheet(isPresented: $viewModel.showKeymapSheet) {
                KeymapView(showKeymapSheet: $viewModel.showKeymapSheet, viewModel: KeymapViewVM(app: viewModel.app))
            }
    }

    func deletePreferences(app: String) {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingEscapedPathComponent(app)
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingEscapedPathComponent(app)
            .appendingPathExtension("plist")

        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }

        do {
            try FileManager.default.removeItem(atPath: plistURL.path)
        } catch {
            Log.shared.log("\(error)", isError: true)
        }
    }
}

struct PlayAppConditionalView: View {
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: PlayApp?
    @Binding var showStartingProgress: Bool

    @State var app: PlayApp
    @State var appIcon: NSImage?
    @State var isList: Bool
    @State var hasPlayTools: Bool?

    @State private var cache = DataCache.instance
    @ObservedObject private var mcpManager = MCPManager.shared

    /// Active session snapshots for this app's bundleId.
    private var appSessions: [MCPManager.RuntimeSessionSnapshot] {
        mcpManager.sessions(for: app.info.bundleIdentifier)
    }

    /// The "best" status to display: prefer ready > starting > disconnected.
    private var sessionIndicatorStatus: String? {
        let sessions = appSessions
        guard !sessions.isEmpty else { return nil }
        if sessions.contains(where: { $0.status == "ready" }) { return "ready" }
        if sessions.contains(where: { $0.status == "starting" }) { return "starting" }
        if sessions.contains(where: { $0.status == "disconnected" }) { return "disconnected" }
        return nil
    }

    /// Whether the capture button should be shown (has ready session).
    private var canCapture: Bool {
        mcpManager.canCapture(bundleId: app.info.bundleIdentifier)
    }

    /// Whether a capture is in progress for this app.
    private var isCapturing: Bool {
        mcpManager.isCapturing(bundleId: app.info.bundleIdentifier)
    }

    var body: some View {
        Group {
            if isList {
                HStack(alignment: .center, spacing: 0) {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                                 .fill(.regularMaterial)
                                 .overlay {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                         .controlSize(.small)
                                 }
                        }
                    }
                    .frame(width: 30, height: 30)
                    .cornerRadius(7.5)
                    .shadow(radius: 1)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 5)

                    Text(app.name)
                        .foregroundColor(selected?.url == app.url ?
                                         selectedTextColor : Color.primary)
                    if !(hasPlayTools ?? true) {
                        Image(systemName: "exclamationmark.triangle")
                            .padding(.leading, 15)
                            .help("settings.noPlayTools")
                    }
                    if showStartingProgress {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 30, height: 30)
                    }
                    Spacer()
                    if let status = sessionIndicatorStatus {
                        SessionIndicatorView(status: status, sessionCount: appSessions.count)
                            .padding(.trailing, 8)
                    }
                    if sessionIndicatorStatus == "ready" {
                        CaptureButton(
                            bundleId: app.info.bundleIdentifier,
                            canCapture: canCapture,
                            isCapturing: isCapturing
                        )
                        .padding(.trailing, 4)
                    }
                    Text(app.settings.info.bundleVersion)
                        .padding(.horizontal, 15)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected?.url == app.url ?
                            selectedBackgroundColor : Color.clear)
                        .brightness(-0.2)
                    )
            } else {
                LazyVStack {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                                 .fill(.regularMaterial)
                                 .overlay {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                 }
                        }
                    }
                    .cornerRadius(15)
                    .shadow(radius: 1)
                    .frame(width: 60, height: 60)
                    .overlay(alignment: .topTrailing) {
                        if let status = sessionIndicatorStatus {
                            SessionDotView(status: status)
                                .offset(x: 4, y: -4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if sessionIndicatorStatus == "ready" {
                            CaptureButton(
                                bundleId: app.info.bundleIdentifier,
                                canCapture: canCapture,
                                isCapturing: isCapturing,
                                compact: true
                            )
                            .offset(x: 4, y: 4)
                        }
                    }

                    let noPlayToolsWarning = Text(
                        (hasPlayTools ?? true) ? "" : "\(Image(systemName: "exclamationmark.triangle"))  "
                    )
                    HStack {
                        Text("\(noPlayToolsWarning)\(app.name)")
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .foregroundColor(selected?.url == app.url ?
                                             selectedTextColor : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selected?.url == app.url ?
                                          selectedBackgroundColor : Color.clear)
                                    .brightness(-0.2)
                            )
                            .help(!(hasPlayTools ?? true) ? "settings.noPlayTools" : "")
                            .frame(height: 20)
                        if showStartingProgress {
                            ProgressView()
                                .padding(.leading, 10)
                                .scaleEffect(0.5)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
                .frame(width: 130, height: 130)
            }
        }
        .task(priority: .userInitiated) {
            let compareStr = app.info.bundleIdentifier + app.info.bundleVersion
            if cache.readImage(forKey: app.info.bundleIdentifier) != nil
                && cache.readString(forKey: compareStr) != nil {
                appIcon = cache.readImage(forKey: app.info.bundleIdentifier)
            } else {
                appIcon = Cacher.shared.resolveLocalIcon(app)
            }
        }
        .task(priority: .background) {
            hasPlayTools = app.hasPlayTools()
            showStartingProgress = app.isStarting
        }
    }
}

// MARK: - Session Status Indicators

/// Color mapping for session status.
private func sessionStatusColor(_ status: String) -> Color {
    switch status {
    case "ready": return .green
    case "starting": return .orange
    case "disconnected": return .red
    default: return .gray
    }
}

/// Localized label for session status.
private func sessionStatusLabel(_ status: String) -> String {
    switch status {
    case "ready": return NSLocalizedString("session.status.ready", comment: "Session connected")
    case "starting": return NSLocalizedString("session.status.starting", comment: "Session starting")
    case "disconnected": return NSLocalizedString("session.status.disconnected", comment: "Session disconnected")
    default: return status
    }
}

/// Inline session status indicator for list mode.
/// Shows a colored dot + label + optional session count badge.
struct SessionIndicatorView: View {
    let status: String
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sessionStatusColor(status))
                .frame(width: 8, height: 8)
            Text(sessionStatusLabel(status))
                .font(.caption)
                .foregroundColor(.secondary)
            if sessionCount > 1 {
                Text("×\(sessionCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .help(sessionStatusTooltip(status: status, count: sessionCount))
    }

    private func sessionStatusTooltip(status: String, count: Int) -> String {
        let label = sessionStatusLabel(status)
        if count > 1 {
            return "\(count) sessions (\(label))"
        }
        return "MCP Session: \(label)"
    }
}

/// Small colored dot overlay for grid mode app icons.
struct SessionDotView: View {
    let status: String

    var body: some View {
        Circle()
            .fill(sessionStatusColor(status))
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(Color(.windowBackgroundColor), lineWidth: 1.5)
            )
            .help("MCP Session: \(sessionStatusLabel(status))")
    }
}

// MARK: - Metal Capture Button

/// Button to trigger Metal GPU frame capture for a running app.
/// Shows in both list and grid modes when a ready session exists.
struct CaptureButton: View {
    let bundleId: String
    let canCapture: Bool
    let isCapturing: Bool
    var compact: Bool = false

    @State private var captureResultMessage: String?
    @State private var showCaptureResult = false
    @State private var captureSucceeded = false

    var body: some View {
        Button {
            guard canCapture else { return }
            Task {
                let result = await MCPManager.shared.captureFrame(bundleId: bundleId)
                await MainActor.run {
                    switch result {
                    case .success(let path):
                        captureSucceeded = true
                        captureResultMessage = path
                        showCaptureResult = true
                    case .failure(let message):
                        captureSucceeded = false
                        captureResultMessage = message
                        showCaptureResult = true
                    }
                }
            }
        } label: {
            if isCapturing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: compact ? 20 : nil, height: compact ? 20 : nil)
            } else if compact {
                Image(systemName: "camera.viewfinder")
                    .font(.callout)
                    .imageScale(.large)
                    .foregroundColor(canCapture ? .accentColor : .secondary)
            } else {
                Label(
                    NSLocalizedString("capture.button", comment: "Capture button label"),
                    systemImage: "camera.viewfinder"
                )
                .font(.caption)
                .foregroundColor(canCapture ? .accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(canCapture ? Color.accentColor : Color.secondary, lineWidth: 1)
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canCapture)
        .help(captureTooltip)
        .alert(
            captureSucceeded
                ? NSLocalizedString("capture.success.title", comment: "Capture succeeded")
                : NSLocalizedString("capture.failure.title", comment: "Capture failed"),
            isPresented: $showCaptureResult
        ) {
            if captureSucceeded, let path = captureResultMessage {
                Button(NSLocalizedString("capture.revealInFinder", comment: "Show in Finder")) {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
                Button(NSLocalizedString("button.OK", comment: ""), role: .cancel) {}
            } else {
                Button(NSLocalizedString("button.OK", comment: ""), role: .cancel) {}
            }
        } message: {
            if let msg = captureResultMessage {
                Text(msg)
            }
        }
    }

    private var captureTooltip: String {
        if isCapturing {
            return NSLocalizedString("capture.inProgress", comment: "Capture in progress")
        }
        if canCapture {
            return NSLocalizedString("capture.tooltip", comment: "Capture Metal frame")
        }
        return NSLocalizedString("capture.unavailable", comment: "No ready session")
    }
}
