# SecVF

A native macOS application for managing and running multiple Linux and macOS virtual machines using Apple's Virtualization framework.

## Overview

SecVF (Computer Security Incident Response Team Virtual Framework) is a production-ready VM management application that provides a clean, intuitive GUI for creating, managing, and running multiple virtual machines on your Mac. The application leverages Apple's native Virtualization framework to deliver superior performance and integration compared to traditional solutions.

## Why Apple Virtualization Framework?

SecVF uses Apple's native Virtualization framework instead of QEMU-based solutions, offering significant advantages:

### Performance Benefits
- **Hardware-accelerated virtualization** - Direct access to Apple's hypervisor for near-native performance
- **Optimized for Apple Silicon** - Designed specifically for M-series chips with exceptional efficiency
- **Lower resource overhead** - Minimal CPU and memory overhead compared to QEMU emulation layers
- **Native graphics acceleration** - Seamless integration with macOS graphics stack

### Integration & User Experience
- **Automatic display scaling** - VMs resize instantly when you change the window size
- **Native clipboard sharing** - Copy/paste between host and guest without configuration
- **macOS guest support** - Run macOS VMs with full Apple support (not possible with QEMU)
- **Rosetta translation** - Run x86_64 binaries in ARM Linux VMs using Apple's Rosetta
- **SPICE agent support** - Enhanced Linux integration for clipboard, display, and more

### Reliability & Maintenance
- **Apple-supported** - Official framework maintained by Apple
- **Regular updates** - Improvements with each macOS release
- **Security hardened** - Built-in sandboxing and entitlement system
- **Simplified architecture** - No complex QEMU/KVM setup or kernel extensions

While QEMU is excellent for cross-platform compatibility and exotic architectures, the Virtualization framework is purpose-built for macOS and delivers the best experience when running Linux and macOS guests on Apple hardware.

## Features

### VM Library Management
- **Visual VM Library** - Browse all your VMs in a clean table view with key details
- **Organization by OS Type** - VMs automatically organized into Linux and macOS directories
- **Quick Actions** - Double-click to start, right-click for options
- **Status Indicators** - See which VMs are running, stopped, or starting at a glance
- **Auto-Migration** - Automatically migrates VMs from legacy locations on first launch

### VM Creation & Configuration
- **Multi-OS Support** - Create both Linux and macOS virtual machines
- **Flexible Configuration**:
  - Custom CPU core allocation
  - Configurable memory (RAM) size
  - Adjustable virtual disk size
  - OS type selection (Linux/macOS)
  - Rosetta support for running x86_64 binaries on ARM Linux

### Linux VM Creation
1. Click **New** in the VM Library
2. Configure VM resources (CPU, memory, disk)
3. Select **Linux** as OS type
4. Enable **Install from ISO** checkbox
5. Click **Select ISO** and choose your Linux distribution ISO
6. The VM boots into the installer - complete installation as normal

