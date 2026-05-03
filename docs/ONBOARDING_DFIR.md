# SecVF Onboarding Guide for DFIR Analysts

> Audience: digital forensics & incident response analysts who will use SecVF
> as a malware detonation, network forensics, and triage platform on macOS.
>
> Goal of this document: get you from a fresh clone to detonating a sample in
> a hardware-isolated VM with full packet capture in under an hour, and give
> you the mental model you need to trust the isolation while you work.

---

## 1. What SecVF actually is (in DFIR terms)

SecVF is a native macOS application built on Apple's Virtualization
Framework. From a forensics standpoint it gives you four things in one
process:

1. A **VM lifecycle manager** for Linux and macOS guests, with isolated bundles
   on disk under `~/.avf/`.
2. A **software L2/L3 switch** (`VirtualNetworkSwitch`) that VMs attach to,
   so you can route guest traffic through an analyst-controlled router VM
   instead of the host's NIC.
3. A **packet capture and analysis pipeline** wrapping `tshark`, with a
   Wireshark-style display-filter UI and PCAP export.
4. A **security monitor** that emits severity-leveled events
   (`INFO` → `WARNING` → `CRITICAL` → `EMERGENCY`) to `~/.avf/logs/`,
   so suspicious guest behavior leaves a forensic trail you can ship to a
   case file.

The closest comparable workflows are FLARE-VM behind a REMnux router, or
Cuckoo's network section, but everything here runs natively on Apple Silicon
under an Apple-blessed hypervisor with no third-party kernel extensions.

If you remember nothing else from this document, remember this: SecVF is
designed around the assumption that **the guest is hostile**. Every default
favors containment over convenience.

---

## 2. Threat model and isolation guarantees

Read this section before you put a real sample anywhere near a VM.

**What contains the guest:**

- Apple Virtualization Framework (`VZVirtualMachine`) — hardware-enforced VT
  boundary, not a container.
- No shared folders are configured by default. The guest's only filesystem
  is its own disk image inside the VM bundle.
- Network egress is whatever you wire up. In the default `NAT` mode the
  guest can reach the internet via the host. In `virtual` mode the guest
  has no path off the switch unless a router VM is also attached and you
  enable forwarding inside it.
- USB is opt-in. Scripts USB delivery uses an ISO image you build
  explicitly via `Tools → Mount Scripts USB to VM` (`⌘⇧U`).

**What is monitored, not contained:**

- `VMSecurityMonitor` watches host-side filesystem access patterns against
  VM bundles, host process activity, resource consumption, and VM state
  transitions. It logs to `~/.avf/logs/security-YYYY-MM-DD.log` and to
  `os_log` under subsystem `com.DaxxSec.SecVF` / category `Security`.
- `SecVFError` events that survive past first-line handling are written
  to `~/.avf/logs/error-audit.log`. Treat that file as part of the case
  artifact set if a detonation goes sideways.

**What is *not* contained — analyst-side gotchas:**

- The host macOS still browses the internet during analysis. Don't run
  the SecVF host on a network you're not willing to associate with the
  analysis traffic.
- IPSW and ISO downloads are pulled by SecVF over the host's NIC, not
  through the router VM. The download domains are pinned (Apple CDN for
  IPSW; per-distro mirror in `Resources/distros.json` for Linux).
- macOS guests require Apple Silicon. Linux ARM64 guests work everywhere
  on macOS 14+.

If you need an air-gapped analysis machine, take the host off the
network entirely and rely on the FakeNet workflow (Section 7) for
simulated internet.

---

## 3. Prerequisites

| Requirement | Minimum | Notes |
|---|---|---|
| macOS | 14.0 Sonoma | required for Virtualization features used here |
| Hardware | Apple Silicon (M1+) | required for macOS guest VMs; Linux ARM64 guests run fine on Intel via Rosetta |
| Xcode | 15.0+ | only if you build from source — the GitHub Actions workflow can also produce signed builds |
| `tshark` | optional but expected | install with `brew install wireshark`; without it the packet panel will not populate |
| Python | 3.10+ | only if you intend to use the TUI; `brew install python@3.12` is fine |
| Disk | ~80 GB free per macOS guest, 5–20 GB per Linux guest | bundles live under `~/.avf/` and grow as the guest writes |

