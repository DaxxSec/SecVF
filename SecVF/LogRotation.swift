//
//  LogRotation.swift
//  SecVF
//
//  Periodic pruning of ~/.avf/logs/ so accumulated security / network /
//  error logs don't sit on disk forever. Logs may contain VM names,
//  filesystem paths, and other low-but-nonzero PII; bounded retention
//  keeps the on-disk footprint predictable.
//
//  Two policies, applied at SecVF.app launch:
//
//    1. Date-based pruning of dated log files (network-YYYY-MM-DD.log,
//       security-YYYY-MM-DD.log) older than `maxAgeDays`. Default 30 days.
//    2. Size cap on append-only files (error-audit.log). When the file
//       exceeds `maxAuditBytes`, rename to `.1` and start fresh. Default
//       10 MB. Older `.1` files are simply replaced — single backup copy.
//
//  Configurable via env vars (no UI yet — tune from the launch script
//  if needed):
//    SECVF_LOG_MAX_AGE_DAYS   (integer, default 30)
//    SECVF_LOG_MAX_AUDIT_MB   (integer, default 10)
//

import Foundation

enum LogRotation {

    private static var logsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".avf/logs", isDirectory: true)
    }

    /// Run all pruning passes. Safe to call from any thread; does its work
    /// on a utility queue so the main thread isn't blocked at launch.
    static func runAtLaunch() {
        DispatchQueue.global(qos: .utility).async {
            do {
                try pruneOldDatedLogs()
                try rotateAuditLog()
                try rotateOversizeDatedLogs()
            } catch {
                NSLog("[LogRotation] failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Date-based pruning

    private static func pruneOldDatedLogs() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logsDir.path) else { return }

        let maxAge = TimeInterval(maxAgeDaysFromEnv()) * 86_400
        let cutoff = Date().addingTimeInterval(-maxAge)

        let entries = try fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for url in entries {
            let name = url.lastPathComponent
            // Only touch the dated log files. Audit log gets a different
            // policy below; anything we don't recognize stays untouched.
            guard name.hasPrefix("network-") || name.hasPrefix("security-") else {
                continue
            }
            guard name.hasSuffix(".log") else { continue }

            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if mtime < cutoff {
                try? fm.removeItem(at: url)
                NSLog("[LogRotation] pruned %@ (mtime %@)",
                      name, ISO8601DateFormatter().string(from: mtime))
            }
        }
    }

    // MARK: - Size-based audit rotation

    private static func rotateAuditLog() throws {
        let fm = FileManager.default
        let auditURL = logsDir.appendingPathComponent("error-audit.log")
        guard fm.fileExists(atPath: auditURL.path) else { return }

        let maxBytes = maxAuditBytesFromEnv()
        let attrs = try fm.attributesOfItem(atPath: auditURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }

        let backupURL = logsDir.appendingPathComponent("error-audit.log.1")
        // Replace any existing backup — single rolling backup.
        if fm.fileExists(atPath: backupURL.path) {
            try? fm.removeItem(at: backupURL)
        }
        try fm.moveItem(at: auditURL, to: backupURL)
        NSLog("[LogRotation] rotated error-audit.log (%d bytes → .1)", size)
    }

    // MARK: - Size cap for dated logs (network-*, security-*)
    //
    // Date-based pruning above only fires for files older than maxAgeDays —
    // a single chatty day (e.g. a packet-flood incident on the virtual
    // switch) could fill disk before the date cutoff helps. Treat dated
    // logs the same way as the audit log when they exceed maxDatedBytes:
    // rename to `.1`, leaving the original empty for new writes.

    private static func rotateOversizeDatedLogs() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logsDir.path) else { return }

        let maxBytes = maxDatedBytesFromEnv()

        let entries = try fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        for url in entries {
            let name = url.lastPathComponent
            // Only the active dated logs; skip already-rotated .1 and
            // anything else that landed in this dir.
            guard name.hasSuffix(".log"),
                  name.hasPrefix("network-") || name.hasPrefix("security-") else {
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size > maxBytes else { continue }

            let backupURL = logsDir.appendingPathComponent("\(name).1")
            if fm.fileExists(atPath: backupURL.path) {
                try? fm.removeItem(at: backupURL)
            }
            try fm.moveItem(at: url, to: backupURL)
            NSLog("[LogRotation] rotated %@ (%d bytes → .1)", name, size)
        }
    }

    // MARK: - Env-driven config

    private static func maxAgeDaysFromEnv() -> Int {
        if let raw = ProcessInfo.processInfo.environment["SECVF_LOG_MAX_AGE_DAYS"],
           let v = Int(raw), v > 0 {
            return v
        }
        return 30
    }

    private static func maxAuditBytesFromEnv() -> Int {
        if let raw = ProcessInfo.processInfo.environment["SECVF_LOG_MAX_AUDIT_MB"],
           let v = Int(raw), v > 0 {
            return v * 1024 * 1024
        }
        return 10 * 1024 * 1024
    }

    /// Size cap for dated logs (`network-*.log`, `security-*.log`). Larger
    /// default than the audit log because these capture higher-volume data.
    private static func maxDatedBytesFromEnv() -> Int {
        if let raw = ProcessInfo.processInfo.environment["SECVF_LOG_MAX_DATED_MB"],
           let v = Int(raw), v > 0 {
            return v * 1024 * 1024
        }
        return 100 * 1024 * 1024
    }
}
