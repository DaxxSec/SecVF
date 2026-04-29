# SecVF Security Guide

## Purpose & Threat Model

SecVF is designed for **malware analysis** and **security research** in isolated sandbox environments. The primary threat model assumes:

- **Hostile guest OS** - VM guests may contain sophisticated malware attempting to escape
- **Exploit attempts** - Malware may target Virtualization framework vulnerabilities
- **Data exfiltration** - Malicious code attempting to access host filesystem or network
- **Resource attacks** - Fork bombs, memory exhaustion, CPU saturation
- **Persistence attempts** - Malware trying to survive VM restarts or infect host

## Security Architecture

### 1. **Apple Virtualization Framework Isolation**

SecVF leverages macOS's native Virtualization framework which provides:

- **Hardware-enforced isolation** via Apple's hypervisor
- **Memory isolation** - Guest cannot access host memory
- **CPU isolation** - Guest runs in isolated virtual CPU context
- **Separate address spaces** for guest and host
- **No shared folders by default** (unlike VMware/VirtualBox)

### 2. **Filesystem Containment**

#### VM Bundle Isolation
Each VM is contained in a `.bundle` directory:
```
~/.avf/[Linux|MacOS]/<VMName>.bundle/
├── Disk.img           # Guest filesystem (isolated)
├── NVRAM              # EFI variables (isolated)
├── MachineIdentifier  # VM ID (isolated)
├── metadata.json      # Configuration (read-only to guest)
└── *.ipsw            # macOS restore image (macOS VMs only)
```

**Security Properties:**
- ✅ Guest OS cannot access parent directories
- ✅ Guests cannot access other VM bundles
- ✅ Host filesystem is completely inaccessible from guest
- ✅ No default shared folders or clipboard (unless explicitly enabled)

#### Monitored Filesystem Access
- Real-time monitoring of VM bundle directory changes
- Detects unauthorized access attempts
- Logs all filesystem events for forensic analysis

### 3. **Network Isolation**

**Default Configuration: NAT Mode**
- Guest has outbound internet access (for malware analysis)
- Guest cannot access host services
- Guest cannot discover other VMs
- No inbound connections to guest (firewall)

**Security Implications:**
⚠️ **WARNING**: Malware CAN communicate with external C2 servers
- Monitor network traffic externally if analyzing APTs
- Consider using a separate analysis network
- Guest cannot port scan or attack local network

### 4. **Security Monitoring System**

SecVF includes `VMSecurityMonitor` that provides:

#### Real-Time Monitoring
- **Filesystem activity** - Tracks changes to VM bundles
- **Resource usage** - Monitors CPU/memory for abnormal patterns
- **VM state changes** - Logs all lifecycle events
- **Process monitoring** - Detects suspicious host processes

#### Event Severity Levels
- `INFO` - Normal operational events
- `WARNING` - Suspicious activity warranting attention
- `CRITICAL` - Potential breakout attempt
- `EMERGENCY` - Active security breach detected

#### Security Logs
Located at: `~/.avf/logs/security-YYYY-MM-DD.log`

Example log entries:
```
[2025-11-13 17:30:15] [INFO] VM_STATE_CHANGE - UbuntuMalware: VM started - security monitoring active
[2025-11-13 17:30:20] [INFO] FILESYSTEM_ACCESS - UbuntuMalware: VM bundle filesystem activity detected
[2025-11-13 17:35:42] [WARNING] RESOURCE_EXHAUSTION - UbuntuMalware: High host memory usage detected
```

### 5. **Download Security (IPSW)**

macOS IPSW downloads implement multi-layer security:

1. **Source Validation** - URLs only from Apple's official API
2. **Domain Whitelist** - Hard-coded Apple CDN domains only
3. **HTTPS Enforcement** - TLS 1.2+ required
4. **File Type Validation** - Only `.ipsw` files accepted
5. **Certificate Pinning** - SSL cert validation for Apple domains