You also need terminal access. Several of the workflows below (CLI, snapshots,
guest exec via vsock) assume you are comfortable in a shell.

---

## 4. Install and first launch

Clone, build, run:

```bash
git clone https://github.com/DaxxSec/SecVF.git
cd SecVF
open SecVF.xcodeproj
# In Xcode: select the SecVF scheme → ⌘R to build and run
```

If you prefer the command line:

```bash
xcodebuild -scheme SecVF -configuration Debug \
           -destination 'platform=macOS,arch=arm64' build
```

On first launch SecVF creates `~/.avf/` and its subdirectories. Verify:

```bash
ls -la ~/.avf
# Linux/      ← Linux VM bundles
# MacOS/      ← macOS VM bundles
# logs/       ← security, network, error-audit, iso-cache-audit
# (keys/, AISandbox/ created lazily)
```

Then install the companion CLI from the menu — `Tools → Install CLI Tool…`
(`⌘⇧I`). This drops `secvf-cli` somewhere on your `PATH` and is the entry
point for everything described in Section 9.

---

## 5. Lay of the land

A quick pass over the directory layout you will care about as an analyst.

### On disk

```
~/.avf/
├── Linux/
│   └── <VMName>.bundle/
│       ├── Disk.img
│       ├── NVRAM
│       ├── MachineIdentifier
│       └── metadata.json
├── MacOS/
│   └── <VMName>.bundle/
│       ├── Disk.img
│       ├── NVRAM
│       ├── MachineIdentifier
│       ├── *.ipsw
│       └── metadata.json
├── keys/
│   └── <VMName>/id_ed25519     ← per-VM SSH key, used by `secvf vm ssh`
├── AISandbox/
│   └── ai-sandbox-base-v1.bundle  ← golden image for ephemeral macOS sessions
└── logs/
    ├── security-YYYY-MM-DD.log
    ├── error-audit.log
    └── iso-cache-audit.log
```

`metadata.json` is a `Codable` snapshot of `VMConfiguration` (CPU, memory,
disk, OS type, distro, network mode). It does **not** contain runtime
status — `status` is recomputed each time the app launches. If you need
to script a VM rename or migrate a bundle between machines, the JSON is
safe to edit while the VM is stopped.

### In the app menus

| Menu item | Shortcut | What it shows |
|---|---|---|
| Monitoring → Security Logs | `⌘⇧1` | live tail of `security-*.log`, color-coded by severity |
| Monitoring → Network Logs | `⌘⇧2` | virtual switch traffic + connection log |
| Monitoring → Packet Analysis | `⌘⇧P` | full Wireshark-style window over `tshark` |
| Monitoring → Switch Statistics | `⌘⇧3` | port table, MAC table, forwarding/drop counters |
| Monitoring → ISO Cache Audit | `⌘⇧4` | every download, every checksum verification |
| Tools → Refresh VM List | `⌘R` | re-scan `~/.avf/` |
| Tools → Install CLI Tool | `⌘⇧I` | install `secvf-cli` to `PATH` |
| Tools → Mount Scripts USB to VM | `⌘⇧U` | hand the guest a tools/scripts ISO |

The shortcuts are defined in `AppDelegate.swift` and are good muscle
memory to learn early — you will use Packet Analysis (`⌘⇧P`) and
Security Logs (`⌘⇧1`) constantly.

---

## 6. First VM — a known-good Kali

Before you put anything malicious on this machine, build a clean Kali VM
and confirm everything works end-to-end.

1. **File → New VM** (or `⌘N`). Pick **Linux** → **Kali Linux**.
   - Defaults are 2 vCPU / 4 GB RAM / 64 GB disk. Bump CPU to 4 if you
     have the headroom — install will move noticeably faster.
   - Leave **Network: NAT** for now.
2. SecVF downloads the ISO into the cache (`~/.avf/cache/`) and verifies
   the SHA256 against the live checksum from `cdimage.kali.org`. Watch
   the ISO Cache Audit (`⌘⇧4`) — if you don't see a `verified` line for
   the file, *do not boot the VM*. A failed verification is the kind of
   supply-chain incident this whole project exists to detect.
3. Click **Start** (or `⌘S`). The installer boots in its own window.
4. Run through the Kali installer normally. Set a root password you can
   throw away — every analyst-facing automation here uses keys, not
   passwords.
