// SSEEncoderTests.swift
// PlayCoverMCPTests

import XCTest

final class SSEEncoderTests: XCTestCase {

    func testEncodeSimpleEvent() {
        let event = SSEEncoder.Event(data: "hello")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "data: hello\n\n")
    }

    func testEncodeEventWithId() {
        let event = SSEEncoder.Event(id: "evt-1", data: "hello")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "id: evt-1\ndata: hello\n\n")
    }

    func testEncodeEventWithRetry() {
        let event = SSEEncoder.Event(data: "hello", retry: 5000)
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "retry: 5000\ndata: hello\n\n")
    }

    func testEncodeJSONRPCMessage() throws {
        let response = JSONRPCResponse.success(
            id: .integer(1),
            result: AnyCodable(["ok": true] as [String: Any] as Any?)
        )
        let message = JSONRPCMessage.response(response)
        let encoded = try SSEEncoder.encode(message, eventId: "evt-1")
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(str.hasPrefix("id: evt-1\n"))
        XCTAssertTrue(str.contains("data: "))
        XCTAssertTrue(str.contains("\"jsonrpc\""))
        XCTAssertTrue(str.hasSuffix("\n\n"))
    }

    func testEncodePrimerEvent() {
        let encoded = SSEEncoder.encodePrimerEvent(eventId: "primer-1")
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "id: primer-1\ndata: \n\n")
    }

    func testEncodeMultilineData() {
        let event = SSEEncoder.Event(data: "line1\nline2\nline3")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "data: line1\ndata: line2\ndata: line3\n\n")
    }

    func testEncodeRetryEvent() {
        let encoded = SSEEncoder.encodeRetryEvent(milliseconds: 3000)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "retry: 3000\n\n")
    }

    func testEncodeEventWithAllFields() {
        let event = SSEEncoder.Event(id: "42", event: "message", data: "payload", retry: 1000)
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "id: 42\nevent: message\nretry: 1000\ndata: payload\n\n")
    }

    func testEncodeEventWithEventType() {
        let event = SSEEncoder.Event(event: "notification", data: "test")
        let encoded = SSEEncoder.encode(event)
        let str = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(str, "event: notification\ndata: test\n\n")
    }
}
