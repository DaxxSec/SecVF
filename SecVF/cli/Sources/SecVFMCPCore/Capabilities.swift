//
//  Capabilities.swift
//  SecVFMCPCore
//
//  CapabilityTier — the user-facing flag that determines which tools are
//  even visible to the agent. The agent CANNOT call tools that aren't in
//  its tier; the dispatch table doesn't include them.
//
//  This is the HARD enforcement layer of the security model. Prompt-level
//  injection cannot bypass the tier — the unauthorized tools literally do
//  not exist in the server's tool catalog.
//

import Foundation

/// Capability tiers for the MCP server. Each tier is a strict superset of
/// the tier below.
///
/// - `.readOnly`     — discovery + forensics only. No mutation possible.
/// - `.safeMutate`   — adds lifecycle + capture (default).
/// - `.full`         — adds destructive operations (create/clone/delete).
public enum CapabilityTier: Sendable, Equatable {
    case readOnly
    case safeMutate
    case full

    /// Tier ordering: read-only < safe-mutate < full.
    var rank: Int {
        switch self {
        case .readOnly:   return 0
        case .safeMutate: return 1
        case .full:       return 2
        }
    }

    /// Parse from a CLI flag string. Accepts canonical forms.
    public init(parsing raw: String) throws {
        switch raw.lowercased() {
        case "read-only", "readonly", "ro":
            self = .readOnly
        case "safe-mutate", "safemutate", "default":
            self = .safeMutate
        case "full":
            self = .full
        default:
            throw CapabilityTierError.unknownTier(raw)
        }
    }
}

public enum CapabilityTierError: Error, Equatable {
    case unknownTier(String)
}
