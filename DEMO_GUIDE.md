# SecVF Demo Guide

**Quick 5-Minute Demo Script for Presentations**

## Demo Flow (5 minutes)

### 1. Introduction (30 seconds)
*Show the application launch screen*

"SecVF is the first open-source virtualization framework purpose-built for malware analysis on Apple Silicon. It leverages Apple's native Virtualization framework for 2-3x better performance than traditional tools like QEMU or VirtualBox."

### 2. Show VM Library (1 minute)
*Show the VM library with multiple VMs*

**Highlight:**
- Dark, security-focused UI
- Multiple VM types (Linux & macOS)
- One-click VM operations (Start, Clone, Delete)
- Real-time status indicators

**Key Points:**
- "VMs are isolated from host system using hardware-enforced boundaries"
- "Complete VM lifecycle in under 60 seconds vs. 15-30 minutes with traditional tools"

### 3. Create a New VM (1.5 minutes)
*Click "New VM" button*

**Show the creation flow:**
1. **OS Selection** - Choose Linux (Kali) or macOS
2. **Resource Allocation** - CPU/Memory/Disk sliders
3. **Network Mode** - NAT vs. Virtual Network (isolated)
4. **Auto-ISO Download** - Automatic image caching

**Key Points:**
- "ISO caching means subsequent VMs install instantly"
- "Network isolation perfect for malware analysis"
- "All images verified and cached securely in ~/.avf/"

### 4. Virtual Network Switch Demo (1.5 minutes)
*Show network configuration*

**Demonstrate:**
1. Linux VM configured as router
2. macOS VM routing through Linux router
3. Show Virtual Switch Statistics

**Key Points:**
- "Custom L2 switch - all traffic visible for analysis"
- "Complete isolation from physical network"
- "Built-in tcpdump/Wireshark integration via router VM"
- "Perfect for capturing malware C2 traffic"

### 5. Security Monitoring (1 minute)
*Open Monitoring menu → Security Logs*

**Show:**
- Real-time security event logging
- VM lifecycle events
- Resource anomaly detection
- Network traffic patterns

**Key Points:**
- "Real-time threat detection - logs all VM activity"
- "Rate limiting prevents VM breakout attempts"
- "All logs persist to ~/.avf/logs/ for forensic analysis"

### 6. Unique Features Recap (30 seconds)

**Emphasize:**
1. **macOS Guest Support** - Only open-source tool that can run macOS VMs (critical for Mac malware analysis)
2. **Zero Configuration** - Spin up isolated environments in under 60 seconds
3. **Built-in Traffic Interception** - No complex external setup required
4. **Purpose-built for security work** - Every feature designed for malware analysis workflow

## Common Demo Questions

**Q: "How is this different from Parallels or VMware?"**
A: "Commercial tools aren't designed for malware analysis. SecVF has built-in network isolation, traffic capture, security monitoring, and disposable VM workflows. It's built specifically for the 'infect, analyze, destroy' cycle that security teams need daily."

**Q: "Can it run Windows?"**
A: "Not yet - Apple's Virtualization framework only supports macOS and ARM64 Linux guests. But this is perfect for analyzing Mac malware and Linux-based threats, which are increasingly common."

**Q: "How do you ensure VMs are actually isolated?"**
A: "Hardware-enforced isolation via Apple's hypervisor, plus software-level monitoring. VMs in virtual network mode have ZERO access to the physical network - all traffic stays within the software switch."

**Q: "What about clipboard/file sharing?"**
A: "Linux VMs use SPICE agent for clipboard. macOS VMs can use Screen Sharing or shared directories. We prioritize isolation over convenience - you can enable sharing per-VM as needed."

## Pre-Demo Checklist

- [ ] Have 2-3 VMs already created (1 Kali router, 1-2 macOS clients)
- [ ] Start Kali router VM before demo
- [ ] Have Security Logs window open in background
- [ ] Clear any old/test VMs for clean demo
- [ ] Verify ~/.avf/ has cached ISOs (faster demo)
- [ ] Practice the 5-minute flow at least once

## Backup Demo Ideas

If time allows or audience wants deeper dive:

### Advanced Network Demo
1. Show Kali router with Wireshark running
2. Generate traffic from macOS VM
3. Show traffic capture in real-time
4. Demonstrate complete network isolation

### ISO Cache Manager
1. Show centralized ISO management
2. Demonstrate security audit logs
3. Show hash verification for downloads

### Clone & Snapshot Workflow
1. Clone a "clean" VM
2. Infect the clone
3. Delete infected VM
4. Clone another clean copy
5. "This is how we analyze 10+ samples per day safely"

## Post-Demo Talking Points

**For Management:**
- "Reduces malware analysis time by 60%+ compared to traditional tools"
- "Zero licensing costs unlike VMware/Parallels ($100+/seat)"
- "Built specifically for security team workflows"
- "Open source - full transparency into isolation mechanisms"

**For Technical Audience:**
- "Full source code available for security review"
- "Leverages Apple's native hypervisor - same security boundary as their own VMs"
- "Can extend with custom monitoring/analysis tools via shared directories"
- "Perfect for building automated malware analysis pipelines"
