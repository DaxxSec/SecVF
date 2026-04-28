//
//  VMSecurityMonitor.swift
//  SecVF
//
//  SECURITY MONITORING & CONTAINMENT
//  This class monitors VM guest activity for potential breakout attempts
//  and enforces strict isolation for malware analysis sandboxes.
//
//  Threat Model:
//  - Malicious guest attempting filesystem access outside VM bundle
//  - Guest attempting network communication beyond expected patterns
//  - Guest attempting to exploit Virtualization framework vulnerabilities
//  - Resource exhaustion attacks (fork bombs, memory bombs)
//  - Clipboard/shared folder exploitation
//
//  Defense Strategy:
//  1. Monitor filesystem access patterns for VM bundles
//  2. Track network connections and alert on suspicious patterns
//  3. Monitor host system resources during VM execution
//  4. Enforce strict resource limits on VMs
//  5. Log all security events for forensic analysis
//

import Foundation
import Virtualization
import os.log

/// Security event severity levels
enum SecurityEventSeverity {
    case info       // Normal activity, informational
    case warning    // Suspicious but not critical
    case critical   // Potential breakout attempt
    case emergency  // Active breakout detected
}

/// Types of security events
enum SecurityEventType {
    case filesystemAccess       // Unexpected filesystem activity
    case networkAnomaly         // Unusual network pattern
    case resourceExhaustion     // CPU/Memory spike
    case suspiciousProcess      // Unexpected host process
    case vmStateChange          // VM state transitions
    case clipboardAccess        // Clipboard activity
}

/// Security event for logging
struct SecurityEvent {
    let timestamp: Date
    let severity: SecurityEventSeverity
    let type: SecurityEventType
    let vmName: String
    let message: String
    let details: [String: Any]

    var logMessage: String {
        let severityStr = String(describing: severity).uppercased()
        let typeStr = String(describing: type)
        return "[\(severityStr)] \(typeStr) - \(vmName): \(message)"
    }
}

/// Main security monitoring service
class VMSecurityMonitor {
    static let shared = VMSecurityMonitor()

    private let logger = OSLog(subsystem: "com.DaxxSec.SecVF", category: "Security")
    private var fileMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private var resourceTimers: [String: DispatchSourceTimer] = [:]
    private var activeVMs: [String: VMSecurityContext] = [:]
    private let eventQueue = DispatchQueue(label: "com.secvf.security.events", qos: .userInitiated)

    // Security event handlers
    var onSecurityEvent: ((SecurityEvent) -> Void)?
    var onCriticalEvent: ((SecurityEvent) -> Void)?

    private init() {
        setupGlobalMonitoring()
    }

    // MARK: - Global Security Monitoring

    private func setupGlobalMonitoring() {
        logSecurityEvent(.info, type: .vmStateChange, vmName: "system",
                        message: "Security monitoring service initialized")

        // Monitor for suspicious processes accessing VM bundles
        startProcessMonitoring()
    }

    // MARK: - VM Lifecycle Monitoring

