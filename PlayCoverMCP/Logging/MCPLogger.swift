// MCPLogger.swift
// PlayCoverMCP

import Foundation

// MARK: - Logging Level

/// MCP logging severity levels, matching the MCP specification.
public enum LogLevel: String, Codable, Equatable, Sendable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    /// Numeric priority for filtering (lower = more severe).
    public var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        }
    }
}

// MARK: - Log Entry

/// A single structured log entry.
public struct LogEntry: Codable, Equatable, Sendable {
    public let level: LogLevel
    public let message: String
    public let timestamp: Date
    public let logger: String?

    public init(level: LogLevel, message: String, logger: String? = nil, timestamp: Date = Date()) {
        self.level = level
        self.message = message
        self.logger = logger
        self.timestamp = timestamp
    }
}

// MARK: - MCP Logging Types

/// Parameters for `logging/setLevel` request.
public struct SetLoggingLevelParams: Codable, Equatable, Sendable {
    public let level: LogLevel

    public init(level: LogLevel) {
        self.level = level
    }
}

/// Parameters for `notifications/message` (client -> server logging messages).
/// We also use this for server -> client log notifications.
public struct LoggingMessageParams: Codable, Equatable, Sendable {
    public let level: LogLevel
    public let data: String?
    public let logger: String?

    public init(level: LogLevel, data: String? = nil, logger: String? = nil) {
        self.level = level
        self.data = data
        self.logger = logger
    }
}

// MARK: - MCPLogger

/// Centralized logging adapter for the MCP server.
///
/// Supports:
/// - Minimum log level filtering
/// - In-memory log buffer with configurable capacity
/// - Callback for forwarding log messages to MCP clients via notifications
/// - Structured log entry creation
///
/// Usage:
/// ```swift
/// let logger = MCPLogger(minLevel: .info)
/// logger.info("Server started")
/// logger.log(.warning, "Low disk space", logger: "disk-manager")
/// ```
public final class MCPLogger {

    // MARK: - Public

    /// The current minimum log level. Messages below this level are discarded.
    public private(set) var minLevel: LogLevel

    /// Callback invoked when a log entry passes the level filter.
    /// The MCPServer can wire this to send `notifications/message` to the client.
    public var onLog: ((LogEntry) -> Void)?

    // MARK: - Private

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private let maxBufferSize: Int

    // MARK: - Init

    /// Create a logger with a minimum level and optional buffer size.
    ///
    /// - Parameters:
    ///   - minLevel: Minimum severity to emit. Default: `.info`.
    ///   - maxBufferSize: Maximum number of log entries to keep in the buffer. Default: 256.
    public init(minLevel: LogLevel = .info, maxBufferSize: Int = 256) {
        self.minLevel = minLevel
        self.maxBufferSize = maxBufferSize
    }

    // MARK: - Level Management

    /// Set the minimum log level, as requested by `logging/setLevel`.
    public func setMinLevel(_ level: LogLevel) {
        lock.lock()
        minLevel = level
        lock.unlock()
    }

    // MARK: - Structured Logging

    /// Emit a log entry if it meets the minimum level threshold.
    public func log(_ level: LogLevel, _ message: String, logger: String? = nil) {
        guard level.priority >= minLevel.priority else { return }

        let entry = LogEntry(level: level, message: message, logger: logger)

        lock.lock()
        buffer.append(entry)
        if buffer.count > maxBufferSize {
            buffer.removeFirst(buffer.count - maxBufferSize)
        }
        lock.unlock()

        onLog?(entry)
    }

    // MARK: - Convenience Methods

    public func debug(_ message: String, logger: String? = nil) {
        log(.debug, message, logger: logger)
    }

    public func info(_ message: String, logger: String? = nil) {
        log(.info, message, logger: logger)
    }

    public func notice(_ message: String, logger: String? = nil) {
        log(.notice, message, logger: logger)
    }

    public func warning(_ message: String, logger: String? = nil) {
        log(.warning, message, logger: logger)
    }

    public func error(_ message: String, logger: String? = nil) {
        log(.error, message, logger: logger)
    }

    public func critical(_ message: String, logger: String? = nil) {
        log(.critical, message, logger: logger)
    }

    // MARK: - Buffer Access

    /// Retrieve all buffered log entries, optionally filtered by minimum level.
    public func getEntries(minLevel: LogLevel? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let min = minLevel {
            return buffer.filter { $0.level.priority >= min.priority }
        }
        return Array(buffer)
    }

    /// Clear the log buffer.
    public func clearBuffer() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    /// Current number of entries in the buffer.
    public var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }
}
