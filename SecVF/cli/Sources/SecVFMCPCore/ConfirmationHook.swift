//
//  ConfirmationHook.swift
//  SecVFMCPCore
//
//  Layer 4 of the layered defense model. When the dangerous-pattern
//  matcher fires on a tool call, the dispatcher invokes the configured
//  ConfirmationHook BEFORE running the tool. The hook returns:
//
//    - `.approve`            → proceed with the call
//    - `.deny(reason:)`      → refuse with audit log + structured error
//    - `.abstain`            → fall back to default policy (configurable;
//                              currently treats abstain as deny for safety)
//
//  Built-in hooks shipped here:
//    - AlwaysAllowHook  — disable confirmation entirely (env var)
//    - AlwaysDenyHook   — hardened deployments
//    - ScriptHook       — user-provided executable receives JSON on stdin,
//                         exit code 0 = approve, anything else = deny.
//                         (Implementation lives in the executable target so
//                         this file stays pure logic.)
//

import Foundation

public enum ConfirmationDecision: Equatable, Sendable {
    case approve
    case deny(reason: String)
    case abstain
}

public protocol ConfirmationHook: Sendable {
    func evaluate(
        tool: String,
        params: [String: Any],
        matches: [DangerPattern]
    ) async -> ConfirmationDecision
}

// MARK: - Built-in hooks

/// Always approves. Use only in trusted automation contexts where the
/// agent's authority equals the operator's.
public struct AlwaysAllowHook: ConfirmationHook {
    public init() {}
    public func evaluate(
        tool: String,
        params: [String: Any],
        matches: [DangerPattern]
    ) async -> ConfirmationDecision {
        return .approve
    }
}

/// Always denies any hook invocation. Use for hardened deployments where
/// the pattern matcher is enabled and any match must be human-reviewed
/// out-of-band before allowing.
public struct AlwaysDenyHook: ConfirmationHook {
    public init() {}
    public func evaluate(
        tool: String,
        params: [String: Any],
        matches: [DangerPattern]
    ) async -> ConfirmationDecision {
        return .deny(reason: "all confirmation requests denied by policy")
    }
}
