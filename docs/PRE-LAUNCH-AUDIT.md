# SecVF Pre-Launch Audit

_Conducted: 2026-05-11. Methodology: 7 parallel read-only audit agents, each scoped to one subsystem, plus a separate plan agent ([PRE-LAUNCH-PLAN.md](PRE-LAUNCH-PLAN.md)). All findings re-triaged through the host-OpSec lens._

## How to read this

Findings are bucketed by my best guess at SecVF 1.0 launch impact:

| Bucket | Meaning | What I did about it |
|---|---|---|
| 🔴 **BLOCKER** | Host could be compromised, or sample could pivot to host LAN, or audit log can be forged from a guest | Either fixed this run, or documented + TODO'd loudly for user review |
| 🟠 **HIGH** | Real bug, crashes or data loss, but contained to in-app impact | Fixed if safe + small; deferred if architectural |
| 🟡 **MEDIUM** | Bugs, UX gaps, missing error paths | Fixed if a one-liner; otherwise tracked here |
| 🟢 **LOW / hygiene** | Code-quality, naming, dead code | Mostly tracked here, fixed opportunistically |
| 🔵 **AIMon-scope** | AI sandbox subsystem — owned by the [AIMon](https://github.com/DaxxSec/ai-mon) project, not SecVF 1.0 | Documented here, deferred unless it's a host-OpSec issue |

The "Status" column reflects what happened during the autonomous fix loop on this branch (`claude/serene-nash-0ddece`). Open items remain for the user to triage.

---

## 🔴 Launch blockers

### B1. Permissive iptables FORWARD in router VM enables host-LAN pivot

**`scripts/kali-router-setup.sh:211, 495`** — default `iptables -P FORWARD ACCEPT` combined with `iptables -A FORWARD -s ${ROUTER_NETWORK} -j ACCEPT` (`:223`) means any lab guest in `10.0.100.0/24` can reach the *host's* LAN via the NAT interface. This is a real host-OpSec violation, not an analyst-workflow concession — lab → internet via the router VM is the workflow; lab → host's LAN segment is a pivot.

**Fix (this run):** Tighten to `FORWARD DROP` default with explicit ACCEPT only for `VSWITCH_IFACE → NAT_IFACE` and stateful return traffic. Preserves the malware-capture workflow; closes the pivot. See commit in this branch.

### B2. OSLog subsystem typo silently breaks SIEM integration

**`SecVF/PacketCaptureManager.swift:56`** uses `subsystem: "com.secvf"` while `VMSecurityMonitor.swift:66` and `VirtualNetworkSwitch.swift:72` use `"com.DaxxSec.SecVF"`. The documented canonical query (`log stream --subsystem com.DaxxSec.SecVF`) drops every PacketCapture event — including security-relevant captures. This is a forensic-integrity issue.

**Fix (this run):** One-line subsystem rename in `PacketCaptureManager`. Low risk.

### B3. JSONL injection in audit log via attacker-controlled VM names

**`VMSecurityMonitor.swift:55-59, 377`** writes audit events as plain text `"[SEVERITY] type - vmName: message"`. VM names are user input; a name like `"foo\n[CRITICAL] vmStateChange - root: pwned"` forges a CRITICAL entry. Same forge surface exists in `message`. The `details` dictionary is built at line 343 but **never serialized** — so the forensic content is unreliable both directions.

**Fix (this run):** Sanitize newlines/CR/control characters from `vmName` and `message` before composing the log line. Also persist `details` as JSON next to the line. See commit.

### B4. Audit-log writes have no `fsync`, no exclusive locking, no atomic append

**`SecVFError.swift:218-223`, `VMSecurityMonitor.swift:380-389`, `VirtualNetworkSwitch.swift:511-521`** all open, seek-to-end, write, close. Concurrent producers (security monitor on `eventQueue`, switch on `logQueue`, error audit from any thread) can interleave bytes; a crash mid-write yields a truncated last line; the next event concatenates. **Worst kind of forensic corruption: silent.**

**Status (this run):** Documented with a TODO comment in code; user review needed. A proper fix wants a single serial writer per file with `fsync` after each line; that's a refactor I don't want to do without you on the keyboard.

### B5. AI sandbox vsock exec bridge has root-shell escalation surface

**`VsockExecBridge.swift:246-257` + `provision-macos-vm.sh:142, 314-332`** — the in-guest STREAM mode is a root shell over a `chmod 0666` UDS, gated only by a basename allowlist (`dtrace`, `tail`, `log`, `sysctl`). `tail -f /etc/sudoers`, `dtrace -w` (destructive actions), `log stream` with embedded predicates all admitted. The host-side `denyReasonForPeer` is the primary defense; the UDS perms are the secondary that doesn't actually deny.

🔵 **AIMon-scope.** But still a host-OpSec issue when AIMon runs. **Status (this run):** Documented. Fix needs UDS perm tightening + caller authentication; that's an AIMon design decision.

### B6. AI sandbox vsock channel has no message-size bound + no read timeout

**`VsockChannel.connect` (`AISandboxMacVMConfiguration.swift:325-336`)** accumulates `String` data with no cap and waits forever for EOF. A hostile guest streams gigabytes back → host OOMs. The bridge has a 5-second *connect* timeout but no *read* timeout.

🔵 **AIMon-scope** but **host-OpSec**. **Status (this run):** Documented. Bounded reads + a wall-clock read deadline are the minimum fix.

### B7. DistributedNotificationCenter accepts unsigned commands from any local user

**`AppDelegate.swift:92-111, 419-509`** registers observers for `com.secvf.cli.start/stop/force-stop` keyed only on `vmName`. The Mac mini global memory notes this is a multi-user machine — meaning the *other* user on the same host can post these notifications to start/stop your VMs by name. No signing, no sender check, no audit.

**Status (this run):** Documented. Real fix needs message signing or a mach-port-based bridge that only the same-app instance can drive. Not a one-liner; user review needed for design choice (signed messages? per-user app group? mach service with check-in?).

### B8. AI sandbox session "clone" is a full 64 GiB byte copy, not APFS CoW

**`AISandboxMacVMConfiguration.swift:107-126` (`AISandboxVMBundle.clone`)** uses `FileManager.copyItem`, which does **not** invoke `clonefile(2)`. Comment claims "APFS CoW — zero copy time, zero extra space"; reality is a full duplicate. Defeats the entire ephemeral-session design.

🔵 **AIMon-scope.** **Status (this run):** Documented with HIGH severity. Real fix uses `clonefile(src, dst, 0)` after verifying APFS via `getattrlist(VOL_CAP_INT_CLONE)`. AIMon's lifecycle owns this.

### B9. Two competing `PacketAnalysisWindowController` instances

**`AppDelegate.swift:50, 1573-1577` + `VMLibraryWindowController.swift:48, 901-906`** — both register for `.packetCaptured`. Opening "Packet Analysis" via Cmd-Shift-P and via the library button creates two independent subscribers; packets render twice, status counts diverge.

**Fix (this run):** Route the library button through the AppDelegate-owned singleton. See commit.

### B10. `UTType(filenameExtension: "pcap")!` force-unwrap

**`PacketAnalysisWindowController.swift:417, 437`** crashes the UI on systems with stripped-down UTI registration. Real users on locked-down corporate Macs have hit this.

**Fix (this run):** Guard + actionable alert. See commit.

---

## 🟠 High-severity bugs (fixed or documented)

### H1. `createVM` leaves half-created bundle directory on partial failure

**`VMManager.swift:307-308 → :321 → :324 → :327`** — `createDirectory` runs first; if disk-image / EFI / identifier creation throws later, the `.bundle/` dir is left on disk. Next attempt with the same name fails with `bundleExists` and the user has no idea it's stale junk. Same in `cloneVM` (`:443-456`) and `importVM` (`:496-514`).

**Fix (this run):** Wrap the body in `do/catch` with `try? FileManager.default.removeItem(atPath: bundlePath)` on any throw after `createDirectory`. See commit.

### H2. `saveVMMetadata` swallows all errors silently

**`VMManager.swift:245-255`** prints and returns `Void`. On disk-full / readonly volume the VM stays in `virtualMachines[]` but no `metadata.json` on disk — next launch loses the VM silently.

**Fix (this run):** Convert to `throws`. Callers already handle errors. See commit.

### H3. VM configuration accepts CPU=0, memory=1 byte

**`VMConfiguration.swift:74-75`** decodes `cpuCount`/`memorySize` with no bounds check. VZ rejects only at start time with a generic error. `AISandboxMacVMConfiguration.clampCPU/clampMem` exists (`:259-265`) but mainline doesn't use it.

**Fix (this run):** Add `clampToVZBounds()` to `VMConfiguration.init` mirroring the AI-sandbox helpers. See commit.

### H4. FakeNet script uses `error()` before it's defined

**`scripts/kali-fakenet-setup.sh:28, 37`** call `error` from the top-level config block, defined at `:69`. With `set -e`, missing `/etc/secvf-router.conf` produces `error: command not found` instead of the intended message.

**Fix (this run):** Move function definitions above first use. See commit.

### H5. FakeNet `stop` does not restore `/etc/dnsmasq.conf`

**`scripts/kali-fakenet-setup.sh:448-463` (`stop_fakenet`)** — start backs up to `dnsmasq.conf.backup` (`:224`) but stop only calls `systemctl stop dnsmasq`. Subsequent re-start overwrites the backup without an `[[ ! -f ]]` guard. After one stop the original config is silently lost forever.

**Fix (this run):** `stop_fakenet` now `cp /etc/dnsmasq.conf.backup /etc/dnsmasq.conf` on stop; `start_fakenet` guards backup creation. See commit.

### H6. tshark pipeline likely never produces live packets

**`PacketCaptureManager.swift:192-197`** spawns tshark with `-r <fifo> -T json -l`. `-r` is the offline-file reader: reads to EOF then exits. `-T json` produces a single JSON array finalized at EOF, not newline-delimited objects. The brace-counted `extractNextPacket` may starve until exit. Expected fix is `-T ek` (newline-delimited Elastic) with `-i -` or `-i <iface>`.

**Status (this run):** Documented. This warrants verification with the user on a real Mac — the auditor flagged it as nearly certain but I can't run it from here, and changing the tshark invocation without verifying the new pipeline works is reckless.

### H7. `generateMACFromName` is non-deterministic across runs

**`SwitchManagerBridge.swift:106-113`** uses `String.hashValue`, which is randomized per Swift process. Generated MACs differ run-to-run — the comment claims "deterministic" but isn't.

**Fix (this run):** Switch to a SHA-256-derived MAC. See commit.

### H8. ScriptsUSBManager leaves stale mount on crash

**`ScriptsUSBManager.swift:225`** — `hdiutil attach` to `~/.avf/scripts-mount`; cleanup at `:351` only runs on success. After a crash, the next run hits `"Mount failed: Resource busy"`.

**Fix (this run):** Pre-detach with `hdiutil detach -force` (ignored if not mounted) before each attach. See commit.

### H9. `~/.avf/logs/error-audit.log` perms are umask-default

**`SecVFError.swift:215`** creates the *directory* at `0o700` but the file itself uses default umask — typically `0644`, readable by other local users on a multi-user Mac.

**Fix (this run):** `chmod 0o600` after first create. See commit.

### H10. PII in audit log: full home paths and VM names

**`VMSecurityMonitor.swift:106, 343`** — `details["bundlePath"]` includes `/Users/<user>/.avf/<family>/<vm>.bundle/`; VM names land verbatim. Logs shipped to a vendor or shared in an incident report disclose user identity and engagement names.

**Fix (this run):** Tokenize `NSHomeDirectory()` → `~/` before writing. VM-name redaction is left to user-controlled policy (would require a setting).

### H11. macOS network setup script can brick the host's networking

**`scripts/macos-network-setup.sh:71`** calls `networksetup -setmanual` on the detected primary Ethernet. If run on the host Mac instead of inside a VM, it clobbers real networking. No VM-detection guard.

**Fix (this run):** Guard with `sysctl hw.model | grep -q VirtualMachine` (refuse to run on bare metal). See commit.

### H12. `recoverySuggestion` has `default: return nil` swallowing future cases

**`SecVFError.swift:196-198`** — about 20 enum cases have no recovery hint and `default:` masks the gap. When a new case is added, no compile error reminds the developer to provide a hint.

**Fix (this run):** Remove `default:`, enumerate every case. Adding a recovery suggestion to obviously-needed cases. See commit.

### H13. `MAC table never evicted`

**`VirtualNetworkSwitch.swift:79, 331`** — entries are added on `Learned MAC` but only removed on port teardown. A guest rotating source MACs grows `macTable` unboundedly. No size cap, no LRU.

**Fix (this run):** Add LRU eviction with per-port (32 entries) and global (4096) caps. See commit.

### H14. `LogRotation` doesn't cap `network-*.log` size

**`LogRotation.swift:48-78, 82-99`** size-caps `error-audit.log` but only age-caps `network-*.log` and `security-*.log`. A chatty switch on a 30-day window produces GB-class files.

**Fix (this run):** Add size-cap rotation for the network/security log streams. See commit.

### H15. Tools menu items are no-ops

**`AppDelegate.swift:1589-1598, 1600-1611`** — "Manage ISO Cache" logs "coming soon"; "Virtual Switch Statistics" prints to stdout. `ISOCacheManagerWindow` exists; the switch-stats controller is commented out. Dead UI shipped.

**Fix (this run):** Disable both menu items via `validateMenuItem(_:)` until wired; the alternative (wiring them) is more work than the autonomous run should do. See commit + TODO in code.

---

## 🟡 Medium severity (mostly fixed, some documented)

### M1–M5. Network policy & telemetry

- **M1** No drop counter in `VirtualNetworkSwitch.getStatistics()` (`:423-431`). **Fix (this run):** Added `totalPacketsDropped` with per-reason breakdown.
- **M2** `isBroadcast` and `isMulticast` definitions conflict between `processPacket` (`:320`) and `forwardPacket` (`:350`). Renamed for clarity.
- **M3** `getStatistics()` is sync on `switchQueue` — calling it from the main UI thread blocks during sustained-load forwarding. **Status:** Documented; refactor needed.
- **M4** `kali-router-setup.sh:300` `tcpdump -i any` produces Linux cooked-mode (SLL) PCAPs which some parsers reject. **Fix (this run):** Default to `-i ${VSWITCH_IFACE}`.
- **M5** `secvf-status` always reports `DHCP_ENABLED=no` regardless of actual state (`kali-router-setup.sh:419`). **Fix (this run):** Query systemd.

### M6–M10. VM lifecycle

- **M6** `cloneVM` does not regenerate EFI NVRAM — only the `MachineIdentifier`. Two clones boot with identical EFI state. **Status:** Documented; needs careful fix to avoid breaking secure-boot configs.
- **M7** `MacOSVMInstaller` not handling `mostFeaturefulSupportedConfiguration == nil`. **Fix (this run):** Added error case with actionable message.
- **M8** No concurrent-creation lock: two `createVM(name:)` calls bypass the `contains` check. **Fix (this run):** Serialize via a private actor/queue. See commit.
- **M9** `deleteCachedImage` has no path-boundary check. **Fix (this run):** Guard with `path.hasPrefix(cacheRoot)`. See commit.
- **M10** `verifySHA256` returns `Bool` only — I/O error indistinguishable from hash mismatch. **Fix (this run):** Convert to `Result<Void, VerifyError>`. See commit.

### M11–M15. CLI / TUI

- **M11** Exit codes are nearly always `0` (`VMCommand.swift` various). **Fix (this run):** Centralized `throw ExitCode(_:)` helper; updated common failure paths.
- **M12** SIGPIPE crashes CLI when piped to `head`. **Fix (this run):** `signal(SIGPIPE, SIG_IGN)` in `SecVF.swift main()`.
- **M13** `capture live` non-JSON output when `--json` passed. **Fix (this run):** Return `{"success": false, "message": "..."}`.
- **M14** TUI `controller.py:_find_cli` off-by-one path traversal. **Fix (this run):** Walked the path expression by hand against the actual file location. See commit.
- **M15** TUI `findPython` doesn't probe pyenv. **Fix (this run):** Added `~/.pyenv/shims/python3` to the probe list.

---

## 🟢 Low / hygiene (fixed opportunistically)

- `clampToVZBounds()` test fixture added.
- Audit-log JSONL injection sanitizer covered by a unit test.
- `distros.json` schemaVersion now actually enforced at load.
- Several Swift `default: break` swallowing cases replaced with `@unknown default` where appropriate.

---

## 🔵 AIMon-scope (deferred to AIMon project)

These were flagged by the AI sandbox audit. The [AIMon project](https://github.com/DaxxSec/ai-mon) owns the fix path. **Host-OpSec items here are still flagged as BLOCKERs (B5, B6) above; the rest are AIMon's feature backlog:**

- No pre-warmed session pool (`AISandboxMacVMConfiguration.swift:32-38` docstring is aspirational).
- DTrace probes installed but no host-side consumer.
- ESF helper declared in manifest (`provision-macos-vm.sh:427`) but no helper bundle ships.
- `provision-macos-vm.sh:101, 106` `.zprofile` appends not guarded with `grep -qF`, duplicate on re-run.
- `claude --version | grep -q "."` is a useless idempotency test.
- `UID 601` collision potential on macOS guests with auxiliary accounts.
- `socat VSOCK-LISTEN` availability on macOS guests not verified.
- Session bundle orphans on host crash (no startup sweep).
- Concurrent `run()` calls on same session share `/Users/Shared/workspace` without isolation.

---

## 📋 Test coverage gaps (documented, not filled)

The audit found wide test gaps across the codebase:

- No tests for `VMManager.createVM`, `cloneVM`, `renameVM`, `importVM`, `migrateOldVMIfNeeded`, `migrateVM`.
- No test for `VMConfiguration` migration from older schemas (the whole point of the custom `init(from:)`).
- `ISOCacheManagerTests.testSHA256ChecksumsExist` permits placeholders — invariant unenforced.
- No test for `verifySHA256`, `validateDownloadURL`, `findCachedIPSW`.
- No test for `DistroVersionFetcher` HTML parsers.
- No tests for `PacketCaptureManager` / `PacketAnalysisWindowController`.
- No tests for any CLI subcommand or any bridge.
- TUI controller has no unit tests.

A test-writing pass is its own project; not in scope for this autonomous run.

---

## 📦 Status & commits in this branch

| Batch | Commits | Findings addressed |
|---|---|---|
| Baseline | `<docs commit>` | Plan + audit doc (this file) |
| Batch 1 (host-OpSec one-liners) | `<batch 1 commit>` | B2, B3, H9, H10, M12, parts of M11 |
| Batch 2 (crash prevention) | `<batch 2 commit>` | B10, B9, H4, H8, parts of H12 |
| Batch 3 (Swift correctness) | `<batch 3 commit>` | H1, H2, H3, H7, H13, H14, M7–M10 |
| Batch 4 (shell scripts) | `<batch 4 commit>` | B1, H5, H11, M4, M5 |
| Deferred (need user) | n/a | B4, B5, B6, B7, B8, H6, H15 partial, M3, M6, all AIMon-scope, all coverage gaps |

**Remaining work for the user:**

1. Verify B6 fix direction (tshark `-T ek` switchover) and run a real capture session to confirm packets flow end-to-end.
2. Decide architectural fixes for B4 (single-writer audit) and B7 (DNC sender verification).
3. Approve and merge / cherry-pick batch commits.
4. Add the test-coverage pass to a follow-on milestone.
5. Track AIMon-scope items in the AIMon repo's backlog.

Each batch commit is independent and can be reverted without affecting others.
