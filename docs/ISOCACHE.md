# ISO Cache Manager

**Centralized, secure ISO/IPSW download and caching system for SecVF**

## Overview

The ISO Cache Manager (`ISOCacheManager.swift`) provides a unified, security-hardened interface for downloading and caching operating system images for both Linux and macOS virtual machines. It eliminates redundant downloads, enforces security policies, and provides comprehensive audit logging.

## Architecture

### Core Components

```
ISOCacheManager (Singleton)
├── macOS IPSW Downloads → MacOSVMInstaller
├── Linux ISO Downloads → (Future: LinuxISODownloader)
└── Security Audit Logger → ~/.avf/logs/iso-cache-audit-YYYY-MM-DD.log
```

### Storage Structure

```
~/.avf/
├── MacOS/
│   ├── UniversalMac_15.6.1_24G90_Restore.ipsw  (15.6 GB, shared across all macOS VMs)
│   └── (cached IPSWs auto-updated when new versions available)
├── Linux/
│   └── (ISOs stored per-VM, not yet centralized)
└── logs/
    └── iso-cache-audit-YYYY-MM-DD.log
```

## Security Features

### macOS IPSW Downloads

**Multi-Layer Security Validation:**

1. **URL Source Validation**
   - Only accepts URLs from Apple's official `VZMacOSRestoreImage.fetchLatestSupported` API
   - No user-controlled URLs accepted
   - Framework-level validation by Apple

2. **Domain Whitelist** (`approvedCDNHosts`)
   ```swift
   static let approvedCDNHosts: Set<String> = [
       "updates.cdn-apple.com",
       "updates-http.cdn-apple.com",
       "mesu.apple.com"
   ]
   ```
   - Hard-coded whitelist prevents unauthorized CDNs
   - All download URLs validated against whitelist
   - Rejected hosts logged to security audit

3. **Protocol Enforcement**
   - HTTPS-only connections (no HTTP)
   - TLS 1.2+ required
   - Standard CA certificate validation via URLSession

4. **File Type Validation**
   - Only `.ipsw` file extensions accepted
   - Validated before download initiation
   - Prevents malicious file type injection

5. **SSL Certificate Validation**
   - Server trust validation via `URLAuthenticationChallenge`
   - Rejects connections from unauthorized hosts
   - Corporate proxy/VPN compatible (uses default system validation)

6. **Download Path Security**
   - Files downloaded to `~/.avf/MacOS/` (user-controlled, sandboxed)
   - Path cannot be manipulated externally
   - Central storage prevents duplication

### Linux ISO Downloads

**Current Implementation:**
- ISOs stored per-VM in bundle directories
- No centralized caching yet
- Security router VM creation has special handling

**Planned Enhancements:**
- Central ISO cache similar to macOS IPSWs
- SHA256 hash validation for downloaded ISOs
- Signature verification for official distros
- Mirror URL validation and ranking

## Download Flow

### macOS IPSW Download

```
1. User creates macOS VM
   ↓
2. ISOCacheManager.downloadImage(for: .macOS)
   ↓
3. Check central cache: ~/.avf/MacOS/
   ├─ Match found → Return cached IPSW (instant)
   └─ No match or outdated → Proceed to download
   ↓
4. VZMacOSRestoreImage.fetchLatestSupported
   ├─ Gets official Apple CDN URL
   └─ Returns metadata (version, size, URL)
   ↓
5. Security validation pipeline:
   ├─ Validate URL scheme (HTTPS only)
   ├─ Validate host (approved CDN list)
   ├─ Validate file extension (.ipsw)
   └─ Re-validate before download
   ↓
6. URLSession download (background queue)
   ├─ TLS 1.2+ enforcement
   ├─ Certificate validation
   ├─ Progress callbacks (RunLoop.main.perform)
   └─ Real-time UI updates (GB/percentage)
   ↓
7. Download complete
   ├─ Move to central cache
   ├─ Log success to audit log
   └─ Return IPSW URL to VM installer
```

### Cache Hit Detection

**Filename-based matching:**
- Remote: `UniversalMac_15.6.1_24G90_Restore.ipsw`
- Cached: `UniversalMac_15.6.1_24G90_Restore.ipsw`
- **Match** → Use cached version (saves 15.6 GB download!)

**Auto-cleanup of outdated IPSWs:**
- Newer version detected → Delete old IPSW
- Ensures cache doesn't grow indefinitely
- Prevents version confusion

