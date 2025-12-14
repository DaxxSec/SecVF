//
//  PacketCaptureManager.swift
//  SecVF
//
//  Manages tshark-based packet capture and analysis for the VirtualNetworkSwitch
//

import Foundation
import os
import Combine

// MARK: - Data Structures

struct CapturedPacket {
    let number: Int
    let timestamp: Date
    let relativeTime: Double
    let sourceMAC: String
    let destMAC: String
    let sourceIP: String?
    let destIP: String?
    let `protocol`: String
    let length: Int
    let info: String
    let rawData: Data
    let decodedLayers: [PacketLayer]
    let sourceVM: String  // VM name that originated this packet
}

struct PacketLayer {
    let name: String
    let fields: [(key: String, value: String)]
    let children: [PacketLayer]
}

struct ProtocolCount {
    let `protocol`: String
    var count: Int
    var bytes: Int
}

// MARK: - Notification Names

extension Notification.Name {
    static let packetCaptured = Notification.Name("packetCaptured")
    static let captureStarted = Notification.Name("captureStarted")
    static let captureStopped = Notification.Name("captureStopped")
    static let protocolStatsUpdated = Notification.Name("protocolStatsUpdated")
}

// MARK: - PacketCaptureManager

class PacketCaptureManager {
    static let shared = PacketCaptureManager()

    private let logger = OSLog(subsystem: "com.secvf", category: "PacketCapture")
    private let captureQueue = DispatchQueue(label: "com.secvf.packetcapture", qos: .userInitiated)
    private let parseQueue = DispatchQueue(label: "com.secvf.packetparse", qos: .utility)

    // MARK: - Combine Publishers (reactive updates)

    /// Publisher that emits each captured packet as it arrives
    private let packetSubject = PassthroughSubject<CapturedPacket, Never>()
    var packetsPublisher: AnyPublisher<CapturedPacket, Never> {
        packetSubject.eraseToAnyPublisher()
    }

    /// Publisher that emits protocol statistics updates
    private let statsSubject = PassthroughSubject<[ProtocolCount], Never>()
    var protocolStatsPublisher: AnyPublisher<[ProtocolCount], Never> {
        statsSubject.eraseToAnyPublisher()
    }

    /// Publisher that emits capture state changes (true = capturing, false = stopped)
    private let captureStateSubject = CurrentValueSubject<Bool, Never>(false)
    var captureStatePublisher: AnyPublisher<Bool, Never> {
        captureStateSubject.eraseToAnyPublisher()
    }

    // Capture state
    private(set) var isCapturing = false {
        didSet {
            captureStateSubject.send(isCapturing)
        }
    }
    private var tsharkProcess: Process?
    private var fifoPath: String?
    private var fifoWriteHandle: FileHandle?
    private var tsharkOutputPipe: Pipe?

    // Packet buffer (circular)
    private var capturedPackets: [CapturedPacket] = []
    private let maxPackets = 10000
    private var packetNumber: Int = 0
    private var captureStartTime: Date?

    // Protocol statistics
    private var protocolCounts: [String: ProtocolCount] = [:]

    // PCAP file writing
    private var pcapFileHandle: FileHandle?
    private var pcapFilePath: String?

