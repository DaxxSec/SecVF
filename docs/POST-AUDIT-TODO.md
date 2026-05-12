# Post-Audit Todo

Everything that didn't make it into the pre-launch audit PR ([#7](https://github.com/DaxxSec/SecVF/pull/7)). Grouped by category, roughly ordered by what blocks launch.

Companion to [`PRE-LAUNCH-AUDIT.md`](PRE-LAUNCH-AUDIT.md) and [`PRE-LAUNCH-PLAN.md`](PRE-LAUNCH-PLAN.md).

Last updated: 2026-05-11 (post-Batch-5 push).

---

## 🔴 Audit items still open

These were flagged in the audit but deferred or (in one case) reported-as-fixed-but-actually-not.

### H12 — `recoverySuggestion` still has `default: return nil`

**`SecVFError.swift:196-198`** — the audit doc claims this was fixed but `default: return nil` is still in place. New enum cases will silently miss a recovery hint.

**Fix:** Remove `default:`, enumerate every case explicitly, add a recovery hint to each. ~20 cases. ~30 min of work.

### M3 — `getStatistics()` blocks main thread under sustained load

**`VirtualNetworkSwitch.swift:423-431`** — `getStatistics()` is sync on `switchQueue`. Calling it from the main UI thread during high packet flow blocks rendering.

**Fix:** Either snapshot stats into an atomic struct on each forward and read lock-free, or make `getStatistics()` async with a cached "last good" return for sync callers.

### M6 — `cloneVM` doesn't regenerate EFI NVRAM

**`VMManager.cloneVM`** — only regenerates the `MachineIdentifier`. Two clones boot with identical EFI variable state, which can cause secure-boot / TPM-like state collisions.

**Fix:** Create a fresh NVRAM file on clone (the same way `createVM` does). Care needed not to break VMs that intentionally share EFI state.

---

## 🟠 Launch readiness (separate from code fixes)

### Code signing + notarization

- [ ] Wire `codesign` with the Developer ID Application certificate into the release build
- [ ] Set up `xcrun notarytool submit` in a release script (manual for first run, CI later)
- [ ] `xcrun stapler staple` the notarized artifact
- [ ] First-launch UX check: Gatekeeper warnings, right-click-Open instructions documented

### Distribution

- [ ] DMG build script (`scripts/build-release-dmg.sh`)
- [ ] Hosted on daxxsec.tech with SHA-256 + signed checksum file
- [ ] Update wiki "Download" page when the DMG is real
- [ ] Decide: keep an unsigned .app available for power users, or DMG only?

### Auto-update

- [ ] Sparkle integration (signed appcast)
- [ ] Appcast hosting on daxxsec.tech
- [ ] Decide opt-in vs opt-out auto-check (security tool — probably opt-in by default)

### License

- [ ] Pick: AGPL-3.0 (copyleft, prevents proprietary forks) vs MIT (permissive, friendlier for ecosystem). Direction is "donations forever, no commercial tier" — AGPL keeps the spirit; MIT is friendlier if you want devs to fork freely.
- [ ] Add LICENSE file to repo root
- [ ] Update wiki + website footer

---

## 🟡 Testing gaps (carry-over from `PRE-LAUNCH-PLAN.md`)

### Unit tests not yet written

- [ ] `VMManager.createVM` — happy path, partial failure cleanup, bundle-exists collision
- [ ] `VMManager.cloneVM` + `importVM` — same coverage
- [ ] `ISOCacheManager.verifySHA256` — match, mismatch, I/O error (now `Result<Void, VerifyError>`)
- [ ] `DistroVersionFetcher` — happy path, network failure, malformed mirror response
- [ ] `AVFAuditLog.append` / `appendAsync` — concurrent producers stay line-coherent
- [ ] `VMConfiguration.clampCPU` / `clampMemory` — bounds enforcement
- [ ] `VirtualNetworkSwitch.detectMACSpoof` — true positive + false positive cases

### Integration tests

- [ ] End-to-end VM create → start → stop → delete (Linux)
- [ ] End-to-end VM create → install → boot (macOS, needs IPSW)
- [ ] Two VMs on the same virtual switch — packet round-trip
- [ ] Router VM + client VM + FakeNet — DNS resolution + HTTP response capture
- [ ] CLI ↔ app DistributedNotificationCenter bridge — start/stop/force-stop from CLI

### Soak / stability

- [ ] 48-hour continuous run: 1 router + 2 client VMs + packet capture
- [ ] Watch for: file-handle leaks, log file size growth, memory creep, switch-queue saturation
- [ ] Verify B4 (single-writer audit log) actually holds under sustained concurrent producers

### Hardware matrix

- [ ] M1 + macOS 14 (Sonoma)
- [ ] M2 + macOS 15 (Sequoia)
- [ ] M3 + macOS 26
- [ ] M4 + macOS 26 (if you have one)
- [ ] Resource: low (8 GB) + medium (16 GB) + high (64 GB) Mac variants