## Audit Logging

All ISO cache operations are logged to `~/.avf/logs/iso-cache-audit-YYYY-MM-DD.log`

### Log Events

**Download Lifecycle:**
```
[2025-11-15 00:54:32] [INFO] Download requested: macOS 15.7.1
[2025-11-15 00:54:32] [INFO] Checking cache: /Users/user/.avf/MacOS/
[2025-11-15 00:54:32] [WARNING] No cached IPSW found
[2025-11-15 00:54:32] [INFO] Fetching latest macOS restore image...
[2025-11-15 00:54:33] [INFO] Latest version: 15.6.1
[2025-11-15 00:54:33] [INFO] Download URL: https://updates.cdn-apple.com/...
[2025-11-15 00:54:33] SECURITY: URL validation passed for: https://updates.cdn-apple.com/...
[2025-11-15 00:54:33] [INFO] Starting download: 15.66 GB
[2025-11-15 00:55:33] [INFO] Download progress: 5.0% (0.78 GB / 15.66 GB)
[2025-11-15 01:10:45] [INFO] Download complete: UniversalMac_15.6.1_24G90_Restore.ipsw
```

**Cache Hits:**
```
[2025-11-15 10:23:45] [INFO] Download requested: macOS 15.7.1
[2025-11-15 10:23:45] [INFO] Found cached IPSW: UniversalMac_15.6.1_24G90_Restore.ipsw
[2025-11-15 10:23:45] [INFO] Cache hit - using existing IPSW
```

**Security Events:**
```
[2025-11-15 12:34:56] SECURITY: Rejected non-HTTPS URL: http://malicious.com/fake.ipsw
[2025-11-15 12:34:57] SECURITY: Rejected URL from unauthorized host: malicious.com
[2025-11-15 12:34:58] SECURITY: Rejected non-IPSW file: malicious.dmg
```

### Monitoring Audit Logs

**Via GUI:**
- Menu: `Monitoring → ISO Cache Audit` (⌘⇧3)
- Real-time tail with auto-refresh
- Syntax highlighting for severity levels

**Via Terminal:**
```bash
# Real-time monitoring
tail -f ~/.avf/logs/iso-cache-audit-$(date +%Y-%m-%d).log

# Search for security events
grep "SECURITY" ~/.avf/logs/iso-cache-audit-*.log

# Download statistics
grep "Download complete" ~/.avf/logs/iso-cache-audit-*.log
```

## Thread Safety

### Modal Dialog Compatibility

**Problem:** Modal dialogs (`NSAlert.runModal()`) block the main thread with their own run loop, preventing `DispatchQueue.main.async` from executing.

**Solution:** Use `RunLoop.main.perform(inModes: [.common])` to schedule UI updates on the modal's run loop.

```swift
// ❌ Doesn't work with modal dialogs
DispatchQueue.main.async {
    progressBar.doubleValue = percentage
}

// ✅ Works with modal dialogs
RunLoop.main.perform(inModes: [.common], block: {
    progressBar.doubleValue = percentage
})
```

### Background Downloads

- URLSession delegates execute on background queue (`delegateQueue: nil`)
- Prevents main thread blocking during large downloads
- Progress handlers scheduled on main run loop for UI updates
- Completion handlers also scheduled on main run loop

## Performance Optimizations

### Bandwidth Efficiency
- **Cache reuse** - Never download same IPSW twice
- **Stall detection** - Warns if download stalls for 30+ seconds
- **Progress throttling** - UI updates throttled to avoid excessive callbacks

### Disk Space Management
- **Central storage** - Single IPSW shared across all macOS VMs (saves ~15 GB per VM)
- **Auto-cleanup** - Outdated IPSWs automatically removed when newer version detected
- **Pre-flight checks** - Validates free disk space before download (prevents partial downloads)

### Network Resilience
- **Timeout configuration** - 60s request timeout, 1 hour resource timeout
- **Resume support** - URLSession download tasks can resume after interruption
- **Corporate proxy support** - Uses system network configuration

## API Reference

### ISOCacheManager

```swift
class ISOCacheManager {
    static let shared: ISOCacheManager

    func downloadImage(
        for imageType: VMImageType,
        progressHandler: @escaping (Double, String) -> Void,
        completionHandler: @escaping (Result<URL, Error>) -> Void
    )
}
```

