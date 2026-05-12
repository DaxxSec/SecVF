//
//  DNCCaptureBridge.swift
//  SecVFMCPCore
//
//  Mirrors DNCVMBridge for the packet capture pipeline. start/stop
//  post com.secvf.cli.capture-start / capture-stop notifications that
//  SecVF.app's AppDelegate listens for (added alongside the existing
//  vm-lifecycle observers). The GUI app drives PacketCaptureManager —
//  same singleton the GUI capture toggle uses, so MCP-driven captures
//  show up in the same tshark pipeline.
//
//  status() returns a fire-and-forget placeholder (running=false,
//  counters=0). Real live status would require a query-back DNC
//  channel (post a `capture-status-request`, listen for a
//  `capture-status-response` with the counters) — out of scope for the
//  initial wire-up. Agents who need confirmation can poll
//  secvf_logs_network for new entries after starting.
//

import Foundation

public actor DNCCaptureBridge: CaptureBridge {
    private let poster: any NotificationPoster

    public init(poster: any NotificationPoster = DNCNotificationPoster()) {
        self.poster = poster
    }

    public func status() async -> CaptureStatusRecord {
        // Fire-and-forget bridge: no live counters available without a
        // query-back DNC channel. Return a deterministic "unknown"
        // placeholder rather than lying about state. Agents looking for
        // real-time status should call secvf_logs_network or check the
        // ~/.avf/logs/network-*.log file directly via that tool.
        return CaptureStatusRecord(
            running: false,
            startedAt: nil,
            packetsCaptured: 0,
            bytesCaptured: 0,
            currentPcapPath: nil
        )
    }

    public func start(
        vm: String?,
        bpfFilter: String?,
        pcapPath: String?
    ) async -> BridgeOutcome {
        // Build userInfo with only the fields the caller actually supplied.
        // Forwarding nil-valued keys would let an agent forge userInfo
        // entries the GUI handler might mis-parse.
        var info: [String: Any] = [:]
        if let vm = vm {
            info["vmName"] = vm
        }
        if let bpfFilter = bpfFilter {
            info["bpfFilter"] = bpfFilter
        }
        if let pcapPath = pcapPath {
            info["pcapPath"] = pcapPath
        }

        let ok = await poster.post(
            name: "com.secvf.cli.capture-start",
            userInfo: info,
            deliverImmediately: true
        )
        guard ok else {
            return BridgeOutcome(
                success: false,
                errorCode: "host_app_post_failed",
                errorMessage: "DistributedNotificationCenter post failed for capture-start"
            )
        }
        return BridgeOutcome(success: true)
    }

    public func stop() async -> BridgeOutcome {
        let ok = await poster.post(
            name: "com.secvf.cli.capture-stop",
            userInfo: [:],
            deliverImmediately: true
        )
        guard ok else {
            return BridgeOutcome(
                success: false,
                errorCode: "host_app_post_failed",
                errorMessage: "DistributedNotificationCenter post failed for capture-stop"
            )
        }
        return BridgeOutcome(success: true)
    }
}
