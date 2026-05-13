//
//  PacketAnalysisWindowController.swift
//  SecVF
//
//  Full-featured packet analysis window with live capture, filters, and PCAP support
//

import Cocoa
import UniformTypeIdentifiers

@MainActor
class PacketAnalysisWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    // UI Components
    private var packetTableView: NSTableView!
    private var detailTextView: NSTextView!
    private var filterTextField: NSTextField!
    private var statusLabel: NSTextField!
    private var emptyStateLabel: NSTextField!

    // Toolbar buttons
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var clearButton: NSButton!
    private var autoScrollCheckbox: NSButton!

    // Data
    private var displayedPackets: [CapturedPacket] = []
    private var selectedPacket: CapturedPacket?
    private var currentFilter: String = ""
    /// Pre-compiled form of `currentFilter`. Set once via `setCurrentFilter`
    /// so per-packet evaluation doesn't re-parse the expression. `nil`
    /// means "no filter" (every packet passes); a `PacketFilter` value
    /// means "evaluate against this AST". A parse error also produces
    /// `nil` (compileOrNil) so a malformed live-typed filter shows
    /// everything rather than nothing — surfaces faster as obviously
    /// wrong than a silent empty list.
    private var compiledFilter: PacketFilter?
    private var autoScroll: Bool = true

    // PERFORMANCE: Batched packet updates to reduce UI redraws during high-traffic captures
    private var packetBuffer: [CapturedPacket] = []
    private var batchUpdateTimer: Timer?
    private let batchInterval: TimeInterval = 0.25  // Flush buffer 4x per second
    private let maxBufferSize: Int = 100  // Flush immediately if buffer exceeds this

    // MARK: - Initialization

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "SecVF Packet Analysis"
        window.minSize = NSSize(width: 700, height: 500)
        window.center()

        super.init(window: window)

        setupUI()
        setupNotifications()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        batchUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Apply dark theme
        window.appearance = NSAppearance(named: .darkAqua)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppColors.backgroundSecondary.cgColor

        let width = contentView.bounds.width
        let height = contentView.bounds.height

        // ═══════════════════════════════════════════════════════════════
        // TOOLBAR (Top)
        // ═══════════════════════════════════════════════════════════════
        let toolbarHeight: CGFloat = 80
        let toolbarView = NSView(frame: NSRect(x: 0, y: height - toolbarHeight, width: width, height: toolbarHeight))
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = AppColors.backgroundTertiary.cgColor
        toolbarView.autoresizingMask = [.width, .minYMargin]

        // Row 1: Capture controls
        var xOffset: CGFloat = LayoutConstants.spacingLG

        startButton = createToolbarButton(title: "▶ Start", action: #selector(startCapture(_:)))
        startButton.frame = NSRect(x: xOffset, y: 45, width: 70, height: 28)
        startButton.toolTip = "Begin live packet capture from the selected interface"
        startButton.setAccessibilityLabel("Start capture")
        toolbarView.addSubview(startButton)
        xOffset += 75

        stopButton = createToolbarButton(title: "⏹ Stop", action: #selector(stopCapture(_:)))
        stopButton.frame = NSRect(x: xOffset, y: 45, width: 70, height: 28)
        stopButton.isEnabled = false
        stopButton.toolTip = "Stop the in-progress packet capture"
        stopButton.setAccessibilityLabel("Stop capture")
        toolbarView.addSubview(stopButton)
        xOffset += 75

        clearButton = createToolbarButton(title: "Clear", action: #selector(clearPackets(_:)))
        clearButton.frame = NSRect(x: xOffset, y: 45, width: 60, height: 28)
        clearButton.toolTip = "Clear the visible packet list (does not delete saved PCAPs)"
        toolbarView.addSubview(clearButton)
        xOffset += 80

        // Separator
        let sep1 = NSBox(frame: NSRect(x: xOffset, y: 40, width: 1, height: 35))
        sep1.boxType = .separator
        toolbarView.addSubview(sep1)
        xOffset += 15

        // PCAP buttons
        let openButton = createToolbarButton(title: "Open PCAP", action: #selector(openPCAP(_:)))
        openButton.frame = NSRect(x: xOffset, y: 45, width: 90, height: 28)
        openButton.toolTip = "Load a .pcap or .pcapng file from disk"
        toolbarView.addSubview(openButton)
        xOffset += 95

        let saveButton = createToolbarButton(title: "Save PCAP", action: #selector(savePCAP(_:)))
        saveButton.frame = NSRect(x: xOffset, y: 45, width: 90, height: 28)
        saveButton.toolTip = "Export the captured packets to a .pcap file"
        toolbarView.addSubview(saveButton)
        xOffset += 110

        // Auto-scroll checkbox — y=47 keeps the 24pt-high checkbox visually
        // centered with the 28pt-high buttons in this row (both centered at y=59).
        autoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: #selector(toggleAutoScroll(_:)))
        autoScrollCheckbox.frame = NSRect(x: xOffset, y: 47, width: 100, height: 24)
        autoScrollCheckbox.state = .on
        autoScrollCheckbox.contentTintColor = NSColor.white
        autoScrollCheckbox.toolTip = "Follow new packets as they arrive (jump to the latest row)"
        toolbarView.addSubview(autoScrollCheckbox)

        // Row 2: Filter with preset dropdown
        let filterLabel = NSTextField(labelWithString: "Filter:")
        filterLabel.frame = NSRect(x: 15, y: 10, width: 45, height: 24)
        filterLabel.textColor = NSColor.white
        filterLabel.font = NSFont.systemFont(ofSize: 12)
        toolbarView.addSubview(filterLabel)

        // Preset filters popup — built from the shared catalog in
        // PacketFilterPresets so the library window's Filter button shows
        // the exact same menu.
        let presetPopup = NSPopUpButton(frame: NSRect(x: 60, y: 10, width: 180, height: 24), pullsDown: true)
        presetPopup.font = NSFont.systemFont(ofSize: 10)
        presetPopup.addItem(withTitle: "⚡ Malware Analysis Filters")
        // Append directly onto the popup's existing menu so the title
        // item created above is preserved — no allocate-then-copy.
        if let popupMenu = presetPopup.menu {
            PacketFilterPresets.populateMenu(popupMenu,
                                             target: self,
                                             action: #selector(presetFilterSelected(_:)))
        }
        toolbarView.addSubview(presetPopup)

        filterTextField = NSTextField(frame: NSRect(x: 250, y: 10, width: width - 365, height: 24))
        filterTextField.placeholderString = "Custom filter or select preset →"
        filterTextField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        filterTextField.target = self
        filterTextField.action = #selector(applyFilter(_:))
        filterTextField.autoresizingMask = [.width]
        toolbarView.addSubview(filterTextField)

        let applyButton = createToolbarButton(title: "Apply", action: #selector(applyFilter(_:)))
        applyButton.frame = NSRect(x: width - 100, y: 10, width: 85, height: 24)
        applyButton.autoresizingMask = [.minXMargin]
        toolbarView.addSubview(applyButton)

        contentView.addSubview(toolbarView)

        // ═══════════════════════════════════════════════════════════════
        // PACKET TABLE (Middle)
        // ═══════════════════════════════════════════════════════════════
        let tableHeight: CGFloat = 280
        let tableY = height - toolbarHeight - tableHeight - 5

        let scrollView = NSScrollView(frame: NSRect(x: 10, y: tableY, width: width - 20, height: tableHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        packetTableView = NSTableView(frame: scrollView.bounds)
        packetTableView.style = .plain
        packetTableView.usesAlternatingRowBackgroundColors = true
        packetTableView.rowHeight = 18
        packetTableView.dataSource = self
        packetTableView.delegate = self
        packetTableView.allowsMultipleSelection = false
        packetTableView.target = self
        packetTableView.action = #selector(tableViewClicked(_:))

        // Create columns
        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("number", "#", 50),
            ("time", "Time", 100),
            ("source", "Source", 140),
            ("destination", "Destination", 140),
            ("protocol", "Protocol", 70),
            ("length", "Length", 60),
            ("info", "Info", 280)
        ]

        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            column.minWidth = 40
            column.headerCell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            packetTableView.addTableColumn(column)
        }

        scrollView.documentView = packetTableView
        contentView.addSubview(scrollView)

        // Empty-state label, overlaid on the table. Visible when the displayed
        // packet list is empty (either capture not started or filter has no hits).
        emptyStateLabel = NSTextField(labelWithString: "No packets captured yet.\nClick ▶ Start to begin capturing.")
        emptyStateLabel.alignment = .center
        emptyStateLabel.isEditable = false
        emptyStateLabel.isBezeled = false
        emptyStateLabel.drawsBackground = false
        emptyStateLabel.textColor = AppColors.textMuted
        emptyStateLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeSubtitle, weight: .regular)
        emptyStateLabel.usesSingleLineMode = false
        emptyStateLabel.maximumNumberOfLines = 3
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.frame = NSRect(x: 10,
                                       y: tableY + tableHeight / 2 - 30,
                                       width: width - 20,
                                       height: 60)
        emptyStateLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        contentView.addSubview(emptyStateLabel)

        // ═══════════════════════════════════════════════════════════════
        // PACKET DETAILS (Bottom)
        // ═══════════════════════════════════════════════════════════════
        let detailY: CGFloat = 35
        let detailHeight = tableY - detailY - 10

        let detailLabel = NSTextField(labelWithString: "Packet Details:")
        detailLabel.frame = NSRect(x: 15, y: tableY - 25, width: 150, height: 20)
        detailLabel.textColor = AppColors.accentODGlow
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .semibold)
        detailLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(detailLabel)

        let detailScrollView = NSScrollView(frame: NSRect(x: 10, y: detailY, width: width - 20, height: detailHeight))
        detailScrollView.autoresizingMask = [.width, .height]
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .bezelBorder

        detailTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 20, height: detailHeight))
        detailTextView.isEditable = false
        detailTextView.backgroundColor = AppColors.backgroundPanel
        detailTextView.textColor = AppColors.textOD
        detailTextView.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular)
        detailTextView.autoresizingMask = [.width, .height]

        detailScrollView.documentView = detailTextView
        contentView.addSubview(detailScrollView)

        // ═══════════════════════════════════════════════════════════════
        // STATUS BAR (Bottom)
        // ═══════════════════════════════════════════════════════════════
        let statusBar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = AppColors.backgroundTertiary.cgColor
        statusBar.autoresizingMask = [.width]

        statusLabel = NSTextField(labelWithString: "Ready - tshark: \(PacketCaptureManager.shared.isTsharkAvailable ? "Available" : "Not Found")")
        statusLabel.frame = NSRect(x: 15, y: 5, width: width - 30, height: 20)
        statusLabel.textColor = AppColors.statusRunning
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSmall, weight: .regular)
        statusLabel.autoresizingMask = [.width]
        statusBar.addSubview(statusLabel)

        contentView.addSubview(statusBar)

        // Update initial state
        updateButtonStates()
    }

    private func createToolbarButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return button
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePacketCaptured(_:)),
            name: .packetCaptured,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureStarted(_:)),
            name: .captureStarted,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCaptureStopped(_:)),
            name: .captureStopped,
            object: nil
        )
    }

    @objc private func handlePacketCaptured(_ notification: Notification) {
        guard let packet = notification.userInfo?["packet"] as? CapturedPacket else { return }

        DispatchQueue.main.async { [weak self] in
            self?.addPacket(packet)
        }
    }

    @objc private func handleCaptureStarted(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateButtonStates()
            self?.updateStatus()
        }
    }

    @objc private func handleCaptureStopped(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateButtonStates()
            self?.updateStatus()
        }
    }

    // MARK: - Actions

    @objc private func startCapture(_ sender: Any) {
        if !PacketCaptureManager.shared.isTsharkAvailable {
            showAlert(title: "tshark Not Found",
                     message: "tshark is required for packet capture.\n\nInstall with:\nbrew install wireshark")
            return
        }

        if PacketCaptureManager.shared.startCapture() {
            updateButtonStates()
            updateStatus()
        } else {
            showAlert(title: "Capture Failed", message: "Failed to start packet capture. Check console for details.")
        }
    }

    @objc private func stopCapture(_ sender: Any) {
        PacketCaptureManager.shared.stopCapture()
        // Flush any pending packets before showing stopped state
        flushPacketBuffer()
        updateButtonStates()
        updateStatus()
    }

    @objc private func clearPackets(_ sender: Any) {
        PacketCaptureManager.shared.clearPackets()
        // Clear buffer and stop batch timer
        batchUpdateTimer?.invalidate()
        batchUpdateTimer = nil
        packetBuffer.removeAll()
        displayedPackets.removeAll()
        packetTableView.reloadData()
        detailTextView.string = ""
        updateStatus()
    }

    @objc private func openPCAP(_ sender: Any) {
        // `UTType(filenameExtension:)` returns `nil` on systems with stripped
        // UTI registration (locked-down corporate Macs, some MDM profiles).
        // Force-unwrapping there crashes the whole UI. Guard + actionable error.
        guard let pcapType  = UTType(filenameExtension: "pcap"),
              let pcapngType = UTType(filenameExtension: "pcapng") else {
            showAlert(title: "Cannot Open PCAP",
                      message: "This Mac doesn't have the pcap/pcapng file types registered. Install Wireshark or run `defaults write ...` to register them, then try again.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [pcapType, pcapngType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a PCAP file to analyze"

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try PacketCaptureManager.shared.loadFromPCAP(url: url)
                self?.reloadPackets()
                self?.updateStatus()
            } catch {
                self?.showAlert(title: "Load Failed", message: "Failed to load PCAP: \(error.localizedDescription)")
            }
        }
    }

    @objc private func savePCAP(_ sender: Any) {
        // Same guard as openPCAP — pcap UTI may be unregistered.
        guard let pcapType = UTType(filenameExtension: "pcap") else {
            showAlert(title: "Cannot Save PCAP",
                      message: "This Mac doesn't have the pcap file type registered. Install Wireshark or register the type, then try again.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pcapType]
        panel.nameFieldStringValue = "capture.pcap"
        panel.message = "Save captured packets to PCAP file"

        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try PacketCaptureManager.shared.saveToPCAP(url: url)
                self?.showAlert(title: "Saved", message: "Packets saved to \(url.lastPathComponent)")
            } catch {
                self?.showAlert(title: "Save Failed", message: "Failed to save PCAP: \(error.localizedDescription)")
            }
        }
    }

    /// Called when the user picks a preset from the toolbar's
    /// "⚡ Malware Analysis Filters" popup. Sender is the NSMenuItem owned
    /// by the popup's menu (target/action wired in
    /// `PacketFilterPresets.buildMenu`). Apply the corresponding filter and
    /// surface an explanation in `showFilterInfo`.
    @objc func presetFilterSelected(_ sender: Any?) {
        let title: String? = {
            if let item = sender as? NSMenuItem { return item.title }
            if let popup = sender as? NSPopUpButton { return popup.selectedItem?.title }
            return nil
        }()
        guard let selectedTitle = title,
              let filter = PacketFilterPresets.filter(for: selectedTitle) else {
            return
        }
        filterTextField.stringValue = filter
        setCurrentFilter(filter)
        reloadPackets()
        updateStatus()
        showFilterInfo(for: selectedTitle)
    }

    /// Public entry point used by `VMLibraryWindowController`'s Filter
    /// button: open this window with the given preset already applied so
    /// the user lands on the filtered packet list.
    func applyPresetByTitle(_ title: String) {
        guard let filter = PacketFilterPresets.filter(for: title) else { return }
        filterTextField.stringValue = filter
        setCurrentFilter(filter)
        reloadPackets()
        updateStatus()
        showFilterInfo(for: title)
    }

    private func showFilterInfo(for filterName: String) {
        let infoMap: [String: String] = [
            "Non-Apple DNS (Suspicious)": "DNS queries NOT to Apple/iCloud — potential C2 communication",
            "Direct IP Connections (No DNS)": "TCP to raw IPs without DNS lookup — malware often does this",
            "Suspicious TLDs (.tk/.ml/.ga/.cf)": "Free TLDs commonly used by malware for C2 domains",
            "HTTP (inspect for non-browser UA manually)": "Filter shows all HTTP; check User-Agent on each row for curl/wget/python — the parser doesn't read UA headers.",
            "Non-Standard Ports": "TCP traffic on ports other than the four well-known commodity ports (22/53/80/443)",
            "TCP (inspect for short-connection beacons manually)": "Filter shows all TCP; look for repeated short-duration connections to the same destination.",
            "DNS Tunneling (Long Queries)": "DNS packets >100 bytes — unusually-long names may hide exfiltrated data",
            "Large Outbound Transfers": "TCP packets >1000 bytes — bulk data movement",
            "ICMP with Payload (Covert Channel)": "ICMP packets >64 bytes — payload-bearing ICMP may be a covert channel",
            "HTTP (inspect for base64 payloads manually)": "Filter shows all HTTP; inspect each row's body for base64-encoded data.",
            "All TLS / SSL": "All TLS / SSL traffic",
            "TLS (inspect handshake/SNI/certs manually)": "Filter shows all TLS; inspect handshake records for SNI, certificate chain, and self-signed indicators.",
            "TCP (inspect for SYN-flood patterns manually)": "Filter shows all TCP; multiple SYN packets to different ports indicates scanning.",
            "ARP Requests (Host Discovery)": "ARP requests can indicate network reconnaissance",
            "ICMP Echo (Ping Sweep)": "ICMP echo requests across many hosts indicate ping sweeping",
            "SMB Enumeration": "SMB traffic + ports 445/139 — host/share enumeration",
            "SSH Traffic": "SSH can be used for tunneling and lateral movement"
        ]

        if let info = infoMap[filterName] {
            NSLog("[PacketAnalysis] Filter applied: \(filterName) — \(info)")
        }
    }

    @objc private func applyFilter(_ sender: Any) {
        setCurrentFilter(filterTextField.stringValue)
        reloadPackets()
        updateStatus()
    }

    @objc private func toggleAutoScroll(_ sender: NSButton) {
        autoScroll = sender.state == .on
    }

    @objc private func tableViewClicked(_ sender: Any) {
        let row = packetTableView.selectedRow
        guard row >= 0, row < displayedPackets.count else {
            detailTextView.string = ""
            return
        }

        selectedPacket = displayedPackets[row]
        updateDetailView()
    }

    // MARK: - Data Management

    private func addPacket(_ packet: CapturedPacket) {
        // PERFORMANCE: Buffer packets instead of updating UI for each one
        // This dramatically reduces CPU usage during high-traffic captures
        if passesFilter(packet) {
            packetBuffer.append(packet)

            // Flush immediately if buffer is full (prevent unbounded memory growth)
            if packetBuffer.count >= maxBufferSize {
                flushPacketBuffer()
            } else {
                // Start coalescing timer if not already running
                startBatchTimerIfNeeded()
            }
        }
    }

    private func startBatchTimerIfNeeded() {
        guard batchUpdateTimer == nil else { return }
        batchUpdateTimer = Timer.scheduledTimer(withTimeInterval: batchInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPacketBuffer() }
        }
    }

    private func flushPacketBuffer() {
        batchUpdateTimer?.invalidate()
        batchUpdateTimer = nil

        guard !packetBuffer.isEmpty else { return }

        // Batch append all buffered packets
        displayedPackets.append(contentsOf: packetBuffer)
        packetBuffer.removeAll(keepingCapacity: true)

        // Single UI update for entire batch
        packetTableView.reloadData()

        if autoScroll {
            packetTableView.scrollRowToVisible(displayedPackets.count - 1)
        }

        updateStatus()
    }

    private func reloadPackets() {
        let allPackets = PacketCaptureManager.shared.getAllPackets()
        displayedPackets = allPackets.filter { passesFilter($0) }
        packetTableView.reloadData()
        updateStatus()  // Refresh empty-state label + counters for the new filter
    }

    private func passesFilter(_ packet: CapturedPacket) -> Bool {
        // No filter set OR filter failed to compile (treat as no filter
        // so a malformed live-typed expression doesn't silently empty
        // the table — the operator sees everything pass through and
        // can spot the parse failure faster).
        guard let compiled = compiledFilter else { return true }
        return compiled.matches(packet)
    }

    /// Update the current filter string and recompile the AST. Call this
    /// from every site that previously set `currentFilter` directly so
    /// the compiled cache stays in sync.
    private func setCurrentFilter(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        currentFilter = trimmed
        compiledFilter = PacketFilter.compileOrNil(trimmed)
    }

    // MARK: - UI Updates

    private func updateButtonStates() {
        let isCapturing = PacketCaptureManager.shared.isCapturing
        startButton.isEnabled = !isCapturing
        stopButton.isEnabled = isCapturing
    }

    private func updateStatus() {
        let isCapturing = PacketCaptureManager.shared.isCapturing
        let total = PacketCaptureManager.shared.totalPacketCount
        let displayed = displayedPackets.count
        let bytes = PacketCaptureManager.shared.totalBytes

        let status = isCapturing ? "Capturing" : "Stopped"
        let bytesStr = formatBytes(bytes)
        let filterStr = currentFilter.isEmpty ? "" : " | Filter: \(currentFilter)"

        statusLabel.stringValue = "Packets: \(total) | Displayed: \(displayed) | \(bytesStr) | Status: \(status)\(filterStr)"
        statusLabel.textColor = isCapturing ? AppColors.accentNeonGreen : AppColors.statusStopped

        // Empty-state visibility: hide the placeholder as soon as we have rows
        // to show; otherwise pick the right message for the situation.
        if displayed > 0 {
            emptyStateLabel?.isHidden = true
        } else {
            emptyStateLabel?.isHidden = false
            if !currentFilter.isEmpty {
                emptyStateLabel?.stringValue = "No packets match the current filter.\nClear the filter to see all captured packets."
            } else if isCapturing {
                emptyStateLabel?.stringValue = "Capture is running. Waiting for traffic…"
            } else if total > 0 {
                emptyStateLabel?.stringValue = "Captured \(total) packet\(total == 1 ? "" : "s"). Cleared from view."
            } else {
                emptyStateLabel?.stringValue = "No packets captured yet.\nClick ▶ Start to begin capturing."
            }
        }
    }

    private func updateDetailView() {
        guard let packet = selectedPacket else {
            detailTextView.string = ""
            return
        }

        var details = ""

        // Frame info
        details += "═══════════════════════════════════════════════════════════════\n"
        details += "  FRAME #\(packet.number)\n"
        details += "═══════════════════════════════════════════════════════════════\n\n"

        details += "Timestamp: \(formatTimestamp(packet.timestamp))\n"
        details += "Length: \(packet.length) bytes\n"
        details += "Relative Time: \(String(format: "%.6f", packet.relativeTime)) sec\n\n"

        // Ethernet
        details += "┌─ Ethernet II ─────────────────────────────────────────────────\n"
        details += "│  Source MAC: \(packet.sourceMAC)\n"
        details += "│  Dest MAC: \(packet.destMAC)\n"
        details += "└───────────────────────────────────────────────────────────────\n\n"

        // IP (if available)
        if let srcIP = packet.sourceIP, let dstIP = packet.destIP {
            details += "┌─ Internet Protocol ───────────────────────────────────────────\n"
            details += "│  Source IP: \(srcIP)\n"
            details += "│  Dest IP: \(dstIP)\n"
            details += "└───────────────────────────────────────────────────────────────\n\n"
        }

        // Protocol
        details += "┌─ \(packet.protocol) ─────────────────────────────────────────────────────\n"
        details += "│  \(packet.info)\n"
        details += "└───────────────────────────────────────────────────────────────\n\n"

        // Decoded layers (if available from tshark)
        if !packet.decodedLayers.isEmpty {
            details += "\n─── Decoded Layers ───────────────────────────────────────────\n\n"
            for layer in packet.decodedLayers {
                details += "▸ \(layer.name)\n"
                for field in layer.fields.prefix(10) {
                    details += "    \(field.key): \(field.value)\n"
                }
                details += "\n"
            }
        }

        // Hex dump (first 256 bytes)
        if !packet.rawData.isEmpty {
            details += "\n─── Hex Dump ─────────────────────────────────────────────────\n\n"
            details += formatHexDump(packet.rawData.prefix(256))
        }

        detailTextView.string = details
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedPackets.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedPackets.count else { return nil }

        let packet = displayedPackets[row]
        let identifier = tableColumn?.identifier.rawValue ?? ""

        let cell = NSTextField(labelWithString: "")
        cell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        cell.textColor = NetworkProtocolColors.color(for: packet.protocol)
        cell.lineBreakMode = .byTruncatingTail

        switch identifier {
        case "number":
            cell.stringValue = "\(packet.number)"
        case "time":
            cell.stringValue = String(format: "%.6f", packet.relativeTime)
        case "source":
            cell.stringValue = packet.sourceIP ?? packet.sourceMAC
        case "destination":
            cell.stringValue = packet.destIP ?? packet.destMAC
        case "protocol":
            cell.stringValue = packet.protocol
            cell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        case "length":
            cell.stringValue = "\(packet.length)"
        case "info":
            cell.stringValue = packet.info
        default:
            break
        }

        return cell
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.2f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.2f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return formatter.string(from: date)
    }

    private func formatHexDump(_ data: Data.SubSequence) -> String {
        var result = ""
        let bytes = Array(data)

        for i in stride(from: 0, to: bytes.count, by: 16) {
            // Offset
            result += String(format: "%04X  ", i)

            // Hex bytes
            for j in 0..<16 {
                if i + j < bytes.count {
                    result += String(format: "%02X ", bytes[i + j])
                } else {
                    result += "   "
                }
                if j == 7 { result += " " }
            }

            result += " "

            // ASCII
            for j in 0..<16 {
                if i + j < bytes.count {
                    let byte = bytes[i + j]
                    if byte >= 32 && byte < 127 {
                        result += String(UnicodeScalar(byte))
                    } else {
                        result += "."
                    }
                }
            }

            result += "\n"
        }

        return result
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
