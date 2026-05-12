//
//  main.swift
//  secvf-mcp
//
//  Thin entry point. All logic lives in SecVFMCPCore so it's testable.
//  This binary parses CLI flags, wires up the server with real I/O
//  bridges, and starts the JSON-RPC loop over stdio.
//
//  Phase 1: scaffolding only. The actual JSON-RPC dispatch loop lands in
//  Phase 1 of the TDD rollout. For now this binary just prints its
//  configured tier so the build system can verify the wiring.
//

import Foundation
import SecVFMCPCore

// Parse capability tier from --capability-tier=<value> or env var.
// Default: safe-mutate.
let args = CommandLine.arguments
var tierFlag = ProcessInfo.processInfo.environment["SECVF_MCP_TIER"] ?? "safe-mutate"

for arg in args.dropFirst() {
    if arg.hasPrefix("--capability-tier=") {
        tierFlag = String(arg.dropFirst("--capability-tier=".count))
    } else if arg == "--read-only" {
        tierFlag = "read-only"
    } else if arg == "--full" {
        tierFlag = "full"
    }
}

let tier: CapabilityTier
do {
    tier = try CapabilityTier(parsing: tierFlag)
} catch {
    FileHandle.standardError.write(Data("secvf-mcp: unknown capability tier '\(tierFlag)'\n".utf8))
    FileHandle.standardError.write(Data("valid: read-only, safe-mutate, full\n".utf8))
    exit(64) // EX_USAGE
}

let registry = ToolRegistry(tier: tier)
let toolList = registry.descriptors.map(\.name).sorted().joined(separator: "\n  ")

FileHandle.standardError.write(Data("""
secvf-mcp (scaffolding build)
tier: \(tierFlag)
tools exposed (\(registry.exposedToolNames.count)):
  \(toolList)

JSON-RPC dispatch loop not yet implemented — see Phase 1 TDD rollout.
""".utf8))
