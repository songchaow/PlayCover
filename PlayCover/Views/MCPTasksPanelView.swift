//
//  MCPTasksPanelView.swift
//  PlayCover
//
//  Collapsible panel showing MCP background task status.
//  Displayed at the bottom of the main window.
//

import SwiftUI

struct MCPTasksPanelView: View {
    @ObservedObject var mcpManager = MCPManager.shared

    var body: some View {
        if !mcpManager.activeTasks.isEmpty {
            VStack(spacing: 0) {
                Divider()
                taskHeader
                if mcpManager.isTasksPanelExpanded {
                    taskList
                }
            }
            .background(.regularMaterial)
            .animation(.easeInOut(duration: 0.2), value: mcpManager.isTasksPanelExpanded)
            .animation(.easeInOut(duration: 0.2), value: mcpManager.activeTasks.count)
        }
    }

    // MARK: - Header

    private var taskHeader: some View {
        Button {
            withAnimation {
                mcpManager.isTasksPanelExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mcpManager.isTasksPanelExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 12)

                Image(systemName: "gearshape.2")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Tasks")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if mcpManager.activeTaskCount > 0 {
                    Text("\(mcpManager.activeTaskCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }

                Spacer()

                if mcpManager.hasActiveTasks {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                Button {
                    withAnimation {
                        mcpManager.activeTasks.removeAll()
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear completed tasks")
                .disabled(mcpManager.hasActiveTasks)
                .opacity(mcpManager.activeTasks.contains(where: { $0.isTerminal }) ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(mcpManager.activeTasks) { task in
                    TaskRowView(task: task)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 200)
    }
}

// MARK: - Task Row

struct TaskRowView: View {
    let task: MCPManager.TaskSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.stateIcon)
                .font(.caption)
                .foregroundColor(iconColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.displayTitle)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if task.state == "running" {
                    if let fraction = task.progressFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                    }
                } else if task.state == "failed", let error = task.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if task.state == "completed" {
                    Text("Completed")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else if task.state == "cancelled" {
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if task.state == "pending" {
                    Text("Pending...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if task.state == "running", let fraction = task.progressFraction {
                Text("\(Int(fraction * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            if !task.isTerminal {
                Button {
                    MCPManager.shared.cancelTask(task.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel task")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(task.isTerminal ? Color.clear : Color.accentColor.opacity(0.05))
        )
    }

    private var iconColor: Color {
        switch task.stateColor {
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        default: return .gray
        }
    }
}
