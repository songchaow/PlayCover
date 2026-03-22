// ResourceRegistry.swift
// PlayCoverMCPCore

import Foundation

/// Registry for MCP resources. Thread-safe for single-writer.
public final class ResourceRegistry: Sendable {

    private var resources: [Resource] = []
    private let lock = NSLock()

    public init() {}

    /// Register a resource. Replaces any existing resource with the same URI.
    public func register(_ resource: Resource) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = resources.firstIndex(where: { $0.uri == resource.uri }) {
            resources[idx] = resource
        } else {
            resources.append(resource)
        }
    }

    /// Unregister a resource by URI.
    public func unregister(uri: String) {
        lock.lock()
        defer { lock.unlock() }
        resources.removeAll(where: { $0.uri == uri })
    }

    /// List all registered resources.
    public func listResources() -> [Resource] {
        lock.lock()
        defer { lock.unlock() }
        return resources
    }

    /// Find a resource by URI.
    public func find(uri: String) -> Resource? {
        lock.lock()
        defer { lock.unlock() }
        return resources.first(where: { $0.uri == uri })
    }
}