5. After install, click **Stop** (`⌘.`) cleanly so the disk image
   commits.

Now do the same again — this time create a second VM called
`Kali-Router` with **Network: Virtual Network** and the **Configure as
security router VM** checkbox set. This VM will become the gateway for
your malware sandbox.

---

## 7. The malware analysis lab pattern

This is the workflow that justifies SecVF's existence.

```
  ┌─────────────────┐                         ┌──────────────────┐
  │ Sample VM       │                         │ Kali Router VM   │
  │ (e.g. Win,      │  Virtual Network mode   │  10.0.100.1/24   │
  │  Linux, macOS)  │ ───────────────────────▶│  iptables, NAT   │
  │                 │   (no host bridging)    │  tcpdump, FakeNet│
  └─────────────────┘                         └──────────────────┘
                                                       │
                                                       │  optional bridge
                                                       ▼
                                              ┌──────────────────┐
                                              │   Host (NAT) →   │
                                              │     Internet     │
                                              └──────────────────┘

  Out-of-band on the host: PacketCaptureManager attaches tshark to the
  router's NIC and feeds the SecVF Packet Analysis window.
```

### 7a. Provision the router

Boot the `Kali-Router` VM. Get the setup script onto it (the simplest is
to mount it via `Tools → Mount Scripts USB to VM`), then inside the
guest:

```bash
chmod +x /tmp/kali-router-setup.sh
sudo /tmp/kali-router-setup.sh
```

This script (`scripts/kali-router-setup.sh`):

- pins the router NIC at `10.0.100.1/24`,
- enables IPv4 forwarding persistently,
- installs `tcpdump`, `tshark`, `nmap`, `arpwatch`, `iftop`, etc.,
- writes helper commands `secvf-status`, `secvf-monitor`, and
  `secvf-capture` into `/usr/local/bin/`,
- configures (but does not start) ISC DHCP serving `10.0.100.50–200`,
- configures iptables logging into `/var/log/iptables.log`.

> **Note** — the project's `CLAUDE.md` mentions helpers prefixed
> `csirtvf-…`. The actual script installs them as `secvf-…`. Use the
> `secvf-…` names; that mismatch is stale documentation, not a bug.

Run `secvf-status` inside the router to confirm the network came up.

NAT to the host is **off** by default. Turn it on only when you need to
let the guest call out to the real internet:

```bash
sudo iptables -t nat -A POSTROUTING -s 10.0.100.0/24 \
              ! -d 10.0.100.0/24 -j MASQUERADE
sudo netfilter-persistent save
```

### 7b. Provision the sample VM

Create the malware sandbox VM (Linux or Windows installer ISO of your
choosing, or macOS via IPSW). Set its network mode to **Virtual Network**.
For a macOS guest, the New VM sheet exposes a router-VM picker — choose
your `Kali-Router`. For a Linux guest, leave the **Configure as security
router VM** checkbox unchecked; the VM will simply attach to the switch
and pick up DHCP from the router. The guest will
get DHCP from the router (if you started `isc-dhcp-server`) or you can
hand-configure `10.0.100.x` with gateway `10.0.100.1`.

Verify isolation before you detonate anything:

- From the sample VM: `ping 10.0.100.1` should succeed.
- From the sample VM: `ping 1.1.1.1` should **fail** unless you enabled
  NAT in 7a.
- From the host: `ifconfig` should not show the sample VM's IP — the
  whole network only exists inside the SecVF process and the switch.

### 7c. FakeNet for offline detonation

For samples you don't want touching the real internet — the common case —
flip the router into FakeNet mode:

```bash
sudo /tmp/kali-fakenet-setup.sh start
```

This (`scripts/kali-fakenet-setup.sh`) hijacks DNS so every name resolves
to `10.0.100.1`, stands up nginx with a self-signed cert to absorb HTTP
and HTTPS, and starts a full-interface PCAP into `/var/log/fakenet/`.
DNS queries land in `/var/log/fakenet/dns.log` and POST/PUT bodies land
in `/var/log/fakenet/suspicious-requests.log`.

The pattern from here is:

1. `⌘⇧P` to open the host-side Packet Analysis window. **Start Capture.**
2. `⌘⇧1` in a second window for the Security Log tail.
3. Drop the sample on the guest and execute it.
4. Watch DNS and HTTP appear in both the FakeNet logs and the host
   capture. Anything attempting non-DNS/HTTP egress will land in the
   PCAP and in the iptables log.

