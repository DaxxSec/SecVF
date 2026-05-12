//
//  ScriptHook.swift
//  SecVFMCPCore
//
//  ConfirmationHook backed by a user-provided executable. Lets operators
//  wire arbitrary policy: an osascript dialog, a Slack DM, an audit
//  webhook, a hardened "always deny on this list" — anything they can
//  express in a script.
//
//  Protocol:
//    - stdin   ← JSON object {tool, matches: [{id, category, description}]}
//    - exit 0  → approve
//    - exit N  → deny; stderr is captured and surfaced in the deny reason
//    - timeout → deny with "hook timed out after Ns"
//
//  Params are NOT passed on stdin by default to avoid leaking sample paths
//  or other sensitive values into hook implementations the operator may
//  not fully trust. The tool name + matched-pattern IDs are enough for a
//  policy decision in most cases.
//

import Foundation

public struct ScriptHook: ConfirmationHook {
    public let scriptPath: String
    public let timeoutSeconds: Int

    public init(scriptPath: String, timeoutSeconds: Int = 30) {
        self.scriptPath = scriptPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func evaluate(
        tool: String,
        params: [String: Any],
        matches: [DangerPattern]
    ) async -> ConfirmationDecision {
        // Preflight: script must exist + be executable.
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return .deny(reason: "confirmation script not found: \(scriptPath)")
        }
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            return .deny(reason: "confirmation script not executable: \(scriptPath)")
        }

        // Build the stdin payload — small, no params leakage by default.
        let payload: [String: Any] = [
            "tool": tool,
            "matches": matches.map { p -> [String: Any] in
                [
                    "id": p.id,
                    "category": p.category.rawValue,
                    "description": p.description,
                ]
            },
        ]
        guard let stdinData = try? JSONSerialization.data(withJSONObject: payload) else {
            return .deny(reason: "could not serialize confirmation payload")
        }

        // Run the script with a wall-clock timeout via Process + a Task.
        return await runWithTimeout(stdinData: stdinData)
    }

    private func runWithTimeout(stdinData: Data) async -> ConfirmationDecision {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardError = stderrPipe
        proc.standardOutput = stdoutPipe

        // Bridge Process termination → async via terminationHandler.
        // continuationFired flag is here because we need to guarantee resume
        // happens exactly once even if terminationHandler races with timeout.
        let waitResult: WaitResult = await withCheckedContinuation { continuation in
            let fired = ContinuationFiredFlag()

            proc.terminationHandler = { p in
                if fired.tryFire() {
                    continuation.resume(returning: .completed(status: p.terminationStatus))
                }
            }

            do {
                try proc.run()
            } catch {
                if fired.tryFire() {
                    continuation.resume(returning: .launchFailed(error.localizedDescription))
                }
                return
            }

            // Write the payload and close stdin so the hook can exit.
            stdinPipe.fileHandleForWriting.write(stdinData)
            try? stdinPipe.fileHandleForWriting.close()

            // Arm timeout — runs concurrently with terminationHandler.
            let timeoutSeconds = self.timeoutSeconds
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if fired.tryFire() {
                    // Terminate the still-running process so its handler
                    // doesn't fire after we've already resumed.
                    proc.terminationHandler = nil
                    if proc.isRunning {
                        proc.terminate()
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if proc.isRunning {
                            kill(proc.processIdentifier, SIGKILL)
                        }
                    }
                    continuation.resume(returning: .timedOut)
                }
            }
        }

        switch waitResult {
        case .launchFailed(let msg):
            return .deny(reason: "could not launch confirmation script: \(msg)")

        case .timedOut:
            return .deny(reason: "confirmation hook timed out after \(timeoutSeconds)s")

        case .completed(let status):
            if status == 0 {
                return .approve
            }
            // Surface stderr (bounded) as the deny reason.
            let stderr = stderrPipe.fileHandleForReading.availableData
            let reason = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            let bounded = String(reason.prefix(512))
            return .deny(
                reason: bounded.isEmpty
                    ? "confirmation hook denied (exit \(status))"
                    : "exit \(status): \(bounded)"
            )
        }
    }

    private enum WaitResult: Sendable {
        case completed(status: Int32)
        case timedOut
        case launchFailed(String)
    }
}

/// Single-use atomic flag — guarantees the CheckedContinuation resumes
/// exactly once even when terminationHandler races with the timeout task.
private final class ContinuationFiredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns true to the FIRST caller; subsequent callers get false.
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
