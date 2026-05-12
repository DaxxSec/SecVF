//
//  main.swift
//  secvf-mcp
//
//  Thin entry point for the MCP server. Wires up:
//    - capability tier flag from CLI or env
//    - production audit sink (FileAuditSink → ~/.avf/logs/mcp-audit-*.log)
//    - tool handlers backed by real bridges (still scaffolded — Phase 1+2
//      tools work, but the bridges in this binary are stubs that return
//      hard-coded data until the SecVF main-app bridges are wired in)
//    - stdio JSON-RPC loop: read line, dispatch through MCPRouter, write
//      response line, repeat
//
//  The production bridges (calling into the existing CLI bridges or
//  reading directly from ~/.avf/) land in a later iteration once we
//  decide on the bridging mechanism (in-process Swift bridge vs subprocess
//  to secvf-cli). For now this binary runs end-to-end with stub bridges
//  so the JSON-RPC protocol can be exercised against real MCP clients.
//

import Foundation
import SecVFMCPCore

// MARK: - CLI flag parsing

let args = CommandLine.arguments
var tierFlag = ProcessInfo.processInfo.environment["SECVF_MCP_TIER"] ?? "safe-mutate"

for arg in args.dropFirst() {
    if arg.hasPrefix("--capability-tier=") {
        tierFlag = String(arg.dropFirst("--capability-tier=".count))
    } else if arg == "--read-only" {
        tierFlag = "read-only"
    } else if arg == "--full" {
        tierFlag = "full"
    } else if arg == "--help" || arg == "-h" {
        FileHandle.standardError.write(Data("""
        secvf-mcp — Model Context Protocol server for SecVF

        USAGE:
            secvf-mcp [--capability-tier=<tier>]

        FLAGS:
            --capability-tier=<tier>   read-only | safe-mutate (default) | full
            --read-only                shortcut for --capability-tier=read-only
            --full                     shortcut for --capability-tier=full
            -h, --help                 print this message

        ENVIRONMENT:
            SECVF_MCP_TIER             same as --capability-tier
            SECVF_MCP_LOGS_DIR         override audit log directory (default: ~/.avf/logs)

        See: docs/MCP-WRAPPER-DESIGN.md for the full design.
        Drop-in trust prompt: docs/MCP-RECOMMENDED-SYSTEM-PROMPT.md.

        """.utf8))
        exit(0)
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

// MARK: - Audit sink

let logsDir = ProcessInfo.processInfo.environment["SECVF_MCP_LOGS_DIR"]
    ?? FileAuditSink.defaultDirectory
let auditSink = FileAuditSink(directory: logsDir)
let auditLogger = MCPAuditLogger(sink: auditSink)

// MARK: - Stub bridges (placeholder until production bridges are wired)
//
// These are intentionally minimal — they let `tools/list` and basic
// `tools/call` round-trip work for protocol-conformance testing without
// requiring the SecVF app to be running. Production bridges land in a
// follow-up iteration.

actor StubVMBridge: VMBridge {
    func listVMs() async -> [VMRecord] {
        // In production this reads from ~/.avf/Linux/*.bundle and ~/.avf/MacOS/*.bundle.
        return []
    }
    func status(forVM name: String) async -> VMRecord? { nil }
    func start(vmNamed name: String) async -> BridgeOutcome {
        BridgeOutcome(success: false, errorCode: "not_implemented",
                      errorMessage: "Production VM bridge not yet wired. See docs/POST-AUDIT-TODO.md.")
    }
    func stop(vmNamed name: String) async -> BridgeOutcome {
        BridgeOutcome(success: false, errorCode: "not_implemented",
                      errorMessage: "Production VM bridge not yet wired. See docs/POST-AUDIT-TODO.md.")
    }
}

actor StubSwitchBridge: SwitchBridge {
    func status() async -> SwitchStatusRecord {
        SwitchStatusRecord(
            running: false,
            connectedPorts: 0,
            learnedMACs: 0,
            packetsTotal: 0,
            dropsTotal: 0
        )
    }
}

actor StubCaptureBridge: CaptureBridge {
    func status() async -> CaptureStatusRecord {
        CaptureStatusRecord(
            running: false,
            startedAt: nil,
            packetsCaptured: 0,
            bytesCaptured: 0,
            currentPcapPath: nil
        )
    }
    func start(vm: String?, bpfFilter: String?, pcapPath: String?) async -> BridgeOutcome {
        BridgeOutcome(success: false, errorCode: "not_implemented",
                      errorMessage: "Production capture bridge not yet wired.")
    }
    func stop() async -> BridgeOutcome {
        BridgeOutcome(success: false, errorCode: "not_implemented",
                      errorMessage: "Production capture bridge not yet wired.")
    }
}

let vmBridge = StubVMBridge()
let switchBridge = StubSwitchBridge()
let captureBridge = StubCaptureBridge()

// MARK: - Handler registry

let handlers: [String: ToolHandler] = [
    "secvf_vm_list":         VMListHandler(bridge: vmBridge),
    "secvf_vm_status":       VMStatusHandler(bridge: vmBridge),
    "secvf_switch_status":   SwitchStatusHandler(bridge: switchBridge),
    "secvf_capture_status":  CaptureStatusHandler(bridge: captureBridge),
    "secvf_vm_start":        VMStartHandler(bridge: vmBridge),
    "secvf_vm_stop":         VMStopHandler(bridge: vmBridge),
    "secvf_capture_start":   CaptureStartHandler(bridge: captureBridge),
    "secvf_capture_stop":    CaptureStopHandler(bridge: captureBridge),
]

let router = MCPRouter(
    tier: tier,
    handlers: handlers,
    auditLogger: auditLogger,
    clientPid: Int(ProcessInfo.processInfo.processIdentifier)
)

// MARK: - stdio loop
//
// MCP over stdio is line-delimited JSON-RPC. We read one JSON object
// per line from stdin, hand it to the router, write the response to
// stdout (also line-delimited), flush, repeat. EOF on stdin → exit 0.
//
// Implemented as a sync read loop driving an async router via the
// Swift concurrency runtime. Each request is dispatched serially —
// the MCP spec allows concurrent requests but we serialize for now
// to keep the audit log in submission order.

func runStdioLoop() async {
    let stdin = FileHandle.standardInput
    let stdout = FileHandle.standardOutput

    // Use line-by-line reading. We don't use FileHandle.bytes here because
    // we want a synchronous blocking read that wakes when one line arrives.
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        let responseLine = await router.handle(rawRequest: line)
        if !responseLine.isEmpty,
           let data = (responseLine + "\n").data(using: .utf8) {
            stdout.write(data)
        }
    }
    _ = stdin  // silence unused
}

// MARK: - Boot

FileHandle.standardError.write(Data("""
secvf-mcp started
  tier:    \(tierFlag)
  audit:   \(logsDir)/mcp-audit-*.log
  tools:   \(handlers.count) registered
  status:  ready (stub bridges — see docs/POST-AUDIT-TODO.md for production wiring)

""".utf8))

// Swift's top-level await isn't available in non-script mode; use the
// trampoline pattern.
let semaphore = DispatchSemaphore(value: 0)
Task {
    await runStdioLoop()
    semaphore.signal()
}
semaphore.wait()
