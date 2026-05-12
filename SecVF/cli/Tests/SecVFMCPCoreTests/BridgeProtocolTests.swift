//
//  BridgeProtocolTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the bridge protocols. The MCP server interacts with SecVF state
//  via injectable protocols (VMBridge, SwitchBridge, CaptureBridge, etc.)
//  so tests can inject in-memory mocks without spinning up real VMs or
//  reading from ~/.avf.
//
//  Production wiring: protocol conformances live in `secvf-mcp` (the
//  executable target) and call into the existing concrete bridges from
//  `secvf-cli/Bridges/`. Tests use the `Mock*Bridge` implementations
//  defined here in the test target.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("BridgeProtocols")
struct BridgeProtocolTests {

    // MARK: - VMBridge

    @Test("VMBridge.listVMs returns registered mocks")
    func vmBridgeListVMs() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "stopped"),
            VMRecord(id: "2", name: "ubuntu", osType: "Linux", status: "running"),
        ])
        let result = await bridge.listVMs()
        #expect(result.count == 2)
        #expect(result.contains(where: { $0.name == "kali" }))
        #expect(result.contains(where: { $0.name == "ubuntu" && $0.status == "running" }))
    }

    @Test("VMBridge.status returns one VM by name")
    func vmBridgeStatus() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let result = await bridge.status(forVM: "kali")
        #expect(result?.status == "running")
    }

    @Test("VMBridge.status returns nil for unknown VM")
    func vmBridgeStatusUnknown() async throws {
        let bridge = MockVMBridge(vms: [])
        let result = await bridge.status(forVM: "ghost")
        #expect(result == nil)
    }

    @Test("VMBridge.start records intent")
    func vmBridgeStartRecordsIntent() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "stopped"),
        ])
        let outcome = await bridge.start(vmNamed: "kali")
        #expect(outcome.success == true)
        let starts = await bridge.startedVMs
        #expect(starts == ["kali"])
    }

    @Test("VMBridge.start fails for unknown VM")
    func vmBridgeStartUnknown() async throws {
        let bridge = MockVMBridge(vms: [])
        let outcome = await bridge.start(vmNamed: "ghost")
        #expect(outcome.success == false)
        #expect(outcome.errorCode == "vm_not_found")
    }

    @Test("VMBridge.stop records intent")
    func vmBridgeStopRecordsIntent() async throws {
        let bridge = MockVMBridge(vms: [
            VMRecord(id: "1", name: "kali", osType: "Linux", status: "running"),
        ])
        let outcome = await bridge.stop(vmNamed: "kali")
        #expect(outcome.success == true)
        let stops = await bridge.stoppedVMs
        #expect(stops == ["kali"])
    }

    // MARK: - SwitchBridge

    @Test("SwitchBridge.status returns running state + counts")
    func switchBridgeStatus() async throws {
        let bridge = MockSwitchBridge(
            running: true,
            connectedPorts: 3,
            learnedMACs: 7,
            packetsTotal: 12345,
            dropsTotal: 12
        )
        let result = await bridge.status()
        #expect(result.running == true)
        #expect(result.connectedPorts == 3)
        #expect(result.learnedMACs == 7)
        #expect(result.packetsTotal == 12345)
        #expect(result.dropsTotal == 12)
    }

    // MARK: - CaptureBridge

    @Test("CaptureBridge.status reflects running state")
    func captureBridgeStatus() async throws {
        let bridge = MockCaptureBridge(running: false)
        let s1 = await bridge.status()
        #expect(s1.running == false)

        let bridge2 = MockCaptureBridge(running: true, packetsCaptured: 42, bytesCaptured: 1024)
        let s2 = await bridge2.status()
        #expect(s2.running == true)
        #expect(s2.packetsCaptured == 42)
        #expect(s2.bytesCaptured == 1024)
    }
}

// MARK: - Test mocks
//
// These mocks demonstrate the protocols by implementing them in pure-Swift,
// no I/O. Production implementations in `secvf-mcp/main.swift` shell into
// the existing CLI bridges.

actor MockVMBridge: VMBridge {
    private(set) var vms: [VMRecord]
    private(set) var startedVMs: [String] = []
    private(set) var stoppedVMs: [String] = []

    init(vms: [VMRecord]) {
        self.vms = vms
    }

    func listVMs() async -> [VMRecord] { vms }

    func status(forVM name: String) async -> VMRecord? {
        vms.first(where: { $0.name == name })
    }

    func start(vmNamed name: String) async -> BridgeOutcome {
        guard vms.contains(where: { $0.name == name }) else {
            return BridgeOutcome(success: false, errorCode: "vm_not_found",
                                 errorMessage: "no VM named '\(name)'")
        }
        startedVMs.append(name)
        return BridgeOutcome(success: true)
    }

    func stop(vmNamed name: String) async -> BridgeOutcome {
        guard vms.contains(where: { $0.name == name }) else {
            return BridgeOutcome(success: false, errorCode: "vm_not_found",
                                 errorMessage: "no VM named '\(name)'")
        }
        stoppedVMs.append(name)
        return BridgeOutcome(success: true)
    }
}

actor MockSwitchBridge: SwitchBridge {
    let running: Bool
    let connectedPorts: Int
    let learnedMACs: Int
    let packetsTotal: Int
    let dropsTotal: Int

    init(running: Bool, connectedPorts: Int = 0, learnedMACs: Int = 0,
         packetsTotal: Int = 0, dropsTotal: Int = 0) {
        self.running = running
        self.connectedPorts = connectedPorts
        self.learnedMACs = learnedMACs
        self.packetsTotal = packetsTotal
        self.dropsTotal = dropsTotal
    }

    func status() async -> SwitchStatusRecord {
        SwitchStatusRecord(
            running: running,
            connectedPorts: connectedPorts,
            learnedMACs: learnedMACs,
            packetsTotal: packetsTotal,
            dropsTotal: dropsTotal
        )
    }
}

actor MockCaptureBridge: CaptureBridge {
    let running: Bool
    let packetsCaptured: Int
    let bytesCaptured: Int
    let startedAt: Date?

    init(running: Bool, packetsCaptured: Int = 0, bytesCaptured: Int = 0,
         startedAt: Date? = nil) {
        self.running = running
        self.packetsCaptured = packetsCaptured
        self.bytesCaptured = bytesCaptured
        self.startedAt = startedAt
    }

    func status() async -> CaptureStatusRecord {
        CaptureStatusRecord(
            running: running,
            startedAt: startedAt,
            packetsCaptured: packetsCaptured,
            bytesCaptured: bytesCaptured,
            currentPcapPath: nil
        )
    }

    func start(vm: String?, bpfFilter: String?, pcapPath: String?) async -> BridgeOutcome {
        BridgeOutcome(success: true)
    }

    func stop() async -> BridgeOutcome {
        BridgeOutcome(success: true)
    }
}
