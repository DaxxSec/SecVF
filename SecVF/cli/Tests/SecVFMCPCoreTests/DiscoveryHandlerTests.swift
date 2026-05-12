//
//  DiscoveryHandlerTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the read-only discovery tools — first set of real tool
//  handlers that wire through bridges and produce the actual response
//  shape agents will see.
//
//  Each handler is constructed with an injected bridge so tests can
//  assert behavior without touching disk or spawning VMs.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("DiscoveryHandlers")
struct DiscoveryHandlerTests {

    // MARK: - secvf_vm_list

    @Test("vm_list returns all VMs from the bridge")
    func vmListReturnsAll() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
            VMRecord(id: "2", name: "macOS-sandbox", osType: "macOS", status: "stopped"),
        ])
        let handler = VMListHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        let vms = data["vms"] as? [[String: Any]] ?? []
        #expect(vms.count == 2)
        #expect(vms.contains(where: { $0["name"] as? String == "kali" }))
        #expect(vms.contains(where: { $0["status"] as? String == "stopped" }))
    }

    @Test("vm_list with empty bridge returns empty array")
    func vmListEmpty() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMListHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        let vms = data["vms"] as? [[String: Any]] ?? []
        #expect(vms.isEmpty)
        // Should still include count for agent ergonomics.
        #expect(data["count"] as? Int == 0)
    }

    // MARK: - secvf_vm_status

    @Test("vm_status returns one VM's status")
    func vmStatusReturnsOne() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let handler = VMStatusHandler(bridge: bridge)
        let result = await handler.invoke(params: ["vm": "kali"])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["name"] as? String == "kali")
        #expect(data["status"] as? String == "running")
    }

    @Test("vm_status returns error for missing param")
    func vmStatusMissingParam() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMStatusHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "missing_param")
    }

    @Test("vm_status returns vm_not_found for unknown name")
    func vmStatusUnknownVM() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMStatusHandler(bridge: bridge)
        let result = await handler.invoke(params: ["vm": "ghost"])

        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "vm_not_found")
    }

    // MARK: - secvf_switch_status

    @Test("switch_status returns shape with all counts")
    func switchStatusReturnsShape() async throws {
        let bridge = MockSwitchBridge(
            running: true,
            connectedPorts: 3,
            learnedMACs: 7,
            packetsTotal: 12345,
            dropsTotal: 12
        )
        let handler = SwitchStatusHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["running"] as? Bool == true)
        #expect(data["connected_ports"] as? Int == 3)
        #expect(data["learned_macs"] as? Int == 7)
        #expect(data["packets_total"] as? Int == 12345)
        #expect(data["drops_total"] as? Int == 12)
    }

    // MARK: - secvf_capture_status

    @Test("capture_status returns running state and counts")
    func captureStatusReturns() async throws {
        let bridge = MockCaptureBridge(
            running: true,
            packetsCaptured: 42,
            bytesCaptured: 1024
        )
        let handler = CaptureStatusHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["running"] as? Bool == true)
        #expect(data["packets_captured"] as? Int == 42)
        #expect(data["bytes_captured"] as? Int == 1024)
    }

    // MARK: - End-to-end through Dispatcher

    @Test("end-to-end: dispatcher routes vm_list through registered handler")
    func endToEndVMList() async throws {
        let sink = MemoryAuditSink()
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let handler: ToolHandler = VMListHandler(bridge: bridge)

        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: ["secvf_vm_list": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(tool: "secvf_vm_list", params: [:])

        guard case .success(let data) = response else {
            Issue.record("expected success")
            return
        }
        let vms = data["vms"] as? [[String: Any]] ?? []
        #expect(vms.count == 1)
        // input-direction tool — no trust boundary marker
        #expect(data["trust_boundary"] == nil)
        // Audit log captured the call
        #expect(sink.entries.count == 1)
        #expect(sink.entries[0]["tool"] as? String == "secvf_vm_list")
        #expect(sink.entries[0]["result"] as? String == "ok")
    }
}
