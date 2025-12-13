import Foundation

/// Bridge to packet capture functionality via tshark
class CaptureManagerBridge {
    private let captureStatePath: String
    private var captureProcess: Process?

    init() {
        captureStatePath = NSHomeDirectory() + "/.avf/capture/state.json"
    }

    // MARK: - Start Capture

    func startCapture(interface: String, filter: String?, outputFile: String?, maxPackets: Int) -> [String: Any] {
        // Check if tshark is available
        guard findTshark() != nil else {
            return ["error": "tshark not found. Install with: brew install wireshark"]
        }

        // Check if capture already running
        if isCapturing() {
            return ["error": "Capture already in progress. Stop it first."]
        }

        // Build tshark command
        var args = ["-i", interface, "-T", "json", "-l"]

        if let f = filter {
            args += ["-f", f]
        }

        if let output = outputFile {
            args += ["-w", output]
        }

        if maxPackets > 0 {
            args += ["-c", String(maxPackets)]
        }

        // Send notification to main app to start capture
        let notification = DistributedNotificationCenter.default()
        notification.postNotificationName(
            NSNotification.Name("com.secvf.cli.start-capture"),
            object: nil,
            userInfo: [
                "interface": interface,
                "filter": filter ?? "",
                "output": outputFile ?? "",
                "maxPackets": maxPackets
            ],
            deliverImmediately: true
        )

        // Save state
        saveState([
            "capturing": true,
            "interface": interface,
            "filter": filter ?? "",
            "startTime": ISO8601DateFormatter().string(from: Date()),
            "outputFile": outputFile ?? ""
        ])

        return [
            "success": true,
            "interface": interface,
            "filter": filter ?? "none",
            "output": outputFile ?? "memory"
        ]
    }

    // MARK: - Stop Capture

    func stopCapture() -> [String: Any] {
        guard isCapturing() else {
            return ["error": "No capture in progress"]
        }

        // Send notification to main app
        let notification = DistributedNotificationCenter.default()
        notification.postNotificationName(
            NSNotification.Name("com.secvf.cli.stop-capture"),
            object: nil,
            userInfo: [:],
            deliverImmediately: true
        )

        // Read stats before clearing state
        let stats = getStatus()
        let packets = stats["packetsCaptured"] as? Int ?? 0
        let bytes = stats["bytesCaptured"] as? Int64 ?? 0

        // Clear state
        saveState(["capturing": false])

        return [
            "success": true,
            "packetsCaptured": packets,
            "bytesCaptured": bytes
        ]
    }

    // MARK: - Get Status

    func getStatus() -> [String: Any] {
        if let data = FileManager.default.contents(atPath: captureStatePath),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            var status = state

            // Calculate duration if capturing
            if let capturing = state["capturing"] as? Bool, capturing,
               let startTimeStr = state["startTime"] as? String,
               let startTime = ISO8601DateFormatter().date(from: startTimeStr) {
                status["duration"] = Date().timeIntervalSince(startTime)
            }

            return status
        }

