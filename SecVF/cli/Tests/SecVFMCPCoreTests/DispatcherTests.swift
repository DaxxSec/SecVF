//
//  DispatcherTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the dispatcher — the core flow:
//
//    1. agent calls tool by name
//    2. dispatcher checks tier (refuse if outside)
//    3. dispatcher invokes the registered handler
//    4. dispatcher audit-logs the outcome
//    5. dispatcher returns the structured result to the agent
//
//  Handlers are protocol-based so tests inject behavior without I/O.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("Dispatcher")
struct DispatcherTests {

    // MARK: - tier gating

    @Test("calling a tool outside tier returns refused_by_tier")
    func toolOutsideTierIsRefused() async throws {
        let sink = MemoryAuditSink()
        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: [:],  // empty; even if we had a handler, tier would refuse first
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_vm_delete",
            params: ["vm": "anything"]
        )

        guard case .error(let code, _) = response else {
            Issue.record("expected error response")
            return
        }
        #expect(code == "refused_by_tier")

        // Audit log should still capture the attempt.
        #expect(sink.entries.count == 1)
        #expect(sink.entries.first?["result"] as? String == "refused_by_tier")
    }

    @Test("calling an unknown tool returns tool_not_found")
    func unknownToolReturnsError() async throws {
        let sink = MemoryAuditSink()
        let dispatcher = Dispatcher(
            tier: .full,  // even at full tier, unknown tools fail
            handlers: [:],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_make_coffee",
            params: [:]
        )

        guard case .error(let code, _) = response else {
            Issue.record("expected error response")
            return
        }
        #expect(code == "tool_not_found")
    }

    // MARK: - handler invocation

    @Test("registered handler is invoked when tool is in tier")
    func handlerInvokedInTier() async throws {
        let sink = MemoryAuditSink()

        actor InvocationCounter {
            var count = 0
            func increment() { count += 1 }
        }
        let counter = InvocationCounter()

        let handler = ClosureHandler { _ in
            await counter.increment()
            return .success(["vms": []])
        }

        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: ["secvf_vm_list": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_vm_list",
            params: [:]
        )

        guard case .success(let data) = response else {
            Issue.record("expected success response")
            return
        }
        #expect(data["vms"] != nil)
        let invocationCount = await counter.count
        #expect(invocationCount == 1)
        #expect(sink.entries.first?["result"] as? String == "ok")
    }

    @Test("handler error is captured in response and audit log")
    func handlerErrorCapturedInResponseAndAudit() async throws {
        let sink = MemoryAuditSink()

        let handler = ClosureHandler { _ in
            return .failure(code: "vm_not_found", message: "no VM named 'x'")
        }

        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_vm_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_vm_start",
            params: ["vm": "x"]
        )

        guard case .error(let code, let msg) = response else {
            Issue.record("expected error response")
            return
        }
        #expect(code == "vm_not_found")
        #expect(msg == "no VM named 'x'")

        let auditEntry = sink.entries.first!
        #expect(auditEntry["result"] as? String == "error")
        #expect(auditEntry["error_code"] as? String == "vm_not_found")
    }

    // MARK: - trust boundary markers

    @Test("output-direction tool wraps result with trust_boundary marker")
    func outputDirectionAddsTrustMarker() async throws {
        let sink = MemoryAuditSink()

        // secvf_packets_recent is declared as .output direction in ToolRegistry.
        // The dispatcher must wrap its result with trust_boundary metadata.
        let handler = ClosureHandler { _ in
            return .success(["packets": [["src": "10.0.100.1", "dst": "10.0.100.2"]]])
        }

        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: ["secvf_packets_recent": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_packets_recent",
            params: [:]
        )

        guard case .success(let data) = response else {
            Issue.record("expected success response")
            return
        }
        #expect(data["trust_boundary"] as? String == "vm_output")
        #expect((data["trust_warning"] as? String)?.contains("untrusted") == true)
    }

    @Test("input-direction tool does NOT wrap with trust marker")
    func inputDirectionNoTrustMarker() async throws {
        let sink = MemoryAuditSink()

        // secvf_vm_list is declared as .input direction (host-only).
        let handler = ClosureHandler { _ in
            return .success(["vms": []])
        }

        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: ["secvf_vm_list": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_vm_list",
            params: [:]
        )

        guard case .success(let data) = response else {
            Issue.record("expected success response")
            return
        }
        #expect(data["trust_boundary"] == nil)
        #expect(data["trust_warning"] == nil)
    }

    // MARK: - duration timing

    @Test("audit log records duration_ms")
    func auditRecordsDuration() async throws {
        let sink = MemoryAuditSink()

        let handler = ClosureHandler { _ in
            // Simulate 50ms of work.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .success([:])
        }

        let dispatcher = Dispatcher(
            tier: .readOnly,
            handlers: ["secvf_vm_list": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        _ = await dispatcher.dispatch(tool: "secvf_vm_list", params: [:])

        let duration = sink.entries.first?["duration_ms"] as? Int ?? 0
        // Should be at least 40ms (some scheduling slop).
        #expect(duration >= 40)
    }
}

// MARK: - Test helper handler

/// A handler whose behavior is provided by a closure. Pure test concern.
final class ClosureHandler: ToolHandler, @unchecked Sendable {
    private let closure: @Sendable ([String: Any]) async -> ToolHandlerResult

    init(_ closure: @escaping @Sendable ([String: Any]) async -> ToolHandlerResult) {
        self.closure = closure
    }

    func invoke(params: [String: Any]) async -> ToolHandlerResult {
        await closure(params)
    }
}
