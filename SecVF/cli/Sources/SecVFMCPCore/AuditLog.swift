//
//  AuditLog.swift
//  SecVFMCPCore
//
//  Per-call audit logging for the MCP server. Every tool call writes a
//  structured JSONL entry capturing what was attempted, by whom, when,
//  and what the outcome was. Forensic provenance — survives even if the
//  agent gets prompt-injected, because the entry was written BEFORE the
//  tool ran.
//
//  The actual write is delegated to an `AuditSink`. In production this
//  routes through `AVFAuditLog` (the single-writer queue Batch 5
//  introduced); in tests it goes to a `MemoryAuditSink`.
//

import Foundation

/// Outcome of an MCP tool call.
public enum AuditResult: Equatable, Sendable {
    case ok
    case error(code: String, message: String)
    /// The tool was refused because the current capability tier doesn't
    /// expose it (e.g. agent asked for `secvf_vm_delete` in read-only mode).
    case refusedByTier
    /// The tool was refused by the user-configured confirmation hook.
    case refusedByHook
    /// The tool was rate-limited.
    case rateLimited

    var serializedValue: String {
        switch self {
        case .ok:                return "ok"
        case .error:             return "error"
        case .refusedByTier:     return "refused_by_tier"
        case .refusedByHook:     return "refused_by_hook"
        case .rateLimited:       return "rate_limited"
        }
    }
}

/// Where audit entries actually go. Production: append to a file via
/// AVFAuditLog. Tests: capture in memory.
public protocol AuditSink: Sendable {
    func append(jsonLine: String)
}

/// Writes structured audit entries.
public final class MCPAuditLogger: @unchecked Sendable {
    private let sink: AuditSink
    private let dateFormatter: ISO8601DateFormatter
    private let maxParamSize: Int = 1024  // bytes of serialized JSON before truncation

    public init(sink: AuditSink) {
        self.sink = sink
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = f
    }

    /// Append one audit entry. Synchronous: returns after the bytes are
    /// handed to the sink. Forensic record exists even if the tool crashes
    /// the server moments later.
    public func log(
        tool: String,
        params: [String: Any],
        tier: CapabilityTier,
        result: AuditResult,
        durationMs: Int,
        clientPid: Int
    ) {
        var entry: [String: Any] = [
            "ts": dateFormatter.string(from: Date()),
            "tool": tool,
            "params": cap(params),
            "tier": tier.serializedValue,
            "result": result.serializedValue,
            "duration_ms": durationMs,
            "client_pid": clientPid,
        ]

        if case .error(let code, let message) = result {
            entry["error_code"] = code
            entry["error_message"] = message
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: entry,
            options: [.sortedKeys]
        ),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        sink.append(jsonLine: line + "\n")
    }

    /// Cap params to a reasonable size to avoid an agent passing a giant
    /// blob and bloating the audit log forever.
    private func cap(_ params: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              data.count > maxParamSize else {
            return params
        }
        return [
            "_truncated": "params exceeded \(maxParamSize) bytes",
            "_size_bytes": data.count,
        ]
    }
}

extension CapabilityTier {
    var serializedValue: String {
        switch self {
        case .readOnly:   return "read-only"
        case .safeMutate: return "safe-mutate"
        case .full:       return "full"
        }
    }
}
