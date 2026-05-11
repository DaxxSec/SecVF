//
//  VirtualNetworkSwitch.swift
//  SecVF
//
//  VIRTUAL NETWORK SWITCH
//  Implements a software-based Ethernet switch for VM-to-VM communication
//  using Unix domain sockets with VZFileHandleNetworkDeviceAttachment.
//
//  Architecture:
//  - Each VM connects via a socket pair (read/write)
//  - Switch learns MAC addresses from source packets
//  - Forwards frames based on destination MAC (L2 switching)
//  - Supports broadcast/multicast flooding
//  - Completely isolated from host physical network
//
//  Security:
//  - No physical network exposure
//  - VMs can only communicate with other VMs on same virtual switch
//  - Perfect for malware analysis sandboxing
//  - All traffic logged for forensic analysis
//

import Foundation
import Network
import os.log

/// Represents a connected VM on the virtual switch
class VirtualSwitchPort {
    let vmId: UUID
    let vmName: String
    let socketPath: String
    var macAddress: String?  // Learned from traffic
    var connection: NWConnection?
    var isConnected: Bool = false

    // FileHandles for bidirectional I/O
    var readHandle: FileHandle?   // For receiving packets from VM
    var writeHandle: FileHandle?  // For sending packets to VM

    // Traffic statistics
    var packetsReceived: UInt64 = 0
    var packetsSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var bytesSent: UInt64 = 0

    // Security monitoring - rate limiting
    var packetsLastSecond: Int = 0
    var lastRateLimitReset: Date = Date()
    var broadcastCountLastSecond: Int = 0

    // Per-port serial write queue. Without this, sendPacket() would block the global
    // switchQueue on every write, so a single slow or wedged guest (recv buffer full)
    // would stall MAC learning and packet forwarding for every other guest, and a
    // disconnectPortSync from the main thread would deadlock-wait behind the write.
    let writeQueue: DispatchQueue

    init(vmId: UUID, vmName: String, socketPath: String) {
        self.vmId = vmId
        self.vmName = vmName
        self.socketPath = socketPath
        self.writeQueue = DispatchQueue(
            label: "com.secvf.virtualswitch.port.\(vmId.uuidString)",
            qos: .userInitiated
        )
    }
}

/// Virtual Ethernet switch for VM-to-VM communication
class VirtualNetworkSwitch {
    static let shared = VirtualNetworkSwitch()

    private let logger = OSLog(subsystem: "com.DaxxSec.SecVF", category: "VirtualSwitch")
    private let switchQueue = DispatchQueue(label: "com.secvf.virtualswitch", qos: .userInitiated)

    // Connected VMs (ports on the switch)
    private var ports: [UUID: VirtualSwitchPort] = [:]

    // MAC address learning table (MAC -> VM ID)
    private var macTable: [String: UUID] = [:]

    // Switch statistics
    private var totalPacketsForwarded: UInt64 = 0
    private var totalPacketsBroadcast: UInt64 = 0

    private var isRunning = false

    /// Threat-model default: a guest spoofing another's MAC is hostile and
    /// the packet is dropped. Logging-only was the previous behaviour and
    /// fundamentally incompatible with this app's stated threat model
    /// ("hostile guest"). Set to `false` to fall back to log-only — useful
    /// for debugging benign MAC reassignments after a guest reboot, but
    /// should not be the default.
    var dropOnMACSpoof: Bool = true

    /// Per-port socket buffer size. macOS defaults SO_SNDBUF/SO_RCVBUF on a
    /// SOCK_DGRAM socketpair to ~8 KB, smaller than the 9000-byte jumbo
    /// frame limit accepted by validatePacket. The kernel silently drops
    /// frames between the buffer size and the validator's limit, so we
    /// raise both buffers to comfortably cover jumbo + several queued frames.
    /// 256 KB is well within macOS's per-socket SO_SNDBUF/SO_RCVBUF maximums.
    private static let socketBufferBytes: Int32 = 256 * 1024

