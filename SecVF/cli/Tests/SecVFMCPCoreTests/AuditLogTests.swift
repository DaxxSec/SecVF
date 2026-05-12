//
//  AuditLogTests.swift
//  SecVFMCPCoreTests
//
//  TDD for per-call audit logging. Every MCP tool call writes a structured
//  JSONL entry capturing tool name, params, tier, result, timing, and
//  client identifier — forensic provenance for whatever the agent did.
//
//  The actual file I/O is injected (AuditSink protocol) so tests can
//  capture log entries in memory.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("AuditLog")
struct AuditLogTests {

    @Test("audit entry captures tool name and params")
    func entryCapturesNameAndParams() throws {
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)

        logger.log(
            tool: "secvf_vm_list",
            params: ["limit": 50],
            tier: .readOnly,
            result: .ok,
            durationMs: 12,
            clientPid: 81234
        )

        #expect(sink.entries.count == 1)
        let entry = sink.entries.first!
        #expect(entry["tool"] as? String == "secvf_vm_list")
        #expect(entry["tier"] as? String == "read-only")
        #expect(entry["result"] as? String == "ok")
        #expect(entry["duration_ms"] as? Int == 12)
        #expect(entry["client_pid"] as? Int == 81234)
    }

    @Test("audit entry has ISO-8601 timestamp")
    func entryHasISOTimestamp() throws {
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)

        logger.log(
            tool: "secvf_vm_status",
            params: [:],
            tier: .safeMutate,
            result: .ok,
            durationMs: 5,
            clientPid: 1
        )

        let entry = sink.entries.first!
        let ts = entry["ts"] as? String
        #expect(ts != nil)
        // ISO-8601 has at least YYYY-MM-DDTHH:MM:SS
        #expect((ts?.count ?? 0) >= 19)
        #expect(ts?.contains("T") == true)
    }

    @Test("audit entry includes error code on failure")
    func entryIncludesError() throws {
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)

        logger.log(
            tool: "secvf_vm_start",
            params: ["vm": "nonexistent"],
            tier: .safeMutate,
            result: .error(code: "vm_not_found", message: "no VM named 'nonexistent'"),
            durationMs: 3,
            clientPid: 1
        )

        let entry = sink.entries.first!
        #expect(entry["result"] as? String == "error")
        #expect(entry["error_code"] as? String == "vm_not_found")
        #expect(entry["error_message"] as? String == "no VM named 'nonexistent'")
    }

    @Test("audit entry handles refused-by-tier")
    func entryHandlesRefusedByTier() throws {
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)

        logger.log(
            tool: "secvf_vm_delete",
            params: ["vm": "any"],
            tier: .readOnly,
            result: .refusedByTier,
            durationMs: 0,
            clientPid: 1
        )

        let entry = sink.entries.first!
        #expect(entry["result"] as? String == "refused_by_tier")
    }

    @Test("multiple sequential logs preserve order")
    func multipleLogsPreserveOrder() throws {
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)

        logger.log(tool: "secvf_vm_list", params: [:], tier: .readOnly,
                   result: .ok, durationMs: 1, clientPid: 1)
        logger.log(tool: "secvf_vm_status", params: [:], tier: .readOnly,
                   result: .ok, durationMs: 2, clientPid: 1)
        logger.log(tool: "secvf_logs_security", params: [:], tier: .readOnly,
                   result: .ok, durationMs: 3, clientPid: 1)

        #expect(sink.entries.count == 3)
        #expect(sink.entries[0]["tool"] as? String == "secvf_vm_list")
        #expect(sink.entries[1]["tool"] as? String == "secvf_vm_status")
        #expect(sink.entries[2]["tool"] as? String == "secvf_logs_security")
    }

    @Test("redacts long params (>1KB serialized)")
    func redactsLongParams() throws {
        // Audit log shouldn't grow unbounded if an agent passes a giant blob.
        let sink = MemoryAuditSink()
        let logger = MCPAuditLogger(sink: sink)
        let longString = String(repeating: "a", count: 2000)

        logger.log(
            tool: "secvf_vm_start",
            params: ["very_long_param": longString],
            tier: .safeMutate,
            result: .ok,
            durationMs: 1,
            clientPid: 1
        )

        let entry = sink.entries.first!
        let serialized = String(
            data: try JSONSerialization.data(withJSONObject: entry["params"] as Any),
            encoding: .utf8
        ) ?? ""
        // Total serialized params should be capped (truncation marker present).
        #expect(serialized.contains("_truncated"))
    }
}

/// In-memory sink for testing — captures entries as parsed dictionaries
/// instead of writing to disk.
final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [[String: Any]] = []

    var entries: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func append(jsonLine: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        _entries.append(obj)
    }
}