See `MacOSVMInstaller.swift` security header for complete details.

### 6. **AI Sandbox Exec Channel** (vsock + UDS bridge)

The AI Sandbox guest VM (`AISandboxMacVMConfiguration`) ships with a vsock
exec agent at port 2222 inside the guest, plus a host-side bridge that
exposes that channel as a Unix domain socket at `/tmp/secvf-exec-<UUID>.sock`
so cross-process clients (e.g. `secvf-cli vm exec`, ai-mon's SecVFTracer)
can drive the guest.

This is a deliberate trust boundary, defended by **three layered controls**:

#### A. Host-side peer authentication (`VsockExecBridge`)

The UDS is mode `0666` so any local user can `connect()`, but the bridge
calls `getpeereid()` on each accept and refuses the connection if the
peer's uid is not on an allowlist:

- Default allowlist: only the user running SecVF.app.
- Opt-in additions: users (numeric uid or username) listed in
  `~/.avf/config/exec-bridge-allowlist`, one per line, comments `#`.
- Reload on every connection — config edits take effect immediately.

Refused connections see `secvf-exec-bridge: uid N not in allowlist` and
the bridge logs the event via `NSLog`.

#### B. Guest-side mode-prefix routing (`ai-sandbox-exec-handler.sh`)

The exec agent in the guest reads one command line per connection and
routes by prefix:

| Prefix     | User                | Timeout | Use case                          |
| ---------- | ------------------- | ------- | --------------------------------- |
| (none)     | `ai-sandbox-agent`  | 120 s   | Default — sandbox-confined exec   |
| `ROOT `    | `root`              | 120 s   | Setup, introspection, `ps`/`lsof` |
| `STREAM `  | `root`              | none    | Long-lived observability probes   |

Default mode runs as a non-admin user (`uid 601`) with a 120 s ceiling —
that's the right shape for general agent commands. ROOT and STREAM are
elevated and should only be reached over an authenticated channel.

#### C. Guest-side STREAM binary whitelist

Even if the host-side gate ever fails open, STREAM mode is restricted to
a small set of observability binaries:

```
dtrace fs_usage ktrace top vm_stat memory_pressure sysctl tail log
```

Anything else in STREAM exits with code 64 and a rejection message. So
the worst-case outcome of a bridge auth bypass is an attacker running
`top` as root inside an already-compromised guest — not arbitrary code
execution.

#### Trust model summary

| Actor                              | Can reach the guest?                          |
| ---------------------------------- | --------------------------------------------- |
| Process running as the SecVF user  | Yes — full exec, default                      |
| Process running as another local user, on the allowlist | Yes — full exec, opt-in   |
| Process running as another local user, NOT on the allowlist | No — bridge refuses    |
| Remote attacker over the network   | No — UDS is local-only                        |
| Compromised guest (privilege gain) | n/a — already inside the sandbox; controls do not apply outward |

#### What this channel deliberately allows

- `secvf-cli vm exec OpenClawVM --command 'ps -A'` — list guest processes
- `secvf-cli vm exec OpenClawVM --root --command 'lsof -p $PID -d 1,2'` — privileged introspection
- `secvf-cli vm exec OpenClawVM --stream --command 'dtrace -p $PID -s writemon.d'` — live syscall capture for ai-mon

#### Cross-user reminder

If you add another user to the allowlist, you grant them the ability to
run `dtrace`/`ps`/etc. inside the guest as root. They can read anything
the guest has. They CANNOT use this channel to gain privileges on the
host — the bridge proxies bytes, it doesn't run host-side commands.

### 7. **VirtioFS Workspace Direction**

The AI Sandbox guest mounts three host directories via VirtioFS:

| Guest path     | Host path                          | Mode | Purpose                        |
| -------------- | ---------------------------------- | ---- | ------------------------------ |
| `/workspace`   | `~/ai-sandbox-workspace/`          | rw   | Agent's writable workspace     |
| `/sessions-ro` | `~/.avf/AISandbox/sessions/`       | ro   | Prior session history          |
| `/anchor-ro`   | `~/ai-sandbox-workspace/anchor/`   | ro   | Identity anchor (immutable)    |

**`/workspace` is the only path the guest can write to host-visible
storage.** A compromised guest can drop files there. Host-side processes
that consume `/workspace` content (analysis tools, scripts, etc.) MUST
treat its contents as untrusted input — same threat model as a download
from the internet.

The dtrace telemetry JSONL files (`dtrace-exec.jsonl`, etc.) are written
into `/workspace/.csirt-telemetry/` by the guest; consumers on the host
should sanity-check structure before parsing.

### 8. **Entitlements & Sandboxing**

Required entitlements (`SecVF.entitlements`):
```xml
<key>com.apple.security.virtualization</key>     <!-- VM access -->
<key>com.apple.security.network.client</key>     <!-- Network -->
<key>com.apple.security.files.downloads.read-write</key>  <!-- IPSW downloads -->
```

**Not Granted:**
- ❌ No arbitrary file system access
- ❌ No camera/microphone access (except guest VM audio)
- ❌ No shared folder capabilities
- ❌ No automatic login items

### 9. **Log Retention & PII Considerations**

SecVF writes three log streams to `~/.avf/logs/`:

| File                            | Contents                                    | PII Risk |
| ------------------------------- | ------------------------------------------- | -------- |
| `network-YYYY-MM-DD.log`        | L2 metadata: MACs, EtherType, sizes         | Low — metadata only, no payloads |
| `security-YYYY-MM-DD.log`       | VM lifecycle, fs events, guest stats alerts | Low — VM names + thresholds |
| `error-audit.log`               | Typed error chain w/ paths                  | Medium — may include filesystem paths from the running user's home |

**No payload bodies are logged by default.** Packet payloads only land on
disk if you explicitly start a tshark capture (the `Capture` tab), in
which case they're written under `/var/captures/` inside the Kali router
VM (not the host). PCAP files there contain everything the guests sent
over the virtual switch.

**Retention is currently unbounded.** Old log files accumulate in
`~/.avf/logs/`. Review and prune periodically; the `.bundle/` and
captured PCAP directories deserve the same treatment.

If you use ai-mon alongside SecVF and have IP enrichment enabled,
ai-mon's `~/.cache/ai-mon/ipinfo.json` contains every public IP a
tracked AI process touched, with a one-week TTL. ipinfo.io itself logs
the lookup on their side. Use `ai-mon --no-enrich` to disable.

## Best Practices for Malware Analysis

### Before Running Malware

1. **Create a dedicated analysis VM**
   ```
   Name: "MalwareAnalysis-YYYY-MM-DD"
   CPU: 2 cores (sufficient for most malware)
   RAM: 4GB (prevents resource exhaustion)
   Disk: 64GB (adequate for analysis)
   ```

2. **Disable unnecessary features**
   - Do NOT enable Rosetta unless analyzing x86_64 malware on ARM
   - Do NOT install spice-vdagent (disables clipboard sharing)
   - Keep VM snapshot before infection

3. **Network considerations**
   - Malware WILL have internet access by default
   - Consider running on isolated analysis network
   - Monitor DNS/HTTP traffic externally for IOCs

### During Analysis

1. **Monitor console logs**
   ```bash
   tail -f ~/.avf/logs/security-$(date +%Y-%m-%d).log
   ```

2. **Watch for security warnings**
   - `[WARNING]` events may indicate detection evasion
   - `[CRITICAL]` events require immediate investigation
   - `[EMERGENCY]` events mean possible containment breach

3. **Resource monitoring**
   - Open Activity Monitor on host
   - Watch for `com.apple.virtualization` process
   - Unusual spikes may indicate exploit attempts

### After Analysis

1. **Delete the infected VM**
   ```
   DO NOT clone or export infected VMs
   Use "Delete" button in VM Library
   ```

2. **Review security logs**
   ```bash
   grep -i "CRITICAL\|EMERGENCY" ~/.avf/logs/security-*.log
   ```

3. **Check for persistence**
   ```bash
   # Verify no malware escaped to host
   ls -la ~/Library/LaunchAgents/
   ls -la ~/Library/LaunchDaemons/
   ```

## Known Limitations

### What SecVF Can Prevent
✅ Guest accessing host filesystem
✅ Guest discovering other VMs
✅ Guest escaping to host processes
✅ Malicious IPSW downloads
✅ Unauthorized VM bundle modifications

### What SecVF Cannot Prevent
❌ **Network-based attacks** - Guests have internet access
❌ **Framework exploits** - If Apple Virtualization.framework has 0-days
❌ **Social engineering** - User copying files between host/guest
❌ **Clipboard exfiltration** - If spice-vdagent is installed
❌ **Display spoofing** - Sophisticated malware may fake VM display
❌ **Privileged peers on the exec-bridge allowlist** - any uid you authorize for `/tmp/secvf-exec-*.sock` can drive the guest as root via STREAM mode (within the binary whitelist). Curate the allowlist deliberately.
❌ **A compromised guest dropping artifacts into `/workspace`** - by design, the workspace is rw. Host-side consumers must treat workspace contents as untrusted.

## Incident Response

### If You Suspect a Breakout Attempt

1. **Immediately stop the VM**
   - Force quit SecVF if necessary
   - Do not use "Shut Down" from guest

2. **Check security logs**
   ```bash
   grep "EMERGENCY\|CRITICAL" ~/.avf/logs/security-*.log
   ```

3. **Inspect VM bundle**
   ```bash
   ls -laR ~/.avf/[Linux|MacOS]/<VMName>.bundle/
   ```

4. **Check host processes**
   ```bash
   ps aux | grep -v grep | grep -i malware
   lsof | grep <VM-bundle-path>
   ```

5. **Inspect cross-process bridges and the workspace**
   ```bash
   # Live exec bridges — should match running VMs.
   ls -la /tmp/secvf-exec-*.sock
   # Anything dropped into the writable host-mounted workspace by the guest.
   ls -laR ~/ai-sandbox-workspace/
   # Who has been allowed to drive the bridge?
   cat ~/.avf/config/exec-bridge-allowlist 2>/dev/null
   ```

5. **If breach confirmed**
   - Disconnect from network
   - Preserve system state for forensics
   - Run malware scan on host: `sudo clamscan -r /`
   - Consider full macOS reinstall if persistence suspected

## Additional Hardening (Advanced)

### Network Isolation
Consider running SecVF on a dedicated analysis Mac that:
- Has no access to corporate network
- Uses burner Apple ID
- Has separate iCloud account
- Is physically isolated from production systems

### Endpoint Detection & Response (EDR)
Deploy EDR on the analysis Mac:
- Enables detection of framework exploits
- Provides additional process monitoring
- Can detect abnormal Virtualization.framework behavior

### Regular Security Updates
- Keep macOS updated (patches framework vulnerabilities)
- Update SecVF when new versions available
- Review security logs after each analysis session

## Reporting Security Issues

If you discover a security vulnerability in SecVF:

1. **Do NOT open a public GitHub issue**
2. Email security concerns to: `[Your Security Email]`
3. Include:
   - Detailed description of vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Suggested mitigation if known

## References

- [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization)
- [macOS Security Guide](https://support.apple.com/guide/security/welcome/web)
- [MITRE ATT&CK: Virtualization/Sandbox Evasion](https://attack.mitre.org/techniques/T1497/)

---

**Remember**: VMs provide strong isolation but are NOT perfect. Always assume malware is attempting to escape and monitor accordingly.
