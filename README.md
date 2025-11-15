# SecVF

**Computer Security Incident Response Team Virtualization Framework**

A macOS application for managing Linux and macOS virtual machines, designed for security research and malware analysis in isolated sandbox environments.

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
- Boot from ISO for any ARM64 or x86_64 distribution (Ubuntu, Debian, Fedora, etc.)
- SPICE agent support for clipboard sharing
- Optional Rosetta support for running x86_64 binaries on ARM Linux

### macOS VM Support
- Automatic download of latest macOS restore images
- Full macOS guest support with native integration
- IPSW caching to avoid re-downloading

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

VMs stored in `~/.avf/` directory organized by OS type. Each VM bundle contains: Disk.img, NVRAM, MachineIdentifier, and metadata.json. macOS IPSWs are stored centrally in `~/.avf/MacOS/` and shared across all macOS VMs.

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

**VM Won't Start:** Verify VM bundle exists in `~/.avf/`, check required files (Disk.img, NVRAM, MachineIdentifier), review console logs.

**Linux Installation:** ISO must match Mac architecture (ARM64/x86_64), allocate 4GB+ memory, verify ISO hash.

**macOS Download Fails:** Check internet connection, ensure 15GB+ free space, verify firewall allows Apple CDN access.

## License

See LICENSE.txt for details.

## Credits

Built using Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
