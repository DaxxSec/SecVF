# Pre-Launch Validation Plan — SecVF 1.0

**Owner:** Solo maintainer
**Target:** Public 1.0 release that survives the first 48 hours
**Scope:** Native macOS Swift app (Virtualization.framework) for malware analysis and IR
**Status:** Framework document — execute against this; do not edit during the window

---

## 0. Operating Assumptions

This plan is written for one person on a fixed calendar, not a QA org. It optimizes for **catching the 1.0-killers** (data loss, host compromise, install crash, framework-level regression on a supported Mac) and explicitly tolerates known cosmetic and edge-case gaps that can be patched in 1.0.1. Every test below has a binary pass/fail. If a test is squishy, it doesn't ship in this plan.

The honest constraint: a solo maintainer cannot exhaustively cover the matrix. The plan invests heavily in **automation + soak + a small community beta** because those scale; it under-invests in manual matrix sweeps because those don't.

---

## 1. What to Test

Seven categories. Each has a pass bar that is testable in under an hour of work or runs unattended.

### 1.1 Build & Sign

| Check | Pass criteria |
|---|---|
| Clean release build from a fresh clone | `xcodebuild -scheme SecVF -configuration Release` succeeds with zero warnings escalating from "new" |
| Code signing | App is Developer ID–signed, hardened runtime on, entitlements match `Virtualization` requirements |
| Notarization | `xcrun notarytool` returns `Accepted`; staple succeeds; `spctl --assess --verbose` says `accepted source=Notarized Developer ID` |
| Gatekeeper first-launch | Double-click on a freshly downloaded DMG/zip on a *different* Mac opens without right-click bypass |
| DMG/zip artifact integrity | SHA-256 of artifact matches release notes; ad-hoc unsigned binaries are not in the bundle |
| CLI binary | `SecVF/cli/` builds, signs, runs `--help` on a clean machine |

### 1.2 Automated Tests

Pass bar: **100% of `SecVF/Tests/` green on the release branch HEAD, on Apple Silicon, on the lowest supported macOS.** No skipped tests without a written reason in the PR.

- Unit tests for `VMConfiguration` Codable round-trip, `ISOCacheManager` SHA-256 verify (including a deliberately corrupted fixture), `VirtualNetworkSwitch` ARP/L2 paths, `SecVFError` formatting, `VMSecurityMonitor` severity mapping.
- Integration tests that don't require a real guest (mocked `VZVirtualMachine`).
- A *separate* test target that DOES boot a tiny Linux guest for end-to-end VM lifecycle — run nightly, not on every commit, because it's slow and physical-host-bound.

### 1.3 Manual Smoke (under 30 minutes, every release candidate)

A scripted checklist the maintainer runs **personally** on each RC before promotion. Items:

1. First-run experience on a clean user account (no prior `~/Library/Application Support/SecVF`).
2. Create a Linux VM from a cached ISO — boot to login prompt.
3. Create a macOS guest via `MacOSVMInstaller` from Apple CDN — at least *start* the install (full install too slow for smoke, full path lives in E2E).
4. Open `PacketAnalysisWindowController` against a live capture, see frames flow, filter by `tcp.port`.
5. Trigger a `VMSecurityMonitor` event (drop a file in a watched path), confirm UI surfaces it with correct severity.
6. Quit and relaunch — VM library restores; no orphaned windows.
7. Trash the app, drag a new build over, relaunch — config preserved.

### 1.4 End-to-End Analyst Workflows

These are the **product**, not the framework. If these don't work, nothing else matters.

| Workflow | Pass criteria |
|---|---|
| "Detonate unknown binary in ephemeral macOS guest" | `AISandboxMacVMConfiguration` boots, sample executes, FSEvents recorded, guest torn down, host state unchanged |
| "Capture C2 traffic from a Linux malware sample" | tshark captures full session, pcap saved, replay in PacketAnalysisWindow filters cleanly |
| "Multi-VM lateral movement scenario" | Two guests on the `VirtualNetworkSwitch`, traffic between them captured, host network never touched |
| "Triage report export" | Events + pcap + screenshots bundle into a single artifact, opens on a second machine |

### 1.5 Security & Isolation

Pass bar is **zero** findings at CRITICAL or HIGH; MEDIUM acceptable with documented mitigation.

