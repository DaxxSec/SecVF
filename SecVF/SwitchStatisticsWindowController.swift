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
        window.minSize = NSSize(width: 500, height: 320)
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
        // Tear down the refresh timer directly — `stopAutoRefresh` is
        // main-actor isolated and can't be called from a nonisolated
        // deinit. The Timer + nil-out are both safe from any thread
        // (Timer.invalidate is documented thread-safe; the optional
        // assignment doesn't touch UI state).
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Toolbar with controls (uses spacing tokens for consistent alignment)
        let toolbarHeight: CGFloat = 40
        let toolbar = NSView(frame: NSRect(x: 0,
                                           y: window.contentView!.bounds.height - toolbarHeight,
                                           width: window.contentView!.bounds.width,
                                           height: toolbarHeight))
        toolbar.autoresizingMask = [.width, .minYMargin]

        let buttonY: CGFloat = (toolbarHeight - 24) / 2
        let buttonH: CGFloat = 24
        let padding = LayoutConstants.spacingMD

        // Refresh button
        let refreshButton = NSButton(frame: NSRect(x: padding, y: buttonY, width: 80, height: buttonH))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatistics)
        refreshButton.toolTip = "Refresh statistics now (⌘R)"
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = .command
        toolbar.addSubview(refreshButton)

        // Auto-refresh checkbox — explicit action so toggling it kicks an
        // immediate refresh (and visually confirms the change), instead of
        // waiting for the next 2s tick.
        autoRefreshCheckbox = NSButton(checkboxWithTitle: "Auto-refresh",
                                       target: self,
                                       action: #selector(autoRefreshToggled(_:)))
        autoRefreshCheckbox.frame = NSRect(x: padding + 80 + LayoutConstants.spacingMD,
                                           y: buttonY,
                                           width: 120,
                                           height: buttonH)
        autoRefreshCheckbox.state = .on
        autoRefreshCheckbox.toolTip = "Refresh statistics automatically every 2 seconds"
        toolbar.addSubview(autoRefreshCheckbox)

        // Status label — right-aligned and autoresizing
        let statusW: CGFloat = 200
        let statusLabel = NSTextField(labelWithString: "Auto-refresh · every 2s")
        statusLabel.frame = NSRect(x: window.contentView!.bounds.width - statusW - padding,
                                   y: (toolbarHeight - 16) / 2,
                                   width: statusW,
                                   height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.autoresizingMask = [.minXMargin]
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
        textView.font = NSFont.monospacedSystemFont(
            ofSize: LayoutConstants.fontSizeBody, weight: .regular)
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

    @objc private func autoRefreshToggled(_ sender: NSButton) {
        // Toggling on triggers an immediate refresh so the user gets
        // instant feedback that the control worked.
        if sender.state == .on {
            loadStatistics()
        }
    }
}
