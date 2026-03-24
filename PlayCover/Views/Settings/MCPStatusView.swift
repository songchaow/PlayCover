//
//  MCPStatusView.swift
//  PlayCover
//
//  Displays MCP Server status in the Settings window.
//

import SwiftUI

struct MCPStatusView: View {
    @ObservedObject var mcpManager = MCPManager.shared

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

            if mcpManager.isRunning {
                HStack {
                    Label {
                        Text("Port: \(mcpManager.port)")
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

                Text("localhost:\(mcpManager.port)")
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
        }
        .padding(20)
        .frame(width: 600, height: 160)
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
}