When the run is over: stop the capture, **Save PCAP** for the case
file, copy `/var/log/fakenet/*` off the router VM (`secvf vm copy-from
Kali-Router /var/log/fakenet/ ./case-NN/fakenet/`), then either snapshot
the VMs (Section 10) or destroy them.

---

## 8. Live packet analysis

The host-side window (`⌘⇧P`) is where most analyst time goes.

- **Start / Stop / Clear** at the top — these wrap `tshark` lifecycles.
- **Display filter** uses Wireshark syntax. The common ones you will
  reach for:

  | Filter | Use |
  |---|---|
  | `tcp` | only TCP segments |
  | `udp.port == 53` | DNS only |
  | `http` | HTTP requests/responses |
  | `tls.handshake.type == 1` | client hellos (good for SNI/JA3) |
  | `ip.addr == 10.0.100.50` | one specific guest |
  | `!arp && !icmp` | mute the noisy floor |

- The protocol-stats panel shows live counts; pivot off it when you see a
  protocol you didn't expect (DNS over a non-53 port, weird ICMP types,
  unexpected SMB).
- **Export PCAP** writes a standard libpcap file. Open it in Wireshark on
  the analyst workstation if you want NetworkMiner / Brim / Zeek to chew
  on it later.

The CLI mirrors all of this — see Section 9.

If the panel stays empty, check, in order:

1. `which tshark` on the host. If missing, `brew install wireshark`.
2. `~/.avf/logs/error-audit.log` for `tsharkLaunchFailed` or similar.
3. The VM's network mode. Capture only attaches to the virtual switch
   path; a VM in `NAT` mode uses host NAT and won't show up here.

---

## 9. CLI and TUI

The CLI is the supported scripting surface. Two layers exist:

- `secvf-cli` — Swift binary built from `SecVF/cli/`. Subcommands: `vm`,
  `usb`, `switch`, `capture`, `tui`. All commands accept `--json` for
  machine-readable output, which makes integration with case-management
  pipelines straightforward.
- `secvf-cli tui` — launches the Python/Textual TUI from
  `SecVF/cli/tui/`. Requires `python3` ≥ 3.10 and the `textual`/`rich`
  packages.

A few commands you will use often:

```bash
# Inventory
secvf-cli vm list --json

# Lifecycle (background by default; --foreground attaches to console)
secvf-cli vm start "Kali-Router"
secvf-cli vm stop  "Kali-Router"            # graceful
secvf-cli vm stop  "Kali-Router" --force    # hard power off
secvf-cli vm status "Sample-1"

# Move evidence in / out
secvf-cli vm copy-to   "Kali-Router" ./script.sh /tmp/
secvf-cli vm copy-from "Kali-Router" /var/log/fakenet/ ./case-42/fakenet/
secvf-cli vm ssh       "Kali-Router" --command "secvf-status"

# AI-Sandbox-style guest exec over vsock (no SSH, no password)
secvf-cli vm exec "AI-Sandbox" --command "uname -a"
secvf-cli vm exec "AI-Sandbox" --root --command "dmesg | tail"
secvf-cli vm exec "AI-Sandbox" --stream --command "dtrace -n 'syscall::open*:entry'"

# Snapshots — your "evidence preserved" point
secvf-cli vm snapshot create  "Sample-1" --name pre-detonation
secvf-cli vm snapshot list    "Sample-1"
secvf-cli vm snapshot restore "Sample-1" --name pre-detonation

# Capture from the CLI
secvf-cli capture start --interface any --output ~/cases/42.pcap
secvf-cli capture status
secvf-cli capture stop
secvf-cli capture export ~/cases/42-dns.pcap --filter "udp.port == 53"
secvf-cli capture live   --filter "ip.addr == 10.0.100.50"

# Switch introspection
secvf-cli switch status
secvf-cli switch stats --watch    # live counters, refreshes every second
secvf-cli switch ports
secvf-cli switch macs

# Scripts/tools delivery via virtual USB
secvf-cli usb list --include-virtual
secvf-cli usb create-virtual --name analyst-tools --size 512 \
                             --format dmg --source ~/Tools/
secvf-cli usb mount  analyst-tools --to "Sample-1"
secvf-cli usb eject  analyst-tools
```

