# SecVF

**Computer Security Incident Response Team Virtualization Framework**

A macOS application for managing Linux and macOS virtual machines, designed for security research and malware analysis in isolated sandbox environments.

## Recent Updates

**November 2025**
- ✅ **Critical Linux VM boot fix** - Fixed boolean logic bug causing Linux VMs to crash on startup
- ✅ **Linux installation support** - Added automatic ISO detection and OS installation tracking for Linux VMs
- ✅ **Legacy VM compatibility** - Intelligent distribution inference for existing VMs without metadata
- ✅ **Real-time macOS IPSW download progress** - Fixed modal dialog threading issue, downloads now show live GB/percentage updates
- ✅ **Enhanced security logging** - Comprehensive NSLog debugging for download flow validation
- ✅ **ISO Cache Manager** - Centralized, secure ISO/IPSW download management with security audit logging
- ✅ **Network config migration** - Moved network types to dedicated file for better organization

## Overview

SecVF provides a clean GUI for creating, managing, and monitoring virtual machines using Apple's native Virtualization framework. Built specifically for security teams, it offers VM-to-VM networking, real-time security monitoring, and complete isolation from your host system.

## Why Apple Virtualization Framework?

- **Native performance** - Hardware-accelerated virtualization with minimal overhead
- **Apple Silicon optimized** - Exceptional efficiency on M-series chips
- **Automatic display scaling** - VMs resize instantly with the window
- **Native clipboard sharing** - Copy/paste between host and guest
- **macOS guest support** - Run macOS VMs (not possible with QEMU)
- **Rosetta translation** - Run x86_64 binaries in ARM Linux VMs
- **Apple-maintained** - Official framework with regular updates and security hardening

## Features

### Core Functionality
- **VM Library** - Browse, create, and manage Linux and macOS VMs
- **Flexible Configuration** - Custom CPU, memory, and disk allocation per VM
- **Network Modes** - NAT for internet access or isolated VM-to-VM networking
- **VM Operations** - Start, stop, clone, rename, delete, and import VMs
- **Smart IPSW Management** - Automatic macOS image caching and reuse
- **Auto-Migration** - Migrates VMs from legacy locations on first launch

### Linux VM Support
- **Automatic OS installation tracking** - Detects when Linux VMs need installation
- **ISO cache management** - Centralized storage in `~/.avf/VMImages/Linux/`
- **Smart distribution detection** - Automatically infers distro from VM names for legacy VMs
- **Supported distributions** (8 total):
  - Ubuntu Desktop & Server (24.04 LTS)
  - Debian (12.0)
  - Fedora (39)
  - Kali Linux (2024.1) - Security/pentesting focused
  - Parrot Security (6.0) - Alternative security distro
  - Arch Linux (Latest) - Rolling release
  - Manjaro (23.1.3)
- Boot from ISO for any ARM64 or x86_64 distribution
- SPICE agent support for clipboard sharing
- Optional Rosetta support for running x86_64 binaries on ARM Linux
- **Progress tracking** for ISO downloads with live updates

### macOS VM Support
- Automatic download of latest macOS restore images (15.6 GB)
- **Real-time download progress** with live GB/percentage tracking
- Full macOS guest support with native integration
- **Smart IPSW caching** - Central storage in `~/.avf/MacOS/` shared across all macOS VMs
- URL validation and CDN security checks (only downloads from official Apple servers)
- TLS 1.2+ requirement with certificate validation

**See [ISOCACHE.md](ISOCACHE.md) for complete ISO Cache Manager documentation including security architecture, threat model, and audit logging.**

**See [docs/LINUX-BOOT-FIX.md](docs/LINUX-BOOT-FIX.md) for detailed documentation of the critical Linux VM boot fix.**

## Getting Started

### Requirements
- macOS 14.0 or later
- Xcode (for building from source)
- Apple Developer account (for code signing)

### Building
```bash
git clone <repository-url>
open SecVF.xcodeproj
# Configure signing in Xcode, then build (⌘R)
```

### First Launch
VMs from legacy locations are automatically migrated to `~/.avf/Linux/` or `~/.avf/MacOS/`.

## VM Storage Structure

VMs are stored in the `~/.avf/` directory, organized by OS type:

```
~/.avf/
├── Linux/          # Linux VMs
│   └── [VM Name].bundle/
│       ├── Disk.img
│       ├── NVRAM
│       ├── MachineIdentifier
│       └── metadata.json
├── MacOS/          # macOS VMs and shared IPSWs
│   ├── [VM Name].bundle/
│   └── *.ipsw      # Shared restore images
└── VMImages/       # Cached ISO files
    └── Linux/
        └── [Distro]-[Version]/
            └── *.iso
```

