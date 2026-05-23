# Weekly Code Review — 2026-05-17

Window: 2026-05-11 → 2026-05-17 (~100 commits, 16 PRs #7–#22, all merged)
Focus: Pre-launch security audit (PR #7), MCP wrapper for Claude (PR #8 + follow-on), tactical UI redesign (PRs #9, #10, #13–#20), vsock scope tightening (PR #21).
Reviewer: scheduled `daily-code-review` task (Claude).

This is a fresh-eyes audit of the past week's diff (`7dca132..HEAD`). Carryover items from [`CODE_REVIEW_2026-05-10.md`](CODE_REVIEW_2026-05-10.md) are re-verified up front; new issues follow.

---

## Activity

| PR | Title | Notes |
|----|-------|-------|
| [#7](https://github.com/DaxxSec/SecVF/pull/7) | Pre-launch audit: 6-batch host-OpSec + correctness sweep | merged 2026-05-12 |
| [#8](https://github.com/DaxxSec/SecVF/pull/8) | Planning: post-audit todo + secvf-mcp design doc | merged 2026-05-12 |
| [#9](https://github.com/DaxxSec/SecVF/pull/9) | Tactical UI redesign — tabbed library, live metrics, AI Sandbox tree | merged 2026-05-13 |
| [#10](https://github.com/DaxxSec/SecVF/pull/10) | Tactical UI palette + mockup-parity layout | merged 2026-05-13 |
| [#12](https://github.com/DaxxSec/SecVF/pull/12) | Filter expression parser — closes #11 | merged 2026-05-13 |
| [#13–#19](https://github.com/DaxxSec/SecVF/pulls?q=is%3Apr+is%3Aclosed) | Detail-card, sidebar, toolbar, packet-window restyles + Xcode target wiring | all merged 2026-05-13 |
| [#20](https://github.com/DaxxSec/SecVF/pull/20) | fix(ui): three layout regressions from the typography pass merge | merged 2026-05-14 |
| [#21](https://github.com/DaxxSec/SecVF/pull/21) | **Scope vsock exec channel to AI Sandbox VMs only** | merged 2026-05-14 (security) |
| [#22](https://github.com/DaxxSec/SecVF/pull/22) | docs: wire redesign-mockup screenshots into README | merged 2026-05-14 |
| (direct to main) | secvf-mcp Swift package: framing, dispatcher, discovery handlers, lifecycle handlers, pattern matcher, FileAuditSink, confirmation hook, detonate composite — ~1880 LOC in `SecVFMCPCore` + ~16 test files | 2026-05-11..12 |
| (direct to main) | website/wiki extracted to private `daxxsec.tech` repo (cleanup) | 2026-05-11 |

LOC delta in the app tree alone: ~+5,923 / −588 across 32 files. MCP package adds another ~1,880 LOC of Swift + tests. Tests-to-code ratio for the week is healthy (10+ new test files in the app tree, 12+ in the MCP package).

---

## Carryover from 2026-05-10

| Item | Status | Evidence |
|------|--------|----------|
| **M1** — `bootAISandboxSession` catch arm leaves `activeSandboxSession` pointing at destroyed session | **NOT fixed** | `AppDelegate.swift:2719-2731` — catch arm clears `activeSandboxVMId`, calls `session.destroy()`, but never sets `self.activeSandboxSession = nil`. Bug is unchanged from last week. |
| **L1** — `VsockExecBridgeManager.startBridge` race | **NOT fixed** | `VsockExecBridge.swift:540-571` — `bridge.start()` still runs **outside** the lock. Two concurrent callers for the same `vmId` can each null out the slot, drop the lock, then race `unlink()`+`bind()` on the same `/tmp/secvf-exec-<UUID>.sock`. The install gate at line 565 is too late — by then the UDS file has already been torn up. Last week's recommendation (install-before-start) not yet applied. |
| **L2** — `provision-macos-vm.sh` STREAM allowlist comment overstates the metachar gate | **NOT fixed** | `scripts/provision-macos-vm.sh:303-306` — comment still says "*Without these, `bash -c` can't be tricked into running a second command — a basename match really IS what executes.*" Still wrong on `dtrace`: `STREAM dtrace -c /usr/bin/whoami -n 'BEGIN{exit(0);}'` passes both the metachar gate (no `; & \| \` $ < > ( )` or newline) and the basename gate (`dtrace`), and `dtrace -c` spawns its argument as root. The primary host-side allowlist still defends the channel; this is a doc-honesty fix, not a security regression. |
| **Guest→host write surfaces section in SECURITY.md** | **fixed** | `docs/SECURITY.md` §7 "VirtioFS Workspace Direction" — explicitly maps the three shares, marks `/workspace` as the only writable share, and tells host consumers to treat its contents as untrusted input. Recommendation satisfied. |
| **Test for `activeSandboxBootInFlight` gate** | **not addressed** | No new test covers this. The gate at `AppDelegate.swift:2492-2499` is untested; gate-removal regressions would not be caught. |

**Bottom line**: three of last week's five recommendations are still open. M1 is the cheapest (one line). L1 is the most worth fixing (race surface around a security-relevant control channel). L2 is documentation truthfulness.

---

## Verified fixed (pre-launch audit, PR #7 batches 1–5)

The 6-batch sweep landed in commits `8d81402..0d2708f`. Spot-checks:

| Batch | Item | Verified |
|-------|------|----------|
| B1 | Kali router `FORWARD` policy → `DROP` + explicit interface ACCEPT | `scripts/kali-router-setup.sh` (commit 109d534) — boot-time re-apply block also updated |
| B4 | Single-writer audit log via `AVFAuditLog` | `SecVF/AVFPaths.swift:AVFAuditLog`, callers `SecVFError.logToAudit`, `VMSecurityMonitor.writeToSecurityLog`, `VirtualNetworkSwitch.logToFile` all route through it (commit 0d2708f) |
| B9 | Duplicate packet-analysis window | `VMLibraryWindowController` now posts `.openPacketAnalysis` notification; `AppDelegate` owns the singleton (commit 0d2708f) |
| H5 | dnsmasq backup overwrite on second `start` | `scripts/kali-fakenet-setup.sh` — backup write now guarded by `[[ ! -f backup ]]`; stop path restores backup (commit 109d534) |
| H11 | `macos-network-setup.sh` clobbering host primary interface | sysctl `hw.model` check at top + `SECVF_FORCE_HOST_NETSETUP=1` override (commit 109d534) |
| (Linux freeze) | Kali (and all Linux) VM freeze at 100% download — modal runloop bug | `commit 748fae0` |
| B6/B7 | tshark stream protocol + DistributedNotificationCenter scope — investigated, no functional change documented | acceptable; commit message explains why each was downgraded |

The audit doc (`docs/PRE-LAUNCH-AUDIT.md`) tracks the disposition of each B/H finding and is current as of `0d2708f`.

---

## Verified fixed (PR #21 — vsock scope)

PR #21 removes two unconditional vsock attachments from the generic VM startup path in `AppDelegate.createVirtualMachine()`:

1. **`VZVirtioSocketDeviceConfiguration` attach** — previously every macOS guest carried a vsock device on port 2222. Now only AI Sandbox VMs (which build their config via `AISandboxMacVMConfiguration`) ship with it.
2. **`VsockExecBridgeManager.startBridge()` call** — already inert after change (1) (the bridge guards on `vm.socketDevices.first is VZVirtioSocketDevice`), but removing the explicit call keeps the wiring "one config change away" from re-exposing the channel.

VirtioFS shares were already AI-Sandbox-only. With this change, both cross-boundary surfaces (VirtioFS workspace + vsock exec bridge) are structurally confined to the AI Sandbox path. **Good security work** — closes a latent surface that mattered for hypothetical macOS-malware-analysis VMs.

No test added to lock the structural invariant ("no socketDevices on non-sandbox macOS configs"). One small XCTest using `VZMacPlatformConfiguration` against a fake bundle would prevent future re-introduction.

---

## New code under audit: `secvf-mcp` Swift package

A new ~1,880-LOC Swift package at `SecVF/cli/Sources/SecVFMCPCore/` plus an executable target at `SecVF/cli/Sources/secvf-mcp/` implementing an MCP server that exposes SecVF state and operations to Claude (or any MCP client). This is the largest new attack-surface added this week, so it gets the most attention.

**Design**: 5-layer defense (see `docs/MCP-WRAPPER-DESIGN.md`).

| Layer | Implementation | Verdict |
|-------|---------------|---------|
| 1. Tier gate | `Dispatcher.dispatch` checks `descriptor.isExposed(at: tier)` against `ToolRegistry.allDescriptors` BEFORE handler lookup. Tools not in the current tier literally cannot be invoked. | **Solid**. Prompt-level injection cannot bypass — the tool's name does not resolve. |
| 2. Handler lookup | Standard dictionary lookup; missing handler emits `no_handler` error and audit-logs it. | OK |
| 3. Pattern matcher | `CommandPatternMatcher.defaultMatcher()` ships 16 regex patterns in 6 categories (egress, exfil, persistence, privesc, self-mod, destructive). | OK — see notes below |
| 4. Confirmation hook | `ConfirmationDecision` enum, abstain treated as deny for safety. Built-ins: `AlwaysAllowHook`, `AlwaysDenyHook`. `ScriptHook` lives in the executable target. | **Safe default** (abstain→deny). |
| 5. Trust boundary wrapping | `ToolDirection.output` tools get `trust_boundary: "vm_output"` + a `trust_warning` string injected into the response payload before audit-log. | OK; depends on the consuming agent's prompt actually respecting it. |

**Audit log** — per-call JSONL, written synchronously, O_APPEND, 0o600 perms, 0o700 dir, single per-process serial queue. Mirrors the main app's `AVFAuditLog`. Cross-process writers (CLI + app + tests) serialize at the kernel for writes ≤ PIPE_BUF. **Forensically sound** for the documented scenarios.

### MCP-1 — `secvf_detonate_start` lives in `.workflow` (safe-mutate), but internally clones a VM

**File**: `SecVF/cli/Sources/SecVFMCPCore/ToolDescriptor.swift:38-46`, `ToolRegistry.swift:152-169`
**Severity**: Low (design choice flag, not a bug)

`ToolCategory.workflow.minimumTier == .safeMutate`. So an MCP client running at the *default* tier can call `secvf_detonate_start`, which (per its description) "clones template VM, mounts sample, boots, captures, snapshots". Cloning a VM bundle is destructive on disk and **`secvf_vm_clone` itself is categorized as `.destructive`** (requires `.full` tier).

The current PoC handler doesn't actually wire up the clone — it just returns a `run_id` and stays in `.queued` — so the gap is latent. But when the workflow runner gets implemented (the file comment at line 156 — "*In production: kick off the actual workflow asynchronously via a VMWorkflowRunner that drives the bridges through boot → capture → snapshot → analyze*"), an agent running at the default tier will be able to trigger disk allocation that the explicit `.destructive` category was meant to gate behind `.full`.

This is a deliberate UX decision (gating detonation behind `.full` would defeat the primary use case of SecVF + Claude), but the inconsistency with `secvf_vm_clone` deserves a comment in `ToolDescriptor.swift` or a paragraph in `MCP-WRAPPER-DESIGN.md`.

**Recommendation**: either (a) gate `.workflow` at `.full` with a `--allow-detonate-at-safe-mutate` opt-in CLI flag, or (b) keep current behavior and document the rationale — "detonate is the primary product feature; the destructive operation is bounded to a designated *template* VM with a designated *sample path*, both authored by the operator, so it isn't equivalent to the agent being able to clone arbitrary VMs."

### MCP-2 — `MCPAuditLogger.log` silently drops the entry on JSON serialization failure

**File**: `SecVF/cli/Sources/SecVFMCPCore/AuditLog.swift:86-93`
**Severity**: Low (forensic integrity hole; theoretical in normal use)

```swift
guard let data = try? JSONSerialization.data(
    withJSONObject: entry,
    options: [.sortedKeys]
),
      let line = String(data: data, encoding: .utf8) else {
    return       // ← entry silently lost
}
```

If `entry` (built from `params: [String: Any]`) contains a non-JSON-serializable value, the audit line never gets written and the caller never knows. Same loss in `cap()` at line 99 — `try?` swallows the error and returns the original `params`, which then fails again at line 86.

In normal use this can't happen — params arrive from JSON-RPC, so they're already JSON-roundtrippable. But the dispatcher passes the raw `[String: Any]` through trust-boundary wrapping which mutates the dict (`payload["trust_boundary"] = ...`); any later code path that injects non-JSON types would silently break audit. Forensic logs are exactly the thing you want to fail noisily.

**Recommendation**: on serialization failure, write a fallback minimal line via the sink and `NSLog` the failure:

```swift
guard let data = try? JSONSerialization.data(...) else {
    let fallback = """
    {"ts":"\(dateFormatter.string(from: Date()))","tool":"\(tool)","result":"audit_serialize_failed","client_pid":\(clientPid)}
    """
    sink.append(jsonLine: fallback + "\n")
    NSLog("[MCPAuditLogger] serialize failed for tool=%@", tool)
    return
}
```

### MCP-3 — PatternMatcher rule `privesc-sudo` will fire on benign mentions

**File**: `SecVF/cli/Sources/SecVFMCPCore/PatternMatcher.swift:127-131`
**Severity**: Informational (intentional per design doc; flagged for operator UX)

`\bsudo\b` matches the word "sudo" anywhere in the command, including:

- `echo "use sudo to install"`
- `cat /var/log/sudo.log`
- `grep sudoers /etc/passwd`
- `find / -name 'sudo*'`

Per the design doc's "broad, not narrow" stance this is intentional — the matcher exists to escalate-for-review, not to be precise. But the confirmation hook will be invoked for many benign commands, which in interactive deployments translates to alert fatigue. Worth noting in `MCP-WRAPPER-DESIGN.md` so operators don't expect a low false-positive rate.

A small refinement (still broad) would be `\bsudo\s+[^|;&\n]*\b` — only matches when `sudo` is followed by an argument. That still catches `sudo command...` invocations and rejects `echo sudo` and `cat sudo.log`.

### MCP-4 — `destructive-rm-root` misses several common destructive idioms

**File**: `SecVF/cli/Sources/SecVFMCPCore/PatternMatcher.swift:154-159`
**Severity**: Informational (acknowledged tradeoff; matcher is "broad, not narrow" by design)

The pattern is `\brm\b\s+-[a-zA-Z]*r[a-zA-Z]*\b\s+(/|/etc|/usr|/var|/home|~)`. Misses:

- `cd /etc && rm -rf .` — no path arg to `rm`
- `rm -rf *` in $HOME — no leading slash
- `find / -delete`
- `dd if=/dev/null of=/etc/passwd` — `dd` only flagged for `/dev/zero` and `/dev/urandom`

The right framing is "matcher catches the obvious cases; tier+confirmation+audit catches what matcher misses." The design doc says this explicitly. **Not a fix request** — flagged so the next reviewer doesn't expect the matcher to be a hardening layer it isn't.

---

## Other observations

### `AppDelegate.swift` LOC growth

Last week's review flagged ~2,700 LOC; current count is **2,733** lines. The vsock-scope change in PR #21 trimmed the generic VM path slightly, but the AI Sandbox boot + IPSW + manifest paths are still inline. Splitting `AISandboxLifecycle.swift` and `IPSWDownload.swift` out remains the right move; not blocking.

### `VMLibraryWindowController.swift` exploded

The tactical UI redesign added **~+2,036 lines** to `VMLibraryWindowController.swift` (from ~2,600 to ~4,600). It now owns the table redesign, the AI Sandbox tab, the detail card, the sidebar filter rail, the toolbar, the empty states, the live metrics, the per-row sparkline, the falling-packets overlay, and the connection overlay. This file is by far the highest auditability risk in the tree — large enough that targeted reviewers will struggle to load the whole picture into working memory.

Test coverage is healthy (10+ new test files for the tactical UI components), but the controller itself is the orchestrator and the orchestration logic isn't well-isolated for testing. **Recommendation** (informational, not blocking 1.0): plan a refactor into `VMTableViewController`, `DetailCardViewController`, `SidebarFilterController` post-launch.

### `PacketFilter.swift` parser (PR #12)

574 LOC of expression-parser code with 223 LOC of tests. Quick scan shows hand-rolled recursive descent over tokenized input. Operates on packet metadata (host-side, parsed from already-captured packets), so it's a *display* filter, not a network filter — no path from this code to root or host execution. Low risk; not deep-audited.

### Direct-to-main commits

Several large commits landed direct to main (the MCP wrapper TDD sequence `192ed49..81b483c` from 2026-05-11, plus the website/wiki extraction `76c881f` and post-audit batches `8d81402..f9b96fe..90f1941..109d534..0d2708f`). Solo-dev rhythm is fine for this stage, but **PR-#21 is a recent counterexample where the PR description was particularly valuable** (it cites the purple-team proposal that motivated the change and the test plan). Keep that style for security-relevant changes; bypassing PRs for those loses both the doc trail and the human-review backstop. The pre-launch audit was at least bundled into PR #7 as a single review unit.

### Test coverage for the carryover items

Three open items from last week, none with a new test:
- M1 (memory leak after failed boot) — would need a VZ mock seam.
- L1 (startBridge race) — testable today, just needs two concurrent `startBridge` callers in an XCTest.
- L2 (provision-macos-vm.sh) — testable via a shell harness that feeds `STREAM dtrace -c "/bin/whoami"` to the handler and asserts the agent rejects it (which it currently does *not*, modulo the host-side primary gate).

A regression test for L1 would prevent the race from being silently reintroduced if the lock-and-install pattern gets simplified later.

---

## Documentation updates

No doc changes are required for this review's findings. Two updates are *worth* making but are optional:

1. **`docs/PRE-LAUNCH-AUDIT.md`** — could append a "Post-audit (open)" section listing M1/L1/L2 from this review as known-deferred. Currently the audit doc reads as "all batches landed", which is true; the carryover here is from a *separate* review track.
2. **`docs/MCP-WRAPPER-DESIGN.md`** — could add a paragraph explaining (a) why `.workflow` is at `.safeMutate` while `.destructive` (clone) is at `.full`, and (b) the matcher's intentional "broad, not narrow" stance (current doc covers the latter only in passing).

Neither is blocking. Marking both as nice-to-haves for the next iteration.

---

## Recommended action items (ranked)

| Priority | Item | Effort |
|---|---|---|
| 1 | **M1** (carryover) — add `self.activeSandboxSession = nil` in `bootAISandboxSession`'s catch arm | 1 line |
| 2 | **L1** (carryover) — serialize `startBridge` correctly (install-before-start or hold lock across start) | ~10 lines |
| 3 | **MCP-2** — fallback audit line on JSON serialization failure + `NSLog` diagnostic | ~10 lines |
| 4 | **MCP-1** — document the `.workflow` tier choice in `MCP-WRAPPER-DESIGN.md` (or change to `.full`) | doc paragraph or 1 enum-case |
| 5 | **L2** (carryover) — rewrite the misleading STREAM comment in `provision-macos-vm.sh`; optionally drop `dtrace` from the basename allowlist and require `-s file.d` | 1 paragraph + optional ~5 lines |
| 6 | Add a regression test for the `startBridge` race (L1) — 2 concurrent callers, assert exactly one UDS file ends up bound | ~30 lines |
| 7 | Add a structural-invariant test for PR #21 — non-sandbox macOS config has empty `socketDevices` | ~15 lines |

None of these block a 1.0 launch. M1 and L1 are the closest to user-visible impact (memory leak and a control-channel race respectively). MCP-2 is the highest-leverage cheap fix (forensic-integrity hole that's currently theoretical but cheap to close).

---

## Sign-off

- **No new critical or high-severity issues** found in this week's diff.
- **Three carryover items from 2026-05-10 still open** (M1, L1, L2). None block launch; M1 is one line.
- **MCP wrapper introduces a well-designed 5-layer defense** with synchronous audit logging and hard tier-gating. Four low/informational items recorded above for next iteration.
- **PR #21 (vsock scope) is good security work** and closes a latent surface.
- **SECURITY.md §7 added** — last week's guest→host write-surface recommendation is satisfied.
- **Pre-launch audit batches 1–5 (PR #7) all verified in code**.
