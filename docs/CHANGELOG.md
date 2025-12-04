# Changelog

All notable changes to SecVF (Computer Security Incident Response Team Virtualization Framework) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **TShark Packet Analysis Integration** - Full packet capture and analysis capabilities
  - `PacketCaptureManager` - Manages tshark subprocess with FIFO-based packet streaming
  - Real-time packet capture from VirtualNetworkSwitch at L3 level
  - JSON output parsing from tshark for detailed packet decoding
  - Circular buffer storing last 10,000 captured packets
  - Protocol statistics tracking (TCP, UDP, ICMP, ARP, DNS, HTTP, TLS)
  - PCAP file import/export for offline analysis

- **Mini Packet Log Panel** - New panel in VM Library window right sidebar
  - Tabbed interface: "Packets" tab (recent 15-20 packets) / "Protocols" tab (live counts)
  - Color-coded protocol display (TCP=blue, UDP=green, DNS=yellow, ARP=orange, etc.)
  - "Open Full Analysis" button to launch detailed packet window
  - Real-time updates via NotificationCenter subscription

- **Full Packet Analysis Window** (Cmd+Shift+P)
  - Live packet capture with Start/Stop/Clear controls
  - Display filter field with Wireshark-style syntax support
  - Sortable packet list table (Time, Source, Dest, Protocol, Length, Info)
  - Detailed packet decode view with layer tree structure
  - Hex dump display for raw packet data
  - PCAP file open/save dialogs
  - Auto-scroll toggle and status bar with live statistics
  - Dark theme consistent with SecVF cybersecurity aesthetic

- **Network Traffic Visualization Improvements**
  - Fixed UInt64 to Int casting for accurate packet/byte counters
  - Packets now animate only when actual traffic is detected
  - Better centering of packet flow visualization

### Fixed
- **Critical**: Fixed boolean logic bug causing Linux VMs to crash on startup
  - Changed `vm.osInstalled != true` to `vm.osInstalled == false` to properly handle nil values
  - This prevented NVRAM deletion on already-installed VMs
  - Resolves immediate crash/exit issues for Linux VMs, especially Kali Router

### Added
- Linux VM OS installation tracking
  - Added `osInstalled`, `linuxDistribution`, and `linuxVersion` fields to VMConfiguration
  - Automatic ISO detection and attachment for fresh Linux installations
  - Progress tracking for Linux ISO downloads with live updates

- Legacy VM compatibility support
  - Intelligent distribution inference from VM names (e.g., "Kali Router" → Kali 2024.1)
  - Graceful handling of VMs without new metadata fields
  - Migration path for existing VMs without requiring manual intervention

- Enhanced ISO cache validation
  - File size validation (> 1MB) to reject placeholder files
  - Proper ISO file detection (not just directory existence)
  - Added `getDistributionInfo()` method for cache status reporting

- Ubuntu variant differentiation
  - Split Ubuntu into Desktop and Server variants
  - Separate download URLs for each variant

### Improved
- ISOCacheManager validation logic
  - Enhanced `getCachedImage()` to validate actual ISO files
  - Added comprehensive error handling with user alerts
  - Better logging for debugging cache issues

- Documentation
  - Created detailed Linux boot fix documentation
  - Updated README with Linux VM installation information
  - Added troubleshooting guide for common Linux VM issues

## [Previous Release] - 2025-11-15

### Fixed
- macOS VM installation and boot issues
  - Fixed NVRAM persistence for successful VM booting
  - Resolved installation state tracking bugs
  - Fixed main thread deadlock in IPSW download initialization

### Added
- Real-time macOS IPSW download progress
  - Live GB/percentage tracking during downloads
  - Fixed modal dialog threading issues
  - Enhanced progress UI with accurate status updates

- ISO Cache Manager
  - Centralized, secure ISO/IPSW download management
  - Security audit logging for all cache operations
  - SSL certificate validation and security hardening
  - Support for 8 Linux distributions

### Improved
- Security logging
  - Comprehensive NSLog debugging for download flow validation
  - Enhanced audit trail for security operations
  - Better error reporting and diagnostics

- Network configuration
  - Moved network types to dedicated file for better organization
  - Improved virtual switch implementation
  - Better VM-to-VM networking support

## [Initial Release] - 2025-11-01

### Features
- Core VM management (create, start, stop, delete, clone)
- Support for Linux and macOS virtual machines
- Apple Virtualization framework integration
- Virtual network switch for isolated VM networking
- Real-time monitoring and logging
- Security-focused design for malware analysis
- Automatic VM migration from legacy locations
- SPICE agent support for clipboard sharing
- Rosetta support for x86_64 binaries on ARM Linux