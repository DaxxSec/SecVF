# Code Review: SecVF - Status Update

## Recent Additions (2026-04 audit + vsock channel)

### Cross-process / cross-user IPC

| Item | Status | Notes |
|------|--------|-------|
| Per-VM UDS exec bridge | ✅ Added | `VsockExecBridge.swift`; `/tmp/secvf-exec-<UUID>.sock` proxies UDS ↔ vsock:2222 |
| `secvf-cli vm exec` subcommand | ✅ Added | Streams over the UDS bridge with `--stream`/`--root` mode flags |
| Guest-side STREAM/ROOT mode routing | ✅ Added | `provision-macos-vm.sh` exec handler now routes by command prefix |
| writemon.d per-PID dtrace probe | ✅ Added | `scripts/writemon.d`; consumed by ai-mon's `SecVFTracer` |
| AppDelegate hooks for bridge lifecycle | ✅ Added | Start/stop next to `VMSecurityMonitor` per VM |

### Security hardening (2026-04)

| Item | Status | Notes |
|------|--------|-------|
| Exec-bridge peer-uid auth | ✅ Added | `getpeereid()` allowlist check; default = SecVF.app owner only |
| Allowlist config file | ✅ Added | `~/.avf/config/exec-bridge-allowlist`, reloaded per connection |
| STREAM mode binary whitelist | ✅ Added | dtrace/fs_usage/ktrace/top/vm_stat/memory_pressure/sysctl/tail/log only |
| BridgeState double-leave race | ✅ Fixed | `DispatchGroup` was being left 3× when entered 2× |
| Unbounded vsock connect wait | ✅ Fixed | 5s timeout on the connect semaphore |
| Global-queue thread pinning | ✅ Fixed | Bridge no longer `group.wait()`s on a worker thread |
| `VZVirtioSocketConnection.fileHandleFor*` misuse | ✅ Fixed | Wrap `fileDescriptor` in `FileHandle` properly |
| DistributedNotificationCenter unauthenticated CLI ops | ⚠️ KNOWN GAP | See SECURITY.md — fix is to migrate to UDS bridge |
| VMSecurityMonitor host-RSS misnomer | ✅ Fixed | Now reads real guest stats over vsock for AI Sandbox guests |
| Timer.scheduledTimer in non-runloop queue | ✅ Fixed | Switched to `DispatchSourceTimer` |
| networkAnomaly events never emitted | ✅ Fixed | L2 switch routes spoofing/rate-limit through `VMSecurityMonitor` |

### Code quality (2026-04)

| Item | Status | Notes |
|------|--------|-------|
| `VsockChannel` extracted | ✅ Done | Collapsed two duplicate continuation+readabilityHandler blocks |
| Tshark JSON regex parser | ✅ Replaced | Streaming brace-counter; 4 MiB buffer cap with truncation log |
| `getSecurityRecommendations` hardcoded strings | ✅ Replaced | Reflects actual VM network mode + live switch / capture state |
| `String(contentsOf:)` macOS 15 deprecation | ✅ Fixed | Adopt `init(contentsOf:encoding:)` |
| Force-unwrap on `Bundle.main.url(forResource:)` | ✅ Replaced | Typed `AISandboxVMError.provisionScriptMissing` |
| `LogRotation` for `~/.avf/logs/` | ✅ Added | 30-day prune + 10 MB audit rotation, env-tunable |

### Modern Virtualization.framework adoption

| Item | Status | Notes |
|------|--------|-------|
| `VZNVMExpressControllerDeviceConfiguration` (macOS 15+) | ✅ Added | `@available` branch in AISandboxMacVMConfiguration storage |

## Completed Items

### Security (Critical)

| Item | Status | Commit |
|------|--------|--------|
| SHA256 placeholder checksums | ✅ Fixed | Dynamic fetching from official CDNs |
| Bundle ID validation | ✅ Fixed | Exact match validation |
| VM name path traversal | ✅ Fixed | Prevents /, \, .., hidden files |
| User config URL bypass | ✅ Fixed | Validates against bundle's approved domains |
| Streaming SHA256 | ✅ Fixed | 1MB buffer, no memory spike |
| Thread-based check | ✅ Removed | Was false security |
| Log path injection | ✅ Fixed | URL-based path construction |

### Code Quality

