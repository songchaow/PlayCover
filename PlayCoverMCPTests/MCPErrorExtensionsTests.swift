// MCPErrorExtensionsTests.swift
// PlayCoverMCPTests

import XCTest

final class MCPErrorExtensionsTests: XCTestCase {

    // MARK: - PlayCoverErrorCode

    func testPlayCoverErrorCode_rawValues() {
        XCTAssertEqual(PlayCoverErrorCode.appNotFound.rawValue, -32001)
        XCTAssertEqual(PlayCoverErrorCode.taskNotFound.rawValue, -32008)
        XCTAssertEqual(PlayCoverErrorCode.bridgeError.rawValue, -32012)
        XCTAssertEqual(PlayCoverErrorCode.unsupportedArchitecture.rawValue, -32016)
    }

    func testPlayCoverErrorCode_defaultMessages() {
        XCTAssertEqual(PlayCoverErrorCode.appNotFound.defaultMessage, "Application not found")
        XCTAssertEqual(PlayCoverErrorCode.signingFailed.defaultMessage, "Code signing failed")
        XCTAssertEqual(PlayCoverErrorCode.taskNotFound.defaultMessage, "Task not found")
        XCTAssertEqual(PlayCoverErrorCode.unsupportedArchitecture.defaultMessage, "Unsupported application architecture")
    }

    // MARK: - PlayCoverMCPError Creation

    func testPlayCoverMCPError_basicCreation() {
        let err = PlayCoverMCPError(code: -32001, message: "App not found")
        XCTAssertEqual(err.code, -32001)
        XCTAssertEqual(err.message, "App not found")
        XCTAssertNil(err.data)
        XCTAssertNil(err.cause)
    }

    func testPlayCoverMCPError_withCodeEnum() {
        let err = PlayCoverMCPError(code: .signingFailed)
        XCTAssertEqual(err.code, -32003)
        XCTAssertEqual(err.message, "Code signing failed")
    }

    func testPlayCoverMCPError_withCodeEnumAndCustomMessage() {
        let err = PlayCoverMCPError(code: .signingFailed, message: "Custom signing error")
        XCTAssertEqual(err.code, -32003)
        XCTAssertEqual(err.message, "Custom signing error")
    }

    func testPlayCoverMCPError_withData() throws {
        let data = try AnyCodable(["key": "value"])
        let err = PlayCoverMCPError(code: -32001, message: "Test", data: data)
        XCTAssertNotNil(err.data)
    }

    func testPlayCoverMCPError_withCause() {
        let err = PlayCoverMCPError(code: -1, message: "Outer", cause: "InnerError: something broke")
        XCTAssertTrue(err.errorDescription!.contains("InnerError"))
        XCTAssertTrue(err.errorDescription!.contains("Outer"))
    }

    // MARK: - Wrapping Errors

    func testPlayCoverMCPError_wrappingMCPError() {
        let mcpErr = MCPError.invalidParams("Bad params")
        let wrapped = PlayCoverMCPError(wrapping: mcpErr)
        XCTAssertEqual(wrapped.code, JSONRPCError.invalidParams)
        XCTAssertEqual(wrapped.message, "Bad params")
    }

    func testPlayCoverMCPError_wrappingMCPErrorMethodNotRegistered() {
        let mcpErr = MCPError.methodNotRegistered("foo/bar")
        let wrapped = PlayCoverMCPError(wrapping: mcpErr)
        XCTAssertEqual(wrapped.code, JSONRPCError.methodNotFound)
    }

    func testPlayCoverMCPError_wrappingGenericError() {
        struct GenericError: Error, LocalizedError {
            var errorDescription: String? { "Something went wrong" }
        }
        let wrapped = PlayCoverMCPError(wrapping: GenericError())
        XCTAssertEqual(wrapped.code, JSONRPCError.internalError)
        XCTAssertEqual(wrapped.message, "Something went wrong")
        XCTAssertNotNil(wrapped.cause)
    }

    func testPlayCoverMCPError_wrappingPlayCoverMCPError_passthrough() {
        let original = PlayCoverMCPError(code: .appNotFound)
        let wrapped = PlayCoverMCPError(wrapping: original)
        XCTAssertEqual(wrapped.code, original.code)
        XCTAssertEqual(wrapped.message, original.message)
    }

    func testPlayCoverMCPError_wrappingWithCustomCode() {
        struct MyError: Error {}
        let wrapped = PlayCoverMCPError(wrapping: MyError(), code: -32099, message: "Custom")
        XCTAssertEqual(wrapped.code, -32099)
        XCTAssertEqual(wrapped.message, "Custom")
    }

