// MCPLoggerTests.swift
// PlayCoverMCPTests

import XCTest

final class MCPLoggerTests: XCTestCase {

    var logger: MCPLogger!

    override func setUp() {
        super.setUp()
        logger = MCPLogger(minLevel: .debug, maxBufferSize: 100)
    }

    override func tearDown() {
        logger = nil
        super.tearDown()
    }

    // MARK: - Level Filtering

    func testDefaultMinLevel_info() {
        let log = MCPLogger()
        XCTAssertEqual(log.minLevel, .info)
    }

    func testMessagesBelowMinLevel_discarded() {
        var capturedCount = 0
        logger.onLog = { _ in capturedCount += 1 }

        logger.setMinLevel(.warning)

        logger.debug("should be filtered")   // priority 0 < 3
        logger.info("should be filtered")    // priority 1 < 3
        logger.notice("should be filtered")  // priority 2 < 3
        logger.warning("should pass")        // priority 3 >= 3
        logger.error("should pass")          // priority 4 >= 3

        XCTAssertEqual(capturedCount, 2)
    }

    func testSetMinLevel() {
        logger.setMinLevel(.error)
        XCTAssertEqual(logger.minLevel, .error)
    }

    // MARK: - onLog Callback

    func testOnLog_receivesEntries() {
        var received: [LogEntry] = []
        logger.onLog = { entry in received.append(entry) }

        logger.info("test message 1")
        logger.warning("test message 2")

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].message, "test message 1")
        XCTAssertEqual(received[0].level, .info)
        XCTAssertEqual(received[1].message, "test message 2")
        XCTAssertEqual(received[1].level, .warning)
    }

    func testOnLog_includesLoggerName() {
        var received: LogEntry?
        logger.onLog = { entry in received = entry }

        logger.error("something failed", logger: "installer")

        XCTAssertEqual(received?.logger, "installer")
    }

    // MARK: - Buffer

    func testBuffer_storesEntries() {
        logger.info("msg1")
        logger.info("msg2")
        logger.info("msg3")

        XCTAssertEqual(logger.bufferedCount, 3)
        XCTAssertEqual(logger.getEntries().count, 3)
    }

    func testBuffer_maxSize_evictsOldest() {
        let smallLogger = MCPLogger(minLevel: .debug, maxBufferSize: 3)

        smallLogger.debug("1")
        smallLogger.debug("2")
        smallLogger.debug("3")
        smallLogger.debug("4") // should evict "1"

        XCTAssertEqual(smallLogger.bufferedCount, 3)
        let entries = smallLogger.getEntries()
        XCTAssertEqual(entries.first?.message, "2")
        XCTAssertEqual(entries.last?.message, "4")
    }

    func testClearBuffer() {
        logger.info("msg1")
        logger.info("msg2")
        logger.clearBuffer()
        XCTAssertEqual(logger.bufferedCount, 0)
        XCTAssertTrue(logger.getEntries().isEmpty)
    }

    func testGetEntries_withMinLevelFilter() {
        logger.debug("d")
        logger.info("i")
        logger.warning("w")
        logger.error("e")

        let filtered = logger.getEntries(minLevel: .warning)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.level.priority >= LogLevel.warning.priority })
    }

    // MARK: - Convenience Methods

    func testConvenienceMethods_setCorrectLevel() {
        var receivedLevels: [LogLevel] = []
        logger.onLog = { entry in receivedLevels.append(entry.level) }

        logger.debug("d")
        logger.info("i")
        logger.notice("n")
        logger.warning("w")
        logger.error("e")
        logger.critical("c")

        XCTAssertEqual(receivedLevels, [.debug, .info, .notice, .warning, .error, .critical])
    }

    // MARK: - LogLevel

    func testLogLevel_priority() {
        XCTAssertLessThan(LogLevel.debug.priority, LogLevel.info.priority)
        XCTAssertLessThan(LogLevel.info.priority, LogLevel.notice.priority)
        XCTAssertLessThan(LogLevel.notice.priority, LogLevel.warning.priority)
        XCTAssertLessThan(LogLevel.warning.priority, LogLevel.error.priority)
        XCTAssertLessThan(LogLevel.error.priority, LogLevel.critical.priority)
    }

    func testLogLevel_allCases() {
        XCTAssertEqual(LogLevel.allCases.count, 6)
    }

    // MARK: - Codable

    func testLogEntry_codableRoundTrip() throws {
        let entry = LogEntry(level: .warning, message: "Test", logger: "test-logger")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LogEntry.self, from: data)
        XCTAssertEqual(decoded.level, .warning)
        XCTAssertEqual(decoded.message, "Test")
        XCTAssertEqual(decoded.logger, "test-logger")
    }

    func testLoggingMessageParams_codableRoundTrip() throws {
        let params = LoggingMessageParams(level: .error, data: "Something failed", logger: "installer")
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(LoggingMessageParams.self, from: data)
        XCTAssertEqual(decoded, params)
    }

    func testSetLoggingLevelParams_codableRoundTrip() throws {
        let params = SetLoggingLevelParams(level: .debug)
        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(SetLoggingLevelParams.self, from: data)
        XCTAssertEqual(decoded, params)
    }

    // MARK: - Integration: MCP Notification

    func testLogEntryCanBeConvertedToNotification() {
        var received = false
        logger.onLog = { entry in
            let params = LoggingMessageParams(level: entry.level, data: entry.message, logger: entry.logger)
            received = true
            _ = try? AnyCodable(params)
        }

        logger.info("notification test", logger: "test")
        XCTAssertTrue(received)
    }
}
