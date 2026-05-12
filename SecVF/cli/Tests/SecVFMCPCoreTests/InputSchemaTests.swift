//
//  InputSchemaTests.swift
//  SecVFMCPCoreTests
//
//  TDD for per-tool typed inputSchema. Previously every tool advertised
//  `additionalProperties: true` which is useless to agents — they have
//  to guess at parameter names + types. Each ToolDescriptor now carries
//  a typed schema; MCPRouter surfaces it via tools/list.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("InputSchema")
struct InputSchemaTests {

    @Test("vm_start advertises a required 'vm' string param")
    func vmStartHasTypedSchema() throws {
        let desc = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_vm_start" })
        #expect(desc != nil)
        let schema = desc?.inputSchema
        #expect(schema?.type == "object")
        let props = schema?.properties ?? [:]
        #expect(props["vm"]?.type == "string")
        #expect(schema?.required.contains("vm") == true)
    }

    @Test("vm_status advertises required 'vm' string param")
    func vmStatusHasTypedSchema() throws {
        let desc = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_vm_status" })
        #expect(desc?.inputSchema?.required.contains("vm") == true)
        #expect(desc?.inputSchema?.properties["vm"]?.type == "string")
    }

    @Test("vm_list has no required params (empty object schema)")
    func vmListHasEmptySchema() throws {
        let desc = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_vm_list" })
        let schema = desc?.inputSchema
        #expect(schema?.type == "object")
        #expect(schema?.required.isEmpty == true)
    }

    @Test("capture_start advertises optional vm/bpf_filter/pcap_path strings")
    func captureStartHasOptionalParams() throws {
        let desc = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_capture_start" })
        let schema = desc?.inputSchema
        let props = schema?.properties ?? [:]
        #expect(props["vm"]?.type == "string")
        #expect(props["bpf_filter"]?.type == "string")
        #expect(props["pcap_path"]?.type == "string")
        // No required fields — all optional.
        #expect(schema?.required.isEmpty == true)
    }

    @Test("detonate_start requires sample_path + template_vm + optional timeout_seconds")
    func detonateStartSchema() throws {
        let desc = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_detonate_start" })
        let schema = desc?.inputSchema
        let props = schema?.properties ?? [:]
        #expect(props["sample_path"]?.type == "string")
        #expect(props["template_vm"]?.type == "string")
        #expect(props["timeout_seconds"]?.type == "integer")
        #expect(schema?.required.contains("sample_path") == true)
        #expect(schema?.required.contains("template_vm") == true)
        #expect(schema?.required.contains("timeout_seconds") == false)  // optional
    }

    @Test("run_status + run_result require run_id")
    func runIdRequired() throws {
        for name in ["secvf_run_status", "secvf_run_result"] {
            let desc = ToolRegistry.allDescriptors.first(where: { $0.name == name })
            #expect(desc?.inputSchema?.required.contains("run_id") == true,
                   "\(name) should require run_id")
            #expect(desc?.inputSchema?.properties["run_id"]?.type == "string")
        }
    }

    // MARK: - tools/list surface

    @Test("tools/list surfaces per-tool typed schemas")
    func toolsListSurfacesTypedSchemas() async throws {
        let auditLogger = MCPAuditLogger(sink: MemoryAuditSink())
        let router = MCPRouter(
            tier: .safeMutate,
            handlers: [:],
            auditLogger: auditLogger,
            clientPid: 1
        )
        let raw = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let responseStr = await router.handle(rawRequest: raw)
        let obj = try JSONSerialization.jsonObject(
            with: responseStr.data(using: .utf8)!
        ) as! [String: Any]
        let result = obj["result"] as? [String: Any]
        let tools = (result?["tools"] as? [[String: Any]]) ?? []
        // Find vm_start and verify its inputSchema is typed.
        let vmStart = tools.first(where: { $0["name"] as? String == "secvf_vm_start" })
        let schema = vmStart?["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object")
        let props = schema?["properties"] as? [String: Any]
        let vmProp = props?["vm"] as? [String: Any]
        #expect(vmProp?["type"] as? String == "string")
        let required = schema?["required"] as? [String]
        #expect(required?.contains("vm") == true)
        // additionalProperties should be false now (typed schema).
        #expect(schema?["additionalProperties"] as? Bool == false)
    }
}
