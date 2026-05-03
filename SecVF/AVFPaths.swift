//
//  AVFPaths.swift
//  SecVF
//
//  Centralizes the on-disk layout under ~/.avf so a future move
//  (per-case namespacing, alternative root) is mechanical instead of
//  scattered across every file that touches `NSHomeDirectory() + "/.avf/..."`.
//

import Foundation

enum AVFPaths {
    static var root: String { NSHomeDirectory() + "/.avf" }

    // MARK: Subdirectories
    static var logsDir: String { root + "/logs" }
    static var configDir: String { root + "/config" }
    static var socketsDir: String { root + "/sockets" }
    static var cacheRoot: String { root + "/VMImages/" }
    static var linuxBundlesDir: String { root + "/Linux" }
    static var macOSDir: String { root + "/MacOS/" }

    // MARK: Specific files
    static var isoCacheAuditLog: String { logsDir + "/iso-cache-audit.log" }
    static var errorAuditLog: String { logsDir + "/error-audit.log" }
    static var execBridgeAllowlist: String { configDir + "/exec-bridge-allowlist" }

    static func vmSocketPath(vmId: UUID) -> String {
        socketsDir + "/vm-\(vmId.uuidString).sock"
    }

    static func securityLog(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return logsDir + "/security-\(f.string(from: date)).log"
    }

    /// Create the directory tree we expect to exist before any logging or
    /// caching happens. Idempotent. Permissions on logs/config are tightened
    /// so audit content stays user-private even on a multi-user box.
    static func ensureDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(atPath: socketsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: linuxBundlesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)
    }
}

// MARK: - Serialized audit-log writer

/// Concurrent open-seek-write-close per call interleaves bytes mid-line. The
/// audit logs are forensic primitives — they MUST stay line-coherent. Routing
/// every appender through one serial queue is the simplest fix and matches
/// the pattern VirtualNetworkSwitch already uses for its log queue.
enum AVFAuditLog {
    private static let queue = DispatchQueue(label: "com.secvf.avf.auditlog")

    /// Append one already-formatted line to a path. Synchronous so callers
    /// don't need to think about whether the line landed before they crash.
    static func append(_ line: String, to path: String) {
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            // Use O_APPEND so concurrent process-level writers (CLI + app) also
            // serialize at the kernel for writes ≤ PIPE_BUF.
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = data.withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
        }
    }
}
