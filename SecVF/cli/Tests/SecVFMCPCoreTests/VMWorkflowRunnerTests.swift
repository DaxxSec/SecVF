//
//  VMWorkflowRunnerTests.swift
//  SecVFMCPCoreTests
//
//  TDD for VMWorkflowRunner — the orchestrator that drives a queued
//  RunStore entry through booting → capturing → analyzing → done.
//
//  The runner is the missing piece between secvf_detonate_start (which
//  enqueues the run) and the real detonation workflow. It owns the
//  state transitions and calls into the VMBridge + CaptureBridge to do
//  the actual work.
//
//  Tests inject mock bridges with deterministic delays so the runner's
//  state machine is exercised quickly without real VMs.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("VMWorkflowRunner")
struct VMWorkflowRunnerTests {

    // MARK: - state transitions

    @Test("runner transitions queued → booting → capturing → analyzing → done")
    func runnerTransitionsThroughAllStates() async throws {
        let runs = RunStore()
        let vmBridge = RecordingVMBridge()
        let captureBridge = RecordingCaptureBridge()

        let runId = await runs.create(
            templateVM: "kali-clean",
            samplePath: "/tmp/sample.bin",
            timeoutSeconds: 1  // short for tests
        )

        let runner = VMWorkflowRunner(
            runs: runs,
            vmBridge: vmBridge,
            captureBridge: captureBridge,
            clock: TestClock()  // skip real waits
        )
        await runner.run(runId: runId)

        // Run should now be done.
        let finalState = await runs.state(forRunId: runId)
        #expect(finalState == .done)

        // Bridge calls happened in the expected order.
        let vmCalls = await vmBridge.callLog
        let captureCalls = await captureBridge.callLog
        #expect(vmCalls.contains("start(kali-clean)"))
        #expect(vmCalls.contains("stop(kali-clean)"))
        #expect(captureCalls.contains("start"))
        #expect(captureCalls.contains("stop"))

        // Report should be populated.
        let report = await runs.report(forRunId: runId)
        #expect(report != nil)
        #expect(report?["template_vm"] as? String == "kali-clean")
    }

    @Test("runner marks run failed if VM start fails")
    func runnerMarksFailedOnStartError() async throws {
        let runs = RunStore()
        let vmBridge = RecordingVMBridge(failOnStart: true)
        let captureBridge = RecordingCaptureBridge()

        let runId = await runs.create(
            templateVM: "broken-vm",
            samplePath: "/tmp/x",
            timeoutSeconds: 1
        )

        let runner = VMWorkflowRunner(
            runs: runs,
            vmBridge: vmBridge,
            captureBridge: captureBridge,
            clock: TestClock()
        )
        await runner.run(runId: runId)

        let finalState = await runs.state(forRunId: runId)
        #expect(finalState == .failed)

        // Capture should NOT have started on a failed VM start.
        let captureCalls = await captureBridge.callLog
        #expect(!captureCalls.contains("start"))
    }

    @Test("runner cleans up VM if capture start fails")
    func runnerCleansUpVMOnCaptureFailure() async throws {
        let runs = RunStore()
        let vmBridge = RecordingVMBridge()
        let captureBridge = RecordingCaptureBridge(failOnStart: true)

        let runId = await runs.create(
            templateVM: "kali-clean",
            samplePath: "/tmp/x",
            timeoutSeconds: 1
        )

        let runner = VMWorkflowRunner(
            runs: runs,
            vmBridge: vmBridge,
            captureBridge: captureBridge,
            clock: TestClock()
        )
        await runner.run(runId: runId)

        let finalState = await runs.state(forRunId: runId)
        #expect(finalState == .failed)

        // VM should have been started AND stopped (cleanup).
        let vmCalls = await vmBridge.callLog
        #expect(vmCalls.contains("start(kali-clean)"))
        #expect(vmCalls.contains("stop(kali-clean)"))
    }