Each VM bundle contains:
- **Disk.img**: Virtual disk image
- **NVRAM**: Boot configuration (critical for Linux VMs)
- **MachineIdentifier**: Unique VM identifier
- **metadata.json**: Configuration including OS installation status

## Advanced Features

### Rosetta Support (Apple Silicon)
Enable Rosetta when creating Linux VMs to run x86_64 binaries transparently on ARM Linux. See [Apple's documentation](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta).

### Clipboard Sharing
Install SPICE agent in Linux VMs for seamless copy/paste:
```bash
# Ubuntu/Debian
sudo apt install spice-vdagent
```

### Virtual Network Switch
Software-based Ethernet switch for VM-to-VM communication without physical network exposure. Perfect for malware analysis:

- Linux VMs act as routers with monitoring tools (Wireshark, tcpdump)
- Route macOS VMs through Linux routers to capture malware traffic
- Complete isolation from physical network
- All traffic logged to `~/.avf/logs/network-YYYY-MM-DD.log`
- Security features: MAC validation, rate limiting, spoofing detection

**Network Modes:**
- **NAT** - Direct internet access (default)
- **Virtual Network** - VM-to-VM only, fully isolated

### Real-Time Monitoring
Access via menu bar `Monitoring` or keyboard shortcuts:
- `⌘⇧1` - **Security Logs** - VM lifecycle, resource warnings, breakout detection
- `⌘⇧2` - **Network Logs** - Packet forwarding, MAC learning, rate limiting
- `⌘⇧3` - **Virtual Switch Stats** - Port status, packet counts, learned MACs

Features: Auto-refresh, syntax highlighting, auto-scroll, search (⌘F)
Logs stored in `~/.avf/logs/`

## Security & Malware Analysis

Designed for security research and malware analysis with hardware-enforced VM isolation, real-time monitoring, breakout detection, and security event logging.

**Best Practices:**
- Use dedicated VMs for each analysis session
- Monitor logs: `tail -f ~/.avf/logs/security-$(date +%Y-%m-%d).log`
- VMs have internet access - malware can communicate externally
- Delete infected VMs after analysis

**See [SECURITY.md](SECURITY.md) for complete threat model, incident response procedures, and hardening recommendations.**

## Troubleshooting

### Linux VM Issues

**VM Crashes on Boot:**
- Check if VM has proper NVRAM file (critical for boot)
- Verify `osInstalled` status in metadata.json
- For legacy VMs, ensure VM name contains distro (e.g., "Kali Router")
- Review logs: `Console.app` and filter for "Linux VM"

**Installation Not Starting:**
- Ensure ISO is cached in `~/.avf/VMImages/Linux/[Distro]-[Version]/`
- ISO file must be > 1MB (not a placeholder)
- Check supported distributions list above

**VM Won't Start:**
- Verify VM bundle exists in `~/.avf/`
- Check required files (Disk.img, NVRAM, MachineIdentifier)
- Review console logs for specific errors

### macOS VM Issues

**Download Fails:**
- Check internet connection
- Ensure 15GB+ free space
- Verify firewall allows Apple CDN access
- Check `~/.avf/logs/` for download errors

### General Issues

**Linux Installation:**
- ISO must match Mac architecture (ARM64/x86_64)
- Allocate 4GB+ memory for installation
- Verify ISO checksum if available

## Development Roadmap

### Validation & Testing
- [ ] Validate re-use of cached IPSW
- [ ] Validate Linux downloading mechanisms for each distro (Kali, Ubuntu, Debian)
- [ ] Write tests for the log functionality
- [ ] Fix the UI VM state panel

### Networking & Routing
- [ ] Thoroughly test and understand software routing for VM-to-VM communications
- [ ] Validate network isolation (ensure malware VMs can't reach host/external network)

### Security & Setup
- [ ] Implement enforcement of Kali VM requirements
- [ ] Create setup scripts for Linux hosts
- [ ] Create setup scripts for macOS hosts

### Critical Features (security Requirements)
- [ ] Implement VM snapshot/checkpoint functionality (critical for malware analysis)
- [ ] Implement secure file transfer mechanism (samples in, artifacts/logs out)
- [ ] Implement VM lifecycle/cleanup automation (prevent disk space exhaustion)
- [ ] Add resource limits/quotas per VM (CPU/memory caps)

### Integration & Tools
- [ ] Improve error handling and user feedback throughout app
- [ ] Add full PCAP network packet capture support (beyond logging)
- [ ] Create VM templates/presets for common analysis scenarios
- [ ] Add integration points for security tools (Wireshark, Volatility, YARA)

### Documentation & Security
- [ ] Write architecture documentation (network topology, security boundaries)
- [ ] Write user guide/runbook for common analyst workflows
- [ ] Perform security validation/penetration testing of isolation mechanisms

## License

See LICENSE.txt for details.

## Credits

Built using Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
