//
//  JSONRPCTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the JSON-RPC 2.0 framing layer. MCP runs on JSON-RPC over stdio.
//  This layer:
//    - parses incoming requests from a line of JSON
//    - validates protocol version + required fields
//    - dispatches to the right handler (initialize, tools/list, tools/call)
//    - serializes responses (success / error) back to JSON-RPC envelopes
//
//  Pure logic — no I/O. The stdio loop in main.swift handles bytes;
//  this module handles the protocol semantics.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("JSONRPC")
struct JSONRPCTests {

    // MARK: - Request parsing

    @Test("parses a valid tools/call request")
    func parsesValidToolsCall() throws {
        let raw = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"secvf_vm_list","arguments":{"limit":50}}}
        """
        let req = try JSONRPCRequest.parse(raw)
        #expect(req.id == .number(1))
        #expect(req.method == "tools/call")
        if case .toolsCall(let name, let args) = req.payload {
            #expect(name == "secvf_vm_list")
            #expect(args["limit"] as? Int == 50)
        } else {
            Issue.record("expected toolsCall payload")
        }
    }

    @Test("parses an initialize request")
    func parsesInitialize() throws {
        let raw = """
        {"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2024-11-05"}}
        """
        let req = try JSONRPCRequest.parse(raw)
        #expect(req.id == .string("init-1"))
        #expect(req.method == "initialize")
        if case .initialize = req.payload {} else {
            Issue.record("expected initialize payload")
        }
    }

    @Test("parses a tools/list request")
    func parsesToolsList() throws {
        let raw = """
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}
        """
        let req = try JSONRPCRequest.parse(raw)
        #expect(req.method == "tools/list")
        if case .toolsList = req.payload {} else {
            Issue.record("expected toolsList payload")
        }
    }

    @Test("rejects request missing jsonrpc field")
    func rejectsMissingJsonrpc() {
        let raw = """
        {"id":1,"method":"tools/list"}
        """
        #expect(throws: JSONRPCParseError.self) {
            try JSONRPCRequest.parse(raw)
        }
    }

    @Test("rejects wrong jsonrpc version")
    func rejectsWrongJsonrpcVersion() {
        let raw = """
        {"jsonrpc":"1.0","id":1,"method":"tools/list"}
        """
        #expect(throws: JSONRPCParseError.self) {
            try JSONRPCRequest.parse(raw)
        }
    }

    @Test("rejects malformed JSON")
    func rejectsMalformedJSON() {
        let raw = "not-json-at-all"
        #expect(throws: JSONRPCParseError.self) {
            try JSONRPCRequest.parse(raw)
        }
    }

    @Test("accepts both string and integer id forms")
    func acceptsBothIdForms() throws {
        let int = try JSONRPCRequest.parse(#"{"jsonrpc":"2.0","id":42,"method":"tools/list"}"#)
        let str = try JSONRPCRequest.parse(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        #expect(int.id == .number(42))
        #expect(str.id == .string("abc"))
    }

    // MARK: - Response serialization

    @Test("serializes a success response")
    func serializesSuccess() throws {
        let response = JSONRPCResponse.success(id: .number(1), result: ["foo": "bar"])
        let json = try response.serialize()

        // Parse it back to validate shape.
        let obj = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 1)
        let result = obj["result"] as? [String: Any]
        #expect(result?["foo"] as? String == "bar")
        #expect(obj["error"] == nil)
    }

    @Test("serializes an error response")
    func serializesError() throws {
        let response = JSONRPCResponse.failure(
            id: .number(7),
            code: -32601,
            message: "Method not found",
            data: ["detail": "no such tool"]
        )
        let json = try response.serialize()
        let obj = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 7)
        let error = obj["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32601)
        #expect(error?["message"] as? String == "Method not found")
        let data = error?["data"] as? [String: Any]
        #expect(data?["detail"] as? String == "no such tool")
        #expect(obj["result"] == nil)
    }

    @Test("response with string id preserves string type")
    func responseStringIdPreservesType() throws {
        let response = JSONRPCResponse.success(id: .string("xyz"), result: [:])
        let json = try response.serialize()
        let obj = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["id"] as? String == "xyz")
    }

    // MARK: - Standard JSON-RPC error codes

    @Test("standard error codes are defined")
    func standardErrorCodes() {
        // From JSON-RPC 2.0 spec
        #expect(JSONRPCErrorCode.parseError == -32700)
        #expect(JSONRPCErrorCode.invalidRequest == -32600)
        #expect(JSONRPCErrorCode.methodNotFound == -32601)
        #expect(JSONRPCErrorCode.invalidParams == -32602)
        #expect(JSONRPCErrorCode.internalError == -32603)
    }
}
