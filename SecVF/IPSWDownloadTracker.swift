//
//  IPSWDownloadTracker.swift
//  SecVF
//
//  Observable singleton for tracking IPSW download progress.
//  Mirrors AISandboxInstallTracker's pattern: AppDelegate drives state,
//  VMLibraryWindowController observes notifications to render in the
//  Tasks tab.
//

import Foundation

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
    }

    func fail(with message: String) {
        phase = .failed
        lastErrorMessage = message
        notify()
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
