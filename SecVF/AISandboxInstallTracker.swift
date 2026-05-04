//
//  AISandboxInstallTracker.swift
//  SecVF
//
//  Lightweight observable singleton for the in-progress AI Sandbox VM
//  install. AppDelegate's `createAISandboxVM` action drives state into
//  this tracker; VMLibraryWindowController observes notifications to
//  render an "installing" entry in the Tasks tab.
//
//  This is *not* a VM in the VMManager sense — it's an in-flight
//  build operation. It exists for as long as the install task runs.
//
//  Concurrency model:
//  - The class is `@MainActor` so writers can't race. Build will fail at
//    any non-main caller and force a `Task { @MainActor in }` hop. Worth
//    doing now rather than waiting for Swift 6's strict concurrency to
//    light it up as a build-breaker.
//
//  Run-id discipline:
//  - Every `begin()` mints a fresh `UUID`. Run-scoped mutators
//    (`fail`, `reset`, `setPhase`, `updateInstallFraction`, `log`) accept
//    an optional `runId:` argument and no-op when it doesn't match
//    `currentRunId`. Prevents a superseded run's late callbacks
//    (typically from a `CancellationError` catch arm) from clobbering
//    the run that replaced it. See PR review F1 / C2 in
//    `docs/PR4_REVIEW_FIXES_2026-05-03.md`.
//

import Foundation

@MainActor
final class AISandboxInstallTracker {
    static let shared = AISandboxInstallTracker()

    enum Phase: String {
        case idle
        case installing      // VZMacOSInstaller running
        case provisioning    // First boot — user completes OOBE + runs provision script
        case sealing         // Bundle being sealed
        case finished
        case failed

        var humanLabel: String {
            switch self {
            case .idle:          return ""
            case .installing:    return "Installing macOS"
            case .provisioning:  return "Provisioning VM"
            case .sealing:       return "Sealing bundle"
            case .finished:      return "Done"
            case .failed:        return "Failed"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0.0
    private(set) var lastErrorMessage: String?
    private(set) var logMessages: [String] = []

    /// Identifier of the install run that currently owns the tracker.
    /// See run-id discipline note in the file header.
    private(set) var currentRunId: UUID?

    private init() {}

    // MARK: - Run-scoped mutators
    //
    // Each `begin()` mints a fresh UUID; pass it back to the run-scoped
    // mutators so a superseded run can't stomp on the current one.
    // Callers that have no run id in scope (e.g. UI dismissing a
    // finished/failed result) can omit the arg; in that case the
    // mutator runs unconditionally.

    /// Start a new run. Returns the run id.
    @discardableResult
    func begin() -> UUID {
        let id = UUID()
        phase = .installing
        fraction = 0
        lastErrorMessage = nil
        logMessages = []
        currentRunId = id
        notify()
        return id
    }

    func updateInstallFraction(_ f: Double, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        guard phase == .installing else { return }
        fraction = max(0, min(1, f))
        notify()
    }

    func setPhase(_ next: Phase, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        phase = next
        // Provisioning and sealing don't have meaningful fractional progress.
        if next == .provisioning || next == .sealing {
            fraction = 0
        } else if next == .finished {
            fraction = 1
        }
        notify()
    }

    func fail(with message: String, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        phase = .failed
        lastErrorMessage = message
        notify()
    }

    /// Drop the tracker back to idle. The run-scoped form skips when the
    /// caller's run is no longer current.
    func reset(runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        phase = .idle
        fraction = 0
        lastErrorMessage = nil
        currentRunId = nil
        notify()
    }

    /// Append a timestamped line to the task log (capped at 500 lines).
    func log(_ message: String, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(ts)] \(message)")
        if logMessages.count > 500 { logMessages.removeFirst(logMessages.count - 500) }
        notify()
    }

    /// True when an install is currently running (any non-terminal phase).
    var isActive: Bool {
        switch phase {
        case .installing, .provisioning, .sealing: return true
        case .idle, .finished, .failed: return false
        }
    }

    private func notify() {
        NotificationCenter.default.post(
            name: .aiSandboxInstallTrackerChanged, object: self
        )
    }
}

extension Notification.Name {
    static let aiSandboxInstallTrackerChanged =
        Notification.Name("com.secvf.aisandbox.install-tracker.changed")
}
