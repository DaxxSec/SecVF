//
//  ServerRoutingTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the top-level MCP method router that translates JSON-RPC
//  requests into Dispatcher calls (for tools/call) or directly handles
//  the meta-methods (initialize, tools/list).
//
//  This is the layer that sits between the JSON-RPC framing and the
//  Dispatcher — it's what the stdio loop actually calls.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("ServerRouting")
struct ServerRoutingTests {

    @Test("initialize returns server info and protocol version")
    func initializeReturnsServerInfo() async throws {
        let router = makeRouter()
        let raw = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#

        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]

        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 1)
        let result = obj["result"] as? [String: Any]
        #expect(result?["protocolVersion"] != nil)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "secvf-mcp")
    }

    @Test("tools/list returns only tools exposed at current tier")
    func toolsListRespectsTier() async throws {
        let router = makeRouter(tier: .readOnly)
        let raw = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        let result = obj["result"] as? [String: Any]
        let tools = (result?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }

        // Read-only tier should expose discovery tools…
        #expect(names.contains("secvf_vm_list"))
        // …and NOT expose mutating/destructive tools
        #expect(!names.contains("secvf_vm_start"))
        #expect(!names.contains("secvf_vm_delete"))
    }

    @Test("tools/call dispatches to registered handler")
    func toolsCallDispatchesToHandler() async throws {
        let router = makeRouter()
        let raw = #"""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"secvf_vm_list","arguments":{}}}
        """#

        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        #expect(obj["id"] as? Int == 3)
        let result = obj["result"] as? [String: Any]
        // The result is wrapped in MCP "content" — for tool calls MCP uses
        // {"content": [{"type":"text","text": ...}]} OR structured data via
        // "structuredContent". We use structuredContent so agents get typed
        // returns.
        #expect(result?["structuredContent"] != nil)
    }

    @Test("malformed JSON returns parse error")
    func malformedJSONReturnsParseError() async throws {
        let router = makeRouter()
        let responseStr = await router.handle(rawRequest: "not-json-at-all")
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        let error = obj["error"] as? [String: Any]
        #expect(error?["code"] as? Int == JSONRPCErrorCode.parseError)
    }

    @Test("unknown method returns methodNotFound")
    func unknownMethodReturnsMethodNotFound() async throws {
        let router = makeRouter()
        let raw = #"{"jsonrpc":"2.0","id":4,"method":"nonexistent/method"}"#

        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        let error = obj["error"] as? [String: Any]
        #expect(error?["code"] as? Int == JSONRPCErrorCode.methodNotFound)
    }

    @Test("tools/call with refused-by-tier returns proper error envelope")
    func toolsCallRefusedByTier() async throws {
        let router = makeRouter(tier: .readOnly)
        let raw = #"""
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"secvf_vm_delete","arguments":{"vm":"x"}}}
        """#

        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        let error = obj["error"] as? [String: Any]
        let data = error?["data"] as? [String: Any]
        #expect(data?["code"] as? String == "refused_by_tier")
    }

    // MARK: - Helper

    private func makeRouter(tier: CapabilityTier = .readOnly) -> MCPRouter {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let handlers: [String: ToolHandler] = [
            "secvf_vm_list": VMListHandler(bridge: bridge),
        ]
        let auditLogger = MCPAuditLogger(sink: MemoryAuditSink())
        return MCPRouter(
            tier: tier,
            handlers: handlers,
            auditLogger: auditLogger,
            clientPid: 1
        )
    }
}
