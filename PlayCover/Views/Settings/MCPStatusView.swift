//
//  MCPStatusView.swift
//  PlayCover
//
//  Displays MCP Server status in the Settings window.
//  Allows configuring the MCP Server transport, port, and listen address.
//

import AppKit
import SwiftUI

struct MCPStatusView: View {
    @ObservedObject var mcpManager = MCPManager.shared

    @State private var portString: String = ""
    @State private var selectedHost: TCPTransport.ListenHost = .loopback
    @State private var selectedTransportType: MCPManager.TransportType = MCPManager.defaultTransportType
    @State private var portError: String?
    @State private var isRestarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("mcp.endpoint.label", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(endpointDisplay)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button(action: copyEndpoint) {
                        Text(NSLocalizedString("mcp.endpoint.copy", comment: ""))
                    }
                }

                HStack {
                    Label {
                        Text("\(connectionCountLabel): \(mcpManager.connectedClients)")
                    } icon: {
                        Image(systemName: "person.2")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
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

            HStack {
                Text(NSLocalizedString("mcp.transport.label", comment: ""))
                    .font(.subheadline)
                Picker("", selection: $selectedTransportType) {
                    Text(NSLocalizedString("mcp.transport.http", comment: ""))
                        .tag(MCPManager.TransportType.http)
                    Text(NSLocalizedString("mcp.transport.tcp", comment: ""))
                        .tag(MCPManager.TransportType.tcp)
                }
                .labelsHidden()
                .frame(width: 280)
                Spacer()
            }

            if !mcpManager.isHTTPTransportSupported && selectedTransportType == .http {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(NSLocalizedString("mcp.transport.http.unsupported", comment: ""))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

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
        .frame(width: 600, height: 340)
        .onAppear {
            portString = "\(mcpManager.savedPort)"
            selectedHost = mcpManager.savedHost
            selectedTransportType = mcpManager.savedTransportType

            if !mcpManager.isHTTPTransportSupported && selectedTransportType == .http {
                selectedTransportType = .tcp
            }
        }
    }

    // MARK: - Computed Properties

    private var endpointDisplay: String {
        switch selectedTransportType {
        case .http:
            return "http://127.0.0.1:\(displayPort)/mcp"
        case .tcp:
            return "tcp://127.0.0.1:\(displayPort)"
        }
    }

    private var listenAddressDisplay: String {
        "\(selectedHost.rawValue):\(displayPort)"
    }

    private var displayPort: UInt16 {
        parsedPort ?? mcpManager.port
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

    private var connectionCountLabel: String {
        let key = mcpManager.effectiveTransportType == .http ? "mcp.sessions.label" : "mcp.clients.label"
        return NSLocalizedString(key, comment: "")
    }

    private var parsedPort: UInt16? {
        let trimmed = portString.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed) else { return nil }
        return MCPManager.isValidPort(value) ? value : nil
    }

    private var hasChanges: Bool {
        guard let newPort = parsedPort else { return false }
        return newPort != mcpManager.port
            || selectedHost != mcpManager.listenHost
            || selectedTransportType != mcpManager.transportType
    }

    private var canApply: Bool {
        hasChanges && !isRestarting && portError == nil
    }

    private var isDefault: Bool {
        let defaultTransportType = mcpManager.runtimeDefaultTransportType
        return portString == "\(MCPManager.defaultPort)"
            && selectedHost == MCPManager.defaultHost
            && selectedTransportType == defaultTransportType
            && mcpManager.savedPort == MCPManager.defaultPort
            && mcpManager.savedHost == MCPManager.defaultHost
            && mcpManager.savedTransportType == defaultTransportType
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
        mcpManager.restart(withPort: newPort, host: selectedHost, transportType: selectedTransportType)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isRestarting = false
        }
    }

    private func resetSettings() {
        let defaultTransportType = mcpManager.runtimeDefaultTransportType
        portString = "\(MCPManager.defaultPort)"
        selectedHost = MCPManager.defaultHost
        selectedTransportType = defaultTransportType
        portError = nil

        let needsRestart = mcpManager.port != MCPManager.defaultPort
            || mcpManager.listenHost != MCPManager.defaultHost
            || mcpManager.transportType != defaultTransportType
            || mcpManager.savedPort != MCPManager.defaultPort
            || mcpManager.savedHost != MCPManager.defaultHost
            || mcpManager.savedTransportType != defaultTransportType

        if needsRestart {
            isRestarting = true
            mcpManager.restart(
                withPort: MCPManager.defaultPort,
                host: MCPManager.defaultHost,
                transportType: defaultTransportType
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isRestarting = false
            }
        }
    }

    private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointDisplay, forType: .string)
    }
}