`vm exec` is worth highlighting: it talks to the in-guest agent over a
Unix domain socket at `/tmp/secvf-exec-<UUID>.sock`, which proxies to
the guest's `vsock:2222`. There is no SSH, no exposed port on the
network. Three modes are routed by prefix tokens (`(default)`, `ROOT`,
`STREAM`); the flags above generate the right prefix for you.

---

## 10. Snapshots, evidence, and chain of custody

`secvf-cli vm snapshot` is the primary checkpoint primitive. Recommended
DFIR pattern:

1. Create a `clean-install` snapshot immediately after a successful
   guest install, before any tooling is added.
2. Create a `pre-detonation` snapshot right before each sample run.
3. After detonation: capture the PCAP, copy guest artifacts off via
   `secvf-cli vm copy-from`, snapshot as `post-detonation-<sample-sha256>`.
4. Restore to `pre-detonation` for the next sample, or destroy the VM
   if you want maximum hygiene.

The bundle directory itself (`~/.avf/Linux/Sample-1.bundle/`) is
self-contained. Compressing it (`tar -czf`) gives you a single file you
can hash for the case record:

```bash
shasum -a 256 ~/cases/42/Sample-1-post.tar.gz
```

Pair it with the matching PCAP, the FakeNet logs, the
`security-YYYY-MM-DD.log` slice covering the run, and a copy of
`error-audit.log`. That bundle of files is your reproducible artifact
set.

---

## 11. Triaging the security log

`~/.avf/logs/security-YYYY-MM-DD.log` is your tripwire feed. The format
is `[SEVERITY] <type> - <vmName>: <message>`, mirrored to `os_log` so
you can also pull it with:

```bash
log show --predicate 'subsystem == "com.DaxxSec.SecVF" \
                       AND category == "Security"' --last 1h
```

Severity meanings, from `VMSecurityMonitor`:

| Severity | When you see it | Suggested response |
|---|---|---|
| `INFO` | normal lifecycle, monitoring start/stop | none — confirms instrumentation is running |
| `WARNING` | suspicious-but-not-critical: unusual filesystem access patterns, unexpected resource burst | snapshot the VM, keep going |
| `CRITICAL` | possible breakout attempt — host process touching VM bundles, anomalous syscalls | stop the VM, preserve the bundle, investigate the host process |
| `EMERGENCY` | active breakout indicator | stop the VM immediately, treat the host as suspect |

`error-audit.log` is the tail end of typed-error handling. Most lines
there are recoverable conditions (`installerAttachmentFailed`,
`scriptsCopyFailed`), but a recurring `vmStartFailed` against the same
bundle usually means corrupted NVRAM — see Section 12.

The log directory rotates by `LogRotation`: files older than 30 days
are pruned automatically, and `error-audit.log` is rolled to
`error-audit.log.1` when it exceeds the size cap. If you need
indefinite retention for a case, copy files out to your case storage
the same day.

---

## 12. Common failures and what to do about them

**VM won't start, error mentions NVRAM or MachineIdentifier.**
Apple Virtualization Framework is strict about these files. Stop the
app, move `~/.avf/<OS>/<VM>.bundle/NVRAM` and `MachineIdentifier`
aside, and let SecVF regenerate them on next start. You will lose
EFI boot variables but the disk is intact.

**ISO download fails or checksum mismatch.**
Check `~/.avf/logs/iso-cache-audit.log` for the `expected` vs `actual`
hashes. Treat any mismatch as a real signal — the project pins both
the download URL domain and the checksum source per distro in
`SecVF/Resources/distros.json`. Do not "just continue" through a
checksum failure. Update the distro JSON if the upstream version moved
and the old checksum is genuinely stale.

**macOS guest install errors out before reaching the desktop.**
Apple Silicon only. Confirm with `uname -m` returning `arm64`. The
IPSW download itself goes through Apple's CDN allowlist
(`*.cdn-apple.com`) — no other source is permitted, by design.

**Packet panel is empty even with traffic flowing.**
See the checklist at the end of Section 8. The most common cause is
a sample VM in `NAT` mode rather than `Virtual Network` mode.

