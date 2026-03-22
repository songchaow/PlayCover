// TaskManager.swift
// PlayCoverMCP

import Foundation

// MARK: - Task State

/// Represents the lifecycle state of a background task.
public enum TaskState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled

    /// Terminal states that cannot transition further.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Task Result

/// The structured result of a completed (or failed) task.
public struct TaskResult: Codable, Equatable, Sendable {
    public let content: [TaskContentItem]

    public init(content: [TaskContentItem] = []) {
        self.content = content
    }
}

/// A single content item within a task result, following MCP task result schema.
public struct TaskContentItem: Codable, Equatable, Sendable {
    public let kind: ContentKind
    public let text: String?

    public init(kind: ContentKind, text: String? = nil) {
        self.kind = kind
        self.text = text
    }
}

/// Content type classification for task result items.
public enum ContentKind: String, Codable, Equatable, Sendable {
    case text
    case image
    case resource
}

// MARK: - Task Progress

/// Progress information that can be updated during task execution.
public struct TaskProgress: Codable, Equatable, Sendable {
    public let total: Int?
    public let current: Int?
    public let message: String?

    public init(total: Int? = nil, current: Int? = nil, message: String? = nil) {
        self.total = total
        self.current = current
        self.message = message
    }

    /// Approximate progress as a 0.0–1.0 fraction, or nil if indeterminate.
    public var fraction: Double? {
        guard let total = total, let current = current, total > 0 else { return nil }
        return min(Double(current) / Double(total), 1.0)
    }
}

// MARK: - Task Status (full snapshot)

/// Full status snapshot for a task, used in `tasks/get` responses and notifications.
public struct TaskStatus: Codable, Equatable, Sendable {
    public let id: String
    public let state: TaskState
    public let progress: TaskProgress?
    public let result: TaskResult?
    public let error: TaskError?

    public init(id: String, state: TaskState, progress: TaskProgress? = nil,
                result: TaskResult? = nil, error: TaskError? = nil) {
        self.id = id
        self.state = state
        self.progress = progress
        self.result = result
        self.error = error
    }
}

// MARK: - Task Error

/// Structured error for failed tasks.
public struct TaskError: Error, Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - MCP Task Protocol Types

/// Request parameters for `tasks/create`.
public struct CreateTaskParams: Codable, Equatable, Sendable {
    /// Unique identifier for the task (client-provided or auto-generated).
    public let id: String?
    /// Human-readable description of the task.
    public let title: String?
    /// Tool reference to execute (not used for simple tasks).
    public let tool: String?

    public init(id: String? = nil, title: String? = nil, tool: String? = nil) {
        self.id = id
        self.title = title
        self.tool = tool
    }
}

/// Result of `tasks/create`.
public struct CreateTaskResult: Codable, Equatable, Sendable {
    public let id: String
    public let status: TaskStatus

    public init(id: String, status: TaskStatus) {
        self.id = id
        self.status = status
    }
}

/// Result of `tasks/get`.
public struct GetTaskResult: Codable, Equatable, Sendable {
    public let status: TaskStatus

    public init(status: TaskStatus) {
        self.status = status
    }
}

/// Result of `tasks/list`.
public struct ListTasksResult: Codable, Equatable, Sendable {
    public let tasks: [TaskStatus]
    public let nextCursor: String?

    public init(tasks: [TaskStatus], nextCursor: String? = nil) {
        self.tasks = tasks
        self.nextCursor = nextCursor
    }
}

// MARK: - Task Manager

/// In-process task registry for tracking background tasks.
///
/// Thread-safe. Designed for single-process MCP server usage.
/// Subsequent tool implementations (install_ipa, export_patched_ipa, resign_app, inject_playtools)
/// should use this to manage long-running operations.
public final class TaskManager {

    public typealias ProgressCallback = @Sendable (String, TaskStatus) -> Void

    // MARK: - Public State

    /// Callback invoked whenever a task's status changes.
    public var onStatusChange: ProgressCallback?

    // MARK: - Private

    private var tasks: [String: TaskStatus] = [:]
    private let lock = NSLock()
    private var idCounter: UInt64 = 0

    // MARK: - Init

    public init() {}

    // MARK: - Task Lifecycle

    /// Create a new task with the given parameters.
    /// Returns the assigned task ID and initial status.
    @discardableResult
    public func createTask(id: String? = nil, title: String? = nil, tool: String? = nil) -> CreateTaskResult {
        let taskId = id ?? generateId()
        let status = TaskStatus(id: taskId, state: .pending)

        lock.lock()
        tasks[taskId] = status
        lock.unlock()

        return CreateTaskResult(id: taskId, status: status)
    }