        return [
            "capturing": false,
            "packetsCaptured": 0,
            "bytesCaptured": Int64(0)
        ]
    }

    // MARK: - Export Packets

    func exportPackets(output: String, format: String, filter: String?, limit: Int?) -> [String: Any] {
        // Check for capture file to export from
        let captureDir = NSHomeDirectory() + "/.avf/capture"
        let defaultCapture = captureDir + "/current.pcap"

        guard FileManager.default.fileExists(atPath: defaultCapture) else {
            return ["error": "No capture data available. Start a capture first."]
        }

        switch format.lowercased() {
        case "pcap":
            return exportAsPCAP(from: defaultCapture, to: output, filter: filter, limit: limit)
        case "json":
            return exportAsJSON(from: defaultCapture, to: output, filter: filter, limit: limit)
        case "csv":
            return exportAsCSV(from: defaultCapture, to: output, filter: filter, limit: limit)
        default:
            return ["error": "Unsupported format: \(format). Use pcap, json, or csv."]
        }
    }

    private func exportAsPCAP(from source: String, to dest: String, filter: String?, limit: Int?) -> [String: Any] {
        guard findTshark() != nil else {
            return ["error": "tshark not found"]
        }

        var args = ["-r", source, "-w", dest]

        if let f = filter {
            args += ["-Y", f]
        }

        if let l = limit {
            args += ["-c", String(l)]
        }

        return runTshark(args: args, outputPath: dest)
    }

    private func exportAsJSON(from source: String, to dest: String, filter: String?, limit: Int?) -> [String: Any] {
        guard let tshark = findTshark() else {
            return ["error": "tshark not found"]
        }

        var args = ["-r", source, "-T", "json"]

        if let f = filter {
            args += ["-Y", f]
        }

        if let l = limit {
            args += ["-c", String(l)]
        }

        // Run tshark and capture output
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tshark)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try data.write(to: URL(fileURLWithPath: dest))

            // Count packets
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return ["success": true, "packetsExported": json.count, "path": dest]
            }

            return ["success": true, "path": dest]
        } catch {
            return ["error": "Export failed: \(error.localizedDescription)"]
        }
    }

    private func exportAsCSV(from source: String, to dest: String, filter: String?, limit: Int?) -> [String: Any] {
        guard let tshark = findTshark() else {
            return ["error": "tshark not found"]
        }

        var args = ["-r", source, "-T", "fields",
                    "-e", "frame.number",
                    "-e", "frame.time",
                    "-e", "ip.src",
                    "-e", "ip.dst",
                    "-e", "frame.protocols",
                    "-e", "frame.len",
                    "-e", "_ws.col.Info",
                    "-E", "header=y",
                    "-E", "separator=,"]

        if let f = filter {
            args += ["-Y", f]
        }

        if let l = limit {
            args += ["-c", String(l)]
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tshark)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try data.write(to: URL(fileURLWithPath: dest))

            // Count lines (minus header)
            let content = String(data: data, encoding: .utf8) ?? ""
            let lineCount = content.components(separatedBy: "\n").count - 2

            return ["success": true, "packetsExported": max(0, lineCount), "path": dest]
        } catch {
            return ["error": "Export failed: \(error.localizedDescription)"]
        }
    }

    private func runTshark(args: [String], outputPath: String) -> [String: Any] {
        guard let tshark = findTshark() else {
            return ["error": "tshark not found"]
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tshark)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                // Get packet count from output file
                let countArgs = ["-r", outputPath, "-T", "fields", "-e", "frame.number"]
                let countTask = Process()
                countTask.executableURL = URL(fileURLWithPath: tshark)
                countTask.arguments = countArgs

                let pipe = Pipe()
                countTask.standardOutput = pipe
                countTask.standardError = FileHandle.nullDevice

                try countTask.run()
                countTask.waitUntilExit()

                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let count = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count

                return ["success": true, "packetsExported": count, "path": outputPath]
            } else {
                return ["error": "tshark failed with exit code \(task.terminationStatus)"]
            }
        } catch {
            return ["error": "Failed to run tshark: \(error.localizedDescription)"]
        }
    }

    // MARK: - Live Packet Stream

    func streamPackets(filter: String?, callback: @escaping ([String: Any]) -> Bool) {
        guard let tshark = findTshark() else {
            print("Error: tshark not found")
            return
        }

        // Check for current capture file or live interface
        let captureDir = NSHomeDirectory() + "/.avf/capture"
        let currentCapture = captureDir + "/current.pcap"

        var args: [String]

        if FileManager.default.fileExists(atPath: currentCapture) {
            // Read from capture file
            args = ["-r", currentCapture, "-T", "json", "-l"]
        } else {
            // Live capture from any interface
            args = ["-i", "any", "-T", "json", "-l"]
        }

        if let f = filter {
            args += ["-Y", f]
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tshark)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // Handle output line by line
        var buffer = Data()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            buffer.append(data)

            // Try to parse complete JSON packets
            while let packet = self.extractNextPacket(from: &buffer) {
                let shouldContinue = callback(packet)
                if !shouldContinue {
                    task.terminate()
                    return
                }
            }
        }

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Error: \(error.localizedDescription)")
        }

        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func extractNextPacket(from buffer: inout Data) -> [String: Any]? {
        guard let str = String(data: buffer, encoding: .utf8) else { return nil }

        // Look for complete JSON object (simplified parsing)
        var depth = 0
        var start: String.Index?
        var end: String.Index?

        for (i, char) in str.enumerated() {
            if char == "{" {
                if depth == 0 {
                    start = str.index(str.startIndex, offsetBy: i)
                }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 && start != nil {
                    end = str.index(str.startIndex, offsetBy: i + 1)
                    break
                }
            }
        }

        guard let s = start, let e = end else { return nil }

        let jsonStr = String(str[s..<e])

        // Remove parsed data from buffer
        let bytesToRemove = str.distance(from: str.startIndex, to: e)
        buffer.removeFirst(bytesToRemove)

        // Parse JSON
        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        // Transform to simplified format
        return transformPacket(json)
    }

    private func transformPacket(_ raw: [String: Any]) -> [String: Any] {
        var packet: [String: Any] = [:]

        if let source = raw["_source"] as? [String: Any],
           let layers = source["layers"] as? [String: Any] {

            // Frame info
            if let frame = layers["frame"] as? [String: Any] {
                packet["time"] = (frame["frame.time_relative"] as? String) ?? "0.000"
                packet["length"] = Int(frame["frame.len"] as? String ?? "0") ?? 0
                packet["protocol"] = frame["frame.protocols"] as? String ?? ""
            }

            // IP addresses
            if let ip = layers["ip"] as? [String: Any] {
                packet["source"] = ip["ip.src"] as? String ?? ""
                packet["destination"] = ip["ip.dst"] as? String ?? ""
            } else if let eth = layers["eth"] as? [String: Any] {
                packet["source"] = eth["eth.src"] as? String ?? ""
                packet["destination"] = eth["eth.dst"] as? String ?? ""
            }

            // Protocol-specific info
            if let tcp = layers["tcp"] as? [String: Any] {
                packet["protocol"] = "TCP"
                let srcPort = tcp["tcp.srcport"] as? String ?? ""
                let dstPort = tcp["tcp.dstport"] as? String ?? ""
                packet["info"] = "\(srcPort) → \(dstPort)"
            } else if let udp = layers["udp"] as? [String: Any] {
                packet["protocol"] = "UDP"
                let srcPort = udp["udp.srcport"] as? String ?? ""
                let dstPort = udp["udp.dstport"] as? String ?? ""
                packet["info"] = "\(srcPort) → \(dstPort)"
            } else if let icmp = layers["icmp"] as? [String: Any] {
                packet["protocol"] = "ICMP"
                packet["info"] = icmp["icmp.type"] as? String ?? ""
            } else if let dns = layers["dns"] as? [String: Any] {
                packet["protocol"] = "DNS"
                packet["info"] = dns["dns.qry.name"] as? String ?? ""
            }
        }

        return packet
    }

    // MARK: - Helpers

    private func findTshark() -> String? {
        let paths = [
            "/opt/homebrew/bin/tshark",
            "/usr/local/bin/tshark",
            "/usr/bin/tshark"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func isCapturing() -> Bool {
        let status = getStatus()
        return status["capturing"] as? Bool ?? false
    }

    private func saveState(_ state: [String: Any]) {
        let captureDir = NSHomeDirectory() + "/.avf/capture"

        do {
            try FileManager.default.createDirectory(atPath: captureDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: captureStatePath))
        } catch {
            // Non-fatal
        }
    }
}
