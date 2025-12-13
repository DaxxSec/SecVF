import Foundation

/// Bridge to Virtual Network Switch state
class SwitchManagerBridge {
    private let switchStatePath: String
    private let switchStatsPath: String

    init() {
        let avfRoot = NSHomeDirectory() + "/.avf"
        switchStatePath = avfRoot + "/switch/state.json"
        switchStatsPath = avfRoot + "/switch/stats.json"
    }

    // MARK: - Get Switch Status

    func getStatus() -> [String: Any] {
        // Try to read switch state from shared file
        if let data = FileManager.default.contents(atPath: switchStatePath),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return state
        }

        // Check if SecVF app is running with switch active
        let isRunning = isSecVFRunning()

        return [
            "running": isRunning,
            "connectedPorts": 0,
            "maxPorts": 8,
            "learnedMACs": 0,
            "uptime": 0
        ]
    }

    // MARK: - Get Statistics

    func getStatistics() -> [String: Any] {
        // Try to read stats from shared file
        if let data = FileManager.default.contents(atPath: switchStatsPath),
           let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return stats
        }

        return [
            "packetsForwarded": 0,
            "packetsBroadcast": 0,
            "packetsDropped": 0,
            "bytesTransferred": Int64(0),
            "rxBytes": Int64(0),
            "txBytes": Int64(0),
            "securityAlerts": []
        ]
    }

    // MARK: - Get Connected Ports

    func getPorts() -> [[String: Any]] {
        let portsPath = NSHomeDirectory() + "/.avf/switch/ports.json"

        if let data = FileManager.default.contents(atPath: portsPath),
           let ports = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return ports
        }

        // If no file, try to infer from running VMs with virtual network mode
        return getPortsFromRunningVMs()
    }

    private func getPortsFromRunningVMs() -> [[String: Any]] {
        var ports: [[String: Any]] = []
        var portNum = 0

        let avfRoot = NSHomeDirectory() + "/.avf"
        let linuxPath = avfRoot + "/Linux"

        guard let vms = try? FileManager.default.contentsOfDirectory(atPath: linuxPath) else {
            return ports
        }

        for vmDir in vms where vmDir.hasSuffix(".bundle") {
            let metadataPath = linuxPath + "/" + vmDir + "/metadata.json"
            if let data = FileManager.default.contents(atPath: metadataPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let networkMode = json["networkMode"] as? String,
               networkMode == "virtual" {

                let vmName = json["name"] as? String ?? vmDir.replacingOccurrences(of: ".bundle", with: "")

                // Check if VM is running
                if isVMRunning(name: vmName) {
                    portNum += 1
                    ports.append([
                        "port": portNum,
                        "vmName": vmName,
                        "macAddress": json["macAddress"] as? String ?? generateMACFromName(vmName),
                        "rxBytes": Int64(0),
                        "txBytes": Int64(0)
                    ])
                }
            }
        }

        return ports
    }

    private func generateMACFromName(_ name: String) -> String {
        // Generate a deterministic MAC from VM name
        let hash = abs(name.hashValue)
        return String(format: "52:54:00:%02X:%02X:%02X",
                     (hash >> 16) & 0xFF,
                     (hash >> 8) & 0xFF,
                     hash & 0xFF)
    }

    // MARK: - Get MAC Address Table

    func getMACTable() -> [[String: Any]] {
        let macTablePath = NSHomeDirectory() + "/.avf/switch/mac_table.json"

        if let data = FileManager.default.contents(atPath: macTablePath),
           let table = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return table
        }

        // Build table from running VMs
        return buildMACTableFromVMs()
    }

    private func buildMACTableFromVMs() -> [[String: Any]] {
        var entries: [[String: Any]] = []

        let ports = getPorts()
        for port in ports {
            if let mac = port["macAddress"] as? String,
               let portNum = port["port"] as? Int,
               let vmName = port["vmName"] as? String {
                entries.append([
                    "macAddress": mac,
                    "port": portNum,
                    "vmName": vmName,
                    "age": "0s"
                ])
            }
        }

        return entries
    }

    // MARK: - Helpers

    private func isSecVFRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "SecVF"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isVMRunning(name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "SecVF.*\(name)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