**Supported Linux Distributions**: Any distribution compatible with ARM64/aarch64 (Apple Silicon) or x86_64 (Intel). Popular choices include:
- [Ubuntu](https://ubuntu.com/download/desktop) (ARM64 for Apple Silicon, AMD64 for Intel)
- [Debian](https://www.debian.org/distrib/)
- [Fedora](https://getfedora.org/en/workstation/download/)

> **Note**: The Virtualization framework requires matching the Linux ISO architecture to your Mac's CPU. Download ARM64/aarch64 images for Apple Silicon Macs, or x86_64/amd64 images for Intel Macs.

### macOS VM Creation
1. Click **New** in the VM Library
2. Configure VM resources (CPU, memory, disk)
3. Select **macOS** as OS type
4. Click **Create**
5. SecVF automatically:
   - Checks for the latest macOS restore image (IPSW)
   - Uses cached IPSW if version matches (no re-download)
   - Downloads only if missing or outdated
   - Prepares the VM and starts installation

> **Smart IPSW Management**: When creating additional macOS VMs, SecVF checks if your cached IPSW matches Apple's latest version. If it matches, the cached version is reused instantly. If outdated, the old IPSW is removed and the latest version is downloaded automatically.

### VM Management Operations

#### Starting VMs
- **Double-click** any VM in the library to start it
- Or select a VM and click the **Start** button
- VM window opens with full graphics, keyboard, and mouse support
- Automatic display scaling when resizing the window

#### Cloning VMs
- Select a VM and click **Clone**
- Enter a new name for the cloned VM
- Creates a complete copy with a new machine identifier
- Perfect for creating multiple test environments

#### Importing VMs
- Click **Import** to add existing VM bundles
- Select a `.bundle` directory from anywhere on your system
- Automatically detects VM configuration and adds to library
- Useful for sharing VMs or restoring from backup

#### Renaming VMs
- Select a VM and click **Rename**
- Enter a new name
- Bundle directory and all references updated automatically

#### Deleting VMs
- Select a VM and click **Delete**
- Confirmation prompt (deletion is permanent)
- Removes VM bundle and all associated files

## Getting Started

### Requirements
- macOS 14.0 or later
- Xcode (for building from source)
- Apple Developer account (for code signing)

### Building & Running

1. Clone the repository and open `SecVF.xcodeproj` in Xcode
2. Navigate to **Signing & Capabilities** and select your team ID
3. Build and run the application (⌘R)

### First Launch

When you launch SecVF for the first time, you'll see the **Virtual Machine Library** window.

**Migration**: If you have VMs from previous versions in `~/GUI Linux VM.bundle/` or `~/VirtualMachines/`, they will be automatically migrated to the new organized structure at `~/.avf/Linux/` or `~/.avf/MacOS/`.

## VM Storage Structure

VMs are organized by OS type in a hidden `.avf` directory in your home folder:

```
~/.avf/
  ├── Linux/
  │   └── Ubuntu.bundle/
  │       ├── Disk.img           # Virtual disk image
  │       ├── NVRAM              # EFI variable store
  │       ├── MachineIdentifier  # Unique VM identifier
  │       └── metadata.json      # VM configuration
  └── MacOS/
      └── macOS Sonoma.bundle/
          ├── Disk.img
          ├── NVRAM
          ├── MachineIdentifier
          ├── metadata.json
          └── UniversalMac_15.0_24A335_Restore.ipsw  # macOS installer
```

Each VM is self-contained in its own `.bundle` directory with all necessary files.

## Advanced Features

### Rosetta Support (Apple Silicon Only)

SecVF supports Apple's Rosetta translation environment for running x86_64 (Intel) binaries inside ARM Linux VMs:

1. When creating a Linux VM on Apple Silicon, check **Enable Rosetta**
2. After installing Linux, install `rosetta` support in the guest
3. Run x86_64 Linux binaries transparently on ARM Linux

See Apple's documentation: [Running Intel Binaries in Linux VMs with Rosetta](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)

### Copy & Paste Support

SecVF includes SPICE agent support for seamless clipboard integration between macOS host and Linux guests.

**Setup for Linux VMs**:
1. Install the SPICE agent in your Linux guest:
   ```bash
   # Ubuntu/Debian
   sudo apt install spice-vdagent

   # Fedora
   sudo dnf install spice-vdagent
   ```
2. Copy/paste text and images between macOS and the Linux VM

### Network Configuration

All VMs use NAT networking by default, providing:
- Automatic internet access through the host's network connection
- Isolated network environment for security
- No additional network configuration required

## Security & Malware Analysis

SecVF is specifically designed for **security research and malware analysis** in isolated sandbox environments. The application includes comprehensive security monitoring and containment features to protect your host system while analyzing potentially malicious code.

### Key Security Features

- **Real-time Security Monitoring** - Active monitoring of VM filesystem, resource usage, and state changes
- **Containment Enforcement** - Hardware-enforced VM isolation via Apple's hypervisor
- **Breakout Detection** - Automated detection of potential escape attempts
- **Security Event Logging** - Detailed logs of all VM activity in `~/.avf/logs/`
- **Download Validation** - Multi-layer security for macOS IPSW downloads
- **Resource Monitoring** - Detection of CPU/memory exhaustion attacks

### Security Recommendations

When analyzing malware or untrusted software:
- ✅ Use dedicated VMs for each analysis session
- ✅ Monitor security logs: `tail -f ~/.avf/logs/security-$(date +%Y-%m-%d).log`
- ✅ Review console output for security warnings on VM start
- ⚠️ Be aware: VMs have internet access - malware can communicate externally
- ⚠️ Delete infected VMs after analysis - do not clone or export

### Complete Security Documentation

**For detailed security information, threat model, best practices, and incident response procedures, see:**

**[📋 SECURITY.md](SECURITY.md)** - Complete security guide covering:
- Threat model and attack scenarios
- VM isolation architecture
- Monitoring and detection capabilities
- Best practices for malware analysis
- Incident response procedures
- Known limitations and hardening recommendations

## Troubleshooting

### VM Won't Start
- Verify the VM bundle directory exists in `~/.avf/Linux/` or `~/.avf/MacOS/`
- Check that disk image, NVRAM, and MachineIdentifier files are present
- Review console logs for specific error messages

### Linux VM Installation Issues
- Ensure the ISO matches your Mac's architecture (ARM64 for Apple Silicon, x86_64 for Intel)
- Verify the ISO file is not corrupted (check SHA256 hash against official source)
- Allocate sufficient memory (minimum 2GB, recommended 4GB+)

### macOS VM Download Fails
- Check internet connection
- Verify you have sufficient disk space (macOS IPSWs are 12-15GB)
- Ensure firewall isn't blocking Apple's CDN servers

## License

See LICENSE.txt for details.

## Credits

Built using Apple's [Virtualization framework](https://developer.apple.com/documentation/virtualization).
