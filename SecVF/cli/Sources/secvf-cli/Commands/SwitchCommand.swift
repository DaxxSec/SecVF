import ArgumentParser
import Foundation

struct SwitchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Virtual network switch commands",
        subcommands: [
            SwitchStatus.self,
            SwitchStats.self,
            SwitchPorts.self,
            SwitchMACs.self,
        ]
    )
}

// MARK: - Switch Status

struct SwitchStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show switch status"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() throws {
        let switchManager = SwitchManagerBridge()
        let status = switchManager.getStatus()

        if options.json {
            JSONOutput(success: true, data: status).print()
        } else {
            let running = (status["running"] as? Bool) ?? false
            let ports = status["connectedPorts"] as? Int ?? 0
            let maxPorts = status["maxPorts"] as? Int ?? 8
            let macs = status["learnedMACs"] as? Int ?? 0

            print("VIRTUAL NETWORK SWITCH")
            print(String(repeating: "-", count: 50))
            print("Status:        \(running ? "● RUNNING" : "○ STOPPED")")
            print("Ports:         \(ports)/\(maxPorts) connected")
            print("MACs Learned:  \(macs)")

            if let uptime = status["uptime"] as? TimeInterval {
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let seconds = Int(uptime) % 60
                print("Uptime:        \(hours)h \(minutes)m \(seconds)s")
            }
        }
    }
}

// MARK: - Switch Stats

struct SwitchStats: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show switch statistics"
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .shortAndLong, help: "Watch mode - continuously update")
    var watch = false

    @Option(name: .long, help: "Update interval in seconds (with --watch)")
    var interval: Double = 1.0

    mutating func run() throws {
        let switchManager = SwitchManagerBridge()

        repeat {
            let stats = switchManager.getStatistics()

            if options.json {
                JSONOutput(success: true, data: stats).print()
                if watch {
                    Thread.sleep(forTimeInterval: interval)
                }
            } else {
                if watch {
                    // Clear screen for watch mode
                    print("\u{001B}[2J\u{001B}[H", terminator: "")
                }

                print("SWITCH STATISTICS")
                print(String(repeating: "-", count: 50))

                let forwarded = stats["packetsForwarded"] as? Int ?? 0
                let broadcast = stats["packetsBroadcast"] as? Int ?? 0
                let dropped = stats["packetsDropped"] as? Int ?? 0
                let bytes = stats["bytesTransferred"] as? Int64 ?? 0

                print("Packets Forwarded: \(formatNumber(forwarded))")
                print("Packets Broadcast: \(formatNumber(broadcast))")
                print("Packets Dropped:   \(formatNumber(dropped))")
                print("Bytes Transferred: \(formatBytes(bytes))")

                if let rxBytes = stats["rxBytes"] as? Int64,
                   let txBytes = stats["txBytes"] as? Int64 {
                    print("")
                    print("RX: \(formatBytes(rxBytes))  TX: \(formatBytes(txBytes))")
                }

                if let alerts = stats["securityAlerts"] as? [[String: Any]], !alerts.isEmpty {
                    print("")
                    print("SECURITY ALERTS:")
                    for alert in alerts.prefix(5) {
                        let msg = alert["message"] as? String ?? ""
                        let time = alert["time"] as? String ?? ""
                        print("  [!] \(msg) (\(time))")
                    }
                }

                if watch {
                    print("")
                    print("Press Ctrl+C to stop...")
                    Thread.sleep(forTimeInterval: interval)
                }
            }
        } while watch
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 { return String(format: "%.2f GB", gb) }
        if mb >= 1 { return String(format: "%.2f MB", mb) }
        if kb >= 1 { return String(format: "%.2f KB", kb) }
        return "\(bytes) B"
    }
}

// MARK: - Switch Ports

struct SwitchPorts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ports",
        abstract: "Show connected ports and traffic"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() throws {
        let switchManager = SwitchManagerBridge()
        let ports = switchManager.getPorts()

        if options.json {
            JSONOutput(success: true, data: ports).print()
        } else {
            if ports.isEmpty {
                print("No ports connected to switch.")
                return
            }

            print("PORT  VM NAME            MAC ADDRESS         RX          TX")
            print(String(repeating: "-", count: 65))

            for port in ports {
                let portNum = String(port["port"] as? Int ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0)
                let vmName = (port["vmName"] as? String ?? "Unknown").padding(toLength: 18, withPad: " ", startingAt: 0)
                let mac = (port["macAddress"] as? String ?? "Unknown").padding(toLength: 19, withPad: " ", startingAt: 0)
                let rx = formatBytes(port["rxBytes"] as? Int64 ?? 0).padding(toLength: 11, withPad: " ", startingAt: 0)
                let tx = formatBytes(port["txBytes"] as? Int64 ?? 0)

                print("\(portNum) \(vmName) \(mac) \(rx) \(tx)")
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024

        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.1f KB", kb) }
        return "\(bytes) B"
    }
}

// MARK: - Switch MACs

struct SwitchMACs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macs",
        abstract: "Show MAC address learning table"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() throws {
        let switchManager = SwitchManagerBridge()
        let macs = switchManager.getMACTable()

        if options.json {
            JSONOutput(success: true, data: macs).print()
        } else {
            if macs.isEmpty {
                print("MAC address table is empty.")
                return
            }

            print("MAC ADDRESS         PORT  VM NAME            AGE")
            print(String(repeating: "-", count: 55))

            for entry in macs {
                let mac = (entry["macAddress"] as? String ?? "").padding(toLength: 19, withPad: " ", startingAt: 0)
                let port = String(entry["port"] as? Int ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0)
                let vmName = (entry["vmName"] as? String ?? "").padding(toLength: 18, withPad: " ", startingAt: 0)
                let age = entry["age"] as? String ?? ""

                print("\(mac) \(port) \(vmName) \(age)")
            }
        }
    }
}
