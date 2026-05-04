//
//  IPSWDownloadTracker.swift
//  SecVF
//
//  Observable singleton for tracking IPSW download progress.
//  Mirrors AISandboxInstallTracker's pattern: AppDelegate drives state,
//  VMLibraryWindowController observes notifications to render in the
//  Tasks tab.
//
//  `@MainActor` so writers can't race with readers (the tracker is
//  observed from the library window controller's main-thread updates).
//

import Foundation

@MainActor
final class IPSWDownloadTracker {
    static let shared = IPSWDownloadTracker()

    enum Phase: String {
        case idle
        case downloading
        case finished
        case failed

        var humanLabel: String {
            switch self {
            case .idle:        return ""
            case .downloading: return "Downloading"
            case .finished:    return "Done"
            case .failed:      return "Failed"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0.0
    private(set) var totalBytes: Int64 = 0
    private(set) var receivedBytes: Int64 = 0
    private(set) var lastErrorMessage: String?
    private(set) var logMessages: [String] = []
    private(set) var filename: String = ""

    /// Auto-reset timing for non-active terminal phases. The Tasks tab
    /// goes back to "No tasks running." after this delay.
    static let autoResetSuccessSeconds: TimeInterval = 5
    static let autoResetFailureSeconds: TimeInterval = 30

    private init() {}

    func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(ts)] \(message)")
        if logMessages.count > 500 { logMessages.removeFirst(logMessages.count - 500) }
        notify()
    }

    var isActive: Bool { phase == .downloading }

    func begin(filename: String, expectedBytes: Int64) {
        self.phase = .downloading
        self.fraction = 0
        self.totalBytes = expectedBytes
        self.receivedBytes = 0
        self.lastErrorMessage = nil
        self.logMessages = []
        self.filename = filename
        notify()
    }

    func updateProgress(received: Int64, total: Int64) {
        guard phase == .downloading else { return }
        receivedBytes = received
        totalBytes = total
        fraction = total > 0 ? Double(received) / Double(total) : 0
        notify()
    }

    func complete() {
        phase = .finished
        fraction = 1
        notify()
        // Auto-clear the sticky "Done" status after the user has had a
        // chance to see it. Only resets if we're still in .finished — a
        // new begin() in the meantime takes priority.
        scheduleAutoReset(after: Self.autoResetSuccessSeconds, expectingPhase: .finished)
    }

    func fail(with message: String) {
        phase = .failed
        lastErrorMessage = message
        notify()
        // Failures stay visible longer — user needs time to read the alert.
        scheduleAutoReset(after: Self.autoResetFailureSeconds, expectingPhase: .failed)
    }

    func reset() {
        phase = .idle
        fraction = 0
        totalBytes = 0
        receivedBytes = 0
        lastErrorMessage = nil
        filename = ""
        notify()
    }

    private func scheduleAutoReset(after delay: TimeInterval, expectingPhase: Phase) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.phase == expectingPhase else { return }
            self.reset()
        }
    }

    private func notify() {
        NotificationCenter.default.post(
            name: .ipswDownloadTrackerChanged, object: self
        )
    }
}

extension Notification.Name {
    static let ipswDownloadTrackerChanged =
        Notification.Name("com.secvf.ipsw.download-tracker.changed")
}
