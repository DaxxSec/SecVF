//
//  SwitchStatisticsWindowController.swift
//  SecVF
//
//  VIRTUAL SWITCH STATISTICS WINDOW
//  Displays real-time virtual network switch statistics and port information
//  in a non-modal, independently manageable window.
//

import Cocoa

@MainActor
class SwitchStatisticsWindowController: NSWindowController {

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var refreshTimer: Timer?
    private var autoRefreshCheckbox: NSButton!

    init() {
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Virtual Switch Statistics"
        window.center()

        super.init(window: window)

        setupUI()
        loadStatistics()
        startAutoRefresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopAutoRefresh()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Toolbar with controls
        let toolbar = NSView(frame: NSRect(x: 0, y: window.contentView!.bounds.height - 40, width: window.contentView!.bounds.width, height: 40))
        toolbar.autoresizingMask = [.width, .minYMargin]

        // Refresh button
        let refreshButton = NSButton(frame: NSRect(x: 10, y: 8, width: 80, height: 24))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatistics)
        toolbar.addSubview(refreshButton)

        // Auto-refresh checkbox
        autoRefreshCheckbox = NSButton(checkboxWithTitle: "Auto-refresh", target: self, action: nil)
        autoRefreshCheckbox.frame = NSRect(x: 100, y: 10, width: 120, height: 20)
        autoRefreshCheckbox.state = .on
        toolbar.addSubview(autoRefreshCheckbox)

        // Status label
        let statusLabel = NSTextField(labelWithString: "Auto-refresh: Every 2 seconds")
        statusLabel.frame = NSRect(x: 230, y: 12, width: 250, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(statusLabel)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: toolbar.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        toolbar.addSubview(separator)

        contentView.addSubview(toolbar)

        // Text view with scroll view
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: window.contentView!.bounds.width, height: window.contentView!.bounds.height - 40))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder

        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        window.contentView = contentView
    }

    // MARK: - Statistics Loading

    private func loadStatistics() {
        let stats = VirtualNetworkSwitch.shared.getStatistics()

        var message = ""
        message += "═══════════════════════════════════════\n"
        message += "   VIRTUAL NETWORK SWITCH STATISTICS\n"
        message += "═══════════════════════════════════════\n\n"

        message += "Status: \(stats["running"] as? Bool ?? false ? "Running ✓" : "Stopped ✗")\n"
        message += "Connected Ports: \(stats["connectedPorts"] ?? 0)\n"
        message += "Learned MACs: \(stats["learnedMACs"] ?? 0)\n"
        message += "Packets Forwarded: \(stats["packetsForwarded"] ?? 0)\n"
        message += "Packets Broadcast: \(stats["packetsBroadcast"] ?? 0)\n"

        if let portStats = stats["ports"] as? [[String: Any]], !portStats.isEmpty {
            message += "\n═══════════════════════════════════════\n"
            message += "             PORT DETAILS\n"
            message += "═══════════════════════════════════════\n\n"

            for port in portStats {
                message += "VM: \(port["vmName"] as? String ?? "unknown")\n"
                message += "  MAC Address: \(port["macAddress"] as? String ?? "unknown")\n"

                let rxPackets = port["packetsRx"] as? UInt64 ?? 0
                let txPackets = port["packetsTx"] as? UInt64 ?? 0
                let rxBytes = port["bytesRx"] as? UInt64 ?? 0
                let txBytes = port["bytesTx"] as? UInt64 ?? 0

                message += "  Received: \(rxPackets) packets (\(formatBytes(rxBytes)))\n"
                message += "  Transmitted: \(txPackets) packets (\(formatBytes(txBytes)))\n"
                message += "\n"
            }
        } else {
            message += "\n═══════════════════════════════════════\n"
            message += "No VMs currently connected to the virtual switch.\n"
        }

        message += "═══════════════════════════════════════\n"

        // Update timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        message += "\nLast updated: \(dateFormatter.string(from: Date()))\n"

        textView.string = message
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Auto-Refresh

    private func startAutoRefresh() {
        // Refresh every 2 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.autoRefreshCheckbox.state == .on else { return }
            self.loadStatistics()
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    @objc private func refreshStatistics() {
        loadStatistics()
    }
}