- Guest cannot reach host loopback unless explicitly bridged.
- Guest cannot reach host LAN unless `VirtualNetworkSwitch` is in bridge mode AND user opted in.
- Sample binaries executed in `AISandboxMac` cannot persist anything to host disk after VM teardown (verify with FSEvents diff before/after).
- App does not request entitlements it doesn't use.
- Sandboxed ISO downloads validate SHA-256 *before* moving into cache (test with a poisoned mirror response — a recorded fixture, not a live MITM).
- `SecVFError` paths never leak absolute home paths into user-visible error strings.
- `security-review` skill run against the diff between last tag and HEAD. Findings triaged.

### 1.6 Performance Budgets

| Metric | Budget |
|---|---|
| Cold launch to library window visible | < 1.5 s on M1 |
| Linux guest boot (cached image) | < 8 s to login prompt |
| macOS guest boot (after install) | < 25 s |
| Packet capture UI at 10k pps sustained | < 60% one core, no dropped frames in UI |
| Memory after 24h idle with one suspended VM | < 600 MB resident for the host app process |
| `VMLibraryWindowController` open with 50 VMs in library | < 500 ms to interactive |

These are budgets, not aspirations. Anything over budget gets a written justification or blocks release.

### 1.7 Recovery & Failure Modes

- Force-quit during VM boot — relaunch finds the VM in a clean stopped state, not a half-written config.
- Disk-full during ISO download — error is typed, cache is not corrupted, retry works.
- Apple CDN returns 503 for IPSW — `MacOSVMInstaller` surfaces a real error, doesn't hang.
- tshark missing or at unexpected path — `PacketCaptureManager` reports actionable error, app stays alive.
- Network switch peer dies mid-session — remaining peer's UI doesn't lock up.

---

## 2. How to Test

### 2.1 What runs in CI vs. on a physical Apple Silicon Mac

| Test | CI (GitHub Actions, macOS runner) | Physical Apple Silicon |
|---|---|---|
| Build & sign artifact | Yes (with secrets) | Verified once per RC |
| Unit tests | Yes, every PR | Yes, on release branch |
| Integration tests w/ mocked VZ | Yes | Yes |
| Real VZ-backed guest boot | **No** (Virtualization.framework needs bare metal; nested virt on a runner is unreliable) | **Required** |
| Notarization | Yes (release branch only) | N/A |
| Smoke checklist | No | Required, by hand |
| 24h / 48h soak | No | Required, on dedicated hardware |
| Performance budgets | No | Required |

GitHub-hosted macOS runners cannot reliably exercise `Virtualization.framework` for real guest boot. Don't try; the false signal will burn time.

### 2.2 TestFlight

TestFlight is **not** the right channel for a tool that needs Developer ID + hardened runtime + system extensions for tshark integration. The Mac App Store sandbox would break `VirtualNetworkSwitch` and `PacketCaptureManager`. Use Developer ID + notarized DMG distribution and a **private beta channel** (GitHub release marked pre-release, link shared with ~5 community testers) for the equivalent function. Call it "Beta DMG," not TestFlight, to avoid confusion.

### 2.3 Sourcing and handling malware samples for analyst-workflow tests

This is the only part of the plan with legal exposure. Rules, non-negotiable:

- **Samples only from MalwareBazaar (abuse.ch) and VirusShare** with documented provenance. No "found it on a forum." No customer samples.
- Samples live on an **encrypted external volume that is mounted only during workflow testing** and unmounted otherwise.
- The test host has FileVault on, is on an isolated VLAN, and EDR is off only on the isolated VLAN segment.
- Detonation happens **only** inside SecVF's own ephemeral guests. The host never executes a sample, even to compute a hash — use `shasum` on the still-encrypted archive.
- Three samples are enough for the framework: one Windows PE (irrelevant to macOS guest path but useful for `PacketAnalysisWindow`), one Mach-O adware variant, one Linux ELF for the Linux guest path. Don't collect a zoo.
- Samples are not in the repo, not in CI, not in screenshots used in the release announcement.

### 2.4 Methodology

- **Risk-based, not exhaustive.** Time goes to the categories where a failure would force a 1.0.1 within 48 hours: install, signing, VM boot, isolation. Cosmetic UI gets one pass.
- **Run the smoke checklist on a clean user account, not the dev account.** The dev account has every cached state, key, and entitlement already warm. Bugs hide there.
- **Record the soak.** `Console.app` filtered to the SecVF subsystem, `log stream` to file, and a periodic `sample` of the app process. If something fails at hour 31, you need the trail.

---

## 3. Test Matrix

### 3.1 Hardware/OS combos

