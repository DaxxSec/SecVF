import ArgumentParser
import Foundation

struct CaptureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Packet capture commands",
        subcommands: [
            CaptureStart.self,
            CaptureStop.self,
            CaptureStatus.self,
            CaptureExport.self,
            CaptureLive.self,
        ]
    )
}

// MARK: - Capture Start

struct CaptureStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start packet capture"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Interface to capture on")
    var interface: String = "any"

    @Option(name: .shortAndLong, help: "Capture filter (BPF syntax)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Output file (pcap format)")
    var output: String?

    @Option(name: .long, help: "Maximum packets to capture (0 = unlimited)")
    var count: Int = 0

    mutating func run() throws {
        let captureManager = CaptureManagerBridge()
        let result = captureManager.startCapture(
            interface: interface,
            filter: filter,
            outputFile: output,
            maxPackets: count
        )

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Capture started", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Packet capture started")
                print("  Interface: \(interface)")
                if let f = filter {
                    print("  Filter: \(f)")
                }
                if let o = output {
                    print("  Output: \(o)")
                }
            }
        }
    }
}

// MARK: - Capture Stop

struct CaptureStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop packet capture"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() throws {
        let captureManager = CaptureManagerBridge()
        let result = captureManager.stopCapture()

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Capture stopped", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                let packets = result["packetsCaptured"] as? Int ?? 0
                let bytes = result["bytesCaptured"] as? Int64 ?? 0
                print("✓ Packet capture stopped")
                print("  Packets captured: \(packets)")
                print("  Bytes captured: \(formatBytes(bytes))")
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        if mb >= 1 { return String(format: "%.2f MB", mb) }
        if kb >= 1 { return String(format: "%.2f KB", kb) }
        return "\(bytes) B"
    }
}

// MARK: - Capture Status

struct CaptureStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show capture status"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() throws {
        let captureManager = CaptureManagerBridge()
        let status = captureManager.getStatus()

        if options.json {
            JSONOutput(success: true, data: status).print()
        } else {
            let capturing = (status["capturing"] as? Bool) ?? false
            print("CAPTURE STATUS")
            print(String(repeating: "-", count: 40))
            print("Status: \(capturing ? "● CAPTURING" : "○ STOPPED")")

            if capturing {
                print("Interface: \(status["interface"] ?? "unknown")")
                if let filter = status["filter"] as? String {
                    print("Filter: \(filter)")
                }
                print("Packets: \(status["packetsCaptured"] ?? 0)")
                if let duration = status["duration"] as? TimeInterval {
                    print("Duration: \(formatDuration(duration))")
                }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Capture Export

struct CaptureExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export captured packets to file"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Output file path")
    var output: String

    @Option(name: .shortAndLong, help: "Export format: pcap, json, csv")
    var format: String = "pcap"

    @Option(name: .shortAndLong, help: "Filter packets to export")
    var filter: String?

    @Option(name: .long, help: "Maximum packets to export")
    var limit: Int?

    mutating func run() throws {
        let captureManager = CaptureManagerBridge()
        let result = captureManager.exportPackets(
            output: output,
            format: format,
            filter: filter,
            limit: limit
        )

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Packets exported", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                let count = result["packetsExported"] as? Int ?? 0
                print("✓ Exported \(count) packets to \(output)")
            }
        }
    }
}

// MARK: - Capture Live

struct CaptureLive: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Show live packet stream"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Display filter")
    var filter: String?

    @Option(name: .shortAndLong, help: "Number of packets to show (0 = unlimited)")
    var count: Int = 0

    @Flag(name: .long, help: "Show packet details")
    var details = false

    func run() throws {
        if options.json {
            print("Live capture not supported in JSON mode.")
            return
        }

        let captureManager = CaptureManagerBridge()

        print("LIVE PACKET CAPTURE (Press Ctrl+C to stop)")
        print(String(repeating: "-", count: 80))
        print("#      TIME       SOURCE            DEST              PROTO  LEN   INFO")
        print(String(repeating: "-", count: 80))

        // Capture values before closure to avoid escaping self
        let maxCount = count
        let showDetails = details

        class PacketCounter {
            var value = 0
        }
        let counter = PacketCounter()

        captureManager.streamPackets(filter: filter) { packet in
            counter.value += 1

            if maxCount > 0 && counter.value > maxCount {
                return false  // Stop streaming
            }

            let num = String(counter.value).padding(toLength: 6, withPad: " ", startingAt: 0)
            let time = (packet["time"] as? String ?? "").padding(toLength: 10, withPad: " ", startingAt: 0)
            let src = (packet["source"] as? String ?? "").padding(toLength: 17, withPad: " ", startingAt: 0)
            let dst = (packet["destination"] as? String ?? "").padding(toLength: 17, withPad: " ", startingAt: 0)
            let proto = (packet["protocol"] as? String ?? "").padding(toLength: 6, withPad: " ", startingAt: 0)
            let len = String(packet["length"] as? Int ?? 0).padding(toLength: 5, withPad: " ", startingAt: 0)
            let info = packet["info"] as? String ?? ""

            print("\(num) \(time) \(src) \(dst) \(proto) \(len) \(info)")

            if showDetails, let detailInfo = packet["details"] as? [String: Any] {
                for (key, value) in detailInfo {
                    print("       \(key): \(value)")
                }
            }

            return true  // Continue streaming
        }
    }
}
