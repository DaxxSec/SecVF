//
//  DiscoveryHandlers.swift
//  SecVFMCPCore
//
//  Read-only tool handlers — the first set of real handlers wired through
//  protocol-based bridges. None of these mutate state; all are safe at
//  the read-only capability tier.
//
//  Each handler:
//    - takes one bridge in its initializer (dependency injection)
//    - implements ToolHandler.invoke(params:) async -> ToolHandlerResult
//    - returns a result shape stable across versions
//    - emits agent-friendly field names (snake_case in payloads)
//

import Foundation

// MARK: - secvf_vm_list

public final class VMListHandler: ToolHandler {
    private let bridge: any VMBridge
    public init(bridge: any VMBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        let vms = await bridge.listVMs()
        let serialized = vms.map { vm -> [String: Any] in
            [
                "id": vm.id,
                "name": vm.name,
                "os_type": vm.osType,
                "status": vm.status,
            ]
        }
        return .success([
            "vms": serialized,
            "count": serialized.count,
        ])
    }
}

// MARK: - secvf_vm_status

public final class VMStatusHandler: ToolHandler {
    private let bridge: any VMBridge
    public init(bridge: any VMBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let name = params["vm"] as? String, !name.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_vm_status requires 'vm' parameter (string)"
            )
        }
        guard let vm = await bridge.status(forVM: name) else {
            return .failure(
                code: "vm_not_found",
                message: "no VM named '\(name)'"
            )
        }
        return .success([
            "id": vm.id,
            "name": vm.name,
            "os_type": vm.osType,
            "status": vm.status,
        ])
    }
}

// MARK: - secvf_switch_status

public final class SwitchStatusHandler: ToolHandler {
    private let bridge: any SwitchBridge
    public init(bridge: any SwitchBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        let s = await bridge.status()
        return .success([
            "running": s.running,
            "connected_ports": s.connectedPorts,
            "learned_macs": s.learnedMACs,
            "packets_total": s.packetsTotal,
            "drops_total": s.dropsTotal,
        ])
    }
}

// MARK: - secvf_capture_status

public final class CaptureStatusHandler: ToolHandler {
    private let bridge: any CaptureBridge
    public init(bridge: any CaptureBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        let s = await bridge.status()
        var payload: [String: Any] = [
            "running": s.running,
            "packets_captured": s.packetsCaptured,
            "bytes_captured": s.bytesCaptured,
        ]
        if let startedAt = s.startedAt {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            payload["started_at"] = f.string(from: startedAt)
        }
        if let path = s.currentPcapPath {
            payload["current_pcap_path"] = path
        }
        return .success(payload)
    }
}