**Parameters:**
- `imageType`: `.macOS(version: String)` or `.linux(distro, version, isSecurityRouter)`
- `progressHandler`: Called on main thread with (progress: 0.0-1.0, message: String)
- `completionHandler`: Called on main thread with Result<URL, Error>

**Example Usage:**
```swift
ISOCacheManager.shared.downloadImage(
    for: .macOS(version: "15.7.1"),
    progressHandler: { progress, message in
        print("\(Int(progress * 100))%: \(message)")
    },
    completionHandler: { result in
        switch result {
        case .success(let ipswURL):
            print("IPSW ready at: \(ipswURL.path)")
        case .failure(let error):
            print("Download failed: \(error)")
        }
    }
)
```

## Future Enhancements

### Short-term
- [ ] Linux ISO centralization (similar to macOS IPSW)
- [ ] SHA256 hash validation for all downloads
- [ ] Disk space pre-flight checks
- [ ] Download bandwidth limiting

### Medium-term
- [ ] Resume support for interrupted downloads
- [ ] Multiple concurrent downloads (queue management)
- [ ] ISO version pinning (allow users to keep specific versions)
- [ ] Cache size limits with LRU eviction

### Long-term
- [ ] Peer-to-peer ISO sharing (for enterprise deployments)
- [ ] Custom mirror configuration
- [ ] Offline mode with pre-cached ISOs
- [ ] ISO signature verification (GPG for Linux distros)

## Security Considerations

### Threat Model

**Threats Mitigated:**
- ✅ Man-in-the-middle attacks (TLS 1.2+, certificate validation)
- ✅ DNS spoofing (domain whitelist)
- ✅ Malicious IPSW injection (URL source validation)
- ✅ Protocol downgrade attacks (HTTPS-only)
- ✅ File type confusion (extension validation)

**Threats NOT Mitigated:**
- ⚠️ Compromised Apple infrastructure (trust in Apple's CDN)
- ⚠️ State-level attacks on Apple (out of scope)
- ⚠️ Malicious IPSWs signed by Apple (trust boundary)

### Recommendations

**For CSIRT Environments:**
1. Monitor audit logs for unauthorized download attempts
2. Validate IPSW checksums against Apple's published values (manual process)
3. Use dedicated, isolated networks for VM creation
4. Consider air-gapped IPSW transfers for highly sensitive environments

**For Development:**
1. Review audit logs weekly for anomalies
2. Keep IPSW cache on encrypted volumes
3. Implement disk quota monitoring to prevent cache overflow

## Troubleshooting

### Download Fails

**Symptom:** "Failed to download macOS" error

**Diagnosis:**
```bash
# Check audit log for security rejections
grep "SECURITY" ~/.avf/logs/iso-cache-audit-*.log

# Check for network errors
grep "ERROR" ~/.avf/logs/iso-cache-audit-*.log
```

**Common Causes:**
- No internet connection → Check network settings
- Firewall blocking Apple CDN → Whitelist `*.cdn-apple.com`
- Insufficient disk space → Free up 20+ GB in `~/.avf/MacOS/`
- Corporate proxy issues → Verify system proxy configuration

### Progress Not Updating

**Symptom:** Progress stuck at 0% or "Initializing..."

**Diagnosis:**
```bash
# Check if download is actually progressing
ls -lh ~/.avf/MacOS/*.ipsw.download  # URLSession temporary file
```

**Fix:** This was resolved in November 2025 update with `RunLoop.main.perform` fix. If still experiencing issues, check for modal dialog threading problems.

### Cache Not Reusing IPSWs

**Symptom:** Downloading same IPSW multiple times

**Diagnosis:**
```bash
# Check cache directory
ls -lh ~/.avf/MacOS/

# Check audit log for cache checks
grep "Found cached IPSW" ~/.avf/logs/iso-cache-audit-*.log
```

**Common Causes:**
- Filename mismatch (shouldn't happen with Apple URLs)
- Cache directory permissions issue → Verify `~/.avf/MacOS/` is readable
- IPSW file corrupted → Delete and re-download

## Related Documentation

- [SECURITY.md](SECURITY.md) - Threat model and security architecture
- [README.md](README.md) - Main project documentation
- [MacOSVMInstaller.swift](SecVF/MacOSVMInstaller.swift) - Implementation details
