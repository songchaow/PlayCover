// SSEEncoder.swift
// PlayCoverMCPCore

import Foundation

/// Encodes JSON-RPC messages into Server-Sent Events format.
///
/// SSE event format:
/// ```
/// id: <event-id>\n
/// data: <json-line>\n
/// \n
/// ```
///
/// Reference: https://html.spec.whatwg.org/multipage/server-sent-events.html
public enum SSEEncoder {

    /// A single SSE event
    public struct Event: Equatable, Sendable {
        /// Optional event ID (for resumability)
        public let id: String?
        /// Optional event type
        public let event: String?
        /// The data payload (JSON-RPC message as a string)
        public let data: String
        /// Optional retry interval in milliseconds
        public let retry: Int?

        public init(id: String? = nil, event: String? = nil, data: String, retry: Int? = nil) {
            self.id = id
            self.event = event
            self.data = data
            self.retry = retry
        }
    }

    /// Encode a JSON-RPC message into an SSE event.
    /// - Parameters:
    ///   - message: The JSON-RPC message to encode
    ///   - eventId: Optional SSE event ID
    ///   - retry: Optional retry interval in milliseconds
    /// - Returns: UTF-8 encoded SSE event data, ready to write to the stream
    public static func encode(_ message: JSONRPCMessage, eventId: String? = nil, retry: Int? = nil) throws -> Data {
        let jsonData = try message.encode()
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw SSEEncoderError.encodingFailed
        }
        let event = Event(id: eventId, data: jsonString, retry: retry)
        return encode(event)
    }

    /// Encode an SSE event into raw bytes.
    public static func encode(_ event: Event) -> Data {
        var result = ""
        if let id = event.id {
            result += "id: \(id)\n"
        }
        if let eventType = event.event {
            result += "event: \(eventType)\n"
        }
        if let retry = event.retry {
            result += "retry: \(retry)\n"
        }
        // data field - each line of data gets its own "data:" prefix
        if event.data.isEmpty {
            result += "data: \n"
        } else {
            let lines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                result += "data: \(line)\n"
            }
        }
        result += "\n" // blank line terminates the event
        return result.data(using: .utf8) ?? Data()
    }

    /// Encode a "primer" event (empty data with ID) used to establish SSE stream resumability.
    /// MCP spec: "server SHOULD immediately send an SSE event consisting of an event ID and an empty data field"
    public static func encodePrimerEvent(eventId: String) -> Data {
        let event = Event(id: eventId, data: "")
        return encode(event)
    }

    /// Encode a retry-only event (sent before server closes connection).
    public static func encodeRetryEvent(milliseconds: Int) -> Data {
        let result = "retry: \(milliseconds)\n\n"
        return result.data(using: .utf8) ?? Data()
    }
}

public enum SSEEncoderError: Error, LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode message as UTF-8 string"
        }
    }
}
