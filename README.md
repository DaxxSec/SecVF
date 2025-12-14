# SecVF - Computer Security Incident Response Team Virtualization Framework

A native macOS virtualization framework for security research, malware analysis, and incident response. Built with Swift using Apple's Virtualization framework.

## Features

### Virtual Machine Management
- Multi-VM library with flexible configuration
- Support for Linux (8 distros) and macOS virtual machines
- Multi-window VM sessions
- Clone, rename, delete VMs
- Automatic ISO cache management

### Network Configuration
- **NAT Mode** - Internet access through host
- **Virtual Network Switch** - Isolated VM-to-VM communication
- **Router VM** - Kali Linux router for traffic analysis
- Real-time network traffic visualization

### Packet Analysis (NEW)

SecVF integrates tshark for deep packet inspection of VM network traffic.

#### Mini Packet Log Panel
The right sidebar displays a compact packet log with:
- **Packets Tab** - Recent 15-20 packets with timestamp, protocol, and addresses
- **Protocols Tab** - Live protocol breakdown (TCP, UDP, DNS, ARP, etc.)
- Color-coded by protocol type
- "Open Full Analysis" button

#### Full Packet Analysis Window
Access via **Monitoring > Packet Analysis** (Cmd+Shift+P):

| Feature | Description |
|---------|-------------|
| Live Capture | Start/Stop/Clear controls with real-time packet display |
| Display Filter | Wireshark-style filters (e.g., `tcp`, `ip.addr == 10.0.100.1`) |
| Packet Table | Sortable columns: Time, Source, Dest, Protocol, Length, Info |
| Packet Details | Layer-by-layer decode tree (Ethernet, IP, TCP/UDP, etc.) |
| Hex Dump | Raw packet bytes with ASCII representation |
| PCAP Support | Open/Save PCAP files for offline analysis |

#### Requirements
```bash
# Install tshark (Wireshark CLI tools)
brew install wireshark
```

### Security Analysis Tools
- **Virtual Network Switch** - L2/L3 packet capture and forwarding
- **Kali Router VM** - Traffic interception and analysis
- **FakeNet Integration** - DNS/HTTP honeypot services
- Security audit logging

### Real-Time Monitoring
| Viewer | Shortcut | Description |
|--------|----------|-------------|
| Security Logs | Cmd+Shift+1 | Filesystem changes, security events |
| Network Logs | Cmd+Shift+2 | Virtual switch traffic logs |
| Packet Analysis | Cmd+Shift+P | Deep packet inspection |
| Switch Statistics | Cmd+Shift+3 | Network switch metrics |
| ISO Cache Audit | Cmd+Shift+4 | Download validation logs |

## Installation

### Prerequisites
- macOS 14.0+ (Sonoma or later)
- Apple Silicon or Intel Mac with Virtualization support
- Xcode 15.0+
- tshark (optional, for packet analysis): `brew install wireshark`

### From Source
```bash
git clone https://github.com/ItzDaxxy/SecVF.git
cd SecVF
open SecVF.xcodeproj
```

Build and run with Xcode (Cmd+R).

## Usage

### Creating a VM
1. Click "New" in the VM Library
2. Select OS type (Linux/macOS)
3. Configure CPU, memory, disk size
4. Select network mode (NAT or Virtual Network)
5. Click "Create"

### Setting Up Malware Analysis Environment
1. Create a Kali Router VM on Virtual Network
2. Run `kali-router-setup.sh` on the router
3. Create analysis VMs connected to Virtual Network
4. Start packet capture in Packet Analysis window
5. Execute malware sample and observe traffic

### Keyboard Shortcuts
| Action | Shortcut |
|--------|----------|
| New VM | Cmd+N |
| Start VM | Cmd+S |
| Stop VM | Cmd+. |
| Packet Analysis | Cmd+Shift+P |
| Security Logs | Cmd+Shift+1 |
| Network Logs | Cmd+Shift+2 |

## Project Structure

```
SecVF/
├── SecVF/
│   ├── AppDelegate.swift           # Main application delegate
│   ├── VMConfiguration.swift       # VM configuration model
│   ├── VMManager.swift             # VM lifecycle management
│   ├── VMLibraryWindowController.swift  # Main window UI
│   ├── VirtualNetworkSwitch.swift  # L2/L3 network switch
│   ├── PacketCaptureManager.swift  # tshark integration (NEW)
│   ├── PacketAnalysisWindowController.swift  # Packet UI (NEW)
│   ├── LogViewerWindowController.swift  # Log viewer
│   └── ...
├── scripts/
│   ├── kali-router-setup.sh        # Router VM configuration
│   ├── kali-fakenet-setup.sh       # FakeNet honeypot setup
│   └── macos-network-setup.sh      # macOS VM networking
├── docs/
│   ├── CHANGELOG.md                # Version history
│   └── ...
└── SecVFTests/                   # Unit tests
```

## Tech Stack

- **Swift** - Native macOS development
- **Apple Virtualization Framework** - VM hypervisor
- **AppKit** - macOS UI framework
- **tshark/Wireshark** - Packet capture and analysis

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE.txt file for details.

## Acknowledgments

- Apple Virtualization Framework team
- Wireshark/tshark developers
- ItzDaxxy team

---

**Developed by ItzDaxxy**
- 
- itzdaxxy@users.noreply.github.com