### Audit-doc accuracy pass

- [ ] Reconcile the claims in `PRE-LAUNCH-AUDIT.md` against actual commits — H12 was flagged "fixed (this run)" but isn't. Spot-check the rest.

---

## 🔵 AIMon-scope (deferred to [ai-mon](https://github.com/DaxxSec/ai-mon))

The AI sandbox subsystem belongs to the AIMon project, not SecVF 1.0. Items flagged below need to be tracked there.

- [ ] **B5** — vsock exec bridge UDS perms (`chmod 0666`) + basename-only allowlist. Need UDS perm tightening + caller authentication.
- [ ] **B6_AIMon** — `VsockChannel.connect` has no message-size bound, no read timeout. Bounded reads + wall-clock read deadline needed.
- [ ] **B8** — `AISandboxVMBundle.clone` uses `FileManager.copyItem` instead of `clonefile(2)`. Defeats the ephemeral-session design (full 64 GiB byte copy vs APFS CoW).
- [ ] No pre-warmed session pool (docstring is aspirational).
- [ ] DTrace probes installed but no host-side consumer.
- [ ] ESF helper declared in manifest but no helper bundle ships.
- [ ] `provision-macos-vm.sh` `.zprofile` appends not guarded with `grep -qF` — duplicate lines on re-run.
- [ ] `claude --version | grep -q "."` is a useless idempotency test in the provision script.

---

## 🟣 Marketing + distribution

### Repo housekeeping

- [ ] `.github/FUNDING.yml` for GitHub Sponsors (quiet, just the repo header button)
- [ ] Memory note update: `~/.claude/projects/.../memory/project_distribution_model.md` still describes the two-forks App Store plan. Rewrite to "direct distribution via daxxsec.tech, notarized DMG, donations-only."
- [ ] Sweep website + wiki (in [`daxxsec.tech`](https://github.com/DaxxSec/daxxsec.tech) private repo) for "Coming to App Store" / paid-tier copy. Drop it.
- [ ] Re-enable downloads on the website once the notarized DMG is real (currently disabled per user request)

### Submissions / discovery

- [ ] [Terminal Trove](https://terminaltrove.com/submit) — TUI fits the audience
- [ ] [awesome-malware-analysis](https://github.com/rshipp/awesome-malware-analysis) — submit PR
- [ ] [awesome-macos](https://github.com/iCHAIT/awesome-macOS) — submit PR
- [ ] [awesome-virtualization](https://github.com/Wenzel/awesome-virtualization) — submit PR
- [ ] [awesome-security](https://github.com/sbilly/awesome-security) — submit PR
- [ ] [AlternativeTo.net](https://alternativeto.net) — list as alternative to Cuckoo Sandbox, ANY.RUN, REMnux
- [ ] [console.dev newsletter](https://console.dev) — email pitch with screenshot
- [ ] [One Thing Well](https://onethingwell.org) — fits the indie Mac-native tool aesthetic

### Launch content

- [ ] Medium post: *"Analyzing macOS malware with SecVF: a hands-on walkthrough"* (synthetic sample only; the no-real-malware hard rule still applies)
- [ ] Show HN post when the post + DMG are both live
- [ ] Post to r/netsec, r/Malware, r/blueteamsec (link the Medium post, not the tool — community conventions on self-promo)
- [ ] r/macapps + r/MacOS — Mac-native angle
- [ ] r/LocalLLaMA + Anthropic dev Discord + MCP community — once `secvf-mcp` ships

### Long-term

- [ ] BSides regional talk
- [ ] YouTube screencast series (use cases, not feature demos)
- [ ] Wikipedia article? Probably premature until users-in-the-wild

---

## 🟢 Future direction

### `secvf-mcp` (MCP wrapper for agent use)

See [`MCP-WRAPPER-DESIGN.md`](MCP-WRAPPER-DESIGN.md) for the full design.

Highlights:
- Exposes the CLI as an MCP server so Claude / any MCP-compatible agent can drive SecVF natively
- Tiered tool catalog: read-only → safe-mutate → destructive (with gating)
- Composite "workflow" tools (`secvf_detonate`, `secvf_replay`, `secvf_summarize`) — the actual agent ergonomics
- Phased: read-only first, lifecycle second, composite workflows third, destructive last

### Audit doc accuracy

- [ ] Reconcile H12 status (audit doc says fixed, code says no)
- [ ] Spot-check every "Fix (this run)" claim against the actual diffs

### Things explicitly NOT planned

- App Store fork — dropped (sandbox would strip the core features)
- Paid commercial tier — dropped (donations forever, per user direction)
- Cloud / SaaS version — out of scope (this is a local tool by design)

---

## How to use this list

1. When a launch-readiness item is done, check the box and commit
2. When an audit item lands, link the PR/commit in the relevant section
3. When something is no longer relevant, strike it through (don't delete — keeps history)
4. New items go in the right category; if no category fits, add one