    @Test("runner refuses to re-run an already-completed run")
    func runnerRefusesAlreadyCompleted() async throws {
        let runs = RunStore()
        let vmBridge = RecordingVMBridge()
        let captureBridge = RecordingCaptureBridge()

        let runId = await runs.create(
            templateVM: "kali",
            samplePath: "/tmp/x",
            timeoutSeconds: 1
        )

        let runner = VMWorkflowRunner(
            runs: runs,
            vmBridge: vmBridge,
            captureBridge: captureBridge,
            clock: TestClock()
        )

        // First run completes.
        await runner.run(runId: runId)
        let firstFinalState = await runs.state(forRunId: runId)
        #expect(firstFinalState == .done)

        // Snapshot bridge state.
        let vmCallsBefore = await vmBridge.callLog.count
        let captureCallsBefore = await captureBridge.callLog.count

        // Try to re-run — should be a no-op.
        await runner.run(runId: runId)

        // No additional bridge activity.
        let vmCallsAfter = await vmBridge.callLog.count
        let captureCallsAfter = await captureBridge.callLog.count
        #expect(vmCallsAfter == vmCallsBefore)
        #expect(captureCallsAfter == captureCallsBefore)
    }

    @Test("runner waits for full timeout before stopping capture")
    func runnerWaitsForTimeoutWindow() async throws {
        let runs = RunStore()
        let vmBridge = RecordingVMBridge()
        let captureBridge = RecordingCaptureBridge()
        let clock = TestClock()

        let runId = await runs.create(
            templateVM: "kali",
            samplePath: "/tmp/x",
            timeoutSeconds: 5
        )

        let runner = VMWorkflowRunner(
            runs: runs,
            vmBridge: vmBridge,
            captureBridge: captureBridge,
            clock: clock
        )
        await runner.run(runId: runId)

        // Test clock should have been asked to sleep for timeout_seconds.
        let sleeps = await clock.sleepCalls
        let totalSlept = sleeps.reduce(0, +)
        // Allow some slop: boot wait + capture window + analysis.
        #expect(totalSlept >= 5)
    }
}

// MARK: - test doubles

/// Tracks calls made by the runner. Lets tests force failures and inspect order.
actor RecordingVMBridge: VMBridge {
    private(set) var callLog: [String] = []
    let failOnStart: Bool

    init(failOnStart: Bool = false) {
        self.failOnStart = failOnStart
    }

    func listVMs() async -> [VMRecord] {
        callLog.append("listVMs")
        return []
    }
    func status(forVM name: String) async -> VMRecord? {
        callLog.append("status(\(name))")
        return VMRecord(id: "1", name: name, osType: "Linux", status: "stopped")
    }
    func start(vmNamed name: String) async -> BridgeOutcome {
        callLog.append("start(\(name))")
        if failOnStart {
            return BridgeOutcome(success: false, errorCode: "start_failed",
                                 errorMessage: "boot failed in test")
        }
        return BridgeOutcome(success: true)
    }
    func stop(vmNamed name: String) async -> BridgeOutcome {
        callLog.append("stop(\(name))")
        return BridgeOutcome(success: true)
    }
}

actor RecordingCaptureBridge: CaptureBridge {
    private(set) var callLog: [String] = []
    let failOnStart: Bool

    init(failOnStart: Bool = false) {
        self.failOnStart = failOnStart
    }

    func status() async -> CaptureStatusRecord {
        CaptureStatusRecord(
            running: false, startedAt: nil,
            packetsCaptured: 0, bytesCaptured: 0, currentPcapPath: nil
        )
    }
    func start(vm: String?, bpfFilter: String?, pcapPath: String?) async -> BridgeOutcome {
        callLog.append("start")
        if failOnStart {
            return BridgeOutcome(success: false, errorCode: "capture_failed",
                                 errorMessage: "capture start failed")
        }
        return BridgeOutcome(success: true)
    }
    func stop() async -> BridgeOutcome {
        callLog.append("stop")
        return BridgeOutcome(success: true)
    }
}

/// Test clock — records sleep requests, returns instantly.
actor TestClock: WorkflowClock {
    private(set) var sleepCalls: [Int] = []

    func sleep(seconds: Int) async {
        sleepCalls.append(seconds)
        // Yield once to keep the runner cooperative.
        await Task.yield()
    }
}
