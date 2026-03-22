// ToolRegistry.swift
// PlayCoverMCPCore

import Foundation

/// Registry for MCP tools. Thread-safe for single-writer (the server init path).
public final class ToolRegistry: Sendable {

    private var tools: [Tool] = []
    private let lock = NSLock()

    public init() {}

    /// Register a tool. Replaces any existing tool with the same name.
    public func register(_ tool: Tool) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = tools.firstIndex(where: { $0.name == tool.name }) {
            tools[idx] = tool
        } else {
            tools.append(tool)
        }
    }

    /// Unregister a tool by name.
    public func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        tools.removeAll(where: { $0.name == name })
    }

    /// List all registered tools.
    public func listTools() -> [Tool] {
        lock.lock()
        defer { lock.unlock() }
        return tools
    }

    /// Find a tool by name.
    public func find(name: String) -> Tool? {
        lock.lock()
        defer { lock.unlock() }
        return tools.first(where: { $0.name == name })
    }
}
