//
//  MCPStatusView.swift
//  PlayCover
//
//  Displays MCP Server status in the Settings window.
//  Allows configuring the MCP Server port and listen address.
//

import SwiftUI

struct MCPStatusView: View {
    @ObservedObject var mcpManager = MCPManager.shared

    @State private var portString: String = ""
    @State private var selectedHost: TCPTransport.ListenHost = .loopback
    @State private var portError: String?
    @State private var isRestarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }

            if mcpManager.isRunning {
                HStack {
                    Label {
                        Text("\(mcpManager.listenHost.rawValue):\(mcpManager.port)")
                    } icon: {
                        Image(systemName: "network")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Label {
                        Text("\(mcpManager.connectedClients)")
                    } icon: {
                        Image(systemName: "person.2")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Text(listenAddressDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let error = mcpManager.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Listen address configuration
            HStack {
                Text(NSLocalizedString("mcp.host.label", comment: ""))
                    .font(.subheadline)
                Picker("", selection: $selectedHost) {
                    Text("127.0.0.1 (\(NSLocalizedString("mcp.host.loopback", comment: "")))")
                        .tag(TCPTransport.ListenHost.loopback)
                    Text("0.0.0.0 (\(NSLocalizedString("mcp.host.all", comment: "")))")
                        .tag(TCPTransport.ListenHost.allInterfaces)
                }
                .labelsHidden()
                .frame(width: 280)
                Spacer()
            }

            if selectedHost == .allInterfaces {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(NSLocalizedString("mcp.host.warning", comment: ""))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Port configuration
            HStack {
                Text(NSLocalizedString("mcp.port.label", comment: ""))
                    .font(.subheadline)
                TextField(
                    "\(MCPManager.defaultPort)",
                    text: $portString
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onChange(of: portString) { _ in
                    validatePort()
                }

                Button(action: applySettings) {
                    if isRestarting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 12, height: 12)
                    } else {
                        Text(NSLocalizedString("mcp.port.apply", comment: ""))
                    }
                }
                .disabled(!canApply)

                Button(action: resetSettings) {
                    Text(NSLocalizedString("mcp.port.reset", comment: ""))
                }
                .disabled(isDefault)

                Spacer()
            }

            if let portError = portError {
                Text(portError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text(NSLocalizedString("mcp.port.hint", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 280)
        .onAppear {
            portString = "\(mcpManager.savedPort)"
            selectedHost = mcpManager.savedHost
        }
    }

    // MARK: - Computed Properties

    private var listenAddressDisplay: String {
        if mcpManager.listenHost == .loopback {
            return "localhost:\(mcpManager.port)"
        } else {
            return "\(mcpManager.listenHost.rawValue):\(mcpManager.port)"
        }
    }

    private var statusColor: Color {
        if mcpManager.isRunning {
            return .green
        } else if mcpManager.lastError != nil {
            return .red
        } else {
            return .gray
        }
    }

    private var statusText: String {
        if mcpManager.isRunning {
            return NSLocalizedString("mcp.status.running", comment: "")
        } else if mcpManager.lastError != nil {
            return NSLocalizedString("mcp.status.error", comment: "")
        } else {
            return NSLocalizedString("mcp.status.stopped", comment: "")
        }
    }

    private var parsedPort: UInt16? {
        guard let value = UInt16(portString) else { return nil }
        return MCPManager.isValidPort(value) ? value : nil
    }

    /// Whether current UI settings differ from the running server config
    private var hasChanges: Bool {
        guard let newPort = parsedPort else { return false }
        return newPort != mcpManager.port || selectedHost != mcpManager.listenHost
    }

    private var canApply: Bool {
        return hasChanges && !isRestarting && portError == nil
    }

    /// Whether current UI settings are at default values
    private var isDefault: Bool {
        return portString == "\(MCPManager.defaultPort)"
            && selectedHost == MCPManager.defaultHost
            && mcpManager.savedPort == MCPManager.defaultPort
            && mcpManager.savedHost == MCPManager.defaultHost
    }

    // MARK: - Actions

    private func validatePort() {
        portError = nil

        let trimmed = portString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        guard let value = UInt16(trimmed) else {
            portError = NSLocalizedString("mcp.port.error.invalid", comment: "")
            return
        }

        if !MCPManager.isValidPort(value) {
            portError = NSLocalizedString("mcp.port.error.range", comment: "")
        }
    }

    private func applySettings() {
        guard let newPort = parsedPort else { return }

        isRestarting = true
        mcpManager.restart(withPort: newPort, host: selectedHost)

        // Brief delay to show restart feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isRestarting = false
        }
    }

    private func resetSettings() {
        portString = "\(MCPManager.defaultPort)"
        selectedHost = MCPManager.defaultHost
        portError = nil

        let needsRestart = mcpManager.port != MCPManager.defaultPort
            || mcpManager.listenHost != MCPManager.defaultHost
            || mcpManager.savedPort != MCPManager.defaultPort
            || mcpManager.savedHost != MCPManager.defaultHost

        if needsRestart {
            isRestarting = true
            mcpManager.restart(withPort: MCPManager.defaultPort, host: MCPManager.defaultHost)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isRestarting = false
            }
        }
    }
}
