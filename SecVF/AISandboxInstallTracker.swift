//
//  AISandboxInstallTracker.swift
//  SecVF
//
//  Lightweight observable singleton for the in-progress AI Sandbox VM
//  install. AppDelegate's `createAISandboxVM` action drives state into
//  this tracker; VMLibraryWindowController observes notifications to
//  render an "installing" entry in the Running VMs sidebar.
//
//  This is *not* a VM in the VMManager sense — it's an in-flight
//  build operation. It exists for as long as `downloadAndInstall +
//  provisionBundle + sealBundle` are running.
//

import Foundation

final class AISandboxInstallTracker {
    static let shared = AISandboxInstallTracker()

    enum Phase: String {
        case idle
        case installing      // Phase 1: VZMacOSInstaller
        case provisioning    // Phase 2: boot + provision-macos-vm.sh
        case sealing         // Phase 3: VZMacAuxiliaryStorage seal
        case finished
        case failed

        var humanLabel: String {
            switch self {
            case .idle:         return ""
            case .installing:   return "Installing macOS"
            case .provisioning: return "Provisioning guest"
            case .sealing:      return "Sealing bundle"
            case .finished:     return "Done"
            case .failed:       return "Failed"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0.0
    private(set) var lastErrorMessage: String?
    private(set) var logMessages: [String] = []

    private init() {}

    /// Append a timestamped line to the task log (capped at 500 lines).
    func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(ts)] \(message)")
        if logMessages.count > 500 { logMessages.removeFirst(logMessages.count - 500) }
        notify()
    }

    /// True when an install is currently running (any non-terminal phase).
    var isActive: Bool {
        switch phase {
        case .installing, .provisioning, .sealing: return true
        case .idle, .finished, .failed:            return false
        }
    }

    func begin() {
        phase = .installing
        fraction = 0
        lastErrorMessage = nil
        logMessages = []
        notify()
    }

    /// Install phase progress (0..1). Other phases ignore the fraction.
    func updateInstallFraction(_ f: Double) {
        guard phase == .installing else { return }
        fraction = max(0, min(1, f))
        notify()
    }

    func setPhase(_ next: Phase) {
        phase = next
        // Provisioning/sealing don't have meaningful fractional progress
        // we can observe, so collapse the bar.
        if next == .provisioning || next == .sealing {
            fraction = 0
        } else if next == .finished {
            fraction = 1
        }
        notify()
    }

    func fail(with message: String) {
        phase = .failed
        lastErrorMessage = message
        notify()
    }

    /// Drop the tracker back to idle. Called once the UI has acknowledged
    /// a finished/failed run (e.g. user dismissed the result alert).
    func reset() {
        phase = .idle
        fraction = 0
        lastErrorMessage = nil
        notify()
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