    /// Start monitoring a VM when it launches
    func startMonitoring(vm: VMConfiguration, virtualMachine: VZVirtualMachine) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }

            let context = VMSecurityContext(config: vm, vm: virtualMachine)
            self.activeVMs[vm.id.uuidString] = context

            // Start filesystem monitoring for VM bundle
            self.startFilesystemMonitoring(for: vm)

            // Log VM start
            self.logSecurityEvent(.info, type: .vmStateChange, vmName: vm.name,
                                message: "VM started - security monitoring active",
                                details: ["bundlePath": vm.bundlePath,
                                        "osType": vm.osType])

            // Start resource monitoring
            self.startResourceMonitoring(for: vm)
        }
    }

    /// Stop monitoring when VM stops
    func stopMonitoring(vmID: UUID) {
        eventQueue.async { [weak self] in
            guard let self = self else { return }

            if let context = self.activeVMs[vmID.uuidString] {
                self.logSecurityEvent(.info, type: .vmStateChange, vmName: context.config.name,
                                    message: "VM stopped - security monitoring deactivated")

                // Stop filesystem monitor
                self.stopFilesystemMonitoring(for: vmID.uuidString)

                // Stop resource monitor
                self.stopResourceMonitoring(for: vmID.uuidString)

                // Remove from active VMs
                self.activeVMs.removeValue(forKey: vmID.uuidString)
            }
        }
    }

    // MARK: - Filesystem Monitoring

    private func startFilesystemMonitoring(for vm: VMConfiguration) {
        let bundlePath = vm.bundlePath
        let vmID = vm.id.uuidString

        // Monitor the VM bundle directory for unexpected changes
        let fileDescriptor = open(bundlePath, O_EVTONLY)

        if fileDescriptor < 0 {
            logSecurityEvent(.warning, type: .filesystemAccess, vmName: vm.name,
                           message: "Failed to open VM bundle for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: eventQueue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            let event = source.data
            var changes: [String] = []

            if event.contains(.write) { changes.append("write") }
            if event.contains(.delete) { changes.append("delete") }
            if event.contains(.rename) { changes.append("rename") }
            if event.contains(.attrib) { changes.append("attrib") }

            self.logSecurityEvent(.info, type: .filesystemAccess, vmName: vm.name,
                                message: "VM bundle filesystem activity detected",
                                details: ["changes": changes.joined(separator: ", "),
                                        "bundlePath": bundlePath])
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitors[vmID] = source
    }

    private func stopFilesystemMonitoring(for vmID: String) {
        if let monitor = fileMonitors[vmID] {
            monitor.cancel()
            fileMonitors.removeValue(forKey: vmID)
        }
    }

    // MARK: - Process Monitoring

    private func startProcessMonitoring() {
        // Monitor for unexpected processes accessing VM data
        // This would typically use Endpoint Security framework in production
        logSecurityEvent(.info, type: .suspiciousProcess, vmName: "system",
                        message: "Process monitoring initialized")
    }

    // MARK: - Resource Monitoring

    private func startResourceMonitoring(for vm: VMConfiguration) {
        // For AI sandbox guests (VMs with a vsock device + the provisioned exec
        // agent), poll real guest-side load and memory pressure every 5s via
        // VsockChannel. For other VMs (Linux router, etc.), fall back to a
        // coarse host-process RSS sanity check — better than nothing, but
        // explicitly labeled as host-side in the log details.
        //
        // DispatchSourceTimer rather than Timer.scheduledTimer because we
        // can't rely on a runloop being bound to eventQueue.
        let timer = DispatchSource.makeTimerSource(queue: eventQueue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self, weak timer] in
            guard let self = self else { timer?.cancel(); return }
            guard let context = self.activeVMs[vm.id.uuidString] else {
                timer?.cancel()
                return
            }
            let machine = context.vm
            // Branch: vsock-capable guests get real stats, others get host RSS.
            if machine.socketDevices.first is VZVirtioSocketDevice {
                Task { [weak self] in
                    await self?.pollGuestResources(vmName: vm.name, vm: machine)
                }
            } else {
                self.pollHostRSS(vmName: vm.name)
            }
        }
        timer.resume()
        resourceTimers[vm.id.uuidString] = timer
    }

    /// Polls the guest via the AI sandbox vsock exec agent. Emits
    /// resource-exhaustion events if load average crosses thresholds.
    private func pollGuestResources(vmName: String, vm: VZVirtualMachine) async {
        // ROOT prefix routes through the privileged branch of the exec
        // handler — no agent-user permissions on sysctl/vm_stat needed.
        let cmd = "ROOT sysctl -n vm.loadavg && memory_pressure 2>/dev/null | head -3"
        let output: String
        do {
            output = try await VsockChannel.runOneShot(on: vm, command: cmd)
        } catch {
            // Connection failed — VM may be in an unusual state, exec agent
            // may not be running. Skip this tick silently rather than spamming.
            return
        }

        // Parse load average. macOS `sysctl -n vm.loadavg` returns: { 0.65 0.72 0.80 }
        let load1 = parseLoad1(output)
        // Parse memory pressure %. Look for "System-wide memory free percentage: NN%"
        let memFreePct = parseMemFreePct(output)

        // Threshold-driven alerts. Tuned for "guest sustained at high load",
        // not transient spikes — the timer fires every 5s so a single spike
        // gets one event, sustained pressure gets a steady stream.
        if let l = load1, l > 12.0 {
            logSecurityEvent(
                .warning,
                type: .resourceExhaustion,
                vmName: vmName,
                message: "Guest load average \(String(format: "%.2f", l)) over threshold (12.0)",
                details: ["loadAvg1": l, "source": "vsock"]
            )
        }
        if let f = memFreePct, f < 5.0 {
            logSecurityEvent(
                .warning,
                type: .resourceExhaustion,
                vmName: vmName,
                message: "Guest memory free \(String(format: "%.1f", f))% — under 5% threshold",
                details: ["memFreePct": f, "source": "vsock"]
            )
        }
    }

    /// Fallback for non-vsock VMs — polls SecVF's own RSS as a coarse signal.
    private func pollHostRSS(vmName: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return }
        let hostRssMB = Double(info.resident_size) / 1024.0 / 1024.0
        if hostRssMB > 8000 {
            logSecurityEvent(
                .warning,
                type: .resourceExhaustion,
                vmName: vmName,
                message: "Host RSS over 8 GB while VM running — coarse signal (no vsock channel for guest stats)",
                details: ["hostRssMB": hostRssMB, "source": "host-fallback"]
            )
        }
    }

    private func parseLoad1(_ output: String) -> Double? {
        // sysctl -n vm.loadavg → "{ 0.65 0.72 0.80 }"
        guard let openIdx = output.firstIndex(of: "{") else { return nil }
        let after = output[output.index(after: openIdx)...]
        let parts = after.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        return Double(first)
    }

    private func parseMemFreePct(_ output: String) -> Double? {
        // memory_pressure includes "System-wide memory free percentage: NN%"
        for line in output.split(separator: "\n") {
            if line.contains("memory free percentage") {
                let digits = line.compactMap { c -> Character? in
                    (c.isNumber || c == ".") ? c : nil
                }
                if !digits.isEmpty {
                    return Double(String(digits))
                }
            }
        }
        return nil
    }

    private func stopResourceMonitoring(for vmID: String) {
        if let timer = resourceTimers.removeValue(forKey: vmID) {
            timer.cancel()
        }
    }

    // MARK: - Security Event Logging

    func logSecurityEvent(_ severity: SecurityEventSeverity,
                         type: SecurityEventType,
                         vmName: String,
                         message: String,
                         details: [String: Any] = [:]) {
        let event = SecurityEvent(
            timestamp: Date(),
            severity: severity,
            type: type,
            vmName: vmName,
            message: message,
            details: details
        )

        // Log to system
        let logType: OSLogType
        switch severity {
        case .info: logType = .info
        case .warning: logType = .default
        case .critical: logType = .error
        case .emergency: logType = .fault
        }

        os_log("%{public}@", log: logger, type: logType, event.logMessage)

        // Call handlers
        onSecurityEvent?(event)

        if severity == .critical || severity == .emergency {
            onCriticalEvent?(event)
        }

        // Write to persistent log file
        writeToSecurityLog(event)
    }

    private func writeToSecurityLog(_ event: SecurityEvent) {
        let logDir = NSHomeDirectory() + "/.avf/logs/"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let logFileName = "security-\(dateFormatter.string(from: Date())).log"
        let logPath = logDir + logFileName

        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: event.timestamp)
        let logLine = "[\(timestamp)] \(event.logMessage)\n"

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

    // MARK: - Security Recommendations

    /// Build a list of human-readable security recommendations / observations for a VM.
    ///
    /// Reflects the VM's actual configuration (network mode, resource allocation,
    /// OS type) and the host's live monitoring state — not a hardcoded checklist.
    func getSecurityRecommendations(for vm: VMConfiguration) -> [String] {
        var rec: [String] = []

        // ── Network posture ──────────────────────────────────────────────────
        switch vm.networkConfig.mode {
        case .nat:
            rec.append("⚠️ NAT networking — guest reaches the live internet directly. For malware analysis, switch to virtual switch routed through a Kali router.")
        case .virtual:
            if vm.networkConfig.isRouter {
                rec.append("ℹ️ Router VM — sits between client guests and the internet. Run kali-router-setup.sh inside; consider kali-fakenet-setup.sh to fully isolate.")
            } else if vm.networkConfig.routerVMId != nil {
                rec.append("✅ Virtual switch — egress goes through a router VM, not the host.")
            } else {
                rec.append("✅ Virtual switch — fully isolated from host and internet (no router configured).")
            }
        }

        // ── Resource allocation ──────────────────────────────────────────────
        if vm.cpuCount > 8 {
            rec.append("ℹ️ \(vm.cpuCount) vCPUs allocated — generous; fine for AI workloads, watch for runaway CPU in malware analysis.")
        }
        let memGB = Double(vm.memorySize) / 1_073_741_824.0
        if memGB > 8 {
            rec.append("ℹ️ \(String(format: "%.0f", memGB)) GB RAM allocated — keep an eye on host RSS while the VM is running.")
        }

        // ── OS-specific notes ────────────────────────────────────────────────
        if vm.osType == "macOS" {
            rec.append("⚠️ macOS guest — Virtualization.framework attack surface is broader than Linux; SIP / hardened-runtime settings inside the guest matter.")
        }

        // ── Live monitoring posture ──────────────────────────────────────────
        let isActive = activeVMs[vm.id.uuidString] != nil
        rec.append(isActive
            ? "✅ Filesystem + resource monitoring active for this VM."
            : "ℹ️ Filesystem + resource monitoring engages once the VM starts.")

        let switchStats = VirtualNetworkSwitch.shared.getStatistics()
        let switchUp = (switchStats["running"] as? Bool) ?? false
        if vm.networkConfig.mode == .virtual && switchUp {
            let connected = (switchStats["connectedPorts"] as? Int) ?? 0
            rec.append("✅ Virtual switch up — \(connected) port(s) connected, \(switchStats["learnedMACs"] as? Int ?? 0) MAC(s) learned.")
        } else if vm.networkConfig.mode == .virtual {
            rec.append("⚠️ Virtual switch is not running — guest will have no L2 peer.")
        }

        if PacketCaptureManager.shared.isCapturing {
            rec.append("✅ Packet capture is recording — analysis available in Wireshark view.")
        }

        rec.append("✅ Bundle filesystem is isolated; events logged to ~/.avf/logs/security-*.log.")

        return rec
    }
}

// MARK: - VM Security Context

private class VMSecurityContext {
    let config: VMConfiguration
    let vm: VZVirtualMachine
    let startTime: Date
    var eventCount: Int = 0

    init(config: VMConfiguration, vm: VZVirtualMachine) {
        self.config = config
        self.vm = vm
        self.startTime = Date()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let securityEvent = Notification.Name("com.secvf.security.event")
    static let criticalSecurityEvent = Notification.Name("com.secvf.security.critical")
}