| Chip | macOS | Tier |
|---|---|---|
| M1 (8GB) | 14.x (lowest supported) | **Must-pass** |
| M1 Pro/Max | 14.x | **Must-pass** |
| M2 | 15.x | **Must-pass** |
| M3 | 15.x | **Must-pass** |
| M4 | 15.x | **Must-pass** |
| M4 | 26.x (current) | **Must-pass** |
| M1 | 13.x | Best-effort, document if not supported |
| M2 Ultra (Mac Studio) | 15.x | Best-effort (gets covered via community beta) |
| Intel Mac | any | **Not supported** — say so explicitly in README |

"Must-pass" means smoke + automated tests + a representative analyst workflow. A solo maintainer typically owns two of these and rents the rest from community beta testers — that's fine, plan for it.

### 3.2 Guest matrix

| Guest | Tier |
|---|---|
| Ubuntu 24.04 LTS arm64 | Must-pass |
| Debian 12 arm64 | Must-pass |
| macOS guest (installed via IPSW) | Must-pass |
| `AISandboxMac` ephemeral | Must-pass |
| Fedora arm64 | Best-effort |
| Windows 11 arm64 | Best-effort, document caveats |
| Kali arm64 | Best-effort |

---

## 4. Acceptance Criteria

The release ships when **all** of the following are true. Not most. All.

1. Every must-pass cell in section 3.1 has a passing smoke checklist run within the previous 7 days.
2. `SecVF/Tests/` is 100% green on the release tag commit on M1/macOS 14 and M4/macOS 26.
3. No CRITICAL or HIGH security findings open.
4. No performance budget in 1.6 is breached by more than 10%.
5. A 48-hour soak (section 7) completes with no crash, no leak above 50 MB/24h, and no CRITICAL `VMSecurityMonitor` event.
6. At least **two** community beta testers on hardware the maintainer does not own report a successful end-to-end analyst workflow.
7. Release notes, README, and `docs/` accurately describe what works and what doesn't. Known issues are listed; nothing in the known-issues list is a 1.0 blocker.
8. A signed, notarized, stapled DMG is downloadable from a URL that is NOT the maintainer's personal machine.
9. Rollback plan exists: the previous 0.x DMG is still hosted and linked from the release announcement.

If any one of these fails, the release slips. No "we'll patch it." That's how 1.0s die.

---

## 5. Sequencing

Real estimates for one person. Pad by 30% if you're not on this full-time.

| Phase | Days | What happens |
|---|---|---|
| **Code freeze** | Day 0 | Branch `release/1.0` cut. Only fixes for blockers from this plan land. Features go to `main`. |
| **Audit pass** | Days 1–3 | Run `security-review` on the diff since last tag. Run the automated suite. Manually walk every entry in section 1. Open issues, do not fix yet. |
| **Triage + fix** | Days 4–7 | Sort findings into BLOCK / FIX-IN-1.0 / DEFER-TO-1.0.1. Fix the BLOCK and FIX-IN-1.0 items. Re-run automated tests after each fix. |
| **Smoke (RC1)** | Day 8 | Build RC1 from `release/1.0`. Run the 30-min smoke checklist on a clean user account on M1 and M4. |
| **Community beta** | Days 9–11 | DMG to 5 testers. Provide a one-page "what to test and how to report." Expect 2 to actually report. |
| **Fix-and-spin** | Days 12–13 | One more fix cycle, RC2. |
| **Soak start** | Day 14 | Kick off the 48h soak on a dedicated machine. |
| **Soak end + final smoke** | Day 16 | Soak completes, full smoke checklist on RC2 one more time, notarize the artifact that you actually plan to ship. |
| **Launch day** | Day 17 | DMG published, release notes live, announcement posted, monitoring window starts. |
| **First-48 watch** | Days 17–18 | Maintainer is on-call. Issue tracker, email, and a pinned thread monitored. Hotfix branch ready. |

**Total: roughly 17 days end-to-end.** This is achievable for a solo maintainer doing this part-time alongside a day job if they're disciplined. It compresses to ~10 days if full-time. Anything shorter is wishful.

---

