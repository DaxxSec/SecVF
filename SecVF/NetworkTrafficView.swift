//
//  NetworkTrafficView.swift
//  SecVF
//
//  Animated visualization of network traffic between VMs.
//  Displays packet flow and switch statistics.
//

import Cocoa

@MainActor
class NetworkTrafficView: NSView {
    private var packets: [AnimatedPacket] = []
    private var displayLink: CVDisplayLink?
    private var animationTimer: Timer?

    // Statistics
    var packetsForwarded: Int = 0
    var packetsBroadcast: Int = 0
    var bytesTransferred: Int = 0
    var connectedPorts: Int = 0

    // Track previous stats to detect new traffic
    private var lastPacketsForwarded: Int = 0
    private var lastPacketsBroadcast: Int = 0
    private var pendingPacketsToSpawn: Int = 0

    // Source and destination names
    var sourceVMName: String = "Client"
    var routerVMName: String = "Router"

    // Animation properties
    private let packetColors: [NSColor] = [
        NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0),   // Neon green
        NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0),   // Cyan
        NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0),   // Light blue
    ]

    struct AnimatedPacket {
        var position: CGFloat  // 0.0 to 1.0
        var speed: CGFloat
        var color: NSColor
        var size: CGFloat
        var direction: Bool  // true = down, false = up
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func startAnimation() {
        stopAnimation()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.updateAnimation()
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        packets.removeAll()
        needsDisplay = true
    }

    private func updateAnimation() {
        // Spawn packets based on actual traffic (pending queue)
        if pendingPacketsToSpawn > 0 && packets.count < 20 {
            // Spawn 1-3 packets per frame when we have pending traffic
            let toSpawn = min(pendingPacketsToSpawn, Int.random(in: 1...3))
            for _ in 0..<toSpawn {
                let packet = AnimatedPacket(
                    position: 0.0,
                    speed: CGFloat.random(in: 0.02...0.04),
                    color: packetColors.randomElement()!,
                    size: CGFloat.random(in: 4...7),
                    direction: Bool.random()
                )
                packets.append(packet)
            }
            pendingPacketsToSpawn -= toSpawn
        }

        // Update packet positions
        packets = packets.compactMap { packet in
            var p = packet
            p.position += p.speed
            return p.position <= 1.0 ? p : nil
        }

        needsDisplay = true
    }

    func updateStats(forwarded: Int, broadcast: Int, bytes: Int, ports: Int) {
        // Calculate new packets since last update
        let newForwarded = forwarded - lastPacketsForwarded
        let newBroadcast = broadcast - lastPacketsBroadcast

        // Queue up visual packets based on actual traffic (scaled down for visual)
        let newPackets = newForwarded + newBroadcast
        if newPackets > 0 {
            // Scale: show ~1 visual packet per 5-10 real packets, with minimum of 1
            pendingPacketsToSpawn += max(1, newPackets / 5)
        }

        lastPacketsForwarded = forwarded
        lastPacketsBroadcast = broadcast

        packetsForwarded = forwarded
        packetsBroadcast = broadcast
        bytesTransferred = bytes
        connectedPorts = ports
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let width = bounds.width
        let height = bounds.height

        // Stats box dimensions (calculated first so we can position line relative to it)
        let statsWidth: CGFloat = width - 20
        let statsHeight: CGFloat = 80
        let statsX: CGFloat = 10
        let statsY: CGFloat = height / 2 - 40

        // Center the line in the middle of the view (not offset by stats box)
        let lineX = width / 2
        let lineTop = height - 15
        let lineBottom: CGFloat = 15

        // Glow effect
        context.saveGState()
        context.setShadow(offset: .zero, blur: 8, color: NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 0.5).cgColor)

        // Main line
        context.setStrokeColor(NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.6).cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.move(to: CGPoint(x: lineX, y: lineTop))
        context.addLine(to: CGPoint(x: lineX, y: lineBottom))
        context.strokePath()
        context.restoreGState()

        // Draw animated packets
        for packet in packets {
            let y: CGFloat
            if packet.direction {
                y = lineTop - (lineTop - lineBottom) * packet.position
            } else {
                y = lineBottom + (lineTop - lineBottom) * packet.position
            }

            // Packet glow
            context.saveGState()
            context.setShadow(offset: .zero, blur: 6, color: packet.color.withAlphaComponent(0.8).cgColor)

            // Draw packet dot - exactly centered on line
            context.setFillColor(packet.color.cgColor)
            context.fillEllipse(in: CGRect(x: lineX - packet.size/2, y: y - packet.size/2, width: packet.size, height: packet.size))
            context.restoreGState()
        }

        // Stats background
        let statsRect = NSRect(x: statsX, y: statsY, width: statsWidth, height: statsHeight)
        context.setFillColor(NSColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 0.9).cgColor)
        context.fill(statsRect)

        // Stats border
        context.setStrokeColor(NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.4).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.stroke(statsRect)

        // Draw statistics text
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1.0)
        ]

        // Title
        let title = "⚡ SWITCH STATS"
        title.draw(at: CGPoint(x: statsX + 5, y: statsY + statsHeight - 15), withAttributes: titleAttrs)

        // Stats values
        let fwdText = "PKT FWD: \(formatNumber(packetsForwarded))"
        fwdText.draw(at: CGPoint(x: statsX + 5, y: statsY + statsHeight - 32), withAttributes: valueAttrs)

        let bcastText = "BCAST: \(formatNumber(packetsBroadcast))"
        bcastText.draw(at: CGPoint(x: statsX + 5, y: statsY + statsHeight - 46), withAttributes: valueAttrs)

        let bytesText = "BYTES: \(formatBytes(bytesTransferred))"
        bytesText.draw(at: CGPoint(x: statsX + 5, y: statsY + statsHeight - 60), withAttributes: valueAttrs)

        let portsText = "PORTS: \(connectedPorts)"
        portsText.draw(at: CGPoint(x: statsX + 5, y: statsY + statsHeight - 74), withAttributes: valueAttrs)

        // Draw direction arrows - properly centered on line
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.8)
        ]

        // Measure arrow width to center properly
        let downArrow = NSAttributedString(string: "▼", attributes: arrowAttrs)
        let upArrow = NSAttributedString(string: "▲", attributes: arrowAttrs)
        let arrowSize = downArrow.size()

        // Top arrow (down) - centered on line
        downArrow.draw(at: CGPoint(x: lineX - arrowSize.width / 2, y: lineTop + 2))

        // Bottom arrow (up) - centered on line
        upArrow.draw(at: CGPoint(x: lineX - arrowSize.width / 2, y: lineBottom - arrowSize.height - 2))
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000)
        } else if num >= 1_000 {
            return String(format: "%.1fK", Double(num) / 1_000)
        }
        return "\(num)"
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}
