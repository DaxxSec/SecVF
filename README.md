<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:0f0c29,50:302b63,100:24243e&height=200&section=header&text=SecVF&fontSize=90&fontColor=ffffff&animation=twinkling&fontAlignY=40&desc=Security%20Virtualization%20Framework&descAlignY=62&descSize=20&descColor=a78bfa" width="100%"/>

[![macOS](https://img.shields.io/badge/macOS_14+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift_5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/newsroom/2020/11/apple-unleashes-m1/)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e?style=for-the-badge)](LICENSE.txt)
[![Tag](https://img.shields.io/github/v/tag/DaxxSec/SecVF?style=for-the-badge&color=6366f1&label=version)](https://github.com/DaxxSec/SecVF/tags)
[![Stars](https://img.shields.io/github/stars/DaxxSec/SecVF?style=for-the-badge&color=eab308)](https://github.com/DaxxSec/SecVF/stargazers)

<br/>

> **Run malware. Capture everything. Stay isolated.**
>
> SecVF spins up hardware-isolated VMs via Apple's Virtualization framework, routes their traffic through an instrumented Kali Linux router, and gives you Wireshark-grade packet analysis — all in a native macOS app.

<br/>

</div>

---

## ⚡ What It Does

<table>
<tr>
<td width="50%">

### 🔬 Malware Analysis
Detonate samples in isolated VMs with full network visibility. Every packet captured, every connection logged. Hardware-enforced containment via Apple Virtualization Framework — no escape to host.

</td>
<td width="50%">

### 🌐 Network Forensics
L2/L3 software switch with real-time packet capture. Wireshark-style display filters, live protocol breakdown, PCAP export. Kali router VM sits between your malware and the internet.

</td>
</tr>
<tr>
<td width="50%">

### 🤖 AI Sandbox
Ephemeral macOS guest VMs for AI agent execution. APFS CoW session cloning (~0ms), VirtioFS workspace sharing, vsock IPC bridge, DTrace/ESF telemetry — spin up, run, destroy.

</td>
<td width="50%">

### 🛡️ Incident Response
Security audit logging with severity levels (INFO → EMERGENCY). Real-time filesystem monitoring, process telemetry, ISO checksum validation. Full audit trail at `~/.avf/logs/`.

</td>
</tr>
</table>

---

## 🖥️ Screenshots

<div align="center">

| VM Library | Packet Analysis |
|:---:|:---:|
| *Multi-VM management with live packet log panel* | *Wireshark-style deep packet inspection* |

> 📸 Screenshots coming soon — build from source and run to see it in action.

</div>

---

## 🚀 Quick Start

### Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| macOS | **14.0+ Sonoma** | Required for Virtualization framework features |
| Xcode | **15.0+** | For building from source |
| Apple Silicon | **M1+** | Required for macOS guest VMs; Intel for Linux VMs |
| tshark | **optional** | Enables packet capture: `brew install wireshark` |

### Install

```bash
git clone https://github.com/DaxxSec/SecVF.git
cd SecVF
open SecVF.xcodeproj
# Build & Run: ⌘R
```

### Optional: tshark for packet capture
```bash
brew install wireshark
```

---

## 🔧 Features

### Virtual Machine Management

```
┌─────────────────────────────────────────────────────┐
│  VM Library                              [+ New VM]  │
│  ─────────────────────────────────────────────────  │
│  ● Kali-Router     Running   Virtual Net   192MB     │
│  ● Ubuntu-Sandbox  Running   Virtual Net   512MB     │
│  ○ Windows-11      Stopped   NAT           -         │
│  ○ macOS-14-AI     Stopped   NAT           -         │
└─────────────────────────────────────────────────────┘
```

- 🐧 **8 Linux distros** — Kali, Ubuntu, Debian, Fedora, Arch & more
- 🍎 **macOS guest VMs** — Full IPSW install via Apple CDN (Apple Silicon only)
- 🔄 **Multi-window sessions** — Each VM gets its own window
- 💾 **ISO cache manager** — SHA256-verified downloads, no re-downloading

### Network Stack

```
  [ Malware VM ] ──┐
  [ Analysis VM ] ─┤──▶ [ Virtual Switch ] ──▶ [ Kali Router ] ──▶ Internet
  [ AI Sandbox ] ──┘         (L2/L3)           (traffic tap)
                                │
                         [ PacketCapture ]
                         [ tshark/PCAP   ]
```

| Mode | Use Case |
|---|---|
| 🌍 **NAT** | Standard internet access through host |
| 🔒 **Virtual Network** | Isolated VM-to-VM, no host internet |
| 🕵️ **Router VM** | Kali as gateway — full traffic interception |
| 🎭 **FakeNet** | DNS/HTTP honeypot — capture malware C2 comms |

### Packet Analysis

> Access via **Monitoring → Packet Analysis** or `⌘⇧P`

| Feature | Details |
|---|---|
| 🔴 **Live Capture** | Start/Stop/Clear with real-time packet stream |
| 🔍 **Display Filters** | Wireshark-style: `tcp`, `ip.addr == 10.0.100.1`, `dns` |
| 📊 **Protocol Stats** | Live breakdown: TCP/UDP/DNS/ARP/ICMP/HTTP |
| 🔬 **Packet Decode** | Layer-by-layer: Ethernet → IP → TCP/UDP → Application |
| 💾 **PCAP Export** | Save captures for Wireshark or offline analysis |
| 📟 **Hex Dump** | Raw bytes with ASCII representation |

### Real-Time Monitoring

| Window | Shortcut | What You See |
|---|---|---|
| 🔐 Security Logs | `⌘⇧1` | Filesystem events, process activity, severity alerts |
| 🌐 Network Logs | `⌘⇧2` | Virtual switch traffic, connection log |
| 📦 Packet Analysis | `⌘⇧P` | Deep packet inspection (tshark) |
| 📈 Switch Statistics | `⌘⇧3` | Forwarding rates, MAC table, dropped packets |
| ✅ ISO Cache Audit | `⌘⇧4` | Download history, checksum validation log |

---

## 🏗️ Architecture

```
SecVF/
├── 🧠 Core
│   ├── AppDelegate.swift              # App lifecycle, VM window management
│   ├── VMManager.swift                # VM CRUD, bundle management
│   └── VMConfiguration.swift         # Codable VM settings model
│
├── 🌐 Network Stack
│   ├── VirtualNetworkSwitch.swift     # L2/L3 software switch, MAC learning
│   ├── PacketCaptureManager.swift     # tshark integration, Combine publishers
│   └── PacketAnalysisWindowController.swift  # Wireshark-style UI
│
├── 🖥️ UI
│   └── VMLibraryWindowController.swift  # Main window (~2600 LOC)
│
├── 🤖 AI Sandbox
│   └── AISandboxMacVMConfiguration.swift  # macOS guest VM + vsock IPC
│
├── 🔒 Security
│   ├── VMSecurityMonitor.swift        # Real-time security event logging
│   └── SecVFError.swift               # Typed errors, audit trail
│
├── 📦 Supporting
│   ├── ISOCacheManager.swift          # ISO download + SHA256 verification
│   ├── MacOSVMInstaller.swift         # IPSW download from Apple CDN
│   └── ScriptsUSBManager.swift        # Guest VM script delivery
│
└── 📜 Scripts
    ├── kali-router-setup.sh           # Kali as NAT router + traffic tap
    ├── kali-fakenet-setup.sh          # FakeNet DNS/HTTP honeypot
    └── provision-macos-vm.sh          # AI Sandbox macOS guest provisioning
```

---

## 🦠 Malware Analysis Workflow

```bash
# 1. Set up your analysis environment
#    Create Kali Router VM → run kali-router-setup.sh inside it

# 2. Create your malware sandbox VM
#    New VM → Linux/Windows → Virtual Network mode

# 3. Start monitoring
#    ⌘⇧P  →  Start Capture

# 4. Detonate
#    Execute malware sample in sandbox VM

# 5. Analyze
#    Watch live traffic in packet panel
#    Export PCAP for deeper Wireshark analysis
#    Check Security Logs (⌘⇧1) for filesystem activity
```

---

## 🤖 AI Sandbox Workflow

Ephemeral macOS VMs for safe AI agent execution:

```
Build once:   AISandboxMacVMInstaller.downloadAndInstall()
               └─▶ IPSW download → macOS install → provision
               └─▶ ai-sandbox-base-v1.bundle  (~/.avf/AISandbox/)

Each session: AISandboxVMSession.cloneBase()   # APFS CoW, ~0ms
              AISandboxVMSession.boot()
              AISandboxVMSession.run("your command")  # vsock:2222
              AISandboxVMSession.destroy()      # wipe session bundle
```

**Isolation guarantees:** hardware VM boundary · non-admin agent user · workspace-only write access · DTrace + ESF telemetry

---

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| New VM | `⌘N` |
| Start VM | `⌘S` |
| Stop VM | `⌘.` |
| Packet Analysis | `⌘⇧P` |
| Security Logs | `⌘⇧1` |
| Network Logs | `⌘⇧2` |
| Switch Stats | `⌘⇧3` |
| ISO Cache Audit | `⌘⇧4` |

---

## 🛠️ Tech Stack

<div align="center">

[![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Apple Virtualization](https://img.shields.io/badge/Virtualization_Framework-000000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/virtualization)
[![AppKit](https://img.shields.io/badge/AppKit-1D6FA5?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/appkit)
[![Combine](https://img.shields.io/badge/Combine-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/documentation/combine)
[![tshark](https://img.shields.io/badge/tshark-1679A7?style=flat-square&logo=wireshark&logoColor=white)](https://www.wireshark.org/docs/man-pages/tshark.html)

</div>

- **Apple Virtualization Framework** — Hardware-enforced VM isolation (macOS 14+)
- **Swift Concurrency** — `async/await`, `@MainActor`, Combine for reactive packet updates
- **tshark** — Packet capture via FIFO pipe, JSON output parsing
- **VirtioFS** — High-performance host↔guest file sharing
- **vsock** — Low-latency host↔VM IPC (AI Sandbox command channel)

---

## 🔐 Security Model

- **Hardware isolation** — Apple Virtualization Framework, not containers
- **No shared folders by default** — VMs are air-gapped from host filesystem
- **IPSW validation** — Downloads only from `*.cdn-apple.com`, TLS 1.2+, extension check
- **ISO verification** — SHA256 checksums fetched from official distro mirrors
- **URL domain whitelisting** — Hardcoded allowlist for all network downloads
- **Severity-levelled alerting** — INFO / WARNING / CRITICAL / EMERGENCY events
- **Audit trail** — `~/.avf/logs/security-*.log`, `error-audit.log`

---

## 🤝 Contributing

```bash
# Fork → branch → commit → PR
git checkout -b feature/your-feature
git commit -m "feat: add your feature"
git push origin feature/your-feature
# Open a Pull Request on GitHub
```

---

## 📄 License

MIT — see [LICENSE.txt](LICENSE.txt)

---

<div align="center">

**Built by [DaxxSec](https://github.com/DaxxSec)**

[![GitHub](https://img.shields.io/badge/GitHub-DaxxSec-181717?style=for-the-badge&logo=github)](https://github.com/DaxxSec)

*If SecVF saves you time on an investigation, give it a ⭐*

</div>