**`vm exec` returns "exec bridge not active".**
The vsock UDS at `/tmp/secvf-exec-<UUID>.sock` only exists while the VM
is running with a vsock device. Most general-purpose Linux VMs are
created without one; the AI Sandbox flow does provision it. For a
generic guest, fall back to `secvf-cli vm ssh`.

**Guest claims it has no network at all.**
Inside the router VM, run `secvf-status`. Confirm the switch interface
is up and `/etc/secvf-router.conf` has a `VSWITCH_IFACE` set. Then on
the host, `Monitoring → Switch Statistics` should show the guest's MAC
in the table within a few seconds of guest boot.

**Forensics machine is shared and you need to isolate cases.**
There is currently no per-case namespacing in `~/.avf/`. Create cases
under their own macOS user accounts, or symlink `~/.avf` to a
case-specific directory before launching SecVF.

---

## 13. Where to look in the code

When the docs and the binary disagree, the source is authoritative.
Pointers, in rough order of how often a DFIR analyst will need them:

- `SecVF/VMSecurityMonitor.swift` — every event severity, every monitor
  type, every place a `WARNING` or `CRITICAL` is raised.
- `SecVF/PacketCaptureManager.swift` — how `tshark` is invoked, the
  Combine publishers that drive the UI, PCAP write path.
- `SecVF/VirtualNetworkSwitch.swift` — L2 forwarding, MAC learning,
  drop counters. The math behind the Switch Statistics window.
- `SecVF/SecVFError.swift` — exhaustive list of typed errors, which is
  the best single reference for "what can go wrong and what it means".
- `SecVF/Resources/distros.json` — the pinned distro catalog
  (downloads, checksum URLs, expected size caps).
- `scripts/kali-router-setup.sh` and `scripts/kali-fakenet-setup.sh` —
  exact iptables/sysctl/dnsmasq/nginx configuration applied inside
  the router VM.
- `SecVF/cli/Sources/secvf-cli/Commands/` — one file per CLI
  subcommand; the `--help` output of each tracks these directly.

`SecVF/Tests/` has Given/When/Then-style tests including
`VirtualNetworkSwitchTests` and `IntegrationTests` — useful as
executable documentation when you need to know the expected behavior
of a particular component without spelunking 2,600 lines of
`VMLibraryWindowController.swift`.

---

## 14. A suggested first-week plan

A week of ~2-hour sessions to get fully self-sufficient:

1. **Day 1.** Install, build, create the throwaway Kali VM in NAT mode
   (Section 6). Reach a clean desktop. Stop cleanly.
2. **Day 2.** Build `Kali-Router` with `kali-router-setup.sh`. Build
   a second guest in Virtual Network mode pointed at it. Confirm the
   isolation tests at the end of 7b pass.
3. **Day 3.** Run the FakeNet workflow against a benign curl-style
   self-test (`curl http://example.com`, `dig anything.lan`, etc.).
   Practice exporting the PCAP and copying FakeNet logs off via
   `secvf-cli vm copy-from`. You are not yet detonating a real sample.
4. **Day 4.** Install the CLI (`⌘⇧I`), run through the commands in
   Section 9. Build a small `bash`/`zsh` wrapper for your own common
   case-prep steps (snapshot → start capture → start VM).
5. **Day 5.** Pick a known, well-documented sample (an EICAR-style
   placeholder, or a public PCAP-replay tool that calls out to a known
   C2 sinkhole). Run the full lab pattern end-to-end. Compare your
   captured artifacts to the public IOCs.

By the end of week one you should be writing CLI scripts faster than
you click menu items, and your security log triage should be
instinctive.

---

## 15. Getting unstuck

- Code questions: read the file pointers in Section 13 and the
  in-source comments in `SecVFError.swift` and `VMSecurityMonitor.swift`.
  Both are heavily annotated.
- App-level bugs: check `~/.avf/logs/error-audit.log` first, then
  `log show --predicate 'subsystem == "com.DaxxSec.SecVF"' --last 1h`.
- Network weirdness: `Monitoring → Switch Statistics` (`⌘⇧3`),
  `secvf-cli switch ports`, and the iptables log inside the router VM
  (`/var/log/iptables.log`) cover almost everything.
- Repository, issues, contributions: see the project README and
  `CHANGELOG.md`.

Welcome aboard. Build paranoid, log everything, snapshot before you
detonate.