    /// Transition a task to `running`. No-op if already running.
    public func startTask(_ taskId: String) {
        updateTask(taskId) { status in
            guard status.state == .pending else { return status }
            return TaskStatus(id: taskId, state: .running)
        }
    }

    /// Update progress for a running task.
    public func updateProgress(_ taskId: String, progress: TaskProgress) {
        updateTask(taskId) { status in
            guard status.state == .running else { return status }
            return TaskStatus(id: taskId, state: .running, progress: progress)
        }
    }

    /// Transition a task to `completed` with the given result.
    public func completeTask(_ taskId: String, result: TaskResult) {
        updateTask(taskId) { status in
            guard !status.state.isTerminal else { return status }
            return TaskStatus(id: taskId, state: .completed, result: result)
        }
    }

    /// Transition a task to `failed` with the given error.
    public func failTask(_ taskId: String, error: TaskError) {
        updateTask(taskId) { status in
            guard !status.state.isTerminal else { return status }
            return TaskStatus(id: taskId, state: .failed, error: error)
        }
    }

    /// Transition a task to `cancelled`.
    public func cancelTask(_ taskId: String) {
        updateTask(taskId) { status in
            guard !status.state.isTerminal else { return status }
            return TaskStatus(id: taskId, state: .cancelled)
        }
    }

    /// Get the current status of a task, or nil if not found.
    public func getTask(_ taskId: String) -> TaskStatus? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]
    }

    /// List all tasks, optionally filtered to non-terminal states.
    public func listTasks(includeCompleted: Bool = false) -> [TaskStatus] {
        lock.lock()
        defer { lock.unlock() }
        if includeCompleted {
            return Array(tasks.values)
        }
        return tasks.values.filter { !$0.state.isTerminal }
    }

    // MARK: - Task Executor (public utility)

    /// Execute a long-running block as a tracked task.
    ///
    /// This is the recommended entry point for tools like `install_ipa`, `resign_app`, etc.
    /// The `work` closure receives the task ID and a `ProgressUpdater` to report progress.
    ///
    /// ```swift
    /// taskManager.executeTask(title: "Installing IPA") { taskId, progress in
    ///     progress.update(total: 100, current: 0)
    ///     // ... do work ...
    ///     progress.update(total: 100, current: 50)
    ///     // ... more work ...
    ///     progress.update(total: 100, current: 100)
    ///     return TaskResult(content: [TaskContentItem(kind: .text, text: "Done")])
    /// }
    /// ```
    public func executeTask(
        id: String? = nil,
        title: String? = nil,
        work: @escaping (_ taskId: String, _ progress: ProgressUpdater) throws -> TaskResult
    ) -> CreateTaskResult {
        let result = createTask(id: id, title: title)
        let taskId = result.id
        let updater = ProgressUpdater(taskId: taskId, manager: self)

        startTask(taskId)

        // Execute synchronously (caller is responsible for dispatching to a queue if needed)
        do {
            let taskResult = try work(taskId, updater)
            completeTask(taskId, result: taskResult)
        } catch let taskErr as TaskError {
            failTask(taskId, error: taskErr)
        } catch {
            failTask(taskId, error: TaskError(code: -1, message: error.localizedDescription))
        }

        return result
    }

    // MARK: - ProgressUpdater

    /// Helper object passed into `executeTask` closures for progress reporting.
    public struct ProgressUpdater: Sendable {
        private let taskId: String
        private let manager: TaskManager

        init(taskId: String, manager: TaskManager) {
            self.taskId = taskId
            self.manager = manager
        }

        /// Report progress update.
        public func update(total: Int? = nil, current: Int? = nil, message: String? = nil) {
            manager.updateProgress(taskId, progress: TaskProgress(total: total, current: current, message: message))
        }
    }

    // MARK: - Private

    private func updateTask(_ taskId: String, transform: (TaskStatus) -> TaskStatus) {
        lock.lock()
        let old = tasks[taskId]
        let new = old.map { transform($0) } ?? old
        if let new = new {
            tasks[taskId] = new
        }
        lock.unlock()

        if let new = new, new != old {
            onStatusChange?(taskId, new)
        }
    }

    private func generateId() -> String {
        lock.lock()
        defer { lock.unlock() }
        idCounter += 1
        return "task-\(idCounter)"
    }
}
