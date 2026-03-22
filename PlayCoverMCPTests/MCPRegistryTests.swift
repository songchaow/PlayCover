import XCTest

/// Registry unit tests.
final class MCPRegistryTests: XCTestCase {

    // MARK: - ToolRegistry

    func testToolRegistryEmpty() {
        let registry = ToolRegistry()
        XCTAssertTrue(registry.listTools().isEmpty)
    }

    func testToolRegistryRegisterAndList() {
        let registry = ToolRegistry()
        registry.register(Tool(name: "tool_a", inputSchema: InputSchema()))
        registry.register(Tool(name: "tool_b", inputSchema: InputSchema()))

        let tools = registry.listTools()
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0].name, "tool_a")
        XCTAssertEqual(tools[1].name, "tool_b")
    }

    func testToolRegistryReplace() {
        let registry = ToolRegistry()
        registry.register(Tool(name: "tool_x", inputSchema: InputSchema(), description: "old"))
        registry.register(Tool(name: "tool_x", inputSchema: InputSchema(), description: "new"))

        let tools = registry.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].description, "new")
    }

    func testToolRegistryUnregister() {
        let registry = ToolRegistry()
        registry.register(Tool(name: "tool_a", inputSchema: InputSchema()))
        registry.register(Tool(name: "tool_b", inputSchema: InputSchema()))
        registry.unregister(name: "tool_a")

        let tools = registry.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "tool_b")
    }

    func testToolRegistryFind() {
        let registry = ToolRegistry()
        registry.register(Tool(name: "target", inputSchema: InputSchema()))

        XCTAssertNotNil(registry.find(name: "target"))
        XCTAssertNil(registry.find(name: "nonexistent"))
    }

    // MARK: - ResourceRegistry

    func testResourceRegistryEmpty() {
        let registry = ResourceRegistry()
        XCTAssertTrue(registry.listResources().isEmpty)
    }

    func testResourceRegistryRegisterAndList() {
        let registry = ResourceRegistry()
        registry.register(Resource(uri: "a://1", name: "A"))
        registry.register(Resource(uri: "b://2", name: "B"))

        let resources = registry.listResources()
        XCTAssertEqual(resources.count, 2)
    }

    func testResourceRegistryReplace() {
        let registry = ResourceRegistry()
        registry.register(Resource(uri: "x://1", name: "old_name"))
        registry.register(Resource(uri: "x://1", name: "new_name"))

        XCTAssertEqual(registry.listResources().count, 1)
        XCTAssertEqual(registry.listResources()[0].name, "new_name")
    }

    func testResourceRegistryUnregister() {
        let registry = ResourceRegistry()
        registry.register(Resource(uri: "a://1", name: "A"))
        registry.unregister(uri: "a://1")

        XCTAssertTrue(registry.listResources().isEmpty)
    }

    func testResourceRegistryFind() {
        let registry = ResourceRegistry()
        registry.register(Resource(uri: "test://1", name: "Test"))

        XCTAssertNotNil(registry.find(uri: "test://1"))
        XCTAssertNil(registry.find(uri: "nonexistent://1"))
    }
}
