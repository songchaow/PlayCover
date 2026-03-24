// SessionResources.swift
// PlayCoverMCP

import Foundation

/// Registers session-related MCP resources and their read handlers.
///
/// Resources registered:
/// - `playcover://sessions`: All sessions as a JSON array
/// - `playcover://sessions/{sessionId}`: Single session details as JSON object
public enum SessionResources {

    /// Register both session resource metadata and their read handlers on the server.
    public static func register(
        on server: MCPServer,
        sessionService: SessionService
    ) {
        // Collection resource
        server.resourceRegistry.register(Resource(
            uri: "playcover://sessions",
            name: "Sessions",
            description: "JSON array of all active runtime sessions with their status.",
            mimeType: "application/json"
        ))

        // Template resource for individual session
        server.resourceRegistry.register(Resource(
            uri: "playcover://sessions/{sessionId}",
            name: "Session Info",
            description: "JSON object with details for a specific session. Replace {sessionId} with the session identifier.",
            mimeType: "application/json"
        ))

        // Resource handler for playcover://sessions (exact match)
        server.registerResource(uriTemplate: "playcover://sessions") { uri, _ in
            let sessions = sessionService.listSessions()
            let dicts = sessions.map { $0.toDictionary() }
            let data = try JSONSerialization.data(
                withJSONObject: dicts,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "[]"

            return ReadResourceResult(
                contents: [.init(uri: uri, mimeType: "application/json", text: text)]
            )
        }

        // Resource handler for playcover://sessions/{sessionId}
        server.registerResource(uriTemplate: "playcover://sessions/") { uri, _ in
            let sessionId = String(uri.dropFirst("playcover://sessions/".count))
            guard !sessionId.isEmpty else {
                throw PlayCoverMCPError(
                    code: JSONRPCError.invalidParams,
                    message: "Session ID must not be empty"
                )
            }

            guard let session = sessionService.getSession(sessionId) else {
                throw PlayCoverMCPError(
                    code: PlayCoverErrorCode.sessionNotFound,
                    message: "Session not found: \(sessionId)"
                )
            }

            let dict = session.toDictionary()
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
            let text = String(data: data, encoding: .utf8) ?? "{}"

            return ReadResourceResult(
                contents: [.init(uri: uri, mimeType: "application/json", text: text)]
            )
        }
    }
}