    // tshark path detection
    private var tsharkPath: String? {
        let paths = [
            "/opt/homebrew/bin/tshark",      // Apple Silicon Homebrew
            "/usr/local/bin/tshark",          // Intel Homebrew
            "/usr/bin/tshark",                // System install
            "/Applications/Wireshark.app/Contents/MacOS/tshark"  // Wireshark.app
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    var isTsharkAvailable: Bool {
        return tsharkPath != nil
    }

    private init() {
        log("PacketCaptureManager initialized")
    }

    // MARK: - Capture Control

    func startCapture() -> Bool {
        guard !isCapturing else {
            log("Capture already running", type: .info)
            return true
        }

        guard let tshark = tsharkPath else {
            log("tshark not found - install with 'brew install wireshark'", type: .error)
            return false
        }

        log("Starting packet capture with tshark at: \(tshark)")

        // Create FIFO for raw packet input
        let fifoDir = NSTemporaryDirectory()
        fifoPath = fifoDir + "secvf_capture_\(ProcessInfo.processInfo.processIdentifier).fifo"

        guard let fifo = fifoPath else { return false }

        // Remove existing FIFO if present
        try? FileManager.default.removeItem(atPath: fifo)

        // Create named pipe
        let result = mkfifo(fifo, 0o600)
        if result != 0 {
            log("Failed to create FIFO: \(String(cString: strerror(errno)))", type: .error)
            return false
        }

        log("Created FIFO at: \(fifo)")

        // Start tshark process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tshark)

        // tshark arguments:
        // -i - : read from stdin (we'll pipe FIFO content)
        // -T json : output as JSON
        // -l : flush output after each packet
        // -x : include hex dump
        process.arguments = [
            "-r", fifo,           // Read from our FIFO
            "-T", "json",         // JSON output
            "-l",                 // Line-buffered output
            "--no-duplicate-keys" // Prevent duplicate JSON keys
        ]

        // Setup output pipe
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        tsharkOutputPipe = outputPipe

        // Handle tshark JSON output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parseTsharkOutput(data)
        }

        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            self?.log("tshark process terminated with status: \(proc.terminationStatus)")
            DispatchQueue.main.async {
                self?.handleCaptureStop()
            }
        }

        do {
            try process.run()
            tsharkProcess = process
            log("tshark process started (PID: \(process.processIdentifier))")
        } catch {
            log("Failed to start tshark: \(error.localizedDescription)", type: .error)
            cleanup()
            return false
        }

        // Open FIFO for writing (must be after tshark opens it for reading)
        captureQueue.async { [weak self] in
            guard let self = self, let fifo = self.fifoPath else { return }

            // Open FIFO - this will block until tshark opens the read end
            if let handle = FileHandle(forWritingAtPath: fifo) {
                self.fifoWriteHandle = handle
                self.log("FIFO write handle opened")

                // Write pcap global header
                self.writePcapHeader()
            } else {
                self.log("Failed to open FIFO for writing", type: .error)
            }
        }

        isCapturing = true
        captureStartTime = Date()
        packetNumber = 0
        capturedPackets.removeAll()
        protocolCounts.removeAll()

        NotificationCenter.default.post(name: .captureStarted, object: nil)
        log("Packet capture started")

        return true
    }

    func stopCapture() {
        guard isCapturing else { return }

        log("Stopping packet capture")

        // Close write handle first
        fifoWriteHandle?.closeFile()
        fifoWriteHandle = nil

        // Terminate tshark
        if let process = tsharkProcess, process.isRunning {
            process.terminate()
        }

        handleCaptureStop()
    }

    private func handleCaptureStop() {
        isCapturing = false

        // Clear output handler
        tsharkOutputPipe?.fileHandleForReading.readabilityHandler = nil
        tsharkOutputPipe = nil
        tsharkProcess = nil

        // Remove FIFO
        if let fifo = fifoPath {
            try? FileManager.default.removeItem(atPath: fifo)
            fifoPath = nil
        }

        NotificationCenter.default.post(name: .captureStopped, object: nil)
        log("Packet capture stopped")
    }

    private func cleanup() {
        fifoWriteHandle?.closeFile()
        fifoWriteHandle = nil

        if let fifo = fifoPath {
            try? FileManager.default.removeItem(atPath: fifo)
        }
        fifoPath = nil

        tsharkProcess?.terminate()
        tsharkProcess = nil
        tsharkOutputPipe = nil
    }

    // MARK: - Packet Capture (called from VirtualNetworkSwitch)

