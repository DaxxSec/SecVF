# PR #4 — Issues & Proposed Fixes

Source review: `/code-review` of [DaxxSec/SecVF#4](https://github.com/DaxxSec/SecVF/pull/4)
Date: 2026-05-03
Branch under review: `feat/ipsw-tracker-distro-refresh-sandbox-cli` (head `0527b6c`'s parent)
Reviewer: Claude (PR diff inspection only — no runtime probe yet)

This file is the merge-blocking checklist for PR #4 plus follow-up items.
Order is the order to apply them in.

---

## Critical (block merge)

### C1 — Cleanup `defer` races against task supersession; deletes an in-flight install's bundle

**File**: [`SecVF/AISandboxMacVMConfiguration.swift`](../SecVF/AISandboxMacVMConfiguration.swift) lines ~371–376
**Reachable when**: user double-clicks `Tools → Create AI Sandbox VM…` (the same superseded-run path that PR #2 set up cancel-and-replace for).

**The race**:

PR #4 added:

```swift
var installSucceeded = false
defer {
    if !installSucceeded {
        try? FileManager.default.removeItem(at: bundle.url)
    }
}
```

The defer is scoped to the function instance, not to the bundle path. Two task instances hitting the same `AISandboxDefaults.baseBundle` path can interleave:

```
Click 1
  └── Task A starts                              ─┐
        bundle.create()                           │
        flock preflight                           │
        await VZMacOSRestoreImage.image(from:)    │   (long; suspends)
                                                  │
Click 2 — main thread                             │
  prior.cancel()                                  │
  modal "Replace existing bundle?" → Delete       │
  FileManager.removeItem(baseBundle)  ←─ sync     │
  AISandboxInstallTracker.shared.begin()          │
                                                  │
Task B starts                                     │   (concurrent with A)
  bundle.create()         ← clean dir, OK         │
  ...                                             │
                                                  │
Task A resumes from suspended await ─────────────┘
  try Task.checkCancellation()    ← THROWS
  catch CancellationError fires
  defer fires:
      FileManager.removeItem(bundle.url)  ← deletes Task B's bundle
                                            mid-install
```

The window where this lands varies but is wide: the suspending awaits are
`VZMacOSRestoreImage.image(from:)`, the `installer.install` continuation,
and any of the `Task.checkCancellation()` hops. Anywhere Swift can resume
A *after* B has reached `bundle.create()`, the cleanup deletes B's files.

**Why the existing F1 race amplifies this**: PR #2's CancellationError catch arm
unconditionally calls `AISandboxInstallTracker.shared.fail(with: "cancelled")`
+ `reset()` (see C2 below). With C1 added, the tracker is also wrong, so the
user sees no error UI for an install that is silently being corrupted.

**Proposed fix** — gate the cleanup on cancellation explicitly, not on the
catch-all "didn't reach the success line":

```swift
let bundle = AISandboxVMBundle(url: bundleURL)
guard !bundle.exists else {
    throw AISandboxVMError.bundleAlreadyExists(bundleURL)
}
try bundle.create()

// Only clean up on a *fatal* failure inside this task's own flow.
// A CancellationError means the user clicked again; a later task already
// owns this bundle path, so we MUST NOT touch the filesystem on cleanup.
var installSucceeded = false
var wasCancelled = false
defer {
    if !installSucceeded && !wasCancelled {
        try? FileManager.default.removeItem(at: bundle.url)
    }
}

do {
    try Self.assertAuxStorageNotExternallyLocked(at: bundle.auxStorageURL)
    try Task.checkCancellation()
    // ... rest of install
    installSucceeded = true
    return bundle
} catch is CancellationError {
    wasCancelled = true
    throw CancellationError()
}
```

Pair with C2 below — once the tracker uses run-ids, the AppDelegate catch
arm becomes a no-op (the superseded run can't clobber tracker state) and a
CancellationError-signaled cleanup-skip is safe.

**Test**:

```swift
// SecurityPrimitivesTests or new AISandboxInstallerTests
func testCancelledInstallDoesNotDeleteSucceedingInstallsBundle() async throws {
    // Hard to integration-test against VZ; the targeted unit test here is
    // "the cleanup defer skips on CancellationError". Build a fake installer
    // that throws CancellationError after bundle.create(); assert
    // FileManager.fileExists(atPath: bundle.url.path) is true after the
    // throw propagates.
}
```

---

### C2 — `AISandboxInstallTracker` clobbered by superseded install's cancel arm (PR review F1, still unfixed)

**File**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) lines ~2087–2091
**Reachable when**: same trigger as C1.

**The bug** (reproduced verbatim from `docs/PR_REVIEW_2026-05-03.md` F1, included for completeness):

1. Click 1 → task A → `tracker.begin()` → phase = `.installing`
2. Click 2 → cancels A → `tracker.begin()` → phase reset to `.installing` for run B
3. Task A's `try Task.checkCancellation()` throws → catch arm runs:

   ```swift
   } catch is CancellationError {
       NSLog("[AISandbox] Install cancelled (likely superseded by a later click)")
       await MainActor.run {
           AISandboxInstallTracker.shared.fail(with: "cancelled")
           AISandboxInstallTracker.shared.reset()
       }
   }
   ```

4. The `MainActor.run` is queued *after* step 2's `begin()`. It overwrites
   task B's tracker state — phase goes to `.failed` then `.idle` — so the
   sidebar widget shows "cancelled" / nothing for an install that is
   actually running fine.

**Why it slipped twice**: PR #2 was reviewed but no test exists for the
overlapping-clicks path. PR #4 made the tracker visible in a new Tasks tab
(making the misreport more visible), but didn't address the underlying race.

**Proposed fix** — add a `currentRunId` to the tracker and require run-scoped
mutators to pass it:

```swift
// SecVF/AISandboxInstallTracker.swift
final class AISandboxInstallTracker {
    // ... existing fields ...

    /// Identifier of the install run that currently owns the tracker. Each
    /// `begin()` mints a fresh UUID. Run-scoped mutators (`fail`, `reset`,
    /// `setPhase`, `updateInstallFraction`, `log`) accept an optional
    /// `runId:` argument and no-op when it doesn't match. Prevents a
    /// superseded run's late callbacks from clobbering the run that
    /// replaced it.
    private(set) var currentRunId: UUID?

    @discardableResult
    func begin() -> UUID {
        let id = UUID()
        phase = .installing
        fraction = 0
        lastErrorMessage = nil
        logMessages = []
        currentRunId = id
        notify()
        return id
    }

    func updateInstallFraction(_ f: Double, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        guard phase == .installing else { return }
        fraction = max(0, min(1, f))
        notify()
    }

    func setPhase(_ next: Phase, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        // ... existing body ...
    }

    func fail(with message: String, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        phase = .failed
        lastErrorMessage = message
        notify()
    }

    func reset(runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        phase = .idle
        fraction = 0
        lastErrorMessage = nil
        currentRunId = nil
        notify()
    }

    func log(_ message: String, runId: UUID? = nil) {
        if let runId = runId, runId != currentRunId { return }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(ts)] \(message)")
        if logMessages.count > 500 { logMessages.removeFirst(logMessages.count - 500) }
        notify()
    }
}
```

Then in `createAISandboxVM`:

```swift
let runId = AISandboxInstallTracker.shared.begin()
AISandboxInstallTracker.shared.log("Starting AI Sandbox build", runId: runId)
AISandboxInstallTracker.shared.log("IPSW: \(cachedIPSW.lastPathComponent)", runId: runId)
AISandboxInstallTracker.shared.log("Bundle: \(AISandboxDefaults.baseBundle.path)", runId: runId)

let task = Task { [weak self] in
    defer {
        Task { @MainActor in
            self?.clearActiveInstallTaskIfMatches()
        }
    }
    do {
        let bundle = try await AISandboxMacVMInstaller.downloadAndInstall(
            localIPSW: cachedIPSW,
            progress: { fraction in
                DispatchQueue.main.async {
                    AISandboxInstallTracker.shared.updateInstallFraction(fraction, runId: runId)
                    // ... 5% milestone log, also pass runId
                }
            }
        )
        // ...
        await MainActor.run {
            AISandboxInstallTracker.shared.log("Bundle sealed at \(bundle.url.path)", runId: runId)
            AISandboxInstallTracker.shared.setPhase(.finished, runId: runId)
            // ... alert + reset
        }
    } catch is CancellationError {
        NSLog("[AISandbox] Install cancelled (likely superseded by a later click)")
        await MainActor.run {
            // Run-scoped — silently no-ops if a newer run owns the tracker.
            AISandboxInstallTracker.shared.log("Cancelled.", runId: runId)
            AISandboxInstallTracker.shared.fail(with: "cancelled", runId: runId)
            AISandboxInstallTracker.shared.reset(runId: runId)
        }
    } catch {
        await MainActor.run {
            AISandboxInstallTracker.shared.log("Error: \(error.localizedDescription)", runId: runId)
            AISandboxInstallTracker.shared.fail(with: error.localizedDescription, runId: runId)
            // ... alert + reset(runId:)
        }
    }
}
activeAISandboxInstallTask = task
```

**Test** — the prevention case the prior review specifically called out:

```swift
// SecVF/Tests/AISandboxInstallTrackerTests.swift (new)
func testSupersededRunCannotClobberCurrent() {
    let tracker = AISandboxInstallTracker.shared
    let oldRun = tracker.begin()
    let newRun = tracker.begin()
    XCTAssertNotEqual(oldRun, newRun)

    // Old run's late fail() must no-op
    tracker.fail(with: "cancelled", runId: oldRun)
    XCTAssertNotEqual(tracker.phase, .failed,
                      "superseded run must not flip phase to .failed")

    // Old run's late reset() must no-op
    tracker.reset(runId: oldRun)
    XCTAssertNotNil(tracker.currentRunId,
                    "superseded run must not clear currentRunId")
    XCTAssertEqual(tracker.currentRunId, newRun)
}
```

---

## High (fix this PR)

### S3 — `bootAISandboxSession()` "already running" guard is racy; double-click leaks a session VM

**File**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) lines ~2143–2150

**The race**: the existing-session check happens inside `Task { @MainActor in ... }`, but the assignment `self.activeSandboxSession = session` happens after `cloneBase()` + `machine.start()` — a multi-second gap. Two clicks within that window each:

1. Pass the `if let existing = activeSandboxSession ...` check (still nil)
2. Clone the base bundle (expensive APFS clone)
3. Build a VZ config + machine
4. Start the machine
5. Start a vsock bridge
6. Assign `self.activeSandboxSession = session` — second writer wins, first session VM is leaked

The leaked session keeps a VM running, a window open, a UDS bridge listening, and 16 connection slots reserved. No teardown path.

**Proposed fix** — synchronous flag set before the Task, mirroring `createAISandboxVM`'s cancel-and-replace pattern:

```swift
private var activeSandboxBootInFlight = false

@objc private func bootAISandboxSession() {
    let baseBundle = AISandboxVMBundle(url: AISandboxDefaults.baseBundle)
    guard baseBundle.exists else { /* alert + return */ }

    // Bring an existing live session forward instead of starting a new one.
    if let existing = activeSandboxSession,
       existing.vm?.state == .running || existing.vm?.state == .starting {
        for window in NSApp.windows where window.title.contains("AI Sandbox") {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
    }

    // Synchronous gate — set BEFORE the Task so a second click sees the flag.
    if activeSandboxBootInFlight {
        NSLog("[AISandbox] Boot already in flight; ignoring duplicate click")
        return
    }
    activeSandboxBootInFlight = true

    Task { @MainActor in
        defer { self.activeSandboxBootInFlight = false }
        // ... existing body ...
    }
}
```

Optional follow-up: add a `Tools → Stop AI Sandbox Session` menu item so the user has an explicit teardown path; today the only way to stop a session is to quit the app.

---

### S4 — Per-boot UUID rewrites the session manifest, breaking concurrent CLI lookups

**File**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) lines ~2207–2218

```swift
let sandboxVMId = UUID()
self.activeSandboxVMId = sandboxVMId

let manifestURL = session.bundleURL.appendingPathComponent("manifest.json")
if var manifest = try? JSONSerialization.jsonObject(
    with: Data(contentsOf: manifestURL)) as? [String: Any] {
    manifest["id"] = sandboxVMId.uuidString
    manifest["name"] = "ai-sandbox-exec-\(session.sessionID)"
    if let updated = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
        try? updated.write(to: manifestURL)
    }
}
```

The CLI bridge addresses `/tmp/secvf-exec-<id>.sock` based on the manifest's `id`. Booting the same session bundle twice gives it two different ids on disk, and the most recently written one wins — but a CLI client that looked up the id moments before the rewrite is now pointed at a UDS path that doesn't exist.

**Proposed fix**: persist the id on first boot only.

```swift
let manifestURL = session.bundleURL.appendingPathComponent("manifest.json")
var manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]) ?? [:]

// Preserve a stable id across re-boots of the same session bundle.
let sandboxVMId: UUID
if let existing = manifest["id"] as? String, let parsed = UUID(uuidString: existing), !existing.isEmpty {
    sandboxVMId = parsed
} else {
    sandboxVMId = UUID()
    manifest["id"] = sandboxVMId.uuidString
}
if (manifest["name"] as? String)?.isEmpty ?? true {
    manifest["name"] = "ai-sandbox-exec-\(session.sessionID)"
}
self.activeSandboxVMId = sandboxVMId
if let updated = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
    try? updated.write(to: manifestURL)
}
```

---

### S5 — Storage controller selection differs by host macOS; can break boot of a bundle moved between hosts

**File**: [`SecVF/cli/Sources/secvf-cli/VMRunner.swift`](../SecVF/cli/Sources/secvf-cli/VMRunner.swift) lines ~231–236

```swift
if #available(macOS 15.0, *) {
    config.storageDevices = [VZNVMExpressControllerDeviceConfiguration(attachment: diskAttachment)]
} else {
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
}
```

The disk image was created against `VZVirtioBlockDeviceConfiguration` ([`AISandboxMacVMConfiguration.swift:418`](../SecVF/AISandboxMacVMConfiguration.swift#L418)). Selecting NVMe on the boot side means the guest sees the disk through a different controller bus than the install ran against.

**Proposed fix** — pin a single controller for AI Sandbox bundles. Lower-friction option: always use VirtioBlock (already in use on the install side). Future-proof option: write the controller kind into the manifest at seal time and read it back at boot.

```swift
// VMRunner.swift — drop the host-version check
let diskAttachment = try VZDiskImageStorageDeviceAttachment(
    url: URL(fileURLWithPath: diskPath), readOnly: false
)
config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
```

If the team genuinely wants NVMe for the perf gain, do it on **both** sides (install + boot) and only on macOS 15+, AND add a `storage_controller: "nvme" | "virtio-blk"` field to the sealed manifest so older hosts know to refuse rather than silently use the wrong controller.

---

### S13 — F2 (`BridgeState` lifetime) is inherited but unfixed; PR #4's `vm exec` test plan likely fails

**File**: [`SecVF/VsockExecBridge.swift`](../SecVF/VsockExecBridge.swift) `bridgeOneConnection`

Pre-existing bug from `docs/PR_REVIEW_2026-05-03.md` F2. PR #4's `bootAISandboxSession()` calls `VsockExecBridgeManager.shared.startBridge(...)` so the bridge path is now reachable from the new menu item. The PR's test plan claims `secvf-cli vm exec ... -c 'uname -a'` returns guest output. If F2 is real, that test fails on the first byte.

**Verification before fixing** (recommended): add the runtime probe from PR_REVIEW F2 and run `vm exec` once. If the probe reports `state` deallocates immediately after `bridgeOneConnection` returns, the bug is real.

**Proposed fix** — capture `state` strongly in both readability closures so the closure ↔ FileHandle ↔ state cycle keeps `state` alive until `finish()` clears the closures:

```swift
// VsockExecBridge.swift — bridgeOneConnection

let state = BridgeState(
    client: clientHandle,
    vsock: vsockHandle,
    vsockConn: vsockConn,
    onFinish: { [weak self] in self?.releaseConnectionSlot() }
)
slotHandedOff = true

// STRONG capture — intentional retain cycle that breaks when finish()
// clears both readabilityHandlers. Without this, `state` has no strong
// owner outside this function and is freed as soon as we return, killing
// the bridge before the first byte flows.
clientHandle.readabilityHandler = { [state] fh in
    let d = fh.availableData
    if d.isEmpty {
        fh.readabilityHandler = nil
        state.finish()
        return
    }
    if !state.writeToVsock(d) {
        fh.readabilityHandler = nil
    }
}

vsockHandle.readabilityHandler = { [state] fh in
    let d = fh.availableData
    if d.isEmpty {
        fh.readabilityHandler = nil
        state.finish()
        return
    }
    if !state.writeToClient(d) {
        fh.readabilityHandler = nil
    }
}
```

`BridgeState.finish()` already clears both readabilityHandlers + closes both FileHandles, breaking the cycle and letting ARC tear everything down. The `onFinish` hook still fires the `releaseConnectionSlot()` call.

**Prevention test** — integration test that opens the UDS, sends bytes, asserts the response (skip on hosts without vsock loopback):

```swift
// SecVF/Tests/VsockExecBridgeIntegrationTests.swift (new, opt-in)
func testBridgeRoundTripsBytesAfterReturn() throws {
    // ... spin up an in-process echo on the vsock side, open the UDS,
    // write 1 KB, read 1 KB back, assert byte-identical
    // skip if !FileManager.isWritableFile(atPath: "/tmp")
}
```

---

## Medium (combine into a single follow-up PR)

### S6 — Tracker singletons hold mutable state without queue protection

**Files**: [`SecVF/IPSWDownloadTracker.swift`](../SecVF/IPSWDownloadTracker.swift), [`SecVF/AISandboxInstallTracker.swift`](../SecVF/AISandboxInstallTracker.swift)

All writers happen to be on `@MainActor` today, but there's nothing in the type that enforces it. Future callers from `captureQueue` / `parseQueue` / `switchQueue` would race silently.

**Proposed fix** — annotate the classes:

```swift
@MainActor
final class IPSWDownloadTracker { /* ... */ }

@MainActor
final class AISandboxInstallTracker { /* ... */ }
```

Build will fail at any non-main caller and force a `Task { @MainActor in ... }` hop. Worth doing before Swift 6's strict concurrency lights this up as a build-breaker anyway.

---

### S7 — `clearActiveInstallTaskIfMatches()` is still the no-op stub from PR #2

**File**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) lines ~2113–2127

Body is empty. Each completed install leaves `activeAISandboxInstallTask` pointing at a finished `Task`; the next click calls `prior.cancel()` on a done task — harmless, but logs `[AISandbox] Cancelling prior install task before starting new attempt` for an install that already finished.

**Proposed fix** — implement the `===` self-clear (Task is a class):

```swift
private func clearActiveInstallTaskIfMatches() {
    // No-op if a newer task already replaced us. We can't compare Task
    // values directly without a wrapper, so we rely on the invariant that
    // each task's defer block runs exactly once when that task ends.
    // If activeAISandboxInstallTask was set by a *later* click after we
    // started but before our defer fires, the next click will cancel it
    // explicitly and there's no harm in leaving it set.
    activeAISandboxInstallTask = nil
}
```

Even simpler: since the cancel-and-replace already handles both stale and live cases on entry, just delete `clearActiveInstallTaskIfMatches` entirely and remove the `defer` that calls it.

---

### S8 — `.provisioning` phase is set nowhere but special-cased in the tracker

**Files**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) (the removed `setPhase(.provisioning)` call), [`SecVF/AISandboxInstallTracker.swift`](../SecVF/AISandboxInstallTracker.swift) line ~73

PR #4 dropped `try await AISandboxMacVMInstaller.provisionBundle(bundle)` from the create flow because the fresh install has no vsock agent to provision against. Fine pragmatically, but `Phase.provisioning` is now dead code that the tracker still treats specially.

**Proposed fix** — pick one:

(a) Remove the case until provisioning lands:

```swift
enum Phase: String {
    case idle
    case installing
    case sealing
    case finished
    case failed
}
```

(b) Keep the case and document it as reserved for the future agent flow; add a `// TODO(provisioning):` comment at the site where `setPhase(.provisioning)` *would* be called once the agent ships.

(a) is cleaner; (b) avoids a Codable migration if the phase is persisted anywhere (it isn't today, but worth checking).

---

### S9 — `refreshDistroVersions` runs unconditionally on every launch and writes `~/.avf/distros.json`

**File**: [`SecVF/DistroConfiguration.swift`](../SecVF/DistroConfiguration.swift) lines ~412–470

Every launch hits every distro mirror. No cache TTL. A 10s splash timeout means cold launches with one slow mirror always wait 10s. No opt-out.

**Proposed fix** — add a TTL gate:

```swift
// DistroConfiguration.swift
private let refreshIntervalSeconds: TimeInterval = 6 * 60 * 60   // 6h

@MainActor
func refreshDistroVersions(
    progress: @escaping (_ distroName: String, _ status: String) -> Void,
    completion: @escaping (_ updated: [String], _ errors: [String]) -> Void
) {
    // Skip if we refreshed recently.
    if let last = configFile?.lastRefreshAttempt,
       Date().timeIntervalSince(last) < refreshIntervalSeconds {
        completion([], [])
        return
    }
    // ... existing body ...
}
```

Add `lastRefreshAttempt` to `DistroConfigurationFile` and persist it. Optional: read a `SECVF_DISABLE_DISTRO_REFRESH` env var or a UserDefaults flag for users who want full opt-out.

Also: lower the splash timeout from 10s to ~3s — if the network is degraded, we'd rather show the library quickly with stale distro data than block launch.

---

### S10 — `DownloadDelegate.lastLoggedPct` mutated from two contexts

**File**: [`SecVF/AppDelegate.swift`](../SecVF/AppDelegate.swift) lines ~2350–2380

`urlSession(_:didWriteData:...)` is called on the URLSession's delegate queue (a serial OperationQueue) but the milestone bookkeeping (`if pct != self.lastLoggedPct { self.lastLoggedPct = pct ... }`) reads/writes `lastLoggedPct` from inside `DispatchQueue.main.async`. Two writers, no protection.

**Proposed fix** — keep all milestone bookkeeping inside the main-thread block:

```swift
func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
) {
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
    DispatchQueue.main.async {
        self.progress(totalBytesWritten, total)

        if total > 0 {
            let pct = Int(Double(totalBytesWritten) / Double(total) * 100)
            if pct != self.lastLoggedPct {
                self.lastLoggedPct = pct
                let mbWritten = totalBytesWritten / (1024 * 1024)
                let mbTotal = total / (1024 * 1024)
                IPSWDownloadTracker.shared.log("Downloading: \(pct)% (\(mbWritten)/\(mbTotal) MB)")
            }
        } else {
            // size-unknown branch — also gated to main
            let mb = totalBytesWritten / (1024 * 1024)
            let lastMB = (totalBytesWritten - bytesWritten) / (1024 * 1024)
            let bucket = (mb / 50) * 50
            let lastBucket = (lastMB / 50) * 50
            if bucket != lastBucket {
                IPSWDownloadTracker.shared.log("Downloaded: \(mb) MB (size unknown)")
            }
        }
    }
}
```

(Already fully inside the block — the original code is already correct as long as we read it carefully. Re-verify against the actual diff at merge time; if still split across contexts, apply the fix above.)

---

### S11 — `IPSWDownloadTracker.complete()` and `fail()` leave phase sticky

**File**: [`SecVF/IPSWDownloadTracker.swift`](../SecVF/IPSWDownloadTracker.swift) lines ~60–76

Phase stays in `.finished` / `.failed` indefinitely. The Tasks tab shows "IPSW Download: Done" forever after a successful download until the next `begin()`.

**Proposed fix** — auto-`reset()` after a delay, matching the install-tracker UX:

```swift
func complete() {
    phase = .finished
    fraction = 1
    notify()
    // Auto-clear the sticky "Done" status after the user has had a chance
    // to see it, so the Tasks tab returns to "No tasks running."
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard self?.phase == .finished else { return }
        self?.reset()
    }
}

func fail(with message: String) {
    phase = .failed
    lastErrorMessage = message
    notify()
    // Failures stay visible longer — user needs time to read the alert.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
        guard self?.phase == .failed else { return }
        self?.reset()
    }
}
```

Combine with S6 (`@MainActor` annotation) so the `asyncAfter` block on main is well-typed.

---

### S12 — `isExecBridgeAvailable` only checks for the socket file, not whether anyone is listening

**File**: [`SecVF/cli/Sources/secvf-cli/Bridges/VMManagerBridge.swift`](../SecVF/cli/Sources/secvf-cli/Bridges/VMManagerBridge.swift) lines ~286–294

```swift
func isExecBridgeAvailable(name: String) -> Bool {
    guard let vm = findVM(name: name),
          let idString = vm["id"] as? String, !idString.isEmpty else {
        return false
    }
    let socketPath = "/tmp/secvf-exec-\(idString).sock"
    return FileManager.default.fileExists(atPath: socketPath)
}
```

A leftover socket from a crashed prior session would falsely return true. Then `vm exec` would see ECONNREFUSED downstream and the user would get a confusing error instead of "VM not booted."

**Proposed fix** — actually attempt a non-blocking connect:

```swift
import Darwin

func isExecBridgeAvailable(name: String) -> Bool {
    guard let vm = findVM(name: name),
          let idString = vm["id"] as? String, !idString.isEmpty else {
        return false
    }
    let socketPath = "/tmp/secvf-exec-\(idString).sock"
    guard FileManager.default.fileExists(atPath: socketPath) else { return false }

    // File exists — but is anyone accepting? Try a short non-blocking connect.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count <= pathCapacity else { return false }

    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        sunPath.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { memcpy(dst, base, pathBytes.count) }
            }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { aptr in
        aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
            connect(fd, saptr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return connectResult == 0
}
```

The connect succeeds → bridge is alive. ECONNREFUSED → stale socket file. Same pattern Postgres / Redis CLIs use.

---

### S14 — `tasksLogTextView.string = newLog` rebuilds NSTextView storage on every notification

**File**: [`SecVF/VMLibraryWindowController.swift`](../SecVF/VMLibraryWindowController.swift) lines ~1379–1383

Each tracker notification fires `refreshTasksTab()`, which assigns a freshly-joined `String` to `tv.string`. Every assignment rebuilds the underlying `NSTextStorage`. For an IPSW download with 1% milestone logs, that's ~100 full rebuilds plus a `scrollToEndOfDocument` each time — visible flicker.

**Proposed fix** — append-only:

```swift
// Track the count of lines already rendered.
private var lastDisplayedLogCount = 0

private func refreshTasksTab() {
    // ... status + progress bar logic ...

    let allLogs = mergedLogs()  // sandbox + ipsw
    if let tv = tasksLogTextView {
        if allLogs.count < lastDisplayedLogCount {
            // begin() reset the buffer — start fresh.
            tv.string = ""
            lastDisplayedLogCount = 0
        }
        let newLines = allLogs[lastDisplayedLogCount..<allLogs.count]
        if !newLines.isEmpty {
            let prefix = lastDisplayedLogCount == 0 ? "" : "\n"
            tv.textStorage?.append(NSAttributedString(
                string: prefix + newLines.joined(separator: "\n"),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor(white: 0.7, alpha: 1.0)
                ]
            ))
            lastDisplayedLogCount = allLogs.count
            tv.scrollToEndOfDocument(nil)
        }
    }
}
```

Reset `lastDisplayedLogCount = 0` whenever a tracker's `begin()` fires (detect by counting backwards) so the merged log resets cleanly.

---

## Cross-cutting

- **No automated test exercises the supersession path.** PR #2's manual-only test plan was where F1 hid; PR #4 shows the same pattern. The fix in C2 above is shipped with a unit test that drives the supersession case directly. Worth adding a similar test for `bootAISandboxSession()` once S3 lands.
- **The Tasks tab makes tracker bugs visible.** The flip side is that any tracker race now manifests as flickering UI under the user's eye. C2 + S6 + S11 together produce a tracker that's robust under concurrent and superseded mutations.
- **CLI integration is the new exposed surface.** S5 (storage controller), S12 (bridge readiness), S13 (BridgeState lifetime) all live under "we now actually use the vsock+manifest plumbing for real." Any one of these failing makes `secvf-cli vm exec` unusable; verify all three before declaring the PR ready.

---

## Recommended fix order

| Priority | Items | Estimated effort |
|---|---|---|
| Block merge | C1, C2 | half-day (with tests) |
| Same PR | S3, S4, S5, S13 | one day |
| Follow-up PR | S6, S7, S8, S9, S10, S11, S12, S14 | one day, batch them |

Continuous: anywhere this PR opens new public surface (`Tools → Boot AI Sandbox`, the Tasks tab, the CLI's AI Sandbox path), add at least one assertion-style test that drives the surface end-to-end.
