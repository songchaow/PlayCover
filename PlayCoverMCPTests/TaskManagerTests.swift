// TaskManagerTests.swift
// PlayCoverMCPTests

import XCTest

final class TaskManagerTests: XCTestCase {

    var manager: TaskManager!

    override func setUp() {
        super.setUp()
        manager = TaskManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Create Task

    func testCreateTask_generatesId() {
        let result = manager.createTask()
        XCTAssertFalse(result.id.isEmpty)
        XCTAssertTrue(result.id.hasPrefix("task-"))
        XCTAssertEqual(result.status.state, .pending)
    }

    func testCreateTask_withCustomId() {
        let result = manager.createTask(id: "my-task-1", title: "Custom Task")
        XCTAssertEqual(result.id, "my-task-1")
        XCTAssertEqual(result.status.state, .pending)
    }

    func testCreateTask_multipleTasks_incrementsId() {
        let r1 = manager.createTask()
        let r2 = manager.createTask()
        XCTAssertNotEqual(r1.id, r2.id)
    }

    // MARK: - State Transitions

    func testStartTask_pendingToRunning() {
        let result = manager.createTask(id: "t1")
        XCTAssertEqual(result.status.state, .pending)

        manager.startTask("t1")
        XCTAssertEqual(manager.getTask("t1")?.state, .running)
    }

    func testStartTask_alreadyRunning_noChange() {
        let result = manager.createTask(id: "t1")
        manager.startTask("t1")
        manager.startTask("t1") // double start
        XCTAssertEqual(manager.getTask("t1")?.state, .running)
    }

    func testCompleteTask_runningToCompleted() {
        manager.createTask(id: "t1")
        manager.startTask("t1")

        let taskResult = TaskResult(content: [
            TaskContentItem(kind: .text, text: "All done")
        ])
        manager.completeTask("t1", result: taskResult)

        let status = manager.getTask("t1")
        XCTAssertEqual(status?.state, .completed)
        XCTAssertEqual(status?.result?.content.first?.text, "All done")
    }

    func testFailTask_runningToFailed() {
        manager.createTask(id: "t1")
        manager.startTask("t1")

        let taskError = TaskError(code: 1, message: "Disk full")
        manager.failTask("t1", error: taskError)

        let status = manager.getTask("t1")
        XCTAssertEqual(status?.state, .failed)
        XCTAssertEqual(status?.error?.message, "Disk full")
    }

    func testCancelTask_runningToCancelled() {
        manager.createTask(id: "t1")
        manager.startTask("t1")

        manager.cancelTask("t1")
        XCTAssertEqual(manager.getTask("t1")?.state, .cancelled)
    }

    func testCompleteTask_fromFailed_noChange() {
        manager.createTask(id: "t1")
        manager.startTask("t1")
        manager.failTask("t1", error: TaskError(code: 1, message: "err"))

        // Terminal state: should not allow further transitions
        manager.completeTask("t1", result: TaskResult())
        XCTAssertEqual(manager.getTask("t1")?.state, .failed)
    }

    // MARK: - Progress

    func testUpdateProgress() {
        manager.createTask(id: "t1")
        manager.startTask("t1")

        manager.updateProgress("t1", progress: TaskProgress(total: 100, current: 50, message: "Halfway"))
        let status = manager.getTask("t1")
        XCTAssertEqual(status?.progress?.total, 100)
        XCTAssertEqual(status?.progress?.current, 50)
        XCTAssertEqual(status?.progress?.message, "Halfway")
        XCTAssertEqual(status?.progress?.fraction, 0.5)
    }

    func testUpdateProgress_nonRunningTask_noChange() {
        manager.createTask(id: "t1")

        manager.updateProgress("t1", progress: TaskProgress(total: 100, current: 50))
        let status = manager.getTask("t1")
        XCTAssertNil(status?.progress)
    }

    // MARK: - Get & List

    func testGetTask_notFound() {
        XCTAssertNil(manager.getTask("nonexistent"))
    }

    func testListTasks_filtersCompletedByDefault() {
        manager.createTask(id: "t1")
        manager.startTask("t1")
        manager.createTask(id: "t2")
        manager.completeTask("t1", result: TaskResult())

        let tasks = manager.listTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.id, "t2")
    }