## 6. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Distro mirror schema changes break ISO discovery | Med | Med | Pin known-good URLs in `ISOCacheManager`; surface a clear error and a "paste URL" fallback when discovery fails; ship with at least one fallback mirror per distro |
| macOS point release regresses Virtualization.framework behavior | Med | High | Test on the latest macOS within 72h of release; subscribe to the seed program; have a `known-broken-on(X)` flag in the app that surfaces a banner |
| `tshark` path or version differs across Homebrew / MacPorts / manual installs | High | Med | `PacketCaptureManager` probes multiple paths; user-overridable in settings; surface version string in About |
| Apple revokes the Developer ID cert | Low | Critical | Keep enrollment current; document an emergency re-sign path; back up the cert + private key to a hardware-secured store |
| Sample handling error during E2E testing leaks malware to host | Low | Critical | Isolated VLAN + encrypted volume + samples-only-in-guest rule from 2.3; if violated, halt testing and reimage the host |
| IPSW URL from Apple CDN changes shape | Med | Med | `MacOSVMInstaller` validates response shape; falls back to user-supplied IPSW; integration test runs nightly and fails loudly |
| Community beta produces zero usable reports | High | Med | Recruit 5 to get 2; have a written reproduction guide; offer a 15-min screen-share slot for one tester to lower the friction |
| 48h soak fails at hour 40 with no time to fix | Med | High | Start the soak with 3 days of calendar slack before the planned launch; have a "delay 7 days" option pre-committed |
| Notarization queue is slow on launch day | Low | Med | Notarize the actual ship artifact 24h before public launch, not on launch day |
| Crash on first launch on a clean account that the dev account masks | Med | High | Always smoke on a fresh user account, not the dev account (section 2.4) |
| Memory leak only visible under multi-VM load | Med | Med | Soak runs a 4-VM scenario for the full 48h, not 1 idle VM |
| Sparkle / auto-update path ships broken | Med | Critical (silent failure mode) | If auto-update is in 1.0, test the *upgrade from 0.x* path explicitly; if not, leave it out and add it in 1.1 |

---

## 7. Soak Plan (48 Hours)

**Hardware:** A dedicated M-series Mac, not the daily driver. Wall power, sleep disabled, FileVault on, EDR off only on the test VLAN.

**Scenario, set up at hour 0 and left running:**

- Four guests running concurrently:
  - One Ubuntu guest running a synthetic netcat traffic generator at ~5k pps.
  - One Debian guest idle.
  - One `AISandboxMac` ephemeral guest that is recreated every 30 minutes (exercises install + teardown path 96 times).
  - One macOS guest under steady light load.
- `VirtualNetworkSwitch` carrying traffic between the two Linux guests.
- `PacketCaptureManager` capturing on the switch the entire time, rotating pcaps hourly.
- `PacketAnalysisWindowController` open and live for the duration.
- `VMSecurityMonitor` armed on a watched directory inside the macOS guest.

**Instrumentation collected:**

- `log stream` filtered to the SecVF subsystem, redirected to a file.
- `top -l 0 -s 60 -pid <SecVF pid>` every 60s.
- `vmmap` snapshot every 4h.
- Hourly screenshot of the library window for visual leak (window stack, ghosted windows).
- Captured pcaps retained.

**Success metrics:**

| Metric | Threshold |
|---|---|
| Host app crashes | 0 |
| Guest crashes | ≤ 2, both recovered automatically |
| Resident memory growth, host app | < 50 MB over 24h, < 100 MB over 48h |
| CPU at idle baseline | Returns to baseline within 5 min of load removal |
| CRITICAL `VMSecurityMonitor` events on host | 0 |
| Ephemeral guest recreation cycles completed without leak | All 96 |
| pcap rotation produces no corrupted files | 100% openable |
| Library window remains responsive (< 200 ms to click) at hour 47 | Yes |

If any threshold is breached, the soak fails. Investigate, fix, restart the soak. Do not ship on a partial soak. The whole point of soak is to find the failure modes that don't manifest in a 30-minute smoke run — short-circuiting it defeats the purpose.

---

## 8. What This Plan Deliberately Does Not Cover

Honesty section, so future-you knows what corners were cut:

- **Full localization QA.** English only at 1.0. Other locales ship in 1.1.
- **Accessibility audit beyond VoiceOver smoke on the main window.** Full WCAG-style pass is 1.1.
- **Stress test beyond 4 concurrent guests.** Real analysts may run more; that gets characterized in 1.1 after we see field data.
- **Intel Macs.** Unsupported, stated up front.
- **Older macOS versions below 14.** Best-effort.
- **Comprehensive fuzzing of `VMConfiguration` decode paths.** One hand-crafted corrupt fixture per field; AFL-style fuzzing is post-1.0.

These are deliberate, defensible omissions. If a reviewer pushes back on any of them, the answer is "1.1, with field data to prioritize." Do not let scope grow inside the release window.
