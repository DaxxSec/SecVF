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

### 6. **Entitlements & Sandboxing**

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
