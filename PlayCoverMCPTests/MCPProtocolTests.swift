import XCTest
import Foundation

final class MCPProtocolTests: XCTestCase {

    // MARK: - RequestID

    func testRequestIDStringRoundTrip() throws {
        let id = RequestID.string("test-id")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RequestID.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testRequestIDIntegerRoundTrip() throws {
        let id = RequestID.integer(42)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RequestID.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    // MARK: - AnyCodable

    func testAnyCodableString() throws {
        let any = try AnyCodable("hello")
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testAnyCodableInt() throws {
        let any = try AnyCodable(42)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testAnyCodableBool() throws {
        let any = try AnyCodable(true)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testAnyCodableDictionary() throws {
        let dict: [String: Any] = ["key": "value", "num": 42]
        let any = AnyCodable(dict)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let d = decoded.dictionary
        XCTAssertEqual(d?["key"] as? String, "value")
        XCTAssertEqual(d?["num"] as? Int, 42)
    }

    func testAnyCodableArray() throws {
        let arr: [Any] = [1, "two", true]
        let any = AnyCodable(arr)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.arrayValue?.count, 3)
    }

    func testAnyCodableNil() throws {
        let any = AnyCodable(nil)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(decoded.isNil)
    }

    func testAnyCodableWrapsEncodable() throws {
        let impl = Implementation(name: "Test", version: "1.0")
        let any = try AnyCodable(impl)
        let data = try JSONEncoder().encode(any)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let restored: Implementation = try decoded.decoded()
        XCTAssertEqual(restored.name, "Test")
        XCTAssertEqual(restored.version, "1.0")
    }

    // MARK: - JSON-RPC Message parsing

    func testParseRequest() throws {
        let json = """
        {"jsonrpc":"2.0","id":"req-1","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONRPCMessage.parse(data)

        if case .request(let req) = message {
            XCTAssertEqual(req.method, "initialize")
            XCTAssertEqual(req.id, .string("req-1"))
            XCTAssertNotNil(req.params)
        } else {
            XCTFail("Expected request, got \(message)")
        }
    }

    func testParseNotification() throws {
        let json = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONRPCMessage.parse(data)

        if case .notification(let notif) = message {
            XCTAssertEqual(notif.method, "notifications/initialized")
            XCTAssertNil(notif.params)
        } else {
            XCTFail("Expected notification, got \(message)")
        }
    }

    func testParseResponse() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONRPCMessage.parse(data)

        if case .response(let resp) = message {
            XCTAssertEqual(resp.id, .integer(1))
            XCTAssertNotNil(resp.result)
            XCTAssertNil(resp.error)
        } else {
            XCTFail("Expected response, got \(message)")
        }
    }

    func testParseError() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONRPCMessage.parse(data)

        if case .response(let resp) = message {
            XCTAssertNil(resp.result)
            XCTAssertEqual(resp.error?.code, -32601)
            XCTAssertEqual(resp.error?.message, "Method not found")
        } else {
            XCTFail("Expected response with error, got \(message)")
        }
    }

    func testParseInvalidJSONThrows() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONRPCMessage.parse(data))
    }

    // MARK: - JSON-RPC Message encoding

    func testRequestEncodeOmitsNilParams() throws {
        let req = JSONRPCRequest(id: .integer(1), method: "ping")
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["params"])
    }

    func testResponseEncodeOmitsNilResultAndError() throws {
        let resp = JSONRPCResponse(id: .integer(1), result: nil, error: nil)
        let data = try JSONEncoder().encode(resp)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertFalse(str.contains("\"result\""))
        XCTAssertFalse(str.contains("\"error\""))
    }

    // MARK: - MCP Types

    func testInitializeParamsDecoding() throws {
        let json = """
        {
            "protocolVersion": "2025-11-25",
            "capabilities": {"roots": {"listChanged": true}},
            "clientInfo": {"name": "test-client", "version": "1.0.0"}
        }
        """
        let data = json.data(using: .utf8)!
        let params = try JSONDecoder().decode(InitializeParams.self, from: data)
        XCTAssertEqual(params.protocolVersion, "2025-11-25")
        XCTAssertEqual(params.clientInfo.name, "test-client")
        XCTAssertEqual(params.clientInfo.version, "1.0.0")
        XCTAssertNotNil(params.capabilities.roots)
    }

    func testInitializeResultEncoding() throws {
        let result = InitializeResult(
            protocolVersion: "2025-11-25",
            capabilities: ServerCapabilities(tools: ToolCapabilities(), resources: ResourceCapabilities()),
            serverInfo: Implementation(name: "PlayCoverMCP", version: "0.1.0"),
            instructions: "Use this server to manage PlayCover apps."
        )
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNotNil(json["capabilities"])
        XCTAssertNotNil(json["serverInfo"])
        XCTAssertNotNil(json["instructions"])
    }

    func testToolEncoding() throws {
        let tool = Tool(
            name: "list_apps",
            inputSchema: InputSchema(
                type: "object",
                properties: nil,
                required: nil
            ),
            description: "List installed apps"
        )
        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["name"] as? String, "list_apps")
        XCTAssertNotNil(json["description"])
        XCTAssertNil(json["title"])
    }

    func testResourceEncoding() throws {
        let resource = Resource(
            uri: "playcover://apps",
            name: "Installed Apps",
            description: "List of installed apps",
            mimeType: "application/json"
        )
        let data = try JSONEncoder().encode(resource)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["uri"] as? String, "playcover://apps")
        XCTAssertEqual(json["name"] as? String, "Installed Apps")
    }

    func testListToolsResultEncoding() throws {
        let result = ListToolsResult(tools: [], nextCursor: nil)
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((json["tools"] as? [Any])?.count, 0)
        XCTAssertNil(json["nextCursor"])
    }

    func testListResourcesResultEncoding() throws {
        let result = ListResourcesResult(resources: [], nextCursor: nil)
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((json["resources"] as? [Any])?.count, 0)
        XCTAssertNil(json["nextCursor"])
    }
}
