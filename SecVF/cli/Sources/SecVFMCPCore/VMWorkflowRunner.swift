//
//  VMWorkflowRunner.swift
//  SecVFMCPCore
//
//  Drives a queued RunStore entry through the detonation lifecycle:
//
//      queued → booting → capturing → analyzing → done
//                                         │
//                                         └──→ failed (any error)
//
//  The runner owns the state transitions and orchestrates the VMBridge +
//  CaptureBridge to do real work. On any bridge failure it transitions
//  to .failed AND cleans up any side effects (stops the VM if it was
//  started, stops the capture if it was started).
//
//  Time-based waits go through a `WorkflowClock` so tests can advance
//  through the timeout window in <1ms.
//

import Foundation

/// Abstracted wait so tests can run instantly.
public protocol WorkflowClock: Sendable {
    func sleep(seconds: Int) async
}

/// Default production clock — uses `Task.sleep`.
public actor WallClock: WorkflowClock {
    public init() {}
    public func sleep(seconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}

public actor VMWorkflowRunner {
    private let runs: RunStore
    private let vmBridge: any VMBridge
    private let captureBridge: any CaptureBridge
    private let clock: any WorkflowClock

    /// Time spent waiting for guest boot before starting capture.
    private let bootWaitSeconds: Int = 3
    /// Time spent in the analyzing phase after capture stops (lets
    /// post-capture work like report assembly happen explicitly).
    private let analyzeSeconds: Int = 1

    public init(
        runs: RunStore,
        vmBridge: any VMBridge,
        captureBridge: any CaptureBridge,
        clock: any WorkflowClock = WallClock()
    ) {
        self.runs = runs
        self.vmBridge = vmBridge
        self.captureBridge = captureBridge
        self.clock = clock
    }

    /// Run the workflow for a queued run. Idempotent — re-runs of an
    /// already-completed (or failed) run are no-ops.
    public func run(runId: String) async {
        guard let snapshot = await runs.snapshot(runId: runId) else { return }

        // Only queued runs are eligible.
        guard snapshot.state == .queued else { return }

        let vmName = snapshot.templateVM

        // === booting ===
        await runs.transition(runId: runId, to: .booting)
        let startOutcome = await vmBridge.start(vmNamed: vmName)
        guard startOutcome.success else {
            await runs.markFailed(
                runId: runId,
                error: "vm start failed: \(startOutcome.errorMessage ?? "unknown")"
            )
            return
        }

        // Boot wait — give guest a chance to come up before tapping the
        // virtual switch.
        await clock.sleep(seconds: bootWaitSeconds)

        // === capturing ===
        await runs.transition(runId: runId, to: .capturing)
        let captureOutcome = await captureBridge.start(
            vm: vmName,
            bpfFilter: nil,
            pcapPath: nil
        )
        guard captureOutcome.success else {
            // Cleanup: stop the VM we just started.
            _ = await vmBridge.stop(vmNamed: vmName)
            await runs.markFailed(
                runId: runId,
                error: "capture start failed: \(captureOutcome.errorMessage ?? "unknown")"
            )
            return
        }

        // Capture window — runs for the user-requested timeout.
        let timeoutSeconds = snapshot.timeoutSeconds
        await clock.sleep(seconds: timeoutSeconds)

        // === analyzing ===
        await runs.transition(runId: runId, to: .analyzing)
        _ = await captureBridge.stop()
        _ = await vmBridge.stop(vmNamed: vmName)

        // Post-capture analysis window. In production this is where YARA
        // scans of dropped files, PCAP summarization, etc. happen. For
        // the PoC it's a deterministic short delay.
        await clock.sleep(seconds: analyzeSeconds)

        // === done ===
        let report: [String: Any] = [
            "template_vm": vmName,
            "sample_path": snapshot.samplePath,
            "duration_seconds": bootWaitSeconds + timeoutSeconds + analyzeSeconds,
            "verdict": "synthetic-test-no-iocs",
            "note": "PoC runner — production version runs YARA + tshark summary",
            "started_at": ISO8601DateFormatter().string(from: snapshot.startedAt),
        ]
        await runs.markDone(runId: runId, report: report)
    }
}