    func testListTasks_includeCompleted() {
        manager.createTask(id: "t1")
        manager.startTask("t1")
        manager.completeTask("t1", result: TaskResult())

        let tasks = manager.listTasks(includeCompleted: true)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.state, .completed)
    }

    func testListTasks_empty() {
        let tasks = manager.listTasks()
        XCTAssertTrue(tasks.isEmpty)
    }

    // MARK: - onStatusChange Callback

    func testOnStatusChange_calledOnTransitions() {
        var capturedId: String?
        var capturedStates: [TaskState] = []

        manager.onStatusChange = { id, status in
            capturedId = id
            capturedStates.append(status.state)
        }

        manager.createTask(id: "t1")
        manager.startTask("t1")
        manager.completeTask("t1", result: TaskResult())

        XCTAssertEqual(capturedId, "t1")
        XCTAssertTrue(capturedStates.contains(.running))
        XCTAssertTrue(capturedStates.contains(.completed))
    }

    // MARK: - executeTask

    func testExecuteTask_success() {
        var capturedTaskId: String?
        let result = manager.executeTask(title: "Test Task") { taskId, progress in
            capturedTaskId = taskId
            progress.update(total: 10, current: 5)
            progress.update(total: 10, current: 10)
            return TaskResult(content: [
                TaskContentItem(kind: .text, text: "Completed successfully")
            ])
        }

        XCTAssertEqual(capturedTaskId, result.id)

        let status = manager.getTask(result.id)
        XCTAssertEqual(status?.state, .completed)
        XCTAssertEqual(status?.result?.content.first?.text, "Completed successfully")
    }

    func testExecuteTask_failure_throwsError() {
        struct CustomError: Error {}
        let result = manager.executeTask(title: "Failing Task") { _, _ in
            throw CustomError()
        }

        let status = manager.getTask(result.id)
        XCTAssertEqual(status?.state, .failed)
        XCTAssertNotNil(status?.error)
    }

    func testExecuteTask_failure_withTaskError() {
        let result = manager.executeTask(title: "Failing Task") { _, _ in
            throw TaskError(code: 42, message: "Specific failure")
        }

        let status = manager.getTask(result.id)
        XCTAssertEqual(status?.state, .failed)
        XCTAssertEqual(status?.error?.code, 42)
        XCTAssertEqual(status?.error?.message, "Specific failure")
    }

    func testExecuteTask_customId() {
        let result = manager.executeTask(id: "custom-id", title: "Custom") { _, _ in
            TaskResult(content: [])
        }

        XCTAssertEqual(result.id, "custom-id")
    }

    // MARK: - TaskState Tests

    func testTaskState_isTerminal() {
        XCTAssertTrue(TaskState.completed.isTerminal)
        XCTAssertTrue(TaskState.failed.isTerminal)
        XCTAssertTrue(TaskState.cancelled.isTerminal)
        XCTAssertFalse(TaskState.pending.isTerminal)
        XCTAssertFalse(TaskState.running.isTerminal)
    }

    // MARK: - TaskProgress Tests

    func testTaskProgress_fraction() {
        let p1 = TaskProgress(total: 100, current: 25)
        XCTAssertEqual(p1.fraction, 0.25)

        let p2 = TaskProgress(total: 100, current: 150)
        XCTAssertEqual(p2.fraction, 1.0)

        let p3 = TaskProgress()
        XCTAssertNil(p3.fraction)

        let p4 = TaskProgress(total: 0, current: 0)
        XCTAssertNil(p4.fraction)
    }

    // MARK: - Codable Round-trip

    func testTaskStatus_codableRoundTrip() throws {
        let status = TaskStatus(
            id: "test-1",
            state: .running,
            progress: TaskProgress(total: 50, current: 25, message: "Working...")
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(TaskStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    func testTaskResult_codableRoundTrip() throws {
        let result = TaskResult(content: [
            TaskContentItem(kind: .text, text: "Hello"),
            TaskContentItem(kind: .resource),
        ])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(TaskResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testCreateTaskResult_codableRoundTrip() throws {
        let status = TaskStatus(id: "t1", state: .pending)
        let result = CreateTaskResult(id: "t1", status: status)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testListTasksResult_codableRoundTrip() throws {
        let result = ListTasksResult(tasks: [
            TaskStatus(id: "t1", state: .running),
            TaskStatus(id: "t2", state: .completed, result: TaskResult()),
        ], nextCursor: "abc")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ListTasksResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