    private init() {
        setupSwitch()
    }

    // MARK: - Switch Lifecycle

    private func setupSwitch() {
        log("Virtual network switch initializing...")

        // Create socket directory if needed
        let socketDir = NSHomeDirectory() + "/.avf/sockets/"
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)

        isRunning = true
        log("Virtual network switch ready")
    }

    func shutdown() {
        // Use async to avoid blocking the caller, and inline disconnect logic
        // to avoid queuing more async blocks that can't execute
        switchQueue.async { [weak self] in
            guard let self = self else { return }

            self.log("Shutting down virtual switch...")

            // Disconnect all ports INLINE (don't call disconnectPort which queues more async work)
            for (_, port) in self.ports {
                self.tearDownPortInline(port)
            }

            self.ports.removeAll()
            self.macTable.removeAll()
            self.isRunning = false

            self.log("Virtual switch shutdown complete")
        }
    }

    /// Shared per-port teardown used by shutdown() and performDisconnect().
    /// Must be called on switchQueue. Mirrors performDisconnect's invariants:
    /// cancel any NWConnection, drop the readability handler, do NOT close()
    /// the FileHandle (closeOnDealloc handles that), remove from MAC table.
    private func tearDownPortInline(_ port: VirtualSwitchPort) {
        port.connection?.cancel()
        port.isConnected = false
        port.readHandle?.readabilityHandler = nil
        if let mac = port.macAddress {
            macTable.removeValue(forKey: mac)
        }
        port.readHandle = nil
        port.writeHandle = nil
    }

    // MARK: - Port Management

    /// Connect a VM to the virtual switch
    func connectVM(vmId: UUID, vmName: String) -> FileHandle? {
        return switchQueue.sync {
            guard isRunning else {
                log("Cannot connect VM - switch not running", type: .error)
                return nil
            }

            // Create unique socket path for this VM
            let socketPath = NSHomeDirectory() + "/.avf/sockets/vm-\(vmId.uuidString).sock"

            // Remove old socket if exists
            try? FileManager.default.removeItem(atPath: socketPath)

            // Create socket pair for bidirectional communication
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
                log("Failed to create socket pair for VM: \(vmName)", type: .error)
                return nil
            }

            let switchFd = fds[0]  // Switch side
            let vmFd = fds[1]      // VM side

            // Tune SO_SNDBUF/SO_RCVBUF on both ends to comfortably hold a
            // jumbo (9000-byte) frame plus headroom. The default ~8 KB on
            // macOS SOCK_DGRAM socketpairs would silently drop frames whose
            // size sits between the buffer cap and validatePacket's 9000-byte
            // limit (item 17 of code review). Failures are logged but
            // non-fatal — a smaller buffer still works for sub-MTU traffic.
            var bufBytes = Self.socketBufferBytes
            let setBuf: (Int32, Int32, String) -> Void = { fd, opt, name in
                if setsockopt(fd, SOL_SOCKET, opt, &bufBytes, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                    NSLog("[VirtualSwitch] setsockopt %@ on fd %d failed: %s",
                          name, fd, strerror(errno))
                }
            }
            setBuf(switchFd, SO_SNDBUF, "SO_SNDBUF")
            setBuf(switchFd, SO_RCVBUF, "SO_RCVBUF")
            setBuf(vmFd, SO_SNDBUF, "SO_SNDBUF")
            setBuf(vmFd, SO_RCVBUF, "SO_RCVBUF")

            // Create FileHandle for the switch side
            // This socket is bidirectional - we can both read and write on it
            let switchHandle = FileHandle(fileDescriptor: switchFd, closeOnDealloc: true)

            // Create port entry
            let port = VirtualSwitchPort(vmId: vmId, vmName: vmName, socketPath: socketPath)
            port.isConnected = true
            port.readHandle = switchHandle   // Read packets from VM
            port.writeHandle = switchHandle  // Send packets to VM (same FD - it's bidirectional)
            ports[vmId] = port

            // Start receiving packets from this VM
            startReceiving(from: switchHandle, vmId: vmId)

            log("VM connected to virtual switch: \(vmName) [Port: \(ports.count)]")

            // Return the VM's end of the socketpair as a FileHandle
            // The VM side is also bidirectional - VM can both send and receive
            return FileHandle(fileDescriptor: vmFd, closeOnDealloc: false)
        }
    }

    /// Disconnect a VM from the virtual switch (async - for internal use only)
    func disconnectPort(vmId: UUID) {
        switchQueue.async { [weak self] in
            self?.performDisconnect(vmId: vmId)
        }
    }

    /// Synchronously disconnect a VM from the virtual switch.
    /// Must be called BEFORE deallocating the VZVirtualMachine to prevent use-after-free
    /// in the readability handler. Safe to call from main thread.
    func disconnectPortSync(vmId: UUID) {
        switchQueue.sync {
            performDisconnect(vmId: vmId)
        }
    }

    /// Shared disconnect implementation. Must be called on switchQueue.
    /// Uses tearDownPortInline so shutdown() and disconnect produce identical
    /// teardown — previously these diverged (shutdown was missing the
    /// connection.cancel() call from this path).
    private func performDisconnect(vmId: UUID) {
        // Use removeValue for atomic check-and-remove to prevent double processing.
        // Any in-flight readability handler is blocked on switchQueue.sync so
        // it will see the port removed and bail out safely. Don't explicitly
        // close() the FileHandle — it was created with closeOnDealloc: true.
        guard let port = ports.removeValue(forKey: vmId) else {
            return
        }
        tearDownPortInline(port)
        log("VM disconnected from virtual switch: \(port.vmName) [Remaining ports: \(ports.count)]")
    }

    // MARK: - Packet Processing

    private func startReceiving(from handle: FileHandle, vmId: UUID) {
        // Read Ethernet frames from VM
        // IMPORTANT: The handler runs on an internal dispatch queue, so we must be
        // defensive against the port being disconnected while the handler runs.
        //
        // The validity check AND the data read must be atomic (both inside switchQueue.sync)
        // to prevent a TOCTOU race where disconnectPortSync runs between the check and the read,
        // causing EXC_BAD_ACCESS on the invalidated file descriptor.
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self = self else { return }

            // Atomically check port validity and read data inside the same lock.
            // This serializes with disconnectPortSync/performDisconnect on switchQueue,
            // so the port cannot be torn down between the check and the read.
            let data: Data? = self.switchQueue.sync {
                guard let port = self.ports[vmId], port.isConnected else { return nil }
                return fileHandle.availableData
            }

            guard let data = data, !data.isEmpty else {
                // nil means port was disconnected — don't touch fileHandle.
                // Empty data means connection closed — request async disconnect.
                if data != nil {
                    self.disconnectPort(vmId: vmId)
                }
                return
            }

            self.switchQueue.async {
                self.processPacket(data: data, fromVM: vmId)
            }
        }
    }

    private func processPacket(data: Data, fromVM: UUID) {
        // SECURITY: Validate packet before processing
        guard validatePacket(data: data, fromVM: fromVM) else {
            return
        }

        // Parse Ethernet header (14 bytes)
        let dstMAC = data[0..<6].map { String(format: "%02x", $0) }.joined(separator: ":")
        let srcMAC = data[6..<12].map { String(format: "%02x", $0) }.joined(separator: ":")
        let etherType = UInt16(data[12]) << 8 | UInt16(data[13])

        // SECURITY: Detect MAC spoofing. The conservative default for a
        // hostile-guest threat model is to drop the offending frame; the
        // legitimate "MAC changed after reboot" case is rare and the guest
        // can recover by sending from a different (unclaimed) MAC. Toggle
        // `dropOnMACSpoof` to false on the switch instance for log-only.
        if detectMACSpoof(srcMAC: srcMAC, vmId: fromVM) {
            if dropOnMACSpoof {
                log("SECURITY: Dropping spoofed packet (srcMAC: \(srcMAC), fromVM: \(fromVM))", type: .error)
                return
            }
        }

        // Update statistics and check rate limits
        guard let port = ports[fromVM] else { return }

        port.packetsReceived += 1
        port.bytesReceived += UInt64(data.count)

        // SECURITY: Check if this is a broadcast for rate limiting
        let isBroadcast = data[0] & 0x01 == 1 || dstMAC == "ff:ff:ff:ff:ff:ff"

        // SECURITY: Rate limiting check
        guard checkRateLimit(port: port, isBroadcast: isBroadcast) else {
            // Rate limit exceeded - drop packet
            return
        }

        // Learn source MAC address
        if port.macAddress == nil || port.macAddress != srcMAC {
            // Evict the previous MAC from the lookup table. Without this,
            // a guest rotating source MACs (legitimately on driver reload,
            // maliciously to bypass filtering, or accidentally by crafting
            // random src MACs) grows macTable unboundedly — each rotation
            // adds a new entry while the previous one orphans. The MAC
            // table is bounded only by port count if we always sweep the
            // old value.
            if let oldMAC = port.macAddress {
                macTable.removeValue(forKey: oldMAC)
            }
            port.macAddress = srcMAC
            macTable[srcMAC] = fromVM
            log("Learned MAC address \(srcMAC) on port \(port.vmName)")
        }

        // Log EtherType for monitoring (helps detect unusual protocols)
        let etherTypeStr = String(format: "0x%04X", etherType)
        log("Packet from \(srcMAC) -> \(dstMAC), EtherType: \(etherTypeStr), Size: \(data.count) bytes", type: .debug)

        // Capture packet for tshark analysis
        let sourceVMName = port.vmName
        PacketCaptureManager.shared.capturePacket(data, sourceVM: sourceVMName, destVM: dstMAC)

        // Forward packet based on destination MAC
        forwardPacket(data: data, dstMAC: dstMAC, srcMAC: srcMAC, fromVM: fromVM)
    }

    private func forwardPacket(data: Data, dstMAC: String, srcMAC: String, fromVM: UUID) {
        // Check if destination is broadcast/multicast
        let isBroadcast = dstMAC == "ff:ff:ff:ff:ff:ff"
        let isMulticast = data[0] & 0x01 == 1  // Check multicast bit

        if isBroadcast || isMulticast {
            // Flood to all ports except source
            totalPacketsBroadcast += 1
            for (vmId, port) in ports where vmId != fromVM && port.isConnected {
                sendPacket(data: data, toPort: port)
            }

            if isBroadcast {
                log("Broadcast packet from \(srcMAC) (\(data.count) bytes) -> all ports")
            }
        } else {
            // Unicast - look up destination in MAC table
            if let destVMId = macTable[dstMAC], let destPort = ports[destVMId] {
                // Known destination - send directly
                totalPacketsForwarded += 1
                sendPacket(data: data, toPort: destPort)

                if let srcPort = ports[fromVM] {
                    log("Forwarded packet \(srcPort.vmName) -> \(destPort.vmName) (\(data.count) bytes)")
                }
            } else {
                // Unknown destination - flood to all ports (learning)
                totalPacketsBroadcast += 1
                for (vmId, port) in ports where vmId != fromVM && port.isConnected {
                    sendPacket(data: data, toPort: port)
                }

                log("Unknown destination \(dstMAC) - flooding to all ports")
            }
        }
    }

    private func sendPacket(data: Data, toPort port: VirtualSwitchPort) {
        // Snapshot write handle while we hold switchQueue (the caller's serial context).
        // Dispatch the actual write to the port's own serial queue so a slow guest
        // (full recv buffer) cannot wedge switchQueue and stall every other port.
        guard let writeHandle = port.writeHandle, port.isConnected else {
            log("Cannot send packet - port not connected or no write handle for \(port.vmName)", type: .error)
            return
        }

        let vmId = port.vmId
        let vmName = port.vmName
        let byteCount = UInt64(data.count)

        port.writeQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try writeHandle.write(contentsOf: data)
                // Statistics and per-port state mutations must run back on switchQueue
                // (where every other access to ports[]/port fields happens).
                self.switchQueue.async {
                    if let p = self.ports[vmId], p.isConnected {
                        p.packetsSent += 1
                        p.bytesSent += byteCount
                    }
                }
                self.log("Sent \(byteCount) bytes to \(vmName)", type: .debug)
            } catch {
                // A write failure means this port is wedged or gone. Disconnect it
                // rather than silently logging — leaving it in `ports` would mean
                // every future broadcast tries (and fails) to write to it again.
                self.log("Failed to send packet to \(vmName): \(error.localizedDescription) — disconnecting port", type: .error)
                self.disconnectPort(vmId: vmId)
            }
        }
    }

    // MARK: - Statistics & Monitoring

    func getStatistics() -> [String: Any] {
        return switchQueue.sync {
            var stats: [String: Any] = [:]

            stats["running"] = isRunning
            stats["connectedPorts"] = ports.count
            stats["learnedMACs"] = macTable.count
            stats["packetsForwarded"] = totalPacketsForwarded
            stats["packetsBroadcast"] = totalPacketsBroadcast

            var portStats: [[String: Any]] = []
            for (_, port) in ports {
                portStats.append([
                    "vmName": port.vmName,
                    "macAddress": port.macAddress ?? "unknown",
                    "packetsRx": port.packetsReceived,
                    "packetsTx": port.packetsSent,
                    "bytesRx": port.bytesReceived,
                    "bytesTx": port.bytesSent
                ])
            }
            stats["ports"] = portStats

            return stats
        }
    }

    func printStatistics() {
        let stats = getStatistics()
        print("\n═══════════════════════════════════════")
        print("   VIRTUAL NETWORK SWITCH STATISTICS")
        print("═══════════════════════════════════════")
        print("Status: \(stats["running"] as? Bool ?? false ? "Running" : "Stopped")")
        print("Connected Ports: \(stats["connectedPorts"] ?? 0)")
        print("Learned MACs: \(stats["learnedMACs"] ?? 0)")
        print("Packets Forwarded: \(stats["packetsForwarded"] ?? 0)")
        print("Packets Broadcast: \(stats["packetsBroadcast"] ?? 0)")

        if let portStats = stats["ports"] as? [[String: Any]], !portStats.isEmpty {
            print("\nPort Details:")
            for port in portStats {
                print("  • \(port["vmName"] ?? "unknown")")
                print("    MAC: \(port["macAddress"] ?? "unknown")")
                print("    RX: \(port["packetsRx"] ?? 0) packets (\(port["bytesRx"] ?? 0) bytes)")
                print("    TX: \(port["packetsTx"] ?? 0) packets (\(port["bytesTx"] ?? 0) bytes)")
            }
        }
        print("═══════════════════════════════════════\n")
    }

    // MARK: - Logging & Security Monitoring

    private func log(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: logger, type: type, "[VSwitch] \(message)")
        print("[VSwitch] \(message)")

        // Also log to persistent network security log
        logToFile(message, type: type)
    }

    // Dedicated queue for log file I/O to prevent blocking switchQueue
    private static let logQueue = DispatchQueue(label: "com.secvf.virtualswitch.log", qos: .utility)

    private func logToFile(_ message: String, type: OSLogType) {
        // Capture timestamp NOW, but do I/O on background queue
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let logFileName = "network-\(dateFormatter.string(from: Date())).log"

        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())

        let severityStr: String
        switch type {
        case .info: severityStr = "INFO"
        case .default: severityStr = "DEFAULT"
        case .error: severityStr = "ERROR"
        case .fault: severityStr = "FAULT"
        default: severityStr = "DEBUG"
        }

        let logLine = "[\(timestamp)] [\(severityStr)] \(message)\n"

        // Move ALL file I/O to background queue to prevent blocking
        Self.logQueue.async {
            let logDir = NSHomeDirectory() + "/.avf/logs/"
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let logPath = logDir + logFileName

            if let logData = logLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logPath) {
                    if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(logData)
                        fileHandle.closeFile()
                    }
                } else {
                    try? logData.write(to: URL(fileURLWithPath: logPath))
                }
            }
        }
    }

    // MARK: - Security Validation

    /// Validates packet contents for security threats.
    /// Internal (not private) so unit tests can exercise it directly.
    func validatePacket(data: Data, fromVM: UUID) -> Bool {
        // Check for minimum Ethernet frame size
        guard data.count >= 14 else {
            if let port = ports[fromVM] {
                log("SECURITY: Malformed packet from \(port.vmName) - size too small (\(data.count) bytes)", type: .error)
            }
            return false
        }

        // Check for maximum frame size (jumbo frames = 9000 bytes)
        guard data.count <= 9000 else {
            if let port = ports[fromVM] {
                log("SECURITY: Oversized packet from \(port.vmName) - potential attack (\(data.count) bytes)", type: .error)
            }
            return false
        }

        return true
    }

    /// Detects potential MAC spoofing.
    /// Internal (not private) so unit tests can exercise it directly. Tests
    /// arrange the macTable + ports state via the public API (connectVM).
    func detectMACSpoof(srcMAC: String, vmId: UUID) -> Bool {
        // Check if this MAC is already learned from a different VM
        if let learnedVMId = macTable[srcMAC], learnedVMId != vmId {
            if let attackerPort = ports[vmId], let victimPort = ports[learnedVMId] {
                let msg = "MAC spoofing detected: \(attackerPort.vmName) using MAC \(srcMAC) already assigned to \(victimPort.vmName)"
                log("SECURITY WARNING: \(msg)", type: .error)
                VMSecurityMonitor.shared.logSecurityEvent(
                    .critical,
                    type: .networkAnomaly,
                    vmName: attackerPort.vmName,
                    message: msg,
                    details: [
                        "srcMAC": srcMAC,
                        "victimVM": victimPort.vmName,
                        "victimVMID": learnedVMId.uuidString
                    ]
                )
                return true
            }
        }
        return false
    }

    /// Rate limiting - detects packet flooding attacks
    private func checkRateLimit(port: VirtualSwitchPort, isBroadcast: Bool) -> Bool {
        let now = Date()
        let timeSinceReset = now.timeIntervalSince(port.lastRateLimitReset)

        // Reset counters every second
        if timeSinceReset >= 1.0 {
            port.packetsLastSecond = 0
            port.broadcastCountLastSecond = 0
            port.lastRateLimitReset = now
        }

        port.packetsLastSecond += 1
        if isBroadcast {
            port.broadcastCountLastSecond += 1
        }

        // Limits: 10,000 packets/sec total, 1,000 broadcast/sec
        if port.packetsLastSecond > 10000 {
            let msg = "Rate limit exceeded for \(port.vmName) — \(port.packetsLastSecond) packets/sec (potential DoS)"
            log("SECURITY WARNING: \(msg)", type: .error)
            VMSecurityMonitor.shared.logSecurityEvent(
                .warning,
                type: .resourceExhaustion,
                vmName: port.vmName,
                message: msg,
                details: ["packetsPerSec": port.packetsLastSecond]
            )
            return false
        }

        if port.broadcastCountLastSecond > 1000 {
            let msg = "Broadcast flood from \(port.vmName) — \(port.broadcastCountLastSecond) broadcasts/sec"
            log("SECURITY WARNING: \(msg)", type: .error)
            VMSecurityMonitor.shared.logSecurityEvent(
                .warning,
                type: .networkAnomaly,
                vmName: port.vmName,
                message: msg,
                details: ["broadcastsPerSec": port.broadcastCountLastSecond]
            )
            return false
        }

        return true
    }
}

// MARK: - Network Mode Configuration
// Note: NetworkMode and VirtualNetworkConfig are now defined in VMConfiguration.swift
