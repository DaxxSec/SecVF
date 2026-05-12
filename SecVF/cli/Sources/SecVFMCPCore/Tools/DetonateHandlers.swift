//
//  DetonateHandlers.swift
//  SecVFMCPCore
//
//  Phase 3 composite workflow — `secvf_detonate_start` /
//  `secvf_run_status` / `secvf_run_result`. The detonation workflow is
//  long-running (boot + capture + snapshot can take 60-300s) which
//  exceeds typical MCP client tool-call timeouts. So we use the
//  async-with-polling pattern:
//
//    secvf_detonate_start  → returns { run_id } immediately
//    secvf_run_status      → poll for state + progress
//    secvf_run_result      → returns the report once state="done"
//
//  RunStore is an actor holding active + completed runs. In production
//  it persists to ~/.avf/runs/<run_id>/ for crash recovery; this PoC
//  keeps runs in memory.
//

import Foundation

public enum RunState: String, Sendable {
    case queued
    case booting
    case capturing
    case analyzing
    case done
    case failed
}

/// Holds active + completed detonation runs. Actor-isolated so concurrent
/// agent calls can't race.
public actor RunStore {
    private struct Run {
        var state: RunState
        var templateVM: String
        var samplePath: String
        var timeoutSeconds: Int
        var startedAt: Date
        var report: [String: Any]?
        var error: String?
    }

    private var runs: [String: Run] = [:]

    public init() {}

    /// Create a new run and return its id. State starts at `.queued`.
    public func create(
        templateVM: String,
        samplePath: String,
        timeoutSeconds: Int
    ) -> String {
        let id = "run_\(UUID().uuidString.prefix(12).lowercased())"
        runs[id] = Run(
            state: .queued,
            templateVM: templateVM,
            samplePath: samplePath,
            timeoutSeconds: timeoutSeconds,
            startedAt: Date(),
            report: nil,
            error: nil
        )
        return id
    }

    public func state(forRunId id: String) -> RunState? {
        runs[id]?.state
    }

    public func report(forRunId id: String) -> [String: Any]? {
        runs[id]?.report
    }

    public func transition(runId: String, to newState: RunState) {
        runs[runId]?.state = newState
    }

    public func markDone(runId: String, report: [String: Any]) {
        runs[runId]?.state = .done
        runs[runId]?.report = report
    }

    public func markFailed(runId: String, error: String) {
        runs[runId]?.state = .failed
        runs[runId]?.error = error
    }

    public func snapshot(runId: String) -> RunSnapshot? {
        guard let r = runs[runId] else { return nil }
        return RunSnapshot(
            id: runId,
            state: r.state,
            templateVM: r.templateVM,
            samplePath: r.samplePath,
            timeoutSeconds: r.timeoutSeconds,
            startedAt: r.startedAt,
            report: r.report,
            error: r.error
        )
    }
}

public struct RunSnapshot: Sendable {
    public let id: String
    public let state: RunState
    public let templateVM: String
    public let samplePath: String
    public let timeoutSeconds: Int
    public let startedAt: Date
    // [String: Any] kept loose; agents see structured content via dispatcher.
    private let _report: [String: Any]?
    public var report: [String: Any]? { _report }
    public let error: String?

    public init(id: String, state: RunState, templateVM: String,
                samplePath: String, timeoutSeconds: Int, startedAt: Date,
                report: [String: Any]?, error: String?) {
        self.id = id
        self.state = state
        self.templateVM = templateVM
        self.samplePath = samplePath
        self.timeoutSeconds = timeoutSeconds
        self.startedAt = startedAt
        self._report = report
        self.error = error
    }
}

// MARK: - secvf_detonate_start

public final class DetonateStartHandler: ToolHandler {
    private let runs: RunStore
    private let runner: VMWorkflowRunner?

    /// Initializer with optional runner. When `runner` is non-nil, the
    /// handler kicks it off in a detached Task so the agent gets an
    /// immediate `run_id` back. When nil (test mode), the run sits at
    /// .queued until the test manually drives it.
    public init(runs: RunStore, runner: VMWorkflowRunner? = nil) {
        self.runs = runs
        self.runner = runner
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let samplePath = params["sample_path"] as? String, !samplePath.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_detonate_start requires 'sample_path' (string)"
            )
        }
        guard let templateVM = params["template_vm"] as? String, !templateVM.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_detonate_start requires 'template_vm' (string)"
            )
        }
        let timeout = (params["timeout_seconds"] as? Int) ?? 60

        let runId = await runs.create(
            templateVM: templateVM,
            samplePath: samplePath,
            timeoutSeconds: timeout
        )

        // If a runner is wired (production), kick it off in a detached
        // Task. The agent gets the run_id back immediately and polls
        // secvf_run_status. Without a runner (test mode), the run sits
        // at .queued for the caller to drive.
        if let runner = runner {
            Task.detached {
                await runner.run(runId: runId)
            }
        }

        return .success([
            "run_id": runId,
            "state": RunState.queued.rawValue,
            "estimated_duration_seconds": timeout + 5,  // boot wait + analyze overhead
            "poll_with": "secvf_run_status",
            "fetch_result_with": "secvf_run_result",
        ])
    }
}

// MARK: - secvf_run_status

public final class RunStatusHandler: ToolHandler {
    private let runs: RunStore
    public init(runs: RunStore) {
        self.runs = runs
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let id = params["run_id"] as? String, !id.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_run_status requires 'run_id' (string)"
            )
        }
        guard let snapshot = await runs.snapshot(runId: id) else {
            return .failure(
                code: "run_not_found",
                message: "no run with id '\(id)'"
            )
        }
        let elapsed = Date().timeIntervalSince(snapshot.startedAt)
        return .success([
            "run_id": snapshot.id,
            "state": snapshot.state.rawValue,
            "template_vm": snapshot.templateVM,
            "elapsed_seconds": Int(elapsed),
        ])
    }
}

// MARK: - secvf_run_result

public final class RunResultHandler: ToolHandler {
    private let runs: RunStore
    public init(runs: RunStore) {
        self.runs = runs
    }

    public func invoke(params: [String: Any]) async -> ToolHandlerResult {
        guard let id = params["run_id"] as? String, !id.isEmpty else {
            return .failure(
                code: "missing_param",
                message: "secvf_run_result requires 'run_id' (string)"
            )
        }
        guard let snapshot = await runs.snapshot(runId: id) else {
            return .failure(
                code: "run_not_found",
                message: "no run with id '\(id)'"
            )
        }
        switch snapshot.state {
        case .done:
            return .success([
                "run_id": snapshot.id,
                "report": snapshot.report ?? [:],
            ])
        case .failed:
            return .failure(
                code: "run_failed",
                message: snapshot.error ?? "run failed"
            )
        default:
            return .failure(
                code: "not_ready",
                message: "run state is '\(snapshot.state.rawValue)' — poll secvf_run_status until state='done'"
            )
        }
    }
}
