//
//  LifecycleHandlers.swift
//  SecVFMCPCore
//
//  Safe-mutate tool handlers — start/stop/pause/resume VMs, start/stop
//  packet capture. All run at the `.safeMutate` capability tier.
//
//  Each handler takes its bridge in init and validates params explicitly.
//  No bare-bones eval; every parameter is checked.
//

import Foundation

// MARK: - secvf_vm_start

public final class VMStartHandler: ToolHandler {
    private let bridge: any VMBridge
    public init(bridge: any VMBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let name = params["vm"] as? String, !name.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_vm_start requires 'vm' parameter (string)"
            )
        }
        let outcome = await bridge.start(vmNamed: name)
        if outcome.success {
            return .success([
                "ok": true,
                "vm": name,
            ])
        }
        return .failure(
            code: outcome.errorCode ?? "start_failed",
            message: outcome.errorMessage ?? "failed to start VM '\(name)'"
        )
    }
}

// MARK: - secvf_vm_stop

public final class VMStopHandler: ToolHandler {
    private let bridge: any VMBridge
    public init(bridge: any VMBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let name = params["vm"] as? String, !name.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_vm_stop requires 'vm' parameter (string)"
            )
        }
        let outcome = await bridge.stop(vmNamed: name)
        if outcome.success {
            return .success([
                "ok": true,
                "vm": name,
            ])
        }
        return .failure(
            code: outcome.errorCode ?? "stop_failed",
            message: outcome.errorMessage ?? "failed to stop VM '\(name)'"
        )
    }
}

// MARK: - secvf_capture_start

public final class CaptureStartHandler: ToolHandler {
    private let bridge: any CaptureBridge
    public init(bridge: any CaptureBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        let vm = params["vm"] as? String
        let bpf = params["bpf_filter"] as? String
        let pcap = params["pcap_path"] as? String

        let outcome = await bridge.start(vm: vm, bpfFilter: bpf, pcapPath: pcap)
        if outcome.success {
            var payload: [String: Any] = ["ok": true]
            if let vm = vm { payload["vm"] = vm }
            if let bpf = bpf { payload["bpf_filter"] = bpf }
            return .success(payload)
        }
        return .failure(
            code: outcome.errorCode ?? "capture_start_failed",
            message: outcome.errorMessage ?? "failed to start capture"
        )
    }
}

// MARK: - secvf_capture_stop

public final class CaptureStopHandler: ToolHandler {
    private let bridge: any CaptureBridge
    public init(bridge: any CaptureBridge) {
        self.bridge = bridge
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        let outcome = await bridge.stop()
        if outcome.success {
            return .success(["ok": true])
        }
        return .failure(
            code: outcome.errorCode ?? "capture_stop_failed",
            message: outcome.errorMessage ?? "failed to stop capture"
        )
    }
}
