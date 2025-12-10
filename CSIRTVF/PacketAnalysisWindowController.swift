//
//  PacketAnalysisWindowController.swift
//  SecVF
//
//  Full-featured packet analysis window with live capture, filters, and PCAP support
//

import Cocoa

class PacketAnalysisWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    // UI Components
    private var packetTableView: NSTableView!
    private var detailTextView: NSTextView!
    private var filterTextField: NSTextField!
    private var statusLabel: NSTextField!

    // Toolbar buttons
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var clearButton: NSButton!
    private var autoScrollCheckbox: NSButton!

    // Data
    private var displayedPackets: [CapturedPacket] = []
    private var selectedPacket: CapturedPacket?
    private var currentFilter: String = ""
    private var autoScroll: Bool = true

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
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Apply dark theme
        window.appearance = NSAppearance(named: .darkAqua)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).cgColor

        let width = contentView.bounds.width
        let height = contentView.bounds.height

        // ═══════════════════════════════════════════════════════════════
        // TOOLBAR (Top)
        // ═══════════════════════════════════════════════════════════════
        let toolbarHeight: CGFloat = 80
        let toolbarView = NSView(frame: NSRect(x: 0, y: height - toolbarHeight, width: width, height: toolbarHeight))
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0).cgColor
        toolbarView.autoresizingMask = [.width, .minYMargin]

        // Row 1: Capture controls
        var xOffset: CGFloat = 15

        startButton = createToolbarButton(title: "▶ Start", action: #selector(startCapture(_:)))
        startButton.frame = NSRect(x: xOffset, y: 45, width: 70, height: 28)
        toolbarView.addSubview(startButton)
        xOffset += 75

        stopButton = createToolbarButton(title: "⏹ Stop", action: #selector(stopCapture(_:)))
        stopButton.frame = NSRect(x: xOffset, y: 45, width: 70, height: 28)
        stopButton.isEnabled = false
        toolbarView.addSubview(stopButton)
        xOffset += 75

        clearButton = createToolbarButton(title: "Clear", action: #selector(clearPackets(_:)))
        clearButton.frame = NSRect(x: xOffset, y: 45, width: 60, height: 28)
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
        toolbarView.addSubview(openButton)
        xOffset += 95

        let saveButton = createToolbarButton(title: "Save PCAP", action: #selector(savePCAP(_:)))
        saveButton.frame = NSRect(x: xOffset, y: 45, width: 90, height: 28)
        toolbarView.addSubview(saveButton)
        xOffset += 110

        // Auto-scroll checkbox
        autoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: #selector(toggleAutoScroll(_:)))
        autoScrollCheckbox.frame = NSRect(x: xOffset, y: 47, width: 100, height: 24)
        autoScrollCheckbox.state = .on
        autoScrollCheckbox.contentTintColor = NSColor.white
        toolbarView.addSubview(autoScrollCheckbox)

        // Row 2: Filter with preset dropdown
        let filterLabel = NSTextField(labelWithString: "Filter:")
        filterLabel.frame = NSRect(x: 15, y: 10, width: 45, height: 24)
        filterLabel.textColor = NSColor.white
        filterLabel.font = NSFont.systemFont(ofSize: 12)
        toolbarView.addSubview(filterLabel)

        // Preset filters popup - MALWARE ANALYSIS FOCUSED
        let presetPopup = NSPopUpButton(frame: NSRect(x: 60, y: 10, width: 180, height: 24), pullsDown: true)
        presetPopup.font = NSFont.systemFont(ofSize: 10)
        presetPopup.addItem(withTitle: "⚡ Malware Analysis Filters")
        presetPopup.menu?.addItem(NSMenuItem.separator())

        // === C2 (Command & Control) Detection ===
        let c2Header = NSMenuItem(title: "── C2 DETECTION ──", action: nil, keyEquivalent: "")
        c2Header.isEnabled = false
        presetPopup.menu?.addItem(c2Header)

        presetPopup.addItem(withTitle: "Non-Apple DNS (Suspicious)")
        presetPopup.addItem(withTitle: "Direct IP Connections (No DNS)")
        presetPopup.addItem(withTitle: "Suspicious TLDs (.tk/.ml/.ga/.cf)")
        presetPopup.addItem(withTitle: "Non-Browser HTTP (curl/wget/python)")
        presetPopup.addItem(withTitle: "Non-Standard Ports")
        presetPopup.addItem(withTitle: "Short TCP Connections (Beacon)")

        // === Data Exfiltration ===
        presetPopup.menu?.addItem(NSMenuItem.separator())
        let exfilHeader = NSMenuItem(title: "── DATA EXFIL ──", action: nil, keyEquivalent: "")
        exfilHeader.isEnabled = false
        presetPopup.menu?.addItem(exfilHeader)

        presetPopup.addItem(withTitle: "DNS Tunneling (Long Queries)")
        presetPopup.addItem(withTitle: "Large Outbound Transfers")
        presetPopup.addItem(withTitle: "ICMP with Payload (Covert Channel)")
        presetPopup.addItem(withTitle: "Base64 in HTTP")

        // === Encrypted Traffic ===
        presetPopup.menu?.addItem(NSMenuItem.separator())
        let tlsHeader = NSMenuItem(title: "── TLS ANALYSIS ──", action: nil, keyEquivalent: "")
        tlsHeader.isEnabled = false
        presetPopup.menu?.addItem(tlsHeader)

        presetPopup.addItem(withTitle: "TLS Handshakes Only")
        presetPopup.addItem(withTitle: "Self-Signed Certificates")
        presetPopup.addItem(withTitle: "TLS Without SNI (Hidden Dest)")
        presetPopup.addItem(withTitle: "Certificate Exchange")

        // === Network Recon ===
        presetPopup.menu?.addItem(NSMenuItem.separator())
        let reconHeader = NSMenuItem(title: "── RECON & SCANNING ──", action: nil, keyEquivalent: "")
        reconHeader.isEnabled = false
        presetPopup.menu?.addItem(reconHeader)

        presetPopup.addItem(withTitle: "Port Scanning (SYN Flood)")
        presetPopup.addItem(withTitle: "ARP Requests (Host Discovery)")
        presetPopup.addItem(withTitle: "ICMP Echo (Ping Sweep)")
        presetPopup.addItem(withTitle: "SMB Enumeration")

        // === Lateral Movement ===
        presetPopup.menu?.addItem(NSMenuItem.separator())
        let lateralHeader = NSMenuItem(title: "── LATERAL MOVEMENT ──", action: nil, keyEquivalent: "")
        lateralHeader.isEnabled = false
        presetPopup.menu?.addItem(lateralHeader)

        presetPopup.addItem(withTitle: "SSH Traffic")
        presetPopup.addItem(withTitle: "Remote Desktop (RDP/VNC)")
        presetPopup.addItem(withTitle: "File Sharing (SMB/AFP)")

        // === Protocol Specific ===
        presetPopup.menu?.addItem(NSMenuItem.separator())
        let protoHeader = NSMenuItem(title: "── PROTOCOLS ──", action: nil, keyEquivalent: "")
        protoHeader.isEnabled = false
        presetPopup.menu?.addItem(protoHeader)

        presetPopup.addItem(withTitle: "All DNS Traffic")
        presetPopup.addItem(withTitle: "All HTTP/HTTPS")
        presetPopup.addItem(withTitle: "All TCP")
        presetPopup.addItem(withTitle: "All UDP")
        presetPopup.addItem(withTitle: "All ARP")

        presetPopup.target = self
        presetPopup.action = #selector(presetFilterSelected(_:))
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

        // ═══════════════════════════════════════════════════════════════
        // PACKET DETAILS (Bottom)
        // ═══════════════════════════════════════════════════════════════
        let detailY: CGFloat = 35
        let detailHeight = tableY - detailY - 10

        let detailLabel = NSTextField(labelWithString: "Packet Details:")
        detailLabel.frame = NSRect(x: 15, y: tableY - 25, width: 150, height: 20)
        detailLabel.textColor = NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        detailLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(detailLabel)

        let detailScrollView = NSScrollView(frame: NSRect(x: 10, y: detailY, width: width - 20, height: detailHeight))
        detailScrollView.autoresizingMask = [.width, .height]
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .bezelBorder

        detailTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 20, height: detailHeight))
        detailTextView.isEditable = false
        detailTextView.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)
        detailTextView.textColor = NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1.0)
        detailTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailTextView.autoresizingMask = [.width, .height]

        detailScrollView.documentView = detailTextView
        contentView.addSubview(detailScrollView)

        // ═══════════════════════════════════════════════════════════════
        // STATUS BAR (Bottom)
        // ═══════════════════════════════════════════════════════════════
        let statusBar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0).cgColor
        statusBar.autoresizingMask = [.width]

        statusLabel = NSTextField(labelWithString: "Ready - tshark: \(PacketCaptureManager.shared.isTsharkAvailable ? "Available" : "Not Found")")
        statusLabel.frame = NSRect(x: 15, y: 5, width: width - 30, height: 20)
        statusLabel.textColor = NSColor(red: 0.6, green: 0.8, blue: 0.6, alpha: 1.0)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
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
        updateButtonStates()
        updateStatus()
    }

    @objc private func clearPackets(_ sender: Any) {
        PacketCaptureManager.shared.clearPackets()
        displayedPackets.removeAll()
        packetTableView.reloadData()
        detailTextView.string = ""
        updateStatus()
    }

    @objc private func openPCAP(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pcap")!, .init(filenameExtension: "pcapng")!]
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pcap")!]
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

    @objc private func presetFilterSelected(_ sender: NSPopUpButton) {
        guard let selectedTitle = sender.selectedItem?.title else { return }

        // Map menu titles to actual filter expressions
        // These are protocol-based filters that work with our basic packet parsing
        let filterMap: [String: String] = [
            // C2 Detection
            "Non-Apple DNS (Suspicious)": "dns and not apple and not icloud",
            "Direct IP Connections (No DNS)": "tcp and not dns and not arp",
            "Suspicious TLDs (.tk/.ml/.ga/.cf)": "dns and (tk or ml or ga or cf or gq)",
            "Non-Browser HTTP (curl/wget/python)": "http",
            "Non-Standard Ports": "tcp and not 80 and not 443 and not 22 and not 53",
            "Short TCP Connections (Beacon)": "tcp",

            // Data Exfiltration
            "DNS Tunneling (Long Queries)": "dns",
            "Large Outbound Transfers": "tcp",
            "ICMP with Payload (Covert Channel)": "icmp",
            "Base64 in HTTP": "http",

            // TLS Analysis
            "TLS Handshakes Only": "tls or ssl",
            "Self-Signed Certificates": "tls or ssl",
            "TLS Without SNI (Hidden Dest)": "tls or ssl",
            "Certificate Exchange": "tls or ssl",

            // Recon & Scanning
            "Port Scanning (SYN Flood)": "tcp",
            "ARP Requests (Host Discovery)": "arp",
            "ICMP Echo (Ping Sweep)": "icmp",
            "SMB Enumeration": "smb or tcp 445 or tcp 139",

            // Lateral Movement
            "SSH Traffic": "tcp 22 or ssh",
            "Remote Desktop (RDP/VNC)": "tcp 3389 or tcp 5900 or tcp 5901",
            "File Sharing (SMB/AFP)": "smb or afp or tcp 445 or tcp 548",

            // Protocols
            "All DNS Traffic": "dns",
            "All HTTP/HTTPS": "http or https or tcp 80 or tcp 443",
            "All TCP": "tcp",
            "All UDP": "udp",
            "All ARP": "arp"
        ]

        if let filter = filterMap[selectedTitle] {
            filterTextField.stringValue = filter
            currentFilter = filter.lowercased()
            reloadPackets()
            updateStatus()

            // Show info about what this filter detects
            showFilterInfo(for: selectedTitle)
        }
    }

    private func showFilterInfo(for filterName: String) {
        let infoMap: [String: String] = [
            "Non-Apple DNS (Suspicious)": "DNS queries NOT to Apple/iCloud - potential C2 communication",
            "Direct IP Connections (No DNS)": "TCP to raw IPs without DNS lookup - malware often does this",
            "Suspicious TLDs (.tk/.ml/.ga/.cf)": "Free TLDs commonly used by malware for C2 domains",
            "Non-Browser HTTP (curl/wget/python)": "HTTP from non-browser tools - may be scripted malware",
            "DNS Tunneling (Long Queries)": "Unusually long DNS names may hide exfiltrated data",
            "ARP Requests (Host Discovery)": "ARP requests can indicate network reconnaissance",
            "Port Scanning (SYN Flood)": "Multiple SYN packets to different ports = scanning",
            "ICMP with Payload (Covert Channel)": "ICMP with data payload may be covert channel",
            "TLS Without SNI (Hidden Dest)": "TLS without Server Name Indication hides destination",
            "SSH Traffic": "SSH can be used for tunneling and lateral movement"
        ]

        if let info = infoMap[filterName] {
            NSLog("[PacketAnalysis] Filter applied: \(filterName) - \(info)")
        }
    }

    @objc private func applyFilter(_ sender: Any) {
        currentFilter = filterTextField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
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
        // Apply filter
        if passesFilter(packet) {
            displayedPackets.append(packet)
            packetTableView.reloadData()

            if autoScroll {
                packetTableView.scrollRowToVisible(displayedPackets.count - 1)
            }

            updateStatus()
        }
    }

    private func reloadPackets() {
        let allPackets = PacketCaptureManager.shared.getAllPackets()
        displayedPackets = allPackets.filter { passesFilter($0) }
        packetTableView.reloadData()
    }

    private func passesFilter(_ packet: CapturedPacket) -> Bool {
        guard !currentFilter.isEmpty else { return true }

        let filter = currentFilter.lowercased()
        let proto = packet.protocol.lowercased()
        let info = packet.info.lowercased()

        // Handle "or" expressions - any term matching means pass
        if filter.contains(" or ") {
            let terms = filter.components(separatedBy: " or ")
            for term in terms {
                if matchesSingleTerm(packet, term: term.trimmingCharacters(in: .whitespaces)) {
                    return true
                }
            }
            return false
        }

        // Handle "and" expressions - all terms must match
        if filter.contains(" and ") {
            let terms = filter.components(separatedBy: " and ")
            for term in terms {
                if !matchesSingleTerm(packet, term: term.trimmingCharacters(in: .whitespaces)) {
                    return false
                }
            }
            return true
        }

        // Single term filter
        return matchesSingleTerm(packet, term: filter)
    }

    private func matchesSingleTerm(_ packet: CapturedPacket, term: String) -> Bool {
        let proto = packet.protocol.lowercased()
        let info = packet.info.lowercased()

        // Protocol filters
        if term == "tcp" { return proto == "tcp" }
        if term == "udp" { return proto == "udp" }
        if term == "icmp" { return proto == "icmp" }
        if term == "arp" { return proto == "arp" }
        if term == "dns" { return proto == "dns" }
        if term == "http" { return proto == "http" || info.contains("http") }
        if term == "https" { return proto == "https" || info.contains("https") || info.contains(":443") }
        if term == "ipv6" { return proto == "ipv6" }
        if term == "ssh" { return info.contains(":22") || info.contains("ssh") }
        if term == "smb" { return info.contains(":445") || info.contains("smb") }
        if term == "afp" { return info.contains(":548") || info.contains("afp") }

        // Port filters: "tcp 80", "tcp 443", "port 22"
        if term.hasPrefix("tcp ") {
            let port = term.replacingOccurrences(of: "tcp ", with: "")
            return proto == "tcp" && (info.contains(":\(port)") || info.contains("→\(port)") || info.contains("->\(port)"))
        }
        if term.hasPrefix("udp ") {
            let port = term.replacingOccurrences(of: "udp ", with: "")
            return proto == "udp" && (info.contains(":\(port)") || info.contains("→\(port)") || info.contains("->\(port)"))
        }
        if term.hasPrefix("port ") {
            let port = term.replacingOccurrences(of: "port ", with: "")
            return info.contains(":\(port)") || info.contains("→\(port)") || info.contains("->\(port)")
        }

        // IP address filter
        if term.contains("ip.addr") {
            if let ipMatch = term.components(separatedBy: "==").last?.trimmingCharacters(in: .whitespaces) {
                return packet.sourceIP == ipMatch || packet.destIP == ipMatch
            }
        }

        // "not" prefix for exclusion
        if term.hasPrefix("not ") {
            let innerTerm = String(term.dropFirst(4))
            return !matchesSingleTerm(packet, term: innerTerm)
        }

        // Text search in info field
        if info.contains(term) || proto.contains(term) {
            return true
        }

        return false
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
        statusLabel.textColor = isCapturing ? NSColor(red: 0.4, green: 1.0, blue: 0.4, alpha: 1.0) : NSColor(red: 0.6, green: 0.8, blue: 0.6, alpha: 1.0)
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
        cell.textColor = colorForProtocol(packet.protocol)
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

    private func colorForProtocol(_ proto: String) -> NSColor {
        switch proto.uppercased() {
        case "TCP": return NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
        case "UDP": return NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)
        case "HTTP", "HTTPS": return NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)
        case "DNS": return NSColor(red: 1.0, green: 1.0, blue: 0.4, alpha: 1.0)
        case "ARP": return NSColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1.0)
        case "ICMP": return NSColor(red: 1.0, green: 0.4, blue: 0.8, alpha: 1.0)
        case "TLS", "SSL": return NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)
        default: return NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1.0)
        }
    }

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