    func testPlayCoverMCPError_wrapsSigningServiceEntitlementsFailure() {
        let wrapped = PlayCoverMCPError(wrapping: SigningServiceError.entitlementsDumpFailed("bad plist"))
        XCTAssertEqual(wrapped.code, PlayCoverErrorCode.entitlementsError.rawValue)
        XCTAssertEqual(wrapped.message, "Failed to dump entitlements: bad plist")
    }

    // MARK: - MCPError Extension

    func testMCPError_asPlayCoverError() {
        let mcpErr = MCPError.internalError("Oops")
        let pce = mcpErr.asPlayCoverError
        XCTAssertEqual(pce.code, JSONRPCError.internalError)
        XCTAssertEqual(pce.message, "Oops")
    }

    // MARK: - MCP Response Mapping

    func testToErrorResponse_stringId() {
        let err = PlayCoverMCPError(code: .appNotFound, message: "Not found")
        let rpcResp = err.toErrorResponse(id: .string("req-1"))

        XCTAssertEqual(rpcResp.id, .string("req-1"))
        XCTAssertEqual(rpcResp.error?.code, -32001)
        XCTAssertEqual(rpcResp.error?.message, "Not found")
    }

    func testToErrorResponse_integerId() {
        let err = PlayCoverMCPError(code: -32003, message: "Signing failed")
        let rpcResp = err.toErrorResponse(id: .integer(42))

        XCTAssertEqual(rpcResp.id, .integer(42))
        XCTAssertEqual(rpcResp.error?.code, -32003)
    }

    func testToErrorResponse_withData() throws {
        let data = try AnyCodable(["detail": "missing field"])
        let err = PlayCoverMCPError(code: -32002, message: "Bad path", data: data)
        let rpcResp = err.toErrorResponse(id: .string("r1"))

        XCTAssertNotNil(rpcResp.error?.data)
    }

    // MARK: - Free Function: mcpErrorResponse

    func testMcpErrorResponse_playCoverMCPError() {
        let err = PlayCoverMCPError(code: .taskNotFound)
        let response = mcpErrorResponse(id: .string("id1"), error: err)

        if case .response(let rpcResp) = response,
           let rpcErr = rpcResp.error {
            XCTAssertEqual(rpcErr.code, -32008)
        } else {
            XCTFail("Expected error response")
        }
    }

    func testMcpErrorResponse_baseMCPError() {
        let err = MCPError.invalidParams("Missing field")
        let response = mcpErrorResponse(id: .integer(1), error: err)

        if case .response(let rpcResp) = response,
           let rpcErr = rpcResp.error {
            XCTAssertEqual(rpcErr.code, JSONRPCError.invalidParams)
        } else {
            XCTFail("Expected error response")
        }
    }

    func testMcpErrorResponse_genericError() {
        struct SomeError: Error {}
        let response = mcpErrorResponse(id: .string("id"), error: SomeError())

        if case .response(let rpcResp) = response,
           let rpcErr = rpcResp.error {
            XCTAssertEqual(rpcErr.code, JSONRPCError.internalError)
        } else {
            XCTFail("Expected error response")
        }
    }

    // MARK: - toAnyCodable

    func testToAnyCodable_basic() throws {
        let err = PlayCoverMCPError(code: -32001, message: "Test error")
        let any = err.toAnyCodable()
        let dict = try XCTUnwrap(any.dictionary)
        XCTAssertEqual(dict["code"] as? Int, -32001)
        XCTAssertEqual(dict["message"] as? String, "Test error")
    }

    func testToAnyCodable_withCause() throws {
        let err = PlayCoverMCPError(code: -1, message: "Outer", cause: "Inner: boom")
        let any = err.toAnyCodable()
        let dict = try XCTUnwrap(any.dictionary)
        XCTAssertEqual(dict["cause"] as? String, "Inner: boom")
    }

    // MARK: - ErrorDescription

    func testErrorDescription_withoutCause() {
        let err = PlayCoverMCPError(code: -1, message: "Simple error")
        XCTAssertEqual(err.errorDescription, "Simple error")
    }

    func testErrorDescription_withCause() {
        let err = PlayCoverMCPError(code: -1, message: "Outer", cause: "InnerError: boom")
        let desc = err.errorDescription
        XCTAssertTrue(desc!.contains("Outer"))
        XCTAssertTrue(desc!.contains("InnerError: boom"))
    }
}
