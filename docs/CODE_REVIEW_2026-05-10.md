# Weekly Code Review — 2026-05-10

Window: 2026-05-03 → 2026-05-10 (17 commits, 6 PRs, all merged)
Focus: AI Sandbox macOS VM landed end-to-end (base build → session clone → vsock exec → CLI)
Reviewer: scheduled `daily-code-review` task (Claude)

This is a fresh-eyes audit of the past week's diff (`db95f4c..HEAD` for the post-PR-#6 hotfixes plus the merged PRs). It does NOT re-state issues already captured in [`PR4_REVIEW_FIXES_2026-05-03.md`](PR4_REVIEW_FIXES_2026-05-03.md); those are confirmed-fixed below.

---

## Activity

| PR | Title | Notes |
|----|-------|-------|
| [#1](https://github.com/DaxxSec/SecVF/pull/1) | address all 22 items from CODE_REVIEW_2026-05-03 | merged |
| [#2](https://github.com/DaxxSec/SecVF/pull/2) | aux-storage flock + cancel-and-replace install | merged |
| [#3](https://github.com/DaxxSec/SecVF/pull/3) | close STREAM allowlist bypass + tighten exec-bridge surface | merged |
| [#4](https://github.com/DaxxSec/SecVF/pull/4) | IPSW tracker, distro refresh, AI Sandbox CLI support | merged |
| [#5](https://github.com/DaxxSec/SecVF/pull/5) | PR #4 review fixes (supersession races, BridgeState lifetime, +11) | merged |
| [#6](https://github.com/DaxxSec/SecVF/pull/6) | AI Sandbox `vm start` routes through GUI app | merged |
| (post-#6 hotfixes) | NVMe→VirtioBlock pin, ~/.avf/ workspace move, chmod cloned imgs, VZ main-thread dispatch, provision-script fixes | direct to main |

LOC delta: ~+2,920 / −370 across 18 files. Heaviest: `AppDelegate.swift` (+829), `provision-macos-vm.sh` (+115).

---

## Verified fixed (PR #4 review)

Confirmed in code as of `HEAD`:

| Item | Status | Evidence |
|------|--------|----------|
| C1 — cleanup `defer` race deletes successor's bundle | **fixed** | `AISandboxMacVMConfiguration.swift:388-406` — `wasCancelled` flag gates the defer |
| C2 — `AISandboxInstallTracker` clobbered by superseded run | **fixed** | `AISandboxInstallTracker.swift:62-128` — `currentRunId` + run-scoped no-ops |
| S3 — `bootAISandboxSession()` "already running" race | **fixed** | `AppDelegate.swift:2464,2492-2499` — `activeSandboxBootInFlight` synchronous gate |
| S4 — per-boot UUID rewrites manifest | **fixed** | `AppDelegate.swift:2542-2557` — preserve existing `id` from manifest |
| S5 — storage controller pinned (VirtioBlock everywhere) | **fixed** | `AISandboxMacVMConfiguration.swift:179-184`, `cli/.../VMRunner.swift:149,242` |
| S13 — `BridgeState` lifetime | **fixed** | `VsockExecBridge.swift:407-429` — strong `[state]` capture in both readability handlers |

The `AISandboxInstallTrackerTests.swift` (157 lines, new) covers the supersession case. Worth porting the same pattern to a `bootAISandboxSession` test once VZ-mockable seams exist.

---

## New issues found this week

### M1 — Boot-failure cleanup leaves stale `activeSandboxSession` reference

**File**: `SecVF/AppDelegate.swift:2536, 2573-2585`
**Severity**: Medium (memory leak, not exploitable)

```swift
self.activeSandboxSession = session       // line 2536, BEFORE machine.start()
// ... (manifest write) ...
try await machine.start()                  // line 2564 — can throw
} catch {
    if let vmId = self.activeSandboxVMId {
        VsockExecBridgeManager.shared.stopBridge(vmId: vmId)
    }
    self.activeSandboxVMId = nil
    try? await session.destroy()
    // BUG: self.activeSandboxSession still points at the destroyed session
}
```

If `machine.start()` (or the VirtioFS-share creation, or the manifest write) throws, the catch arm tears down the bundle and stops the bridge but leaves `activeSandboxSession` pointing at the dead session struct. The session retains a `VZVirtualMachine` and a bundle URL whose backing files have been removed.

The next `bootAISandboxSession()` click works because the early "session already running" check at line 2479 requires `state == .running || .starting` — a never-started VM doesn't match. So functionally the user is fine, but the strong reference holds VZ memory until the app exits.

**Fix**: in the catch arm, after `session.destroy()`:

```swift
} catch {
    NSLog("[AISandbox] Boot failed: %@", error.localizedDescription)
    if let vmId = self.activeSandboxVMId {
        VsockExecBridgeManager.shared.stopBridge(vmId: vmId)
    }
    self.activeSandboxVMId = nil
    self.activeSandboxSession = nil   // ← add this
    try? await session.destroy()
    showAlert(title: "AI Sandbox Boot Failed", message: error.localizedDescription)
}
```

---

### L1 — `VsockExecBridgeManager.startBridge` race not fully closed

**File**: `SecVF/VsockExecBridge.swift:540-573`
**Severity**: Low (theoretical; VM lifecycle events are main-thread-serialized in practice)

The doc comment claims:

> we now serialize the whole build-and-install path under the lock and stop any prior bridge for the same vmId before installing the new one

…but `bridge.start()` (which `unlink()`s and re-`bind()`s `/tmp/secvf-exec-<UUID>.sock`) runs **outside** the lock. Two concurrent callers for the same `vmId` can each:

1. Take lock, `bridges[vmId] = nil`, drop lock
2. `prior?.stop()` (whoever has it)
3. `bridge.start()` → `unlink(socketPath)` then `bind` — second caller's unlink kills first caller's just-created UDS file mid-listen

Then they race the install gate at line 565. Whoever loses the install gate calls `bridge.stop()` on their own bridge — but the winner's UDS file may already have been unlinked by the loser before the loser realized it was the loser.

In practice all `startBridge` callers are on `@MainActor`-attached lifecycle paths (`bootAISandboxSession`, VM start notifications), so reentrancy is unlikely. But the assertion in the comment overstates the guarantee.

**Fix**: serialize start under the lock (or check `bridges[vmId] != nil` before constructing):

```swift
func startBridge(vmId: UUID, vmName: String, vm: VZVirtualMachine) {
    guard vm.socketDevices.first is VZVirtioSocketDevice else { return }
    lock.lock()
    if let prior = bridges[vmId] {
        bridges[vmId] = nil
        lock.unlock()
        prior.stop()
        lock.lock()
    }
    let bridge = VsockExecBridge(vmId: vmId, vmName: vmName, vm: vm)
    bridges[vmId] = bridge   // install BEFORE start so a racer sees it
    lock.unlock()
    do {
        try bridge.start()
    } catch {
        lock.lock()
        if bridges[vmId] === bridge { bridges[vmId] = nil }
        lock.unlock()
        NSLog("[VsockExecBridgeManager] %@ start failed: %@", vmName, error.localizedDescription)
    }
}
```

---

### L2 — STREAM allowlist defense-in-depth gap (and misleading comment)

**File**: `scripts/provision-macos-vm.sh:303-332`
**Severity**: Low (genuine primary defense — host-side peer-uid gate — is unaffected; this is depth-of-defense correctness)

The metacharacter denylist blocks `; & | ` ` $ < > ( )` + newline. It does **not** block `* ? [ ] { } ' " \`. More important, the allowed binary `dtrace` accepts `-c <command>` to spawn arbitrary commands as root:

```
STREAM dtrace -c "/usr/bin/whoami" -n 'BEGIN { exit(0); }'
```

This passes the metachar check (no chars in the denylist), passes the basename check (`dtrace`), and then `bash -c` invokes dtrace which forks the `-c` argument as root. So the **comment's claim** —

> Without these, `bash -c` can't be tricked into running a second command — a basename match really IS what executes.

— is wrong on `dtrace`. The same is true for `log` (`log stream --predicate <foo>` is fine, but `log` has many subcommands and is a complex CLI) and arguably `ktrace`.

**Why this is not a critical finding**: the *primary* gate is the host-side `getpeereid`+allowlist check on `/tmp/secvf-exec-<UUID>.sock`. Anyone reaching the STREAM handler is already on the allowlist, which means they can already do anything the SecVF process can do (read/write `~/.avf/`, stop VMs, etc.). Root-in-VM ≠ privilege escalation when the VM is the threat-bearing layer.

**Fix options**:

1. **Tighten the comment** to say: "primary defense is the host-side peer-uid allowlist; this metachar/basename gate is depth-of-defense and is intentionally porous against the allowed binaries' own arg surfaces (e.g. `dtrace -c`, `log <subcommand>`)."
2. **Drop `dtrace` from the STREAM allowlist** and require the canonical pattern the comment already recommends: drop probes into `/usr/local/share/secvf-ai-sandbox/*.d` and invoke `dtrace -s file.d` only. That tightens the allowlist to: `dtrace -s, fs_usage, ktrace, top, vm_stat, memory_pressure, sysctl, tail, log`. Implementing the `-s file.d`-only constraint requires a second token check rather than basename.

Option 1 is one-line; option 2 is the correct hardening but adds parsing complexity.

---

### Informational — guest→host write surface

**File**: `SecVF/AISandboxMacVMConfiguration.swift:202` (`/workspace` VirtioFS share, `readOnly: false`)
**Severity**: Informational (intentional; flagged for `SECURITY.md`)

Guest code (running as `ai-sandbox-agent`, UID 601, non-admin in the guest) can write arbitrary content to host's `~/.avf/AISandbox/workspace/`. Host code that *reads* from this directory must treat the contents as untrusted:

- `provision-complete.json` — parsed via `JSONSerialization` (safe)
- DTrace JSONL telemetry — parsed by host monitoring (verify any consumer doesn't `eval`/shell-interpret)
- Staged Claude Code tarball — pre-staged by host via `npm pack`, *then* picked up by guest. If a guest wrote a malicious tarball before the host re-stages, the next provision run could install it. Mitigation: provision script uses `npm install -g "$AGENT_TARBALL"` against the staged path, and provision happens once before the bundle is sealed; subsequent session VMs are CoW clones of the sealed base and never re-provision.

**Recommendation**: add a section to `docs/SECURITY.md` listing the trust boundaries (host trusts guest = no; guest trusts host = yes) and the explicit write-surfaces the host must defensively read.

---

## Other observations

- **`AppDelegate.swift` is now ~2700+ LOC** — the AI Sandbox boot, IPSW download, distro refresh, manifest backfill, and download delegate all live there. A future refactor splitting `AISandboxLifecycle.swift` and `IPSWDownload.swift` out would make this auditable. Not blocking; flag for the next reviewer.
- **No tests for the `bootAISandboxSession` race** even though C2's tracker race got one. The path is hard to drive without VZ mocks; a small unit test of just `activeSandboxBootInFlight` toggling would still catch reintroduction of the gate-removal mistake.
- **`provision-macos-vm.sh` is `set -euo pipefail`** but several lines silently accept failure with `2>/dev/null || true` (mdutil, tmutil, the chmod/chown on VirtioFS shares, dscl createhomedir). All are intentional per inline comments. No issue — flagged for awareness.
- **Homebrew-via-curl-pipe-bash** at script line 98 is the standard install method but is a supply-chain risk in a freshly-provisioned VM. The VM is destroyed after each session so persistence is bounded; mention in `SECURITY.md` if not already.

---

## Recommended action items (ranked)

| Priority | Item | Effort |
|---|---|---|
| 1 | M1 — add `self.activeSandboxSession = nil` in `bootAISandboxSession`'s catch arm | 1 line |
| 2 | L1 — serialize `startBridge` under the lock or install-before-start | ~10 lines |
| 3 | L2 — at minimum, correct the comment in `provision-macos-vm.sh` to describe defense-in-depth honestly | 1 paragraph |
| 4 | Add `docs/SECURITY.md` section on guest→host write surfaces | ~30 lines |
| 5 | Add a unit test for the `activeSandboxBootInFlight` gate | ~20 lines |

None of these block any merged PR. M1 is the closest to user-visible behavior (memory leak after a failed boot).

---

## Sign-off

All PR-#4-review critical/high items confirmed fixed in code.
No new critical or high issues found this week.
Three new low/medium issues recorded above for next-iteration follow-up.
