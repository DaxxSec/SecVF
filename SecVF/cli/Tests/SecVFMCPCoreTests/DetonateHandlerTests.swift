//
//  DetonateHandlerTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the secvf_detonate composite workflow — the centerpiece of
//  Phase 3 from the design doc. This is the agent ergonomics tool: one
//  call clones a clean VM, mounts a sample, boots, captures for N
//  seconds, snapshots, stops, and returns a forensic report.
//
//  This iteration ships an async-with-polling implementation:
//    - secvf_detonate_start  → returns { run_id, estimated_duration }
//    - secvf_run_status      → returns { run_id, state, progress_pct }
//    - secvf_run_result      → returns { run_id, report } once done
//
//  Sync-blocking dispatch is the wrong shape — Claude Desktop times out
//  at ~60-120s and detonations often run longer.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("DetonateHandler")
struct DetonateHandlerTests {

    // MARK: - DetonateStartHandler

    @Test("detonate_start returns a run_id and immediately moves to running")
    func detonateStartReturnsRunId() async throws {
        let runs = RunStore()
        let handler = DetonateStartHandler(runs: runs)
        let result = await handler.invoke(params: [
            "sample_path": "/tmp/sample.bin",
            "template_vm": "kali-clean",
            "timeout_seconds": 30,
        ])
        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        let runId = data["run_id"] as? String ?? ""
        #expect(!runId.isEmpty)
        #expect(data["estimated_duration_seconds"] as? Int != nil)
        // After the call returns, the run should be findable in the store.
        let state = await runs.state(forRunId: runId)
        #expect(state != nil)
    }

    @Test("detonate_start requires sample_path and template_vm params")
    func detonateStartRequiresParams() async throws {
        let runs = RunStore()
        let handler = DetonateStartHandler(runs: runs)

        let missingSample = await handler.invoke(params: ["template_vm": "x"])
        guard case .failure(let code1, _) = missingSample else {
            Issue.record("expected failure")
            return
        }
        #expect(code1 == "missing_param")

        let missingTemplate = await handler.invoke(params: ["sample_path": "/tmp/x"])
        guard case .failure(let code2, _) = missingTemplate else {
            Issue.record("expected failure")
            return
        }
        #expect(code2 == "missing_param")
    }

    // MARK: - RunStatusHandler

    @Test("run_status returns state for existing run")
    func runStatusReturnsState() async throws {
        let runs = RunStore()
        let runId = await runs.create(
            templateVM: "kali-clean",
            samplePath: "/tmp/x",
            timeoutSeconds: 60
        )
        let handler = RunStatusHandler(runs: runs)
        let result = await handler.invoke(params: ["run_id": runId])
        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["run_id"] as? String == runId)
        #expect(data["state"] as? String != nil)
    }

    @Test("run_status returns run_not_found for unknown id")
    func runStatusUnknownRun() async throws {
        let runs = RunStore()
        let handler = RunStatusHandler(runs: runs)
        let result = await handler.invoke(params: ["run_id": "nonexistent"])
        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "run_not_found")
    }

    // MARK: - RunResultHandler

    @Test("run_result returns not_ready while run is in progress")
    func runResultNotReadyForInProgress() async throws {
        let runs = RunStore()
        let runId = await runs.create(
            templateVM: "kali-clean",
            samplePath: "/tmp/x",
            timeoutSeconds: 60
        )
        // No completion update yet — run is still "queued".
        let handler = RunResultHandler(runs: runs)
        let result = await handler.invoke(params: ["run_id": runId])
        guard case .failure(let code, _) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(code == "not_ready")
    }

    @Test("run_result returns the report once done")
    func runResultReturnsReportWhenDone() async throws {
        let runs = RunStore()
        let runId = await runs.create(
            templateVM: "kali-clean",
            samplePath: "/tmp/x",
            timeoutSeconds: 60
        )
        // Simulate completion.
        let report: [String: Any] = [
            "verdict": "synthetic-test-no-iocs",
            "packets_captured": 0,
        ]
        await runs.markDone(runId: runId, report: report)

        let handler = RunResultHandler(runs: runs)
        let result = await handler.invoke(params: ["run_id": runId])
        guard case .success(let data) = result else {
            Issue.record("expected success")
            return
        }
        #expect(data["run_id"] as? String == runId)
        let returned = data["report"] as? [String: Any]
        #expect(returned?["verdict"] as? String == "synthetic-test-no-iocs")
    }

    // MARK: - Trust boundary

    @Test("run_result output gets vm_output trust marker via dispatcher")
    func runResultIsOutputDirection() async throws {
        // ToolRegistry should declare secvf_run_result as .output direction
        // because the report contains content derived from inside the VM.
        let descriptor = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_run_result" })
        #expect(descriptor != nil)
        #expect(descriptor?.direction == .output)
    }

    @Test("detonate_start is workflow category (safe-mutate tier)")
    func detonateStartIsWorkflowCategory() async throws {
        let descriptor = ToolRegistry.allDescriptors.first(where: { $0.name == "secvf_detonate_start" })
        #expect(descriptor != nil)
        #expect(descriptor?.category == .workflow)
        // workflow → safe-mutate minimum
        #expect(descriptor?.isExposed(at: .safeMutate) == true)
        #expect(descriptor?.isExposed(at: .readOnly) == false)
    }
}
