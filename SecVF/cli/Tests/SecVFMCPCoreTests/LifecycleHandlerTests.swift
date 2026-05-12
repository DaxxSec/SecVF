//
//  LifecycleHandlerTests.swift
//  SecVFMCPCoreTests
//
//  TDD for safe-mutate lifecycle handlers. These tools change VM state
//  (start/stop/pause/resume) and capture state (start/stop). All run at
//  the `.safeMutate` tier — `read-only` agents cannot reach them.
//
//  Bridges are mocked. Tests assert the handler:
//    - validates required params
//    - calls the right bridge method with the right args
//    - returns the right success/failure shape
//    - records the intent on the mock so we can verify the bridge call
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("LifecycleHandlers")
struct LifecycleHandlerTests {

    // MARK: - secvf_vm_start

    @Test("vm_start calls bridge.start with the right vm name")
    func vmStartCallsBridge() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "stopped"),
        ])
        let handler = VMStartHandler(bridge: bridge)
        let result = await handler.invoke(params: ["vm": "kali"])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["vm"] as? String == "kali")
        #expect(data["ok"] as? Bool == true)
        let starts = await bridge.startedVMs
        #expect(starts == ["kali"])
    }

    @Test("vm_start requires 'vm' parameter")
    func vmStartMissingParam() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMStartHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "missing_param")
    }

    @Test("vm_start surfaces bridge errors")
    func vmStartSurfacesBridgeError() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMStartHandler(bridge: bridge)
        let result = await handler.invoke(params: ["vm": "ghost"])

        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "vm_not_found")
    }

    // MARK: - secvf_vm_stop

    @Test("vm_stop calls bridge.stop")
    func vmStopCallsBridge() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let handler = VMStopHandler(bridge: bridge)
        let result = await handler.invoke(params: ["vm": "kali"])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["ok"] as? Bool == true)
        let stops = await bridge.stoppedVMs
        #expect(stops == ["kali"])
    }

    @Test("vm_stop requires 'vm' parameter")
    func vmStopMissingParam() async throws {
        let bridge = MockVMBridge(vms: [])
        let handler = VMStopHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "missing_param")
    }

    // MARK: - secvf_capture_start / secvf_capture_stop

    @Test("capture_start starts on the bridge")
    func captureStartCallsBridge() async throws {
        let bridge = StatefulCaptureBridge()
        let handler = CaptureStartHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["ok"] as? Bool == true)
        let was = await bridge.didStart
        #expect(was == true)
    }

    @Test("capture_start accepts optional bpf_filter param")
    func captureStartAcceptsFilter() async throws {
        let bridge = StatefulCaptureBridge()
        let handler = CaptureStartHandler(bridge: bridge)
        let result = await handler.invoke(params: ["bpf_filter": "tcp port 80"])

        guard case .success = result else {
            Issue.record("expected success")
            return
        }
        let filter = await bridge.lastBpfFilter
        #expect(filter == "tcp port 80")
    }

    @Test("capture_stop stops on the bridge")
    func captureStopCallsBridge() async throws {
        let bridge = StatefulCaptureBridge()
        let handler = CaptureStopHandler(bridge: bridge)
        let result = await handler.invoke(params: [:])

        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["ok"] as? Bool == true)
        let was = await bridge.didStop
        #expect(was == true)
    }

    // MARK: - End-to-end through dispatcher: refusal at read-only tier

    @Test("end-to-end: vm_start refused at read-only tier")
    func endToEndVMStartRefusedReadOnly() async throws {
        let sink = MemoryAuditSink()
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "stopped"),
        ])
        let handler: ToolHandler = VMStartHandler(bridge: bridge)

        let dispatcher = Dispatcher(
            tier: .readOnly,  // not safe-mutate
            handlers: ["secvf_vm_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(tool: "secvf_vm_start", params: ["vm": "kali"])

        guard case .error(let code, _) = response else {
            Issue.record("expected error response")
            return
        }
        #expect(code == "refused_by_tier")

        // Bridge should NOT have been invoked.
        let starts = await bridge.startedVMs
        #expect(starts.isEmpty)
    }

    @Test("end-to-end: vm_start works at safe-mutate tier")
    func endToEndVMStartSafeMutate() async throws {
        let sink = MemoryAuditSink()
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "stopped"),
        ])
        let handler: ToolHandler = VMStartHandler(bridge: bridge)

        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_vm_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(tool: "secvf_vm_start", params: ["vm": "kali"])

        guard case .success = response else {
            Issue.record("expected success")
            return
        }
        let starts = await bridge.startedVMs
        #expect(starts == ["kali"])
        #expect(sink.entries.first?["result"] as? String == "ok")
    }
}

// MARK: - Stateful capture mock for lifecycle tests

actor StatefulCaptureBridge: CaptureBridge {
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var lastBpfFilter: String?
    private(set) var lastPcapPath: String?
    private(set) var lastVMFilter: String?

    func status() async -> CaptureStatusRecord {
        CaptureStatusRecord(
            running: didStart && !didStop,
            startedAt: nil,
            packetsCaptured: 0,
            bytesCaptured: 0,
            currentPcapPath: lastPcapPath
        )
    }

    func start(vm: String?, bpfFilter: String?, pcapPath: String?) async -> BridgeOutcome {
        didStart = true
        lastVMFilter = vm
        lastBpfFilter = bpfFilter
        lastPcapPath = pcapPath
        return BridgeOutcome(success: true)
    }

    func stop() async -> BridgeOutcome {
        didStop = true
        return BridgeOutcome(success: true)
    }
}