| Item | Status | Notes |
|------|--------|-------|
| LayoutConstants | ✅ Extracted | Centralized UI constants |
| AppColors | ✅ Extracted | Centralized color definitions |
| NetworkProtocolColors | ✅ Extracted | Protocol color mapping |
| NetworkTrafficView | ✅ Extracted | From VMLibraryWindowController |
| NotificationNames | ✅ Extracted | Centralized notification names |
| UTTypeExtensions | ✅ Extracted | File type identifiers |
| Protocol abstractions | ✅ Added | VMManagerProtocol, NetworkSwitchProtocol, PacketCaptureProtocol |
| Integration tests | ✅ Added | 25 tests for component integration |
| Combine publishers | ✅ Added | Reactive updates in PacketCaptureManager |
| Distro configuration | ✅ Externalized | distros.json with dynamic checksums |
| ProcessExecutor | ✅ Added | Consolidated process execution |
| ProtocolInfo | ✅ Added | Protocol metadata structure |
| SecVFError | ✅ Added | Typed error handling |

### Thread Safety

| Item | Status | Notes |
|------|--------|-------|
| @MainActor annotations | ✅ Added | All UI window controllers and views |

### Remaining (Lower Priority)

| Item | Priority | Notes |
|------|----------|-------|
| AppDelegate refactoring | P1 | 1724 lines, tightly coupled - needs careful planning |
| Timer → Combine migration | P3 | Combine publishers available, migration optional |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SecVF App                              │
├─────────────────────────────────────────────────────────────────┤
│  AppDelegate.swift (1724 lines - refactor candidate)            │
│  ├── VM lifecycle (start/stop/pause handlers)                   │
│  ├── VZ configuration builders                                  │
│  ├── Menu setup (Monitoring, Tools)                             │
│  └── VZVirtualMachineDelegate                                   │
├─────────────────────────────────────────────────────────────────┤
│  VMManager.swift                                                │
│  ├── VM CRUD operations                                         │
│  ├── Path traversal protection ✅                               │
│  └── Implements VMManagerProtocol ✅                            │
├─────────────────────────────────────────────────────────────────┤
│  ISOCacheManager.swift                                          │
│  ├── Dynamic checksum fetching ✅                               │
│  ├── Streaming SHA256 verification ✅                           │
│  └── Per-distro size limits ✅                                  │
├─────────────────────────────────────────────────────────────────┤
│  ChecksumFetcher.swift ✅ (NEW)                                 │
│  ├── Fetches SHA256SUMS from official CDNs                      │
│  ├── Supports sha256sums / fedora formats                       │
│  └── 24-hour cache in ~/.avf/checksums-cache.json               │
├─────────────────────────────────────────────────────────────────┤
│  DistroConfiguration.swift                                      │
│  ├── JSON config loading from distros.json                      │
│  ├── User config domain validation ✅                           │
│  └── checksumURL / checksumFormat fields ✅                     │
└─────────────────────────────────────────────────────────────────┘
```

## Dynamic Checksum Flow

```
ISO Download Request
        │
        ▼
┌───────────────────┐
│ ChecksumFetcher   │
│  .fetchChecksum() │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │   Cache   │ ← 24hr TTL
    │   Hit?    │
    └─────┬─────┘
          │
    No    │    Yes
    │     └────────────► Return cached hash
    ▼
┌───────────────────┐
│ Fetch from        │
│ checksumURL       │
│ (official CDN)    │
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │  Success? │
    └─────┬─────┘
          │
    No    │    Yes
    │     │
    │     └────────────► Cache & verify ISO
    ▼
┌───────────────────┐
│ Fallback to       │
│ static checksum   │
│ (if not PLACEHOLDER)
└─────────┬─────────┘
          │
    ┌─────┴─────┐
    │  Valid?   │
    └─────┬─────┘
          │
    No    │    Yes
    │     │
    │     └────────────► Verify ISO
    ▼
┌───────────────────┐
│ Proceed unverified│
│ (with warning)    │
└───────────────────┘
```

## Next Steps (If Continuing)

1. **AppDelegate Refactoring** (requires careful planning):
   - Extract `VMConfigurationBuilder` (device configs)
   - Extract `MenuBarController` (menu setup/handlers)
   - Requires moving state and updating all references

2. **Timer → Combine Migration** (optional):
   - VMLibraryWindowController stats timer
   - Combine publishers already available in PacketCaptureManager
