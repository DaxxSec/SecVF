//
//  DNCVMBridge.swift
//  SecVFMCPCore
//
//  Closes the host_app_required gap. Reads delegate to FileBackedVMBridge
//  (same metadata.json reads as before). Mutating ops (start/stop) post
//  DistributedNotificationCenter notifications matching the existing
//  com.secvf.cli.<action> contract that SecVF.app's AppDelegate already
//  listens for.
//
//  DNC is fire-and-forget: the bridge can't synchronously confirm the
//  VM actually started. `BridgeOutcome.success == true` means "request
//  posted to GUI app"; the agent must poll `secvf_vm_status` for boot
//  confirmation. We refuse to post for unknown VM names — protects
//  against an agent triggering an arbitrary userInfo payload against
//  the GUI.
//
//  Production wiring: `DNCNotificationPoster` is the concrete poster.
//  Tests inject a `MockNotificationPoster` (in the test target) so we
//  can assert the exact notification name + userInfo without spinning
//  up the real DNC.
//

import Foundation

/// Abstracted notification post — tests inject a recording mock,
/// production uses DNCNotificationPoster.
public protocol NotificationPoster: Sendable {
    func post(
        name: String,
        userInfo: [String: Any],
        deliverImmediately: Bool
    ) async -> Bool
}

/// Concrete poster that calls DistributedNotificationCenter.
public struct DNCNotificationPoster: NotificationPoster {
    public init() {}

    public func post(
        name: String,
        userInfo: [String: Any],
        deliverImmediately: Bool
    ) async -> Bool {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: deliverImmediately
        )
        // DNC's post API doesn't surface success/failure. There is no
        // delivery confirmation — if no one is listening, the message
        // is silently dropped. We return true unconditionally; agents
        // should poll secvf_vm_status to confirm the action took.
        return true
    }
}

/// VM bridge that reads from disk and writes via DNC.
public actor DNCVMBridge: VMBridge {
    private let fileBacked: FileBackedVMBridge
    private let poster: any NotificationPoster

    public init(
        avfRoot: String = NSHomeDirectory() + "/.avf",
        poster: any NotificationPoster = DNCNotificationPoster()
    ) {
        self.fileBacked = FileBackedVMBridge(avfRoot: avfRoot)
        self.poster = poster
    }

    public func listVMs() async -> [VMRecord] {
        await fileBacked.listVMs()
    }

    public func status(forVM name: String) async -> VMRecord? {
        await fileBacked.status(forVM: name)
    }

    public func start(vmNamed name: String) async -> BridgeOutcome {
        await postAction("start", vmNamed: name)
    }

    public func stop(vmNamed name: String) async -> BridgeOutcome {
        await postAction("stop", vmNamed: name)
    }

    /// Force-stop is a separate action that maps to the same listener
    /// pattern. Exposed via a public helper so future handlers can use
    /// it without rebuilding the action string.
    public func forceStop(vmNamed name: String) async -> BridgeOutcome {
        await postAction("force-stop", vmNamed: name)
    }

    // MARK: - private

    private func postAction(_ action: String, vmNamed name: String) async -> BridgeOutcome {
        // Preflight: refuse for unknown VMs. Protects the GUI's notification
        // handler from arbitrary inputs and gives the agent an actionable
        // error.
        guard await fileBacked.status(forVM: name) != nil else {
            return BridgeOutcome(
                success: false,
                errorCode: "vm_not_found",
                errorMessage: "no VM named '\(name)' in ~/.avf — list with secvf_vm_list"
            )
        }

        let ok = await poster.post(
            name: "com.secvf.cli.\(action)",
            userInfo: ["vmName": name],
            deliverImmediately: true
        )

        if !ok {
            return BridgeOutcome(
                success: false,
                errorCode: "host_app_post_failed",
                errorMessage: "DistributedNotificationCenter post failed for action '\(action)'"
            )
        }

        // Fire-and-forget success. Agent should poll secvf_vm_status to
        // confirm the action actually took effect inside the GUI app.
        return BridgeOutcome(success: true)
    }
}