    func capturePacket(_ data: Data, sourceVM: String, destVM: String) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }

            // Always store raw packet for mini log display
            self.storeRawPacket(data, sourceVM: sourceVM, destVM: destVM)

            // Only write to tshark FIFO if capture is running
            if self.isCapturing, self.fifoWriteHandle != nil {
                self.writePcapPacket(data)
            }
        }
    }

    private func writePcapHeader() {
        guard let handle = fifoWriteHandle else { return }

        // PCAP global header (24 bytes)
        var header = Data(capacity: 24)

        // Magic number (native byte order)
        var magic: UInt32 = 0xa1b2c3d4
        header.append(Data(bytes: &magic, count: 4))

        // Version (2.4)
        var versionMajor: UInt16 = 2
        var versionMinor: UInt16 = 4
        header.append(Data(bytes: &versionMajor, count: 2))
        header.append(Data(bytes: &versionMinor, count: 2))

        // Timezone offset (0)
        var tzOffset: Int32 = 0
        header.append(Data(bytes: &tzOffset, count: 4))

        // Timestamp accuracy (0)
        var sigfigs: UInt32 = 0
        header.append(Data(bytes: &sigfigs, count: 4))

        // Snap length (65535)
        var snaplen: UInt32 = 65535
        header.append(Data(bytes: &snaplen, count: 4))

        // Link-layer type (1 = Ethernet)
        var linktype: UInt32 = 1
        header.append(Data(bytes: &linktype, count: 4))

        try? handle.write(contentsOf: header)
    }

    private func writePcapPacket(_ data: Data) {
        guard let handle = fifoWriteHandle else { return }

        // PCAP packet header (16 bytes)
        var packetHeader = Data(capacity: 16)

        let now = Date()
        let timestamp = now.timeIntervalSince1970
        var tsSec: UInt32 = UInt32(timestamp)
        var tsUsec: UInt32 = UInt32((timestamp - Double(tsSec)) * 1_000_000)
        var inclLen: UInt32 = UInt32(data.count)
        var origLen: UInt32 = UInt32(data.count)

        packetHeader.append(Data(bytes: &tsSec, count: 4))
        packetHeader.append(Data(bytes: &tsUsec, count: 4))
        packetHeader.append(Data(bytes: &inclLen, count: 4))
        packetHeader.append(Data(bytes: &origLen, count: 4))

        try? handle.write(contentsOf: packetHeader)
        try? handle.write(contentsOf: data)
    }

    private func storeRawPacket(_ data: Data, sourceVM: String, destVM: String) {
        guard data.count >= 14 else { return }

        packetNumber += 1

        // Parse basic Ethernet header
        let destMAC = formatMAC(Array(data[0..<6]))
        let sourceMAC = formatMAC(Array(data[6..<12]))
        let etherType = UInt16(data[12]) << 8 | UInt16(data[13])

        var proto = "Unknown"
        var sourceIP: String? = nil
        var destIP: String? = nil
        var info = ""

        switch etherType {
        case 0x0800: // IPv4
            if data.count >= 34 {
                proto = parseIPv4Protocol(data)
                sourceIP = formatIPv4(Array(data[26..<30]))
                destIP = formatIPv4(Array(data[30..<34]))
                info = "\(sourceIP ?? "?") -> \(destIP ?? "?")"
            }
        case 0x0806: // ARP
            proto = "ARP"
            if data.count >= 28 {
                let opcode = UInt16(data[20]) << 8 | UInt16(data[21])
                info = opcode == 1 ? "Who has?" : "Reply"
            }
        case 0x86DD: // IPv6
            proto = "IPv6"
        default:
            proto = String(format: "0x%04X", etherType)
        }

        let relativeTime = captureStartTime.map { Date().timeIntervalSince($0) } ?? 0

        let packet = CapturedPacket(
            number: packetNumber,
            timestamp: Date(),
            relativeTime: relativeTime,
            sourceMAC: sourceMAC,
            destMAC: destMAC,
            sourceIP: sourceIP,
            destIP: destIP,
            protocol: proto,
            length: data.count,
            info: info,
            rawData: data,
            decodedLayers: [],
            sourceVM: sourceVM
        )

        addPacket(packet)
        updateProtocolStats(proto, bytes: data.count)
    }

    private func parseIPv4Protocol(_ data: Data) -> String {
        guard data.count >= 24 else { return "IPv4" }
        let protoNum = data[23]
        switch protoNum {
        case 1: return "ICMP"
        case 6: return "TCP"
        case 17: return "UDP"
        default: return "IPv4"
        }
    }

    private func formatMAC(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func formatIPv4(_ bytes: [UInt8]) -> String {
        return bytes.map { String($0) }.joined(separator: ".")
    }

    // MARK: - tshark Output Parsing

    private var jsonBuffer = Data()

    private func parseTsharkOutput(_ data: Data) {
        parseQueue.async { [weak self] in
            guard let self = self else { return }

            self.jsonBuffer.append(data)

            // Try to parse complete JSON objects from buffer
            while let packet = self.extractNextPacket() {
                DispatchQueue.main.async {
                    self.addPacket(packet)
                    self.updateProtocolStats(packet.protocol, bytes: packet.length)
                }
            }
        }
    }

    private func extractNextPacket() -> CapturedPacket? {
        // Look for complete JSON packet objects
        guard let string = String(data: jsonBuffer, encoding: .utf8) else { return nil }

        // tshark outputs array elements, look for complete objects
        if let range = string.range(of: "\\{[^{}]*\"_source\"[^{}]*\\}", options: .regularExpression) {
            let jsonString = String(string[range])

            // Remove processed data from buffer
            if let dataRange = jsonString.data(using: .utf8) {
                if let bufferRange = jsonBuffer.range(of: dataRange) {
                    jsonBuffer.removeSubrange(bufferRange)
                }
            }

            // Parse JSON
            if let jsonData = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                return parsePacketJSON(json)
            }
        }

        return nil
    }

    private func parsePacketJSON(_ json: [String: Any]) -> CapturedPacket? {
        guard let source = json["_source"] as? [String: Any],
              let layers = source["layers"] as? [String: Any] else {
            return nil
        }

        packetNumber += 1

        // Parse frame info
        var timestamp = Date()
        var length = 0

        if let frame = layers["frame"] as? [String: Any] {
            if let timeStr = frame["frame.time_epoch"] as? String,
               let timeVal = Double(timeStr) {
                timestamp = Date(timeIntervalSince1970: timeVal)
            }
            if let lenStr = frame["frame.len"] as? String {
                length = Int(lenStr) ?? 0
            }
        }

        // Parse Ethernet
        var sourceMAC = ""
        var destMAC = ""

        if let eth = layers["eth"] as? [String: Any] {
            sourceMAC = eth["eth.src"] as? String ?? ""
            destMAC = eth["eth.dst"] as? String ?? ""
        }

        // Parse IP
        var sourceIP: String? = nil
        var destIP: String? = nil
        var proto = "Ethernet"

        if let ip = layers["ip"] as? [String: Any] {
            sourceIP = ip["ip.src"] as? String
            destIP = ip["ip.dst"] as? String
            proto = "IPv4"
        }

        // Determine protocol
        if layers["tcp"] != nil {
            proto = "TCP"
        } else if layers["udp"] != nil {
            proto = "UDP"
        } else if layers["icmp"] != nil {
            proto = "ICMP"
        } else if layers["arp"] != nil {
            proto = "ARP"
        } else if layers["dns"] != nil {
            proto = "DNS"
        } else if layers["http"] != nil {
            proto = "HTTP"
        } else if layers["tls"] != nil {
            proto = "TLS"
        }

        // Build info string
        var info = ""
        if let tcp = layers["tcp"] as? [String: Any] {
            let srcPort = tcp["tcp.srcport"] as? String ?? ""
            let dstPort = tcp["tcp.dstport"] as? String ?? ""
            let flags = tcp["tcp.flags.str"] as? String ?? ""
            info = "\(srcPort) -> \(dstPort) \(flags)"
        } else if let udp = layers["udp"] as? [String: Any] {
            let srcPort = udp["udp.srcport"] as? String ?? ""
            let dstPort = udp["udp.dstport"] as? String ?? ""
            info = "\(srcPort) -> \(dstPort)"
        } else if let arp = layers["arp"] as? [String: Any] {
            let opcode = arp["arp.opcode"] as? String ?? ""
            info = opcode == "1" ? "Who has?" : "Reply"
        }

        let relativeTime = captureStartTime.map { timestamp.timeIntervalSince($0) } ?? 0

        // Build layer tree for detail view
        let decodedLayers = buildLayerTree(layers)

        return CapturedPacket(
            number: packetNumber,
            timestamp: timestamp,
            relativeTime: relativeTime,
            sourceMAC: sourceMAC,
            destMAC: destMAC,
            sourceIP: sourceIP,
            destIP: destIP,
            protocol: proto,
            length: length,
            info: info,
            rawData: Data(),
            decodedLayers: decodedLayers,
            sourceVM: "tshark"  // Parsed from tshark, source VM unknown
        )
    }

    private func buildLayerTree(_ layers: [String: Any]) -> [PacketLayer] {
        var result: [PacketLayer] = []

        let layerOrder = ["frame", "eth", "ip", "ipv6", "arp", "tcp", "udp", "icmp", "dns", "http", "tls"]

        for layerName in layerOrder {
            if let layerData = layers[layerName] as? [String: Any] {
                let fields = layerData.compactMap { key, value -> (key: String, value: String)? in
                    guard let strValue = value as? String else { return nil }
                    return (key: key, value: strValue)
                }

                let displayName: String
                switch layerName {
                case "frame": displayName = "Frame"
                case "eth": displayName = "Ethernet II"
                case "ip": displayName = "Internet Protocol Version 4"
                case "ipv6": displayName = "Internet Protocol Version 6"
                case "arp": displayName = "Address Resolution Protocol"
                case "tcp": displayName = "Transmission Control Protocol"
                case "udp": displayName = "User Datagram Protocol"
                case "icmp": displayName = "Internet Control Message Protocol"
                case "dns": displayName = "Domain Name System"
                case "http": displayName = "Hypertext Transfer Protocol"
                case "tls": displayName = "Transport Layer Security"
                default: displayName = layerName.uppercased()
                }

                result.append(PacketLayer(name: displayName, fields: fields, children: []))
            }
        }

        return result
    }

    // MARK: - Packet Storage

    private func addPacket(_ packet: CapturedPacket) {
        capturedPackets.append(packet)

        // Trim to max size
        if capturedPackets.count > maxPackets {
            capturedPackets.removeFirst(capturedPackets.count - maxPackets)
        }

        // Notify observers on main thread for reliable UI updates
        DispatchQueue.main.async { [weak self] in
            // Publish via Combine
            self?.packetSubject.send(packet)

            // Also post notification for backwards compatibility
            NotificationCenter.default.post(
                name: .packetCaptured,
                object: nil,
                userInfo: ["packet": packet]
            )
        }
    }

    private func updateProtocolStats(_ proto: String, bytes: Int) {
        if var existing = protocolCounts[proto] {
            existing.count += 1
            existing.bytes += bytes
            protocolCounts[proto] = existing
        } else {
            protocolCounts[proto] = ProtocolCount(protocol: proto, count: 1, bytes: bytes)
        }

        let currentStats = Array(protocolCounts.values).sorted { $0.count > $1.count }

        // Notify on main thread for reliable UI updates
        DispatchQueue.main.async { [weak self] in
            // Publish via Combine
            self?.statsSubject.send(currentStats)

            // Also post notification for backwards compatibility
            NotificationCenter.default.post(name: .protocolStatsUpdated, object: nil)
        }
    }

    // MARK: - Data Access

    func getRecentPackets(count: Int) -> [CapturedPacket] {
        let startIndex = max(0, capturedPackets.count - count)
        return Array(capturedPackets[startIndex...])
    }

    func getAllPackets() -> [CapturedPacket] {
        return capturedPackets
    }

    func getProtocolStats() -> [ProtocolCount] {
        return Array(protocolCounts.values).sorted { $0.count > $1.count }
    }

    func clearPackets() {
        capturedPackets.removeAll()
        protocolCounts.removeAll()
        packetNumber = 0
    }

    var totalPacketCount: Int {
        return capturedPackets.count
    }

    var totalBytes: Int {
        return capturedPackets.reduce(0) { $0 + $1.length }
    }

    // MARK: - PCAP File Operations

    func saveToPCAP(url: URL) throws {
        var pcapData = Data()

        // Write global header
        var magic: UInt32 = 0xa1b2c3d4
        pcapData.append(Data(bytes: &magic, count: 4))

        var versionMajor: UInt16 = 2
        var versionMinor: UInt16 = 4
        pcapData.append(Data(bytes: &versionMajor, count: 2))
        pcapData.append(Data(bytes: &versionMinor, count: 2))

        var tzOffset: Int32 = 0
        pcapData.append(Data(bytes: &tzOffset, count: 4))

        var sigfigs: UInt32 = 0
        pcapData.append(Data(bytes: &sigfigs, count: 4))

        var snaplen: UInt32 = 65535
        pcapData.append(Data(bytes: &snaplen, count: 4))

        var linktype: UInt32 = 1
        pcapData.append(Data(bytes: &linktype, count: 4))

        // Write packets
        for packet in capturedPackets {
            guard !packet.rawData.isEmpty else { continue }

            let timestamp = packet.timestamp.timeIntervalSince1970
            var tsSec: UInt32 = UInt32(timestamp)
            var tsUsec: UInt32 = UInt32((timestamp - Double(tsSec)) * 1_000_000)
            var inclLen: UInt32 = UInt32(packet.rawData.count)
            var origLen: UInt32 = UInt32(packet.rawData.count)

            pcapData.append(Data(bytes: &tsSec, count: 4))
            pcapData.append(Data(bytes: &tsUsec, count: 4))
            pcapData.append(Data(bytes: &inclLen, count: 4))
            pcapData.append(Data(bytes: &origLen, count: 4))
            pcapData.append(packet.rawData)
        }

        try pcapData.write(to: url)
        log("Saved \(capturedPackets.count) packets to \(url.path)")
    }

    func loadFromPCAP(url: URL) throws {
        // This would use tshark to parse the PCAP file
        guard let tshark = tsharkPath else {
            throw NSError(domain: "PacketCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "tshark not found"
            ])
        }

        clearPackets()
        captureStartTime = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tshark)
        process.arguments = ["-r", url.path, "-T", "json", "--no-duplicate-keys"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        parseTsharkOutput(data)

        log("Loaded packets from \(url.path)")
    }

    // MARK: - Logging

    private func log(_ message: String, type: OSLogType = .info) {
        os_log("%{public}@", log: logger, type: type, "[PacketCapture] \(message)")
        print("[PacketCapture] \(message)")
    }
}
