//
//  FileAuditSink.swift
//  SecVFMCPCore
//
//  Production AuditSink that writes lines to mcp-audit-YYYY-MM-DD.log
//  under the configured logs directory. Uses O_APPEND so concurrent
//  process-level writers (e.g. multiple agents driving the same MCP
//  binary in different terminals) serialize at the kernel for writes
//  ≤ PIPE_BUF. First-create permissions are 0o600.
//
//  Mirrors the AVFAuditLog pattern from the main SecVF app — same
//  single-writer queue + O_APPEND + restrictive perms.
//

import Foundation

public final class FileAuditSink: AuditSink, @unchecked Sendable {
    /// Default location matches the main app's ~/.avf/logs/.
    public static let defaultDirectory: String = {
        NSHomeDirectory() + "/.avf/logs"
    }()

    private let directory: String
    private let queue: DispatchQueue

    public init(directory: String = FileAuditSink.defaultDirectory) {
        self.directory = directory
        self.queue = DispatchQueue(label: "com.secvf.mcp.audit", qos: .utility)
    }

    public func append(jsonLine: String) {
        // Synchronous: audit log writes happen at human pace (one per tool
        // call) and durability matters — we don't want writes lost when the
        // process exits at EOF on stdin. The serial queue still gives us
        // cross-thread line coherence.
        queue.sync { [directory] in
            // Ensure the logs directory exists (idempotent).
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let path = Self.path(for: Date(), in: directory)
            guard let data = jsonLine.data(using: .utf8) else { return }

            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = data.withUnsafeBytes { buf in
                write(fd, buf.baseAddress, buf.count)
            }
        }
    }

    static func path(for date: Date, in directory: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return directory + "/mcp-audit-\(f.string(from: date)).log"
    }
}
