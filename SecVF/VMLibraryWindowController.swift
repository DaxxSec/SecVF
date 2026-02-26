//
//  VMLibraryWindowController.swift
//  SecVF
//

import Cocoa
import Virtualization

@MainActor
class VMLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    @IBOutlet weak var tableView: NSTableView?
    @IBOutlet weak var startButton: NSButton?
    @IBOutlet weak var newButton: NSButton?
    @IBOutlet weak var deleteButton: NSButton?
    @IBOutlet weak var renameButton: NSButton?
    @IBOutlet weak var cloneButton: NSButton?
    @IBOutlet weak var importButton: NSButton?
    @IBOutlet weak var configureButton: NSButton?

    private var vmManager = VMManager.shared
    var selectedVM: VMConfiguration?
    private var statusBar: NSView?
    private var statusLabel: NSTextField?
    private var runningVMsContainer: NSStackView?
    private var networkVisualizationView: NetworkTrafficView?
    private var statsUpdateTimer: Timer?

    // Packet Log Panel
    private var packetLogPanel: NSView?
    private var packetLogTabControl: NSSegmentedControl?
    private var packetVMFilterControl: NSSegmentedControl?
    private var packetListContainer: NSScrollView?
    private var protocolStatsContainer: NSView?
    private var packetAnalysisWindowController: PacketAnalysisWindowController?
    private var currentVMFilter: String = "macOS"  // Default to macOS packets
    private var filterARPEnabled: Bool = true  // Filter ARP by default
    private var arpFilteredCount: Int = 0
    private var arpFilterCountLabel: NSTextField?

    override var windowNibName: NSNib.Name? {
        return "VMLibraryWindow"
    }

    deinit {
        // Clean up timer and notification observers to prevent memory leaks
        statsUpdateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        // Set window delegate to handle close button
        window?.delegate = self

        // Ensure window stays in front
        window?.level = .normal
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Apply dark theme, add sidebar, and add status bar
        applyDarkTheme()
        addSidebar()
        addStatusBar()

        // Configure table view
        tableView?.dataSource = self
        tableView?.delegate = self
        tableView?.target = self
        tableView?.doubleAction = #selector(startVM(_:))

        // Load VMs asynchronously to avoid blocking main thread
        vmManager.initializeAsync { [weak self] in
            guard let self = self else { return }
            self.tableView?.reloadData()
            self.refreshStatusBar()
        }

        // Force the table to use view-based mode
        tableView?.rowSizeStyle = .default

        // Register for VM status change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVMStatusChanged(_:)),
            name: .vmStatusChanged,
            object: nil
        )

        // Update button states
        updateButtonStates()

        // Reload data
        tableView?.reloadData()
    }

    // MARK: - Dark Theme & Sidebar

    private func applyDarkTheme() {
        guard let window = window, let contentView = window.contentView else { return }

        // Set window appearance to dark
        window.appearance = NSAppearance(named: .darkAqua)

        // Cybersecurity dark background - deep black
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor

        // Style table view with dark theme - darker grey
        tableView?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
        tableView?.enclosingScrollView?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)
        tableView?.gridColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.3)  // Subtle cyan grid

        // Style toolbar buttons to match session panel
        styleToolbarButtons()
    }

    private func styleToolbarButtons() {
        let buttons: [NSButton?] = [newButton, startButton, deleteButton, renameButton, cloneButton, importButton, configureButton]

        for button in buttons.compactMap({ $0 }) {
            let title = button.title
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = AppColors.backgroundButton.cgColor
            button.layer?.borderColor = AppColors.accentCyan.withAlphaComponent(0.5).cgColor
            button.layer?.borderWidth = 1.0
            button.layer?.cornerRadius = 5
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: AppColors.accentCyan,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ])
        }
    }

    private func addSidebar() {
        guard let window = window, let contentView = window.contentView else { return }

        let sidebarWidth: CGFloat = 220

        // Create sidebar view - full height
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: contentView.bounds.height))
        sidebar.autoresizingMask = [.height]
        sidebar.wantsLayer = true

        // Cybersecurity gradient - dark grey to black with blue tint
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = sidebar.bounds
        gradientLayer.colors = [
            NSColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1.0).cgColor,  // Deep black
            NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0).cgColor   // Charcoal with blue tint
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        sidebar.layer?.addSublayer(gradientLayer)

        // Logo - CENTERED in sidebar
        let logoWidth: CGFloat = 170
        let logoHeight: CGFloat = 120
        let logoX = (sidebarWidth - logoWidth) / 2  // Center horizontally
        let logoView = NSImageView(frame: NSRect(x: logoX, y: sidebar.bounds.height - 130, width: logoWidth, height: logoHeight))
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.image = createStylizedLogo()
        logoView.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]
        sidebar.addSubview(logoView)

        // Title - Two-tone: "Sec" in light gray, "VF" in medium gray - CENTERED
        let titleLabel = NSTextField()
        titleLabel.frame = NSRect(x: 0, y: sidebar.bounds.height - 170, width: sidebarWidth, height: 35)
        titleLabel.alignment = .center
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.autoresizingMask = [.minYMargin, .width]

        // Create attributed string with two colors and center alignment
        let attributedTitle = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .heavy)

        // Create paragraph style for centering
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // "Sec" in light gray
        let secPart = NSAttributedString(string: "Sec", attributes: [
            .font: font,
            .foregroundColor: NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(secPart)

        // "VF" in medium gray
        let vfPart = NSAttributedString(string: "VF", attributes: [
            .font: font,
            .foregroundColor: NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(vfPart)

        titleLabel.attributedStringValue = attributedTitle
        sidebar.addSubview(titleLabel)

        // Subtitle - Light gray - CENTERED
        let subtitleLabel = NSTextField(labelWithString: "Security Virtualization Framework")
        subtitleLabel.frame = NSRect(x: 0, y: sidebar.bounds.height - 195, width: sidebarWidth, height: 20)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        subtitleLabel.textColor = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)
        subtitleLabel.isBordered = false
        subtitleLabel.isEditable = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(subtitleLabel)

        // Separator line
        let separator1 = createSeparator(y: sidebar.bounds.height - 220, width: sidebarWidth)
        separator1.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(separator1)

        // Stats/Info below title - Medium gray accents - CENTERED
        let statsLabel = NSTextField(labelWithString: "▸ Malware Analysis\n▸ Isolated Sandbox\n▸ Virtual Networking")
        statsLabel.frame = NSRect(x: 0, y: sidebar.bounds.height - 310, width: sidebarWidth, height: 80)
        statsLabel.alignment = .center
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        statsLabel.textColor = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.9)  // Medium gray
        statsLabel.isBordered = false
        statsLabel.isEditable = false
        statsLabel.drawsBackground = false
        statsLabel.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(statsLabel)

        // Separator line above developer info
        let separator2 = createSeparator(y: 155, width: sidebarWidth)
        separator2.autoresizingMask = [.maxYMargin, .width]
        sidebar.addSubview(separator2)

        // Framework info section at bottom - CENTERED
        let infoY: CGFloat = 115
        addInfoLabel(to: sidebar, text: "Built on", y: infoY, bold: false, width: sidebarWidth)
        addInfoLabel(to: sidebar, text: "Apple Virtualization Framework", y: infoY - 28, bold: true, width: sidebarWidth)
        addInfoLabel(to: sidebar, text: "github.com/ItzDaxxy/SecVF", y: infoY - 58, bold: false, color: NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0), width: sidebarWidth)

        // Add sidebar to window
        contentView.addSubview(sidebar, positioned: .above, relativeTo: nil)

        // Adjust existing content to make room for sidebar
        adjustContentForSidebar(sidebarWidth: sidebarWidth)
    }

    private func createProtocolLegend(width: CGFloat, height: CGFloat) -> NSView {
        let legendView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        legendView.wantsLayer = true
        legendView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).cgColor
        legendView.layer?.cornerRadius = 6
        legendView.layer?.borderWidth = 1
        legendView.layer?.borderColor = NSColor(red: 0.0, green: 0.5, blue: 0.7, alpha: 0.3).cgColor

        // Legend title
        let titleLabel = NSTextField(labelWithString: "⚡ PROTOCOL COLORS")
        titleLabel.frame = NSRect(x: 8, y: height - 18, width: width - 16, height: 14)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 1.0)
        legendView.addSubview(titleLabel)

        // Protocol colors - matching the packet log colors
        let protocols: [(String, NSColor)] = [
            ("TCP", NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)),     // Cyan
            ("UDP", NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)),     // Green
            ("DNS", NSColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1.0)),     // Yellow
            ("HTTP", NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)),    // Orange
            ("ARP", NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0)),     // Gray
            ("ICMP", NSColor(red: 1.0, green: 0.5, blue: 0.5, alpha: 1.0)),    // Red/Pink
            ("IPv6", NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)),    // Purple
            ("TLS", NSColor(red: 0.3, green: 1.0, blue: 0.8, alpha: 1.0))      // Teal
        ]

        let colWidth = (width - 16) / 2
        let rowHeight: CGFloat = 14
        var col = 0
        var row = 0

        for (proto, color) in protocols {
            let x = 8 + CGFloat(col) * colWidth
            let y = height - 34 - CGFloat(row) * rowHeight

            // Color dot
            let dot = NSView(frame: NSRect(x: x, y: y + 3, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 4
            legendView.addSubview(dot)

            // Protocol name
            let label = NSTextField(labelWithString: proto)
            label.frame = NSRect(x: x + 12, y: y, width: colWidth - 16, height: 12)
            label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            label.textColor = color
            legendView.addSubview(label)

            col += 1
            if col >= 2 {
                col = 0
                row += 1
            }
        }

        return legendView
    }

    private func createStylizedLogo() -> NSImage {
        // Cybersecurity/hacker themed logo matching splash screen
        let size = CGSize(width: 170, height: 120)
        let image = NSImage(size: size)

        image.lockFocus()

        let centerX = size.width / 2
        let centerY = size.height / 2

        // Hexagonal border (cybersecurity theme)
        let hexPath = NSBezierPath()
        let hexRadius: CGFloat = 42
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3.0
            let x = centerX + hexRadius * cos(angle)
            let y = centerY + hexRadius * sin(angle)
            if i == 0 {
                hexPath.move(to: CGPoint(x: x, y: y))
            } else {
                hexPath.line(to: CGPoint(x: x, y: y))
            }
        }
        hexPath.close()
        hexPath.lineWidth = 2.5

        // Neon cyan stroke
        NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).setStroke()
        hexPath.stroke()

        // Digital lock icon in center
        let lockWidth: CGFloat = 20
        let lockHeight: CGFloat = 24
        let lockX = centerX - lockWidth / 2
        let lockY = centerY - lockHeight / 2

        // Lock body
        let lockBody = NSBezierPath(roundedRect: NSRect(x: lockX, y: lockY, width: lockWidth, height: lockHeight * 0.6), xRadius: 2, yRadius: 2)
        NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.8).setFill()
        lockBody.fill()

        // Lock shackle (top arc)
        let shacklePath = NSBezierPath()
        shacklePath.appendArc(
            withCenter: CGPoint(x: centerX, y: lockY + lockHeight * 0.6),
            radius: lockWidth * 0.35,
            startAngle: 0,
            endAngle: 180,
            clockwise: false
        )
        shacklePath.lineWidth = 3.0
        NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0).setStroke()
        shacklePath.stroke()

        // Keyhole
        let keyholePath = NSBezierPath(ovalIn: NSRect(x: centerX - 2, y: lockY + 5, width: 4, height: 4))
        let keyholeSlot = NSBezierPath(rect: NSRect(x: centerX - 1, y: lockY + 2, width: 2, height: 5))
        NSColor.black.setFill()
        keyholePath.fill()
        keyholeSlot.fill()

        // Circuit board pattern in corners (hacker aesthetic)
        NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.4).setStroke()

        // Top-left circuit
        let circuit1 = NSBezierPath()
        circuit1.move(to: CGPoint(x: 25, y: 85))
        circuit1.line(to: CGPoint(x: 45, y: 85))
        circuit1.line(to: CGPoint(x: 45, y: 75))
        circuit1.lineWidth = 1.2
        circuit1.stroke()

        // Draw nodes
        NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 23, y: 83, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 43, y: 83, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 43, y: 73, width: 4, height: 4)).fill()

        // Bottom-right circuit
        let circuit2 = NSBezierPath()
        circuit2.move(to: CGPoint(x: 145, y: 35))
        circuit2.line(to: CGPoint(x: 125, y: 35))
        circuit2.line(to: CGPoint(x: 125, y: 45))
        circuit2.lineWidth = 1.2
        NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.4).setStroke()
        circuit2.stroke()

        NSColor(red: 0.0, green: 1.0, blue: 0.5, alpha: 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: 143, y: 33, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 123, y: 33, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 123, y: 43, width: 4, height: 4)).fill()

        image.unlockFocus()
        return image
    }

    private func createSeparator(y: CGFloat, width: CGFloat) -> NSBox {
        let separator = NSBox(frame: NSRect(x: 20, y: y, width: width - 40, height: 1))
        separator.boxType = .separator
        separator.fillColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.3)  // Subtle cyan glow
        return separator
    }

    private func addInfoLabel(to view: NSView, text: String, y: CGFloat, bold: Bool, color: NSColor = NSColor(white: 0.8, alpha: 1.0), width: CGFloat = 220) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 0, y: y, width: width, height: 20)
        label.alignment = .center
        label.font = bold ? NSFont.systemFont(ofSize: 13, weight: .bold) : NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.autoresizingMask = [.minYMargin, .width]
        view.addSubview(label)
    }

    private func adjustContentForSidebar(sidebarWidth: CGFloat) {
        guard let window = window, let contentView = window.contentView else { return }

        let activePanelWidth: CGFloat = 220
        let buttonRowHeight: CGFloat = 50
        let padding: CGFloat = 15
        let packetPanelHeight: CGFloat = 180  // Horizontal packet panel below table

        // Set window to proper size
        let minWidth: CGFloat = sidebarWidth + 680 + activePanelWidth + padding * 3
        let minHeight: CGFloat = 600  // Increased to accommodate packet panel
        window.minSize = NSSize(width: minWidth, height: minHeight)

        // Set default window size on launch
        var windowFrame = window.frame
        let defaultWidth: CGFloat = 1150
        let defaultHeight: CGFloat = 650  // Taller default
        if windowFrame.size.width < defaultWidth || windowFrame.size.height < defaultHeight {
            windowFrame.size.width = defaultWidth
            windowFrame.size.height = defaultHeight
            if let screen = window.screen {
                windowFrame.origin.x = (screen.visibleFrame.width - defaultWidth) / 2 + screen.visibleFrame.origin.x
                windowFrame.origin.y = (screen.visibleFrame.height - defaultHeight) / 2 + screen.visibleFrame.origin.y
            }
            window.setFrame(windowFrame, display: true, animate: false)
        }

        let contentWidth = contentView.bounds.width
        let contentHeight = contentView.bounds.height

        // Calculate areas - table above packet panel
        let tableX = sidebarWidth + padding
        let tableWidth = contentWidth - sidebarWidth - activePanelWidth - padding * 3
        let tableY = buttonRowHeight + padding + packetPanelHeight + padding  // Above packet panel
        let tableHeight = contentHeight - tableY - padding

        // Position the table scroll view
        if let scrollView = tableView?.enclosingScrollView {
            scrollView.frame = NSRect(x: tableX, y: tableY, width: tableWidth, height: tableHeight)
            scrollView.autoresizingMask = [.width, .height]
            scrollView.wantsLayer = true
            scrollView.layer?.borderWidth = 1
            scrollView.layer?.borderColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.4).cgColor
            scrollView.layer?.cornerRadius = 6
        }

        // Position buttons at the bottom, centered in the table area
        let buttons: [NSButton?] = [newButton, deleteButton, renameButton, cloneButton, importButton, configureButton, startButton]
        let buttonWidth: CGFloat = 80
        let buttonSpacing: CGFloat = 10
        let visibleButtons = buttons.compactMap { $0 }
        let totalButtonsWidth = CGFloat(visibleButtons.count) * buttonWidth + CGFloat(visibleButtons.count - 1) * buttonSpacing
        var buttonX = tableX + (tableWidth - totalButtonsWidth) / 2

        for button in visibleButtons {
            button.frame = NSRect(x: buttonX, y: padding, width: buttonWidth, height: 32)
            button.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]
            buttonX += buttonWidth + buttonSpacing
        }
    }

    private func addStatusBar() {
        guard let window = window, let contentView = window.contentView else { return }

        let sidebarWidth: CGFloat = 220
        let activePanelWidth: CGFloat = 220
        let buttonRowHeight: CGFloat = 50
        let padding: CGFloat = 15
        let packetPanelHeight: CGFloat = 180

        let contentWidth = contentView.bounds.width
        let contentHeight = contentView.bounds.height

        // ═══════════════════════════════════════════════════════════════
        // ACTIVE VMs PANEL (Right side - same height as VM table)
        // ═══════════════════════════════════════════════════════════════
        let activePanelX = contentWidth - activePanelWidth - padding
        let activePanelY = buttonRowHeight + padding + packetPanelHeight + padding  // Same as table Y
        let activePanelHeight = contentHeight - activePanelY - padding

        let runningVMsPanel = NSView(frame: NSRect(x: activePanelX, y: activePanelY, width: activePanelWidth, height: activePanelHeight))
        runningVMsPanel.wantsLayer = true
        runningVMsPanel.autoresizingMask = [.minXMargin, .height]

        // Dark background with cyan border
        runningVMsPanel.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor
        runningVMsPanel.layer?.cornerRadius = 8
        runningVMsPanel.layer?.borderWidth = 1
        runningVMsPanel.layer?.borderColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.4).cgColor

        // Panel title
        let titleLabel = NSTextField(labelWithString: "● ACTIVE VMs")
        titleLabel.frame = NSRect(x: 12, y: activePanelHeight - 28, width: activePanelWidth - 24, height: 20)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)
        titleLabel.autoresizingMask = [.minYMargin]
        runningVMsPanel.addSubview(titleLabel)
        statusLabel = titleLabel

        // Separator
        let separator = NSBox(frame: NSRect(x: 10, y: activePanelHeight - 38, width: activePanelWidth - 20, height: 1))
        separator.boxType = .separator
        separator.fillColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.3)
        separator.autoresizingMask = [.minYMargin]
        runningVMsPanel.addSubview(separator)

        // Scrollable container for running VM items
        let scrollView = NSScrollView(frame: NSRect(x: 8, y: 8, width: activePanelWidth - 16, height: activePanelHeight - 55))
        scrollView.autoresizingMask = [.height]
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: activePanelWidth - 16, height: activePanelHeight - 55))
        stackView.orientation = .vertical
        stackView.spacing = 10
        stackView.alignment = .centerX
        stackView.distribution = .gravityAreas
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        scrollView.documentView = stackView
        runningVMsPanel.addSubview(scrollView)
        runningVMsContainer = stackView

        // Placeholder when no VMs running
        let placeholder = NSTextField(labelWithString: "No active VMs.\n\nSelect a VM and\nclick Start.")
        placeholder.frame = NSRect(x: 12, y: activePanelHeight / 2 - 30, width: activePanelWidth - 24, height: 60)
        placeholder.font = NSFont.systemFont(ofSize: 10)
        placeholder.textColor = NSColor(white: 0.45, alpha: 1.0)
        placeholder.alignment = .center
        placeholder.isEditable = false
        placeholder.isBordered = false
        placeholder.drawsBackground = false
        placeholder.maximumNumberOfLines = 0
        placeholder.tag = 999
        placeholder.autoresizingMask = [.minYMargin, .maxYMargin]
        runningVMsPanel.addSubview(placeholder)

        contentView.addSubview(runningVMsPanel)
        statusBar = runningVMsPanel

        // ═══════════════════════════════════════════════════════════════
        // PACKET LOG PANEL (Horizontal - below VM Table, extends to Active VMs)
        // ═══════════════════════════════════════════════════════════════
        let packetPanelX = sidebarWidth + padding
        let packetPanelY = buttonRowHeight + padding
        let packetPanelWidth = contentWidth - sidebarWidth - activePanelWidth - padding * 2 - 5  // Reduced gap

        let packetPanel = NSView(frame: NSRect(x: packetPanelX, y: packetPanelY, width: packetPanelWidth, height: packetPanelHeight))
        packetPanel.wantsLayer = true
        packetPanel.autoresizingMask = [.width]

        // Dark background with yellow/orange border
        packetPanel.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor
        packetPanel.layer?.cornerRadius = 8
        packetPanel.layer?.borderWidth = 1
        packetPanel.layer?.borderColor = NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 0.4).cgColor

        // Panel title
        let packetTitle = NSTextField(labelWithString: "⚡ PACKET LOG")
        packetTitle.frame = NSRect(x: 12, y: packetPanelHeight - 28, width: 110, height: 20)
        packetTitle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        packetTitle.textColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        packetPanel.addSubview(packetTitle)

        // Tab control (Packets / Protocols) - next to title
        let tabControl = NSSegmentedControl(labels: ["Packets", "Protocols"], trackingMode: .selectOne, target: self, action: #selector(packetLogTabChanged(_:)))
        tabControl.frame = NSRect(x: 120, y: packetPanelHeight - 30, width: 130, height: 24)
        tabControl.selectedSegment = 0
        tabControl.segmentStyle = .texturedSquare
        packetPanel.addSubview(tabControl)
        packetLogTabControl = tabControl

        // VM Filter tabs (macOS / Kali / All) - to the right of Packets/Protocols
        let vmFilterControl = NSSegmentedControl(labels: ["macOS", "Kali", "All"], trackingMode: .selectOne, target: self, action: #selector(vmFilterChanged(_:)))
        vmFilterControl.frame = NSRect(x: 258, y: packetPanelHeight - 30, width: 140, height: 24)
        vmFilterControl.selectedSegment = 0  // Default to macOS
        vmFilterControl.segmentStyle = .texturedSquare
        vmFilterControl.setWidth(45, forSegment: 0)  // macOS
        vmFilterControl.setWidth(45, forSegment: 1)  // Kali
        vmFilterControl.setWidth(40, forSegment: 2)  // All
        packetPanel.addSubview(vmFilterControl)
        packetVMFilterControl = vmFilterControl

        // Filter ARP checkbox (checked by default)
        let arpCheckbox = NSButton(checkboxWithTitle: "Filter ARP", target: self, action: #selector(toggleARPFilter(_:)))
        arpCheckbox.frame = NSRect(x: 400, y: packetPanelHeight - 30, width: 80, height: 24)
        arpCheckbox.state = .on  // Checked by default
        arpCheckbox.font = NSFont.systemFont(ofSize: 10)
        arpCheckbox.contentTintColor = NSColor.white
        packetPanel.addSubview(arpCheckbox)

        // ARP filtered count label (yellow, compact format)
        let arpCountLabel = NSTextField(labelWithString: "(0)")
        arpCountLabel.frame = NSRect(x: 478, y: packetPanelHeight - 28, width: 45, height: 18)
        arpCountLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        arpCountLabel.textColor = NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)  // Yellow
        arpCountLabel.alignment = .left
        packetPanel.addSubview(arpCountLabel)
        arpFilterCountLabel = arpCountLabel

        // Open Full Analysis button - top right (styled to match toolbar)
        let openButton = NSButton(title: "Open Full Analysis", target: self, action: #selector(openPacketAnalysisWindow(_:)))
        openButton.frame = NSRect(x: packetPanelWidth - 140, y: packetPanelHeight - 32, width: 130, height: 26)
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        openButton.wantsLayer = true
        openButton.layer?.backgroundColor = AppColors.backgroundButton.cgColor
        openButton.layer?.borderColor = AppColors.accentCyan.withAlphaComponent(0.5).cgColor
        openButton.layer?.borderWidth = 1.0
        openButton.layer?.cornerRadius = 5
        openButton.contentTintColor = AppColors.accentCyan
        openButton.attributedTitle = NSAttributedString(string: "Open Full Analysis", attributes: [
            .foregroundColor: AppColors.accentCyan,
            .font: NSFont.systemFont(ofSize: 10, weight: .medium)
        ])
        openButton.autoresizingMask = [.minXMargin]
        packetPanel.addSubview(openButton)

        // Separator below header
        let packetSeparator = NSBox(frame: NSRect(x: 10, y: packetPanelHeight - 45, width: packetPanelWidth - 20, height: 1))
        packetSeparator.boxType = .separator
        packetSeparator.fillColor = NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 0.3)
        packetSeparator.autoresizingMask = [.width]
        packetPanel.addSubview(packetSeparator)

        // Packets list container - horizontal layout
        let packetsScrollView = NSScrollView(frame: NSRect(x: 8, y: 8, width: packetPanelWidth - 16, height: packetPanelHeight - 60))
        packetsScrollView.autoresizingMask = [.width]
        packetsScrollView.hasHorizontalScroller = false
        packetsScrollView.hasVerticalScroller = true
        packetsScrollView.autohidesScrollers = true
        packetsScrollView.drawsBackground = false
        packetsScrollView.borderType = .noBorder

        let packetsTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: packetPanelWidth - 16, height: packetPanelHeight - 60))
        packetsTextView.isEditable = false
        packetsTextView.drawsBackground = false
        packetsTextView.textColor = NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1.0)
        packetsTextView.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        packetsTextView.autoresizingMask = [.width]
        packetsScrollView.documentView = packetsTextView

        packetPanel.addSubview(packetsScrollView)
        packetListContainer = packetsScrollView

        // Protocol stats container (hidden by default)
        let protocolView = NSView(frame: NSRect(x: 8, y: 8, width: packetPanelWidth - 16, height: packetPanelHeight - 60))
        protocolView.wantsLayer = true
        protocolView.isHidden = true
        protocolView.autoresizingMask = [.width]
        packetPanel.addSubview(protocolView)
        protocolStatsContainer = protocolView

        contentView.addSubview(packetPanel)
        packetLogPanel = packetPanel

        // ═══════════════════════════════════════════════════════════════
        // PROTOCOL LEGEND PANEL (Right side - below Active VMs, same level as packet panel)
        // ═══════════════════════════════════════════════════════════════
        let legendPanelX = activePanelX
        let legendPanelY = buttonRowHeight + padding
        let legendPanelWidth = activePanelWidth
        let legendPanelHeight = packetPanelHeight

        let legendPanel = NSView(frame: NSRect(x: legendPanelX, y: legendPanelY, width: legendPanelWidth, height: legendPanelHeight))
        legendPanel.wantsLayer = true
        legendPanel.autoresizingMask = [.minXMargin]

        // Dark background with cyan border (matching Active VMs panel)
        legendPanel.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor
        legendPanel.layer?.cornerRadius = 8
        legendPanel.layer?.borderWidth = 1
        legendPanel.layer?.borderColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.4).cgColor

        // Add the protocol legend centered in the panel
        let legendHeight: CGFloat = 95
        let legendView = createProtocolLegend(width: legendPanelWidth - 16, height: legendHeight)
        legendView.frame = NSRect(x: 8, y: (legendPanelHeight - legendHeight) / 2, width: legendPanelWidth - 16, height: legendHeight)
        legendPanel.addSubview(legendView)

        contentView.addSubview(legendPanel)

        // Subscribe to packet capture notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePacketCaptured(_:)),
            name: .packetCaptured,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProtocolStatsUpdated(_:)),
            name: .protocolStatsUpdated,
            object: nil
        )
    }

    @objc private func packetLogTabChanged(_ sender: NSSegmentedControl) {
        let showPackets = sender.selectedSegment == 0
        packetListContainer?.isHidden = !showPackets
        protocolStatsContainer?.isHidden = showPackets

        if !showPackets {
            updateProtocolStatsDisplay()
        }
    }

    @objc private func vmFilterChanged(_ sender: NSSegmentedControl) {
        // Update filter based on selected segment
        switch sender.selectedSegment {
        case 0:
            currentVMFilter = "macOS"
        case 1:
            currentVMFilter = "Kali"
        case 2:
            currentVMFilter = "All"
        default:
            currentVMFilter = "All"
        }

        // Clear current display and refresh with filtered packets
        clearPacketLog()
        refreshPacketLogWithFilter()
    }

    @objc private func toggleARPFilter(_ sender: NSButton) {
        filterARPEnabled = sender.state == .on
        arpFilterCountLabel?.isHidden = !filterARPEnabled
        if !filterARPEnabled {
            arpFilteredCount = 0
            arpFilterCountLabel?.stringValue = "(0)"
        }
        // Refresh display with new filter setting
        clearPacketLog()
        refreshPacketLogWithFilter()
    }

    private func clearPacketLog() {
        guard let scrollView = packetListContainer,
              let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    private func refreshPacketLogWithFilter() {
        // Reset ARP counter when refreshing
        arpFilteredCount = 0

        // Get recent packets and display those matching the filter
        let recentPackets = PacketCaptureManager.shared.getRecentPackets(count: 100)
        for packet in recentPackets {
            if packetMatchesFilter(packet) {
                // Filter ARP packets if enabled
                if filterARPEnabled && packet.protocol.uppercased() == "ARP" {
                    arpFilteredCount += 1
                    continue
                }
                addPacketToMiniLog(packet)
            }
        }

        // Update the ARP filter count label
        arpFilterCountLabel?.stringValue = "(\(arpFilteredCount))"
    }

    private func packetMatchesFilter(_ packet: CapturedPacket) -> Bool {
        // tshark packets pass all filters since we can't determine source VM
        if packet.sourceVM.lowercased() == "tshark" {
            return true
        }

        switch currentVMFilter {
        case "macOS":
            return packet.sourceVM.lowercased().contains("mac")
        case "Kali":
            return packet.sourceVM.lowercased().contains("kali") ||
                   packet.sourceVM.lowercased().contains("linux") ||
                   packet.sourceVM.lowercased().contains("router")
        case "All":
            return true
        default:
            return true
        }
    }

    @objc private func openPacketAnalysisWindow(_ sender: Any) {
        if packetAnalysisWindowController == nil {
            packetAnalysisWindowController = PacketAnalysisWindowController()
        }
        packetAnalysisWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handlePacketCaptured(_ notification: Notification) {
        guard let packet = notification.userInfo?["packet"] as? CapturedPacket else { return }

        // Only display if packet matches current VM filter
        guard packetMatchesFilter(packet) else { return }

        // Filter ARP packets if enabled
        if filterARPEnabled && packet.protocol.uppercased() == "ARP" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.arpFilteredCount += 1
                self.arpFilterCountLabel?.stringValue = "(\(self.arpFilteredCount))"
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.addPacketToMiniLog(packet)
        }
    }

    @objc private func handleProtocolStatsUpdated(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.packetLogTabControl?.selectedSegment == 1 else { return }
            self.updateProtocolStatsDisplay()
        }
    }

    private func addPacketToMiniLog(_ packet: CapturedPacket) {
        guard let scrollView = packetListContainer,
              let textView = scrollView.documentView as? NSTextView else { return }

        // Format: "HH:MM:SS PROTO src→dst"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeStr = timeFormatter.string(from: packet.timestamp)

        let srcAddr = packet.sourceIP ?? packet.sourceMAC
        let dstAddr = packet.destIP ?? packet.destMAC

        // Truncate addresses for mini display
        let srcShort = srcAddr.count > 12 ? String(srcAddr.suffix(12)) : srcAddr
        let dstShort = dstAddr.count > 12 ? String(dstAddr.suffix(12)) : dstAddr

        let line = "\(timeStr) \(packet.protocol.padding(toLength: 5, withPad: " ", startingAt: 0))\n  \(srcShort)→\(dstShort)\n"

        // Create attributed string with protocol coloring
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NetworkProtocolColors.color(for: packet.protocol)
        ]

        let attrStr = NSAttributedString(string: line, attributes: attrs)

        // Append to text view
        textView.textStorage?.append(attrStr)

        // Keep only last ~50 lines (roughly 100 lines with 2-line format)
        if let storage = textView.textStorage, storage.length > 5000 {
            storage.deleteCharacters(in: NSRange(location: 0, length: 2500))
        }

        // Auto-scroll to bottom
        textView.scrollToEndOfDocument(nil)
    }

    private func updateProtocolStatsDisplay() {
        guard let container = protocolStatsContainer else { return }

        // Remove existing subviews
        container.subviews.forEach { $0.removeFromSuperview() }

        let stats = PacketCaptureManager.shared.getProtocolStats()

        var yOffset = container.bounds.height - 20

        for (_, stat) in stats.prefix(10).enumerated() {
            let label = NSTextField(labelWithString: "\(stat.protocol): \(stat.count)")
            label.frame = NSRect(x: 5, y: yOffset, width: container.bounds.width - 10, height: 16)
            label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            label.textColor = NetworkProtocolColors.color(for: stat.protocol)
            label.isBordered = false
            label.drawsBackground = false
            container.addSubview(label)

            yOffset -= 18
        }

        if stats.isEmpty {
            let noDataLabel = NSTextField(labelWithString: "No protocol data.\nStart capture to\nsee statistics.")
            noDataLabel.frame = NSRect(x: 5, y: container.bounds.height / 2 - 30, width: container.bounds.width - 10, height: 50)
            noDataLabel.font = NSFont.systemFont(ofSize: 10)
            noDataLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            noDataLabel.alignment = .center
            noDataLabel.maximumNumberOfLines = 0
            noDataLabel.isBordered = false
            noDataLabel.drawsBackground = false
            container.addSubview(noDataLabel)
        }
    }

    func updateStatusBar(runningVMs: [(vm: VMConfiguration, state: String)]) {
        guard let container = runningVMsContainer, let label = statusLabel else {
            return
        }

        // Update title with count
        let count = runningVMs.count
        label.stringValue = count > 0 ? "● ACTIVE VMs (\(count))" : "● ACTIVE VMs"

        // Clear existing VM status items
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Stop existing animation and timer
        networkVisualizationView?.stopAnimation()
        statsUpdateTimer?.invalidate()
        statsUpdateTimer = nil

        // Show/hide placeholder based on running VMs
        if let panel = statusBar {
            for subview in panel.subviews {
                if subview.tag == 999 {
                    subview.isHidden = !runningVMs.isEmpty
                }
            }
        }

        // Check if we have a router VM running with other VMs
        let routerVM = runningVMs.first { $0.vm.networkConfig.isRouter }
        let clientVMs = runningVMs.filter { !$0.vm.networkConfig.isRouter }
        let hasActiveNetwork = routerVM != nil && !clientVMs.isEmpty

        // Add status items with network visualization between router and clients
        var visualizationAdded = false

        for (index, (vm, state)) in runningVMs.enumerated() {
            let itemView = createVMStatusItem(vm: vm, state: state)
            container.addArrangedSubview(itemView)

            // Add network visualization after the router VM (between router and clients)
            if hasActiveNetwork && !visualizationAdded && vm.networkConfig.isRouter {
                let netView = NetworkTrafficView(frame: NSRect(x: 0, y: 0, width: 188, height: 120))
                netView.translatesAutoresizingMaskIntoConstraints = false
                netView.widthAnchor.constraint(equalToConstant: 188).isActive = true
                netView.heightAnchor.constraint(equalToConstant: 120).isActive = true
                netView.sourceVMName = clientVMs.first?.vm.name ?? "Client"
                netView.routerVMName = vm.name

                container.addArrangedSubview(netView)
                networkVisualizationView = netView
                netView.startAnimation()
                visualizationAdded = true

                // Start stats update timer
                startStatsUpdateTimer()
            }
            // Also handle case where router isn't first - add after first client
            else if hasActiveNetwork && !visualizationAdded && index == 0 && !vm.networkConfig.isRouter {
                let netView = NetworkTrafficView(frame: NSRect(x: 0, y: 0, width: 188, height: 120))
                netView.translatesAutoresizingMaskIntoConstraints = false
                netView.widthAnchor.constraint(equalToConstant: 188).isActive = true
                netView.heightAnchor.constraint(equalToConstant: 120).isActive = true
                netView.sourceVMName = vm.name
                netView.routerVMName = routerVM?.vm.name ?? "Router"

                container.addArrangedSubview(netView)
                networkVisualizationView = netView
                netView.startAnimation()
                visualizationAdded = true

                startStatsUpdateTimer()
            }
        }

        // Force layout update
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    private func startStatsUpdateTimer() {
        // PERFORMANCE: 2.0s interval is sufficient for stats display - 0.5s was excessive
        // Network stats don't change rapidly enough to warrant 2Hz updates
        statsUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer callback is nonisolated, dispatch to main actor
            Task { @MainActor in
                self?.updateNetworkStats()
            }
        }
    }

    private func updateNetworkStats() {
        guard let netView = networkVisualizationView else { return }

        let stats = VirtualNetworkSwitch.shared.getStatistics()

        // Stats are UInt64, need to cast properly
        let forwarded = (stats["packetsForwarded"] as? UInt64).map { Int($0) } ?? 0
        let broadcast = (stats["packetsBroadcast"] as? UInt64).map { Int($0) } ?? 0
        let ports = stats["connectedPorts"] as? Int ?? 0

        // Calculate total bytes from port stats (also UInt64)
        var totalBytes: UInt64 = 0
        if let portStats = stats["ports"] as? [[String: Any]] {
            for port in portStats {
                totalBytes += port["bytesRx"] as? UInt64 ?? 0
                totalBytes += port["bytesTx"] as? UInt64 ?? 0
            }
        }

        netView.updateStats(forwarded: forwarded, broadcast: broadcast, bytes: Int(totalBytes), ports: ports)
    }

    private func createVMStatusItem(vm: VMConfiguration, state: String) -> NSView {
        // Vertical card layout for each VM - fits in 200px wide panel
        let cardWidth: CGFloat = 188
        let cardHeight: CGFloat = 85  // Taller to fit network toggle

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).cgColor
        containerView.layer?.cornerRadius = 6
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.5).cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Store VM ID in layer name for button lookups (safer than hash)
        containerView.layer?.name = vm.id.uuidString

        // Size constraints
        containerView.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true

        // State color and icon
        let stateColor: NSColor
        let stateIcon: String
        switch state.lowercased() {
        case "running":
            stateColor = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)  // Neon green
            stateIcon = "▶"
        case "starting":
            stateColor = NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 1.0)  // Cyan
            stateIcon = "◐"
        case "paused":
            stateColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)  // Yellow
            stateIcon = "⏸"
        case "stopping":
            stateColor = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)  // Orange
            stateIcon = "◑"
        default:
            stateColor = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)  // Grey
            stateIcon = "●"
        }

        // VM name with status icon (top line)
        let nameLabel = NSTextField(labelWithString: "\(stateIcon) \(vm.name)")
        nameLabel.frame = NSRect(x: 8, y: cardHeight - 22, width: cardWidth - 16, height: 16)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = stateColor
        nameLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(nameLabel)

        // OS type label (second line, left side)
        let osLabel = NSTextField(labelWithString: vm.osType)
        osLabel.frame = NSRect(x: 8, y: cardHeight - 38, width: 50, height: 14)
        osLabel.font = NSFont.systemFont(ofSize: 9)
        osLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        containerView.addSubview(osLabel)

        // Network state label and colored button (second line, right side)
        let networkMode: String
        let networkColor: NSColor
        if vm.networkConfig.isRouter && vm.networkConfig.mode == .virtual {
            networkMode = "Router"
            networkColor = NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1.0) // Amber for router (monitoring)
        } else if vm.networkConfig.mode == .virtual {
            networkMode = "VSwitch"
            networkColor = NSColor(red: 0.0, green: 0.8, blue: 0.4, alpha: 1.0)   // Bright green for virtual switch (secure)
        } else {
            networkMode = "NAT"
            networkColor = NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1.0) // Red for NAT (less secure)
        }

        // "Network State:" label
        let netStateLabel = NSTextField(labelWithString: "Network:")
        netStateLabel.frame = NSRect(x: 60, y: cardHeight - 38, width: 50, height: 14)
        netStateLabel.font = NSFont.systemFont(ofSize: 8)
        netStateLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        containerView.addSubview(netStateLabel)

        // Network mode button with colored background
        let netButton = NSButton(frame: NSRect(x: 110, y: cardHeight - 40, width: 70, height: 18))
        netButton.title = networkMode
        netButton.bezelStyle = .roundRect
        netButton.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        netButton.controlSize = .mini
        netButton.wantsLayer = true
        netButton.layer?.backgroundColor = networkColor.withAlphaComponent(0.25).cgColor
        netButton.layer?.borderColor = networkColor.cgColor
        netButton.layer?.borderWidth = 1.5
        netButton.layer?.cornerRadius = 4
        netButton.contentTintColor = networkColor
        netButton.target = self
        netButton.action = #selector(toggleNetworkMode(_:))
        if vm.networkConfig.isRouter && vm.networkConfig.mode == .virtual {
            netButton.toolTip = "Router: Monitors all traffic (Virtual Switch + NAT passthrough)"
        } else if vm.networkConfig.mode == .virtual {
            netButton.toolTip = "Virtual Switch: Routes through router VM (monitored)"
        } else {
            netButton.toolTip = "NAT: Internet access (less secure)"
        }
        // Store VM ID in identifier
        netButton.identifier = NSUserInterfaceItemIdentifier(vm.id.uuidString)
        containerView.addSubview(netButton)

        // Action buttons row (bottom)
        let buttonY: CGFloat = 6
        let buttonHeight: CGFloat = 20
        let buttonWidth: CGFloat = 56
        let buttonSpacing: CGFloat = 4

        // Stop button
        let stopButton = NSButton(frame: NSRect(x: 8, y: buttonY, width: buttonWidth, height: buttonHeight))
        stopButton.title = "Stop"
        stopButton.bezelStyle = .roundRect
        stopButton.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stopVMFromStatusBar(_:))
        stopButton.identifier = NSUserInterfaceItemIdentifier(vm.id.uuidString)
        containerView.addSubview(stopButton)

        // Restart button
        let restartButton = NSButton(frame: NSRect(x: 8 + buttonWidth + buttonSpacing, y: buttonY, width: buttonWidth, height: buttonHeight))
        restartButton.title = "Restart"
        restartButton.bezelStyle = .roundRect
        restartButton.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        restartButton.controlSize = .small
        restartButton.target = self
        restartButton.action = #selector(restartVMFromStatusBar(_:))
        restartButton.identifier = NSUserInterfaceItemIdentifier(vm.id.uuidString)
        containerView.addSubview(restartButton)

        // Pause button
        let pauseButton = NSButton(frame: NSRect(x: 8 + (buttonWidth + buttonSpacing) * 2, y: buttonY, width: buttonWidth, height: buttonHeight))
        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .roundRect
        pauseButton.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        pauseButton.controlSize = .small
        pauseButton.target = self
        pauseButton.action = #selector(pauseVMFromStatusBar(_:))
        pauseButton.identifier = NSUserInterfaceItemIdentifier(vm.id.uuidString)
        containerView.addSubview(pauseButton)

        return containerView
    }

    private func findVMByIdentifier(_ identifier: NSUserInterfaceItemIdentifier?) -> VMConfiguration? {
        guard let idString = identifier?.rawValue,
              let uuid = UUID(uuidString: idString) else { return nil }
        return vmManager.virtualMachines.first { $0.id == uuid }
    }

    @objc private func stopVMFromStatusBar(_ sender: NSButton) {
        guard let vm = findVMByIdentifier(sender.identifier) else {
            NSLog("[VMLibrary] Stop: VM not found")
            return
        }
        NSLog("[VMLibrary] Stopping VM: \(vm.name)")
        NotificationCenter.default.post(name: .stopVM, object: vm)
    }

    private var vmRestartInProgress: Set<UUID> = []

    @objc private func restartVMFromStatusBar(_ sender: NSButton) {
        guard let vm = findVMByIdentifier(sender.identifier) else {
            NSLog("[VMLibrary] Restart: VM not found")
            return
        }

        // Guard against double-click spawning duplicate VMs
        guard !vmRestartInProgress.contains(vm.id) else {
            NSLog("[VMLibrary] Restart already in progress for: \(vm.name)")
            return
        }
        vmRestartInProgress.insert(vm.id)

        NSLog("[VMLibrary] Restarting VM: \(vm.name)")
        // Stop then start
        NotificationCenter.default.post(name: .stopVM, object: vm)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            NotificationCenter.default.post(name: .startVM, object: vm)
            self?.vmRestartInProgress.remove(vm.id)
        }
    }

    @objc private func pauseVMFromStatusBar(_ sender: NSButton) {
        guard let vm = findVMByIdentifier(sender.identifier) else {
            NSLog("[VMLibrary] Pause: VM not found")
            return
        }
        NSLog("[VMLibrary] Pause/Resume VM: \(vm.name)")
        NotificationCenter.default.post(name: .pauseVM, object: vm)
    }

    @objc private func toggleNetworkMode(_ sender: NSButton) {
        guard var vm = findVMByIdentifier(sender.identifier) else {
            NSLog("[VMLibrary] Toggle network: VM not found")
            return
        }

        // Toggle network mode
        let newMode: NetworkMode = vm.networkConfig.mode == .virtual ? .nat : .virtual
        vm.networkConfig.mode = newMode

        // Save configuration
        do {
            try vmManager.saveVMConfiguration(vm)
            NSLog("[VMLibrary] Network mode changed to \(newMode) for VM: \(vm.name)")

            // Show warning for NAT mode (less secure)
            if newMode == .nat {
                let alert = NSAlert()
                alert.messageText = "Network Mode Changed"
                alert.informativeText = "VM '\(vm.name)' now has NAT (internet) access.\n\nWarning: This is less secure for malware analysis. The VM can potentially reach external networks."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

            // Refresh the status bar to show new network state
            refreshStatusBar()
        } catch {
            NSLog("[VMLibrary] Failed to save network config: \(error)")
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // When user clicks the close button on the library window, quit the app
        NSApplication.shared.terminate(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        // Recalculate layout when window is resized
        guard let contentView = window?.contentView else { return }

        let sidebarWidth: CGFloat = 220
        let activePanelWidth: CGFloat = 220
        let buttonRowHeight: CGFloat = 50
        let padding: CGFloat = 15
        let packetPanelHeight: CGFloat = 180

        let contentWidth = contentView.bounds.width
        let contentHeight = contentView.bounds.height

        // Recalculate table position and size (above packet panel)
        let tableX = sidebarWidth + padding
        let tableWidth = contentWidth - sidebarWidth - activePanelWidth - padding * 3
        let tableY = buttonRowHeight + padding + packetPanelHeight + padding
        let tableHeight = contentHeight - tableY - padding

        if let scrollView = tableView?.enclosingScrollView {
            scrollView.frame = NSRect(x: tableX, y: tableY, width: tableWidth, height: tableHeight)
        }

        // Recalculate button positions
        let buttons: [NSButton?] = [newButton, deleteButton, renameButton, cloneButton, importButton, configureButton, startButton]
        let buttonWidth: CGFloat = 80
        let buttonSpacing: CGFloat = 10
        let visibleButtons = buttons.compactMap { $0 }
        let totalButtonsWidth = CGFloat(visibleButtons.count) * buttonWidth + CGFloat(visibleButtons.count - 1) * buttonSpacing
        var buttonX = tableX + (tableWidth - totalButtonsWidth) / 2

        for button in visibleButtons {
            button.frame = NSRect(x: buttonX, y: padding, width: buttonWidth, height: 32)
            buttonX += buttonWidth + buttonSpacing
        }

        // Recalculate Active VMs panel position (right side, same height as table)
        if let panel = statusBar {
            let panelX = contentWidth - activePanelWidth - padding
            let panelY = buttonRowHeight + padding + packetPanelHeight + padding  // Same as table Y
            let panelHeight = contentHeight - panelY - padding
            panel.frame = NSRect(x: panelX, y: panelY, width: activePanelWidth, height: panelHeight)
        }

        // Recalculate Packet Log panel position (horizontal, below table)
        if let packetPanel = packetLogPanel {
            let packetX = sidebarWidth + padding
            let packetY = buttonRowHeight + padding
            let packetWidth = contentWidth - sidebarWidth - activePanelWidth - padding * 3
            packetPanel.frame = NSRect(x: packetX, y: packetY, width: packetWidth, height: packetPanelHeight)
        }
    }

    @objc private func handleVMStatusChanged(_ notification: Notification) {
        // Refresh the table to show updated status
        DispatchQueue.main.async {
            self.tableView?.reloadData()

            // Update status bar with current running VMs
            self.refreshStatusBar()
        }
    }

    private func refreshStatusBar() {
        let runningVMs = vmManager.getRunningVMs()
        let vmStates: [(vm: VMConfiguration, state: String)] = runningVMs.map { vm in
            let stateString: String
            switch vm.status {
            case .running:
                stateString = "running"
            case .starting:
                stateString = "starting"
            case .stopping:
                stateString = "stopping"
            default:
                stateString = "stopped"
            }
            return (vm: vm, state: stateString)
        }
        updateStatusBar(runningVMs: vmStates)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return vmManager.virtualMachines.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < vmManager.virtualMachines.count else {
            return nil
        }

        let vm = vmManager.virtualMachines[row]

        // Try to get existing cell, or create new one programmatically
        var cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTableCellView

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = tableColumn!.identifier

            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell?.addSubview(textField)
            cell?.textField = textField

            // Add constraints
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
        }

        guard let finalCell = cell else {
            return nil
        }

        switch tableColumn?.identifier.rawValue {
        case "NameColumn":
            finalCell.textField?.stringValue = vm.name
        case "StatusColumn":
            finalCell.textField?.stringValue = vm.statusDisplayString
        case "OSColumn":
            finalCell.textField?.stringValue = vm.osType
        case "CPUColumn":
            finalCell.textField?.stringValue = "\(vm.cpuCount) cores"
        case "MemoryColumn":
            finalCell.textField?.stringValue = vm.memoryDisplayString
        case "DiskColumn":
            finalCell.textField?.stringValue = vm.diskDisplayString
        case "LastUsedColumn":
            if let lastUsed = vm.lastUsedDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                finalCell.textField?.stringValue = formatter.string(from: lastUsed)
            } else {
                finalCell.textField?.stringValue = "Never"
            }
        default:
            break
        }

        return finalCell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    // MARK: - Actions

    @IBAction func startVM(_ sender: Any) {
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to start")
            return
        }

        // Check concurrent VM limit (max 2 VMs for Linux router support)
        let runningCount = vmManager.getRunningVMsCount()
        if runningCount >= 2 {
            let runningVMs = vmManager.getRunningVMs()
            let vmNames = runningVMs.map { $0.name }.joined(separator: ", ")
            showAlert(message: "Maximum of 2 VMs can run concurrently (for Linux router + client support).\n\nCurrently running: \(vmNames)\n\nPlease stop a VM before starting another.")
            return
        }

        selectedVM = vmManager.virtualMachines[selectedRow]

        // Update last used date
        vmManager.updateLastUsedDate(selectedVM!)

        // Keep the library window visible - don't hide it
        // The VM guest window will open alongside the library window

        // Notify app delegate to start VM
        NotificationCenter.default.post(name: .startVM, object: selectedVM)
    }

    @IBAction func newVM(_ sender: Any) {
        showNewVMDialog()
    }

    @IBAction func deleteVM(_ sender: Any) {
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to delete")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Delete VM?"
        alert.informativeText = "Are you sure you want to delete '\(vm.name)'? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try vmManager.deleteVM(vm)
                refreshTable()
            } catch {
                showAlert(message: "Failed to delete VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func renameVM(_ sender: Any) {
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to rename")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Rename VM"
        alert.informativeText = "Enter a new name for '\(vm.name)':"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = vm.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue
            do {
                try vmManager.renameVM(vm, newName: newName)
                refreshTable()
            } catch {
                showAlert(message: "Failed to rename VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func cloneVM(_ sender: Any) {
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to clone")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Clone VM"
        alert.informativeText = "Enter a name for the cloned VM:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = vm.name + " Copy"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue
            do {
                _ = try vmManager.cloneVM(vm, newName: newName)
                refreshTable()
            } catch {
                showAlert(message: "Failed to clone VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func importVM(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.treatsFilePackagesAsDirectories = true
        openPanel.message = "Select a VM bundle to import"
        openPanel.allowedContentTypes = [.bundle]
        openPanel.allowsOtherFileTypes = true

        if openPanel.runModal() == .OK {
            guard let sourcePath = openPanel.url?.path else { return }

            let alert = NSAlert()
            alert.messageText = "Import VM"
            alert.informativeText = "Enter a name for the imported VM:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            textField.stringValue = "Imported VM"
            alert.accessoryView = textField

            if alert.runModal() == .alertFirstButtonReturn {
                let newName = textField.stringValue
                do {
                    _ = try vmManager.importVM(from: sourcePath, name: newName)
                    refreshTable()
                } catch {
                    showAlert(message: "Failed to import VM: \(error.localizedDescription)")
                }
            }
        }
    }

    @IBAction func configureVM(_ sender: Any) {
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to configure")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]
        showConfigureVMDialog(vm)
    }

    @IBAction func refreshVMList(_ sender: Any) {
        refreshTable()
    }

    // MARK: - macOS VM Download

    private func downloadAndPrepareMacOSVM(_ vmConfig: VMConfiguration) {
        NSLog("[VMLibrary] === downloadAndPrepareMacOSVM() ENTERED ===")
        NSLog("[VMLibrary] VM config: %@", vmConfig.name)

        // Create progress alert
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading macOS"
        progressAlert.informativeText = "Initializing..."
        NSLog("[VMLibrary] Created progress alert")
        progressAlert.alertStyle = .informational
        progressAlert.addButton(withTitle: "Cancel")

        // Create a container view for progress bar, percentage label, and URL
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 75))

        // Add source URL label at top for security transparency
        let urlLabel = NSTextField(labelWithString: "Source: Apple Inc. (mesu.apple.com)")
        urlLabel.frame = NSRect(x: 0, y: 55, width: 400, height: 20)
        urlLabel.alignment = .center
        urlLabel.font = NSFont.systemFont(ofSize: 9)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.isEditable = false
        urlLabel.isBordered = false
        urlLabel.backgroundColor = .clear
        containerView.addSubview(urlLabel)

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 30, width: 400, height: 20))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100.0
        containerView.addSubview(progressIndicator)

        // Add percentage label below progress bar
        let percentageLabel = NSTextField(labelWithString: "0%")
        percentageLabel.frame = NSRect(x: 0, y: 5, width: 400, height: 20)
        percentageLabel.alignment = .center
        percentageLabel.font = NSFont.systemFont(ofSize: 11)
        percentageLabel.textColor = .secondaryLabelColor
        containerView.addSubview(percentageLabel)

        progressAlert.accessoryView = containerView

        // Show alert in background
        DispatchQueue.main.async {
            let response = progressAlert.runModal()
            if response == .alertFirstButtonReturn {
                // User clicked Cancel
                print("Download cancelled by user")
                // TODO: Add cancel support to ISOCacheManager
            }
        }

        // Use centralized ISOCacheManager for IPSW download
        NSLog("[VMLibrary] Starting macOS download flow...")
        let cacheManager = ISOCacheManager.shared
        NSLog("[VMLibrary] Got ISOCacheManager.shared")

        // Get current macOS version for cache path (will be updated after download to actual version)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        NSLog("[VMLibrary] macOS version: %@", versionString)

        let imageType = VMImageType.macOS(version: versionString)
        NSLog("[VMLibrary] Created VMImageType, about to call downloadImage...")

        cacheManager.downloadImage(
            for: imageType,
            progressHandler: { progress, message in
                // Use performSelector for modal dialog compatibility (DispatchQueue.main.async doesn't work with modal run loops)
                RunLoop.main.perform(inModes: [.common], block: {
                    if progress < 0 {
                        // Phase transition: download complete, starting validation
                        progressAlert.messageText = "Validating macOS Image"
                        progressAlert.informativeText = message
                        progressIndicator.doubleValue = 0
                        percentageLabel.stringValue = "0%"
                    } else {
                        progressAlert.informativeText = message
                        let percentage = progress * 100.0
                        progressIndicator.doubleValue = percentage
                        percentageLabel.stringValue = String(format: "%.1f%%", percentage)
                    }
                    progressIndicator.display()
                })
            },
            completionHandler: { [weak self] result in
                RunLoop.main.perform(inModes: [.common], block: {
                    NSLog("[VMLibrary] downloadImage completion handler called")
                    // Close progress window
                    NSApp.abortModal()

                    switch result {
                    case .success(let ipswURL):
                        NSLog("[VMLibrary] IPSW downloaded to: %@", ipswURL.path)
                        // Start VM with IPSW
                        self?.selectedVM = vmConfig
                        self?.vmManager.updateLastUsedDate(vmConfig)
                        // Keep library window visible
                        NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": vmConfig, "iso": ipswURL])

                    case .failure(let error):
                        NSLog("[VMLibrary] Download failed: %@", error.localizedDescription)
                        self?.showAlert(message: "Failed to download macOS: \(error.localizedDescription)")
                    }
                })
            }
        )
    }

    // MARK: - Linux VM Download

    private func downloadAndPrepareLinuxVM(_ vmConfig: VMConfiguration, distro: LinuxDistro, isRouter: Bool, customVersion: DiscoveredVersion? = nil) {
        NSLog("[VMLibrary] === downloadAndPrepareLinuxVM() ENTERED ===")
        NSLog("[VMLibrary] VM config: %@, distro: %@, isRouter: %d", vmConfig.name, distro.rawValue, isRouter)
        if let version = customVersion {
            NSLog("[VMLibrary] Using custom version: %@ from %@", version.version, version.downloadURL)
        }

        // Use custom version info if provided, otherwise fall back to distro defaults
        let versionString = customVersion?.version ?? distro.version
        let downloadURL = customVersion?.downloadURL ?? distro.downloadURL
        let checksumURL = customVersion?.checksumURL

        // Check if ISO is already cached
        let imageType = VMImageType.linux(distro: distro, version: versionString, isSecurityRouter: isRouter)
        if let cachedISO = ISOCacheManager.shared.getCachedImage(for: imageType) {
            NSLog("[VMLibrary] ISO already cached at: %@", cachedISO.path)
            // Start VM immediately with cached ISO
            selectedVM = vmConfig
            vmManager.updateLastUsedDate(vmConfig)
            NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": vmConfig, "iso": cachedISO])
            return
        }

        NSLog("[VMLibrary] ISO not cached, will download from: %@", downloadURL)

        // Create progress alert
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading \(distro.rawValue) \(versionString) ISO"
        progressAlert.informativeText = "Initializing..."
        progressAlert.alertStyle = .informational
        progressAlert.addButton(withTitle: "Cancel")

        // Create a container view for progress bar, percentage label, and URL
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 75))

        // Add source URL label at top for security transparency
        let urlLabel = NSTextField(labelWithString: "Source: \(downloadURL)")
        urlLabel.frame = NSRect(x: 0, y: 55, width: 400, height: 20)
        urlLabel.alignment = .center
        urlLabel.font = NSFont.systemFont(ofSize: 9)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.isEditable = false
        urlLabel.isBordered = false
        urlLabel.backgroundColor = .clear
        containerView.addSubview(urlLabel)

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 30, width: 400, height: 20))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100.0
        containerView.addSubview(progressIndicator)

        // Add percentage label below progress bar
        let percentageLabel = NSTextField(labelWithString: "0%")
        percentageLabel.frame = NSRect(x: 0, y: 5, width: 400, height: 20)
        percentageLabel.alignment = .center
        percentageLabel.font = NSFont.systemFont(ofSize: 11)
        percentageLabel.textColor = .secondaryLabelColor
        containerView.addSubview(percentageLabel)

        progressAlert.accessoryView = containerView

        // Show alert in background
        DispatchQueue.main.async {
            let response = progressAlert.runModal()
            if response == .alertFirstButtonReturn {
                // User clicked Cancel
                print("Download cancelled by user")
                // TODO: Add cancel support to ISOCacheManager
            }
        }

        // Use centralized ISOCacheManager for ISO download
        NSLog("[VMLibrary] Starting Linux ISO download flow...")
        let cacheManager = ISOCacheManager.shared

        NSLog("[VMLibrary] Created VMImageType: %@", imageType.description)

        // Pass custom URL if using a discovered version, otherwise nil to use distro defaults
        let customURLToUse: String? = customVersion != nil ? downloadURL : nil
        let customChecksumToUse: String? = checksumURL

        cacheManager.downloadImage(
            for: imageType,
            customDownloadURL: customURLToUse,
            customChecksumURL: customChecksumToUse,
            progressHandler: { progress, message in
                // Use performSelector for modal dialog compatibility
                RunLoop.main.perform(inModes: [.common], block: {
                    if progress < 0 {
                        // Phase transition: download complete, starting validation
                        progressAlert.messageText = "Validating \(distro.rawValue) \(versionString) ISO"
                        progressAlert.informativeText = message
                        progressIndicator.doubleValue = 0
                        percentageLabel.stringValue = "0%"
                    } else {
                        progressAlert.informativeText = message
                        let percentage = progress * 100.0
                        progressIndicator.doubleValue = percentage
                        percentageLabel.stringValue = String(format: "%.1f%%", percentage)
                    }
                    progressIndicator.display()
                })
            },
            completionHandler: { [weak self] result in
                RunLoop.main.perform(inModes: [.common], block: {
                    NSLog("[VMLibrary] downloadImage completion handler called")
                    // Close progress window
                    NSApp.abortModal()

                    switch result {
                    case .success(let isoURL):
                        NSLog("[VMLibrary] ISO downloaded to: %@", isoURL.path)
                        // Start VM with ISO
                        self?.selectedVM = vmConfig
                        self?.vmManager.updateLastUsedDate(vmConfig)
                        // Keep library window visible
                        NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": vmConfig, "iso": isoURL])

                    case .failure(let error):
                        NSLog("[VMLibrary] Download failed: %@", error.localizedDescription)
                        self?.showAlert(message: "Failed to download \(distro.rawValue): \(error.localizedDescription)")
                    }
                })
            }
        )
    }

    // Helper function to map distro display names to LinuxDistro enum
    private func mapDistroNameToEnum(_ distroName: String) -> LinuxDistro {
        switch distroName {
        case "Kali":
            return .kali
        case "Ubuntu Desktop":
            return .ubuntu
        case "Ubuntu Server":
            return .ubuntuServer
        case "Debian":
            return .debian
        case "Fedora":
            return .fedora
        case "ParrotOS":
            return .parrot
        case "Arch":
            return .arch
        case "Manjaro":
            return .manjaro
        default:
            return .kali  // Default to Kali
        }
    }

    // MARK: - Helper Methods

    func refreshTableFromOutside() {
        // Public method that can be called from AppDelegate
        refreshTable()
    }

    private func refreshTable() {
        // Reload VMs from disk asynchronously
        vmManager.initializeAsync { [weak self] in
            guard let self else { return }
            self.tableView?.reloadData()
            self.updateButtonStates()
        }
    }

    private func updateButtonStates() {
        let hasSelection = tableView?.selectedRow ?? -1 >= 0
        startButton?.isEnabled = hasSelection
        deleteButton?.isEnabled = hasSelection
        renameButton?.isEnabled = hasSelection
        cloneButton?.isEnabled = hasSelection
        configureButton?.isEnabled = hasSelection
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showNewVMDialog() {
        let alert = NSAlert()
        alert.messageText = "Create New VM"
        alert.informativeText = "Configure your new virtual machine:"
        alert.alertStyle = .informational

        let createButton = alert.addButton(withTitle: "Select ISO")
        alert.addButton(withTitle: "Cancel")

        // Create form (increased height for Linux router controls + distro selection)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 380))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 350, width: 100, height: 20)
        view.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 110, y: 348, width: 280, height: 24))
        nameField.stringValue = "New VM"
        view.addSubview(nameField)

        // OS Type dropdown
        let osLabel = NSTextField(labelWithString: "OS Type:")
        osLabel.frame = NSRect(x: 0, y: 320, width: 100, height: 20)
        view.addSubview(osLabel)

        let osPopup = NSPopUpButton(frame: NSRect(x: 110, y: 315, width: 150, height: 26), pullsDown: false)
        osPopup.addItem(withTitle: "Linux")
        osPopup.addItem(withTitle: "macOS")
        osPopup.selectItem(at: 0) // Default to Linux
        view.addSubview(osPopup)

        // Linux Distribution dropdown (only visible for Linux VMs)
        let distroLabel = NSTextField(labelWithString: "Distribution:")
        distroLabel.frame = NSRect(x: 0, y: 290, width: 100, height: 20)
        view.addSubview(distroLabel)

        let distroPopup = NSPopUpButton(frame: NSRect(x: 110, y: 285, width: 200, height: 26), pullsDown: false)
        distroPopup.addItem(withTitle: "Kali")
        distroPopup.addItem(withTitle: "Ubuntu Desktop")
        distroPopup.addItem(withTitle: "Ubuntu Server")
        distroPopup.addItem(withTitle: "Debian")
        distroPopup.addItem(withTitle: "Fedora")
        distroPopup.addItem(withTitle: "ParrotOS")
        distroPopup.addItem(withTitle: "Arch")
        distroPopup.addItem(withTitle: "Manjaro")
        distroPopup.selectItem(at: 0) // Default to Kali
        view.addSubview(distroPopup)

        // Version dropdown (dynamic based on distro selection)
        let versionLabel = NSTextField(labelWithString: "Version:")
        versionLabel.frame = NSRect(x: 0, y: 260, width: 100, height: 20)
        view.addSubview(versionLabel)

        let versionPopup = NSPopUpButton(frame: NSRect(x: 110, y: 255, width: 200, height: 26), pullsDown: false)
        versionPopup.addItem(withTitle: "Default")
        view.addSubview(versionPopup)

        // Version loading indicator
        let versionSpinner = NSProgressIndicator(frame: NSRect(x: 320, y: 258, width: 20, height: 20))
        versionSpinner.style = .spinning
        versionSpinner.controlSize = .small
        versionSpinner.isHidden = true
        view.addSubview(versionSpinner)

        // ISO Cache Status Label (below version dropdown)
        let isoCacheStatusLabel = NSTextField(labelWithString: "")
        isoCacheStatusLabel.frame = NSRect(x: 110, y: 230, width: 280, height: 20)
        isoCacheStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        isoCacheStatusLabel.isEditable = false
        isoCacheStatusLabel.isBordered = false
        isoCacheStatusLabel.drawsBackground = false
        view.addSubview(isoCacheStatusLabel)

        // Delegate to handle dynamic UI updates
        @MainActor class VMConfigDelegate: NSObject {
            weak var isoCheckbox: NSButton?
            weak var createButton: NSButton?
            weak var routerCheckbox: NSButton?
            weak var linuxRouterCheckbox: NSButton?
            weak var routerLabel: NSTextField?
            weak var routerPopup: NSPopUpButton?
            weak var networkPopup: NSPopUpButton?
            weak var osPopup: NSPopUpButton?
            weak var distroPopup: NSPopUpButton?
            weak var distroLabel: NSTextField?
            weak var versionPopup: NSPopUpButton?
            weak var versionLabel: NSTextField?
            weak var versionSpinner: NSProgressIndicator?
            weak var isoCacheStatusLabel: NSTextField?
            weak var vmManager: VMManager?

            // Track discovered versions per distro
            var discoveredVersions: [String: [DiscoveredVersion]] = [:]
            var selectedVersion: DiscoveredVersion?

            @objc func osTypeChanged(_ sender: NSPopUpButton) {
                let isMacOS = sender.titleOfSelectedItem == "macOS"
                isoCheckbox?.isHidden = isMacOS
                createButton?.title = isMacOS ? "Create" : "Select ISO"

                // Show/hide Linux-specific controls
                distroPopup?.isHidden = isMacOS
                distroLabel?.isHidden = isMacOS
                versionPopup?.isHidden = isMacOS
                versionLabel?.isHidden = isMacOS
                versionSpinner?.isHidden = true

                // Update ISO cache status when showing Linux controls
                if !isMacOS {
                    updateISOCacheStatus()
                    fetchVersionsForSelectedDistro()
                } else {
                    isoCacheStatusLabel?.stringValue = ""
                }

                // Update network UI based on OS type (this will handle linuxRouterCheckbox visibility)
                updateNetworkUI()
            }

            @objc func networkModeChanged(_ sender: NSPopUpButton) {
                updateNetworkUI()
            }

            @objc func linuxRouterCheckboxChanged(_ sender: NSButton) {
                let isRouterMode = sender.state == .on

                if isRouterMode {
                    // Force Kali selection when router mode is enabled
                    distroPopup?.selectItem(at: 0) // Kali is at index 0
                    distroPopup?.isEnabled = false
                    updateISOCacheStatus()
                } else {
                    // Re-enable distro selection when router mode is disabled
                    distroPopup?.isEnabled = true
                }
            }

            @objc func distroChanged(_ sender: NSPopUpButton) {
                updateISOCacheStatus()
                fetchVersionsForSelectedDistro()
            }

            @objc func versionChanged(_ sender: NSPopUpButton) {
                guard let selectedTitle = sender.titleOfSelectedItem,
                      let distroName = distroPopup?.titleOfSelectedItem,
                      let versions = discoveredVersions[distroName] else {
                    selectedVersion = nil
                    return
                }

                // Find the selected version
                if selectedTitle == "Default" || selectedTitle.hasPrefix("Fetching") {
                    selectedVersion = nil
                } else if selectedTitle == "Latest" {
                    // "Latest" means use the first (most recent) discovered version
                    selectedVersion = versions.first
                } else {
                    selectedVersion = versions.first { $0.displayName == selectedTitle || $0.version == selectedTitle }
                }
            }

            func fetchVersionsForSelectedDistro() {
                guard let distroName = distroPopup?.titleOfSelectedItem else { return }

                // Check if we already have versions cached
                if let cached = discoveredVersions[distroName], !cached.isEmpty {
                    populateVersionPopup(with: cached)
                    return
                }

                // Get the distro config
                let distroID = mapDistroNameToID(distroName)
                guard let config = DistroConfigurationManager.shared.configuration(for: distroID),
                      let versionConfig = config.versionDiscovery,
                      versionConfig.enabled else {
                    // Version discovery not enabled - show default only
                    versionPopup?.removeAllItems()
                    versionPopup?.addItem(withTitle: "Default (\(DistroConfigurationManager.shared.configuration(for: distroID)?.version ?? "latest"))")
                    return
                }

                // Show spinner and start fetching
                versionPopup?.removeAllItems()
                versionPopup?.addItem(withTitle: "Fetching versions...")
                versionPopup?.isEnabled = false
                versionSpinner?.isHidden = false
                versionSpinner?.startAnimation(nil)

                // Capture config values before entering Task
                let configID = config.id
                let configBaseURL = versionConfig.baseURL
                let configStrategy = versionConfig.strategy
                let configFilenamePattern = versionConfig.filenamePattern
                let configArchitecture = versionConfig.architecture

                Task { @MainActor [weak self] in
                    DistroVersionFetcher.shared.fetchVersions(
                        for: configID,
                        baseURL: configBaseURL,
                        strategy: configStrategy,
                        filenamePattern: configFilenamePattern,
                        architecture: configArchitecture
                    ) { result in
                        DispatchQueue.main.async { [weak self] in
                            self?.versionSpinner?.stopAnimation(nil)
                            self?.versionSpinner?.isHidden = true
                            self?.versionPopup?.isEnabled = true

                            switch result {
                            case .success(let versions):
                                self?.discoveredVersions[distroName] = versions
                                self?.populateVersionPopup(with: versions)
                            case .noVersionsFound(let reason):
                                NSLog("[VersionFetch] No versions found for \(distroName): \(reason)")
                                self?.versionPopup?.removeAllItems()
                                self?.versionPopup?.addItem(withTitle: "Default")
                            case .networkError(let error):
                                NSLog("[VersionFetch] Network error for \(distroName): \(error)")
                                self?.versionPopup?.removeAllItems()
                                self?.versionPopup?.addItem(withTitle: "Default (offline)")
                            case .parseError(let error):
                                NSLog("[VersionFetch] Parse error for \(distroName): \(error)")
                                self?.versionPopup?.removeAllItems()
                                self?.versionPopup?.addItem(withTitle: "Default")
                            }
                        }
                    }
                }
            }

            private func populateVersionPopup(with versions: [DiscoveredVersion]) {
                versionPopup?.removeAllItems()
                versionPopup?.addItem(withTitle: "Latest")

                for version in versions.prefix(5) {
                    versionPopup?.addItem(withTitle: version.displayName)
                }

                versionPopup?.selectItem(at: 0)
                selectedVersion = nil
            }

            private func mapDistroNameToID(_ name: String) -> LinuxDistro {
                switch name {
                case "Kali": return .kali
                case "Ubuntu Desktop": return .ubuntu
                case "Ubuntu Server": return .ubuntuServer
                case "Debian": return .debian
                case "Fedora": return .fedora
                case "ParrotOS": return .parrot
                case "Arch": return .arch
                case "Manjaro": return .manjaro
                default: return .kali
                }
            }

            func updateISOCacheStatus() {
                guard let distroPopup = distroPopup,
                      let isoCacheStatusLabel = isoCacheStatusLabel,
                      let selectedDistro = distroPopup.titleOfSelectedItem else { return }

                // Map distro name to LinuxDistro enum
                let linuxDistro: LinuxDistro
                switch selectedDistro {
                case "Kali":
                    linuxDistro = .kali
                case "Ubuntu Desktop":
                    linuxDistro = .ubuntu
                case "Ubuntu Server":
                    linuxDistro = .ubuntuServer
                case "Debian":
                    linuxDistro = .debian
                case "Fedora":
                    linuxDistro = .fedora
                case "ParrotOS":
                    linuxDistro = .parrot
                case "Arch":
                    linuxDistro = .arch
                case "Manjaro":
                    linuxDistro = .manjaro
                default:
                    isoCacheStatusLabel.stringValue = ""
                    return
                }

                let distroInfo = ISOCacheManager.shared.getDistributionInfo(for: linuxDistro)

                if distroInfo.isCached, let downloadDate = distroInfo.lastDownloaded {
                    // ISO is cached - show green text
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    let dateString = formatter.string(from: downloadDate)

                    isoCacheStatusLabel.stringValue = "ISO Cached! (downloaded: \(dateString))"
                    isoCacheStatusLabel.textColor = NSColor(red: 0.0, green: 0.8, blue: 0.2, alpha: 1.0) // Green
                } else {
                    // ISO not cached - show red text
                    isoCacheStatusLabel.stringValue = "Will download latest ISO"
                    isoCacheStatusLabel.textColor = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1.0) // Red
                }
            }

            private func updateNetworkUI() {
                guard let osPopup = osPopup else { return }

                let isMacOS = osPopup.titleOfSelectedItem == "macOS"
                let isVirtual = networkPopup?.indexOfSelectedItem == 1

                // Show/hide router options based on OS type and network mode
                if isVirtual {
                    if isMacOS {
                        // macOS in virtual mode: show router selection dropdown only
                        routerCheckbox?.isHidden = true
                        linuxRouterCheckbox?.isHidden = true
                        routerLabel?.isHidden = false
                        routerPopup?.isHidden = false

                        // Populate router dropdown with Linux VMs
                        populateRouterList()
                    } else {
                        // Linux in virtual mode: show Linux Router checkbox only
                        routerCheckbox?.isHidden = true
                        linuxRouterCheckbox?.isHidden = false
                        routerLabel?.isHidden = true
                        routerPopup?.isHidden = true
                    }
                } else {
                    // NAT mode: hide all router options
                    routerCheckbox?.isHidden = true
                    linuxRouterCheckbox?.isHidden = true
                    routerLabel?.isHidden = true
                    routerPopup?.isHidden = true
                }
            }

            private func populateRouterList() {
                guard let vmManager = vmManager,
                      let routerPopup = routerPopup else { return }

                routerPopup.removeAllItems()

                // Get only Linux VMs that are configured as routers
                let routerVMs = vmManager.virtualMachines.filter {
                    $0.osType.lowercased().contains("linux") && $0.networkConfig.isRouter
                }

                if routerVMs.isEmpty {
                    routerPopup.addItem(withTitle: "No router VMs available")
                    routerPopup.isEnabled = false
                } else {
                    routerPopup.isEnabled = true
                    for vm in routerVMs {
                        routerPopup.addItem(withTitle: vm.name)
                    }
                }
            }
        }
        let configDelegate = VMConfigDelegate()
        configDelegate.vmManager = vmManager

        // CPU count
        let cpuLabel = NSTextField(labelWithString: "CPU Cores:")
        cpuLabel.frame = NSRect(x: 0, y: 195, width: 100, height: 20)
        view.addSubview(cpuLabel)

        let cpuField = NSTextField(frame: NSRect(x: 110, y: 193, width: 100, height: 24))
        cpuField.stringValue = "2"
        view.addSubview(cpuField)

        // Memory size
        let memLabel = NSTextField(labelWithString: "Memory (GB):")
        memLabel.frame = NSRect(x: 0, y: 165, width: 100, height: 20)
        view.addSubview(memLabel)

        let memField = NSTextField(frame: NSRect(x: 110, y: 163, width: 100, height: 24))
        memField.stringValue = "4"
        view.addSubview(memField)

        // Disk size
        let diskLabel = NSTextField(labelWithString: "Disk (GB):")
        diskLabel.frame = NSRect(x: 0, y: 135, width: 100, height: 20)
        view.addSubview(diskLabel)

        let diskField = NSTextField(frame: NSRect(x: 110, y: 133, width: 100, height: 24))
        diskField.stringValue = "64"
        view.addSubview(diskField)

        // Network Mode dropdown
        let networkLabel = NSTextField(labelWithString: "Network:")
        networkLabel.frame = NSRect(x: 0, y: 105, width: 100, height: 20)
        view.addSubview(networkLabel)

        let networkPopup = NSPopUpButton(frame: NSRect(x: 110, y: 100, width: 200, height: 26), pullsDown: false)
        networkPopup.addItem(withTitle: "NAT (Internet Access)")
        networkPopup.addItem(withTitle: "Virtual Network (VM-to-VM)")
        networkPopup.selectItem(at: 0) // Default to NAT
        view.addSubview(networkPopup)

        // Linux Router checkbox (top-level, always visible for Linux VMs)
        let linuxRouterCheckbox = NSButton(checkboxWithTitle: "Linux Router", target: nil, action: nil)
        linuxRouterCheckbox.frame = NSRect(x: 110, y: 75, width: 150, height: 20)
        linuxRouterCheckbox.state = .off
        linuxRouterCheckbox.isHidden = false  // Visible by default for Linux
        view.addSubview(linuxRouterCheckbox)

        // Network-based router checkbox (only for Linux VMs in Virtual Network mode)
        let routerCheckbox = NSButton(checkboxWithTitle: "Act as Router for other VMs", target: nil, action: nil)
        routerCheckbox.frame = NSRect(x: 110, y: 75, width: 250, height: 20)
        routerCheckbox.state = .off
        routerCheckbox.isHidden = true  // Hidden by default
        view.addSubview(routerCheckbox)

        // macOS Router selection (only for macOS VMs in Virtual Network mode)
        let routerLabel = NSTextField(labelWithString: "Route via:")
        routerLabel.frame = NSRect(x: 110, y: 75, width: 70, height: 20)
        routerLabel.isHidden = true  // Hidden by default
        view.addSubview(routerLabel)

        let routerPopup = NSPopUpButton(frame: NSRect(x: 185, y: 70, width: 200, height: 26), pullsDown: false)
        routerPopup.isHidden = true  // Hidden by default
        view.addSubview(routerPopup)

        // Rosetta support checkbox
        let rosettaCheckbox = NSButton(checkboxWithTitle: "Enable Rosetta (x86_64 emulation)", target: nil, action: nil)
        rosettaCheckbox.frame = NSRect(x: 110, y: 45, width: 250, height: 20)
        rosettaCheckbox.state = .off
        view.addSubview(rosettaCheckbox)

        // Install from ISO checkbox (only for Linux)
        let isoCheckbox = NSButton(checkboxWithTitle: "Install from ISO", target: nil, action: nil)
        isoCheckbox.frame = NSRect(x: 110, y: 20, width: 200, height: 20)
        isoCheckbox.state = .on
        view.addSubview(isoCheckbox)

        // Connect the delegate references
        configDelegate.isoCheckbox = isoCheckbox
        configDelegate.createButton = createButton
        configDelegate.routerCheckbox = routerCheckbox
        configDelegate.linuxRouterCheckbox = linuxRouterCheckbox
        configDelegate.routerLabel = routerLabel
        configDelegate.routerPopup = routerPopup
        configDelegate.networkPopup = networkPopup
        configDelegate.osPopup = osPopup
        configDelegate.distroPopup = distroPopup
        configDelegate.distroLabel = distroLabel
        configDelegate.versionPopup = versionPopup
        configDelegate.versionLabel = versionLabel
        configDelegate.versionSpinner = versionSpinner
        configDelegate.isoCacheStatusLabel = isoCacheStatusLabel

        // Set up delegate actions
        osPopup.target = configDelegate
        osPopup.action = #selector(VMConfigDelegate.osTypeChanged(_:))

        versionPopup.target = configDelegate
        versionPopup.action = #selector(VMConfigDelegate.versionChanged(_:))
        networkPopup.target = configDelegate
        networkPopup.action = #selector(VMConfigDelegate.networkModeChanged(_:))
        linuxRouterCheckbox.target = configDelegate
        linuxRouterCheckbox.action = #selector(VMConfigDelegate.linuxRouterCheckboxChanged(_:))
        distroPopup.target = configDelegate
        distroPopup.action = #selector(VMConfigDelegate.distroChanged(_:))

        // Initialize ISO cache status check for Kali (default selection)
        configDelegate.updateISOCacheStatus()
        // Fetch versions for the default Linux selection (since selectItem doesn't trigger action)
        configDelegate.fetchVersionsForSelectedDistro()

        alert.accessoryView = view

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue
            let osType = osPopup.titleOfSelectedItem ?? "Linux"
            let cpuCount = Int(cpuField.stringValue) ?? 2
            let memoryGB = UInt64(memField.stringValue) ?? 4
            let diskGB = UInt64(diskField.stringValue) ?? 64
            _ = rosettaCheckbox.state == .on  // Reserved for future Rosetta support
            let needsISO = isoCheckbox.state == .on
            let networkModeIndex = networkPopup.indexOfSelectedItem
            let isLinuxRouter = routerCheckbox.state == .on || linuxRouterCheckbox.state == .on
            let selectedRouterName = routerPopup.titleOfSelectedItem
            let selectedDistro = distroPopup.titleOfSelectedItem ?? "Kali"
            let selectedVersion = configDelegate.selectedVersion  // User-selected version from popup

            let memorySize = memoryGB * 1024 * 1024 * 1024
            let diskSize = diskGB * 1024 * 1024 * 1024

            do {
                var newVM = try vmManager.createVM(
                    name: name,
                    cpuCount: cpuCount,
                    memorySize: memorySize,
                    diskSize: diskSize,
                    osType: osType
                )

                // Store Linux distribution info in VM config
                if osType == "Linux" {
                    newVM.linuxDistribution = selectedDistro
                    // Use selected version if available, otherwise fall back to distro default
                    if let version = selectedVersion {
                        newVM.linuxVersion = version.version
                    } else {
                        let distroEnum = mapDistroNameToEnum(selectedDistro)
                        newVM.linuxVersion = distroEnum.version
                    }
                }

                // Configure network settings
                if networkModeIndex == 1 {  // Virtual Network mode
                    newVM.networkConfig.mode = .virtual

                    if osType.lowercased().contains("mac") {
                        // macOS VM - find router VM by name
                        if let routerVM = vmManager.virtualMachines.first(where: { $0.name == selectedRouterName }) {
                            newVM.networkConfig.routerVMId = routerVM.id
                            print("[Network] macOS VM \(name) will route through \(routerVM.name)")
                        }
                    } else {
                        // Linux VM - set as router if checkbox is checked
                        newVM.networkConfig.isRouter = isLinuxRouter
                        if isLinuxRouter {
                            print("[Network] Linux VM \(name) configured as virtual network router")
                        }
                    }
                } else {
                    // NAT mode (default)
                    newVM.networkConfig.mode = .nat
                    print("[Network] VM \(name) configured for NAT networking")
                }

                // Save updated VM configuration
                try vmManager.saveVMConfiguration(newVM)

                refreshTable()

                NSLog("[VMLibrary] VM created successfully, checking if we should auto-start...")

                // Check concurrent VM limit before starting
                let runningCount = vmManager.getRunningVMsCount()
                NSLog("[VMLibrary] Running VM count: %d", runningCount)
                if runningCount >= 2 {
                    let runningVMs = vmManager.getRunningVMs()
                    let vmNames = runningVMs.map { $0.name }.joined(separator: ", ")
                    NSLog("[VMLibrary] Too many VMs running, not starting")
                    showAlert(message: "Maximum of 2 VMs can run concurrently.\n\nCurrently running: \(vmNames)\n\nVM created but not started. Please stop a running VM first.")
                    return
                }

                NSLog("[VMLibrary] Checking OS type: '%@'", osType)
                if osType == "macOS" {
                    // For macOS, automatically handle IPSW download/reuse
                    NSLog("[VMLibrary] OS type is macOS, calling downloadAndPrepareMacOSVM...")
                    downloadAndPrepareMacOSVM(newVM)
                    NSLog("[VMLibrary] downloadAndPrepareMacOSVM() call completed")
                } else if needsISO {
                    // For Linux, auto-download ISO via ISOCacheManager
                    let distroEnum = mapDistroNameToEnum(selectedDistro)
                    NSLog("[VMLibrary] %@ selected, checking cache/downloading ISO...", selectedDistro)
                    downloadAndPrepareLinuxVM(newVM, distro: distroEnum, isRouter: isLinuxRouter, customVersion: selectedVersion)
                }
            } catch {
                showAlert(message: "Failed to create VM: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Configure VM Dialog

    private func showConfigureVMDialog(_ vm: VMConfiguration) {
        let alert = NSAlert()
        alert.messageText = "Configure VM: \(vm.name)"
        alert.informativeText = "Modify network settings for this virtual machine:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // Create form view
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))

        let isMacOS = vm.osType.lowercased().contains("mac")
        let isLinux = vm.osType.lowercased().contains("linux")

        // Current settings info
        let currentLabel = NSTextField(labelWithString: "Current: \(vm.networkConfig.description)")
        currentLabel.frame = NSRect(x: 0, y: 130, width: 400, height: 20)
        currentLabel.font = NSFont.systemFont(ofSize: 11)
        currentLabel.textColor = .secondaryLabelColor
        view.addSubview(currentLabel)

        // Network Mode dropdown
        let networkLabel = NSTextField(labelWithString: "Network Mode:")
        networkLabel.frame = NSRect(x: 0, y: 100, width: 100, height: 20)
        view.addSubview(networkLabel)

        let networkPopup = NSPopUpButton(frame: NSRect(x: 110, y: 95, width: 200, height: 26), pullsDown: false)
        networkPopup.addItem(withTitle: "NAT (Internet Access)")
        networkPopup.addItem(withTitle: "Virtual Network (VM-to-VM)")
        networkPopup.selectItem(at: vm.networkConfig.mode == .virtual ? 1 : 0)
        view.addSubview(networkPopup)

        // Linux Router checkbox (for Linux VMs)
        let linuxRouterCheckbox = NSButton(checkboxWithTitle: "Act as Router for other VMs", target: nil, action: nil)
        linuxRouterCheckbox.frame = NSRect(x: 110, y: 65, width: 250, height: 20)
        linuxRouterCheckbox.state = vm.networkConfig.isRouter ? .on : .off
        linuxRouterCheckbox.isHidden = !isLinux
        view.addSubview(linuxRouterCheckbox)

        // Router selection (for macOS VMs)
        let routerLabel = NSTextField(labelWithString: "Route via:")
        routerLabel.frame = NSRect(x: 0, y: 65, width: 100, height: 20)
        routerLabel.isHidden = !isMacOS
        view.addSubview(routerLabel)

        let routerPopup = NSPopUpButton(frame: NSRect(x: 110, y: 60, width: 200, height: 26), pullsDown: false)
        routerPopup.isHidden = !isMacOS
        view.addSubview(routerPopup)

        // Populate router list for macOS VMs
        if isMacOS {
            let routerVMs = vmManager.virtualMachines.filter {
                $0.osType.lowercased().contains("linux") && $0.networkConfig.isRouter
            }

            if routerVMs.isEmpty {
                routerPopup.addItem(withTitle: "No router VMs available")
                routerPopup.isEnabled = false
            } else {
                routerPopup.addItem(withTitle: "None (no routing)")
                for routerVM in routerVMs {
                    routerPopup.addItem(withTitle: routerVM.name)
                    // Select current router if set
                    if vm.networkConfig.routerVMId == routerVM.id {
                        routerPopup.selectItem(withTitle: routerVM.name)
                    }
                }
            }
        }

        // Helper to update UI based on network mode
        @MainActor class ConfigDelegate: NSObject {
            weak var linuxRouterCheckbox: NSButton?
            weak var routerLabel: NSTextField?
            weak var routerPopup: NSPopUpButton?
            var isMacOS: Bool = false
            var isLinux: Bool = false

            @objc func networkModeChanged(_ sender: NSPopUpButton) {
                let isVirtual = sender.indexOfSelectedItem == 1

                if isVirtual {
                    linuxRouterCheckbox?.isHidden = !isLinux
                    routerLabel?.isHidden = !isMacOS
                    routerPopup?.isHidden = !isMacOS
                } else {
                    // NAT mode - hide router options
                    linuxRouterCheckbox?.isHidden = true
                    routerLabel?.isHidden = true
                    routerPopup?.isHidden = true
                }
            }
        }

        let configDelegate = ConfigDelegate()
        configDelegate.linuxRouterCheckbox = linuxRouterCheckbox
        configDelegate.routerLabel = routerLabel
        configDelegate.routerPopup = routerPopup
        configDelegate.isMacOS = isMacOS
        configDelegate.isLinux = isLinux

        networkPopup.target = configDelegate
        networkPopup.action = #selector(ConfigDelegate.networkModeChanged(_:))

        // Initialize visibility based on current mode
        configDelegate.networkModeChanged(networkPopup)

        // Info label
        let infoLabel = NSTextField(labelWithString: "Note: Network changes take effect on next VM start.")
        infoLabel.frame = NSRect(x: 0, y: 10, width: 400, height: 20)
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .tertiaryLabelColor
        view.addSubview(infoLabel)

        alert.accessoryView = view

        if alert.runModal() == .alertFirstButtonReturn {
            // Save changes
            var updatedVM = vm
            let networkModeIndex = networkPopup.indexOfSelectedItem

            if networkModeIndex == 1 {
                // Virtual Network mode
                updatedVM.networkConfig.mode = .virtual

                if isLinux {
                    updatedVM.networkConfig.isRouter = linuxRouterCheckbox.state == .on
                    updatedVM.networkConfig.routerVMId = nil
                    if updatedVM.networkConfig.isRouter {
                        print("[Network] Linux VM '\(vm.name)' configured as router")
                    }
                } else if isMacOS {
                    updatedVM.networkConfig.isRouter = false
                    // Find selected router VM
                    if let selectedRouterName = routerPopup.titleOfSelectedItem,
                       selectedRouterName != "None (no routing)",
                       selectedRouterName != "No router VMs available" {
                        if let routerVM = vmManager.virtualMachines.first(where: { $0.name == selectedRouterName }) {
                            updatedVM.networkConfig.routerVMId = routerVM.id
                            print("[Network] macOS VM '\(vm.name)' will route through '\(routerVM.name)'")
                        }
                    } else {
                        updatedVM.networkConfig.routerVMId = nil
                    }
                }
            } else {
                // NAT mode
                updatedVM.networkConfig.mode = .nat
                updatedVM.networkConfig.isRouter = false
                updatedVM.networkConfig.routerVMId = nil
                print("[Network] VM '\(vm.name)' configured for NAT networking")
            }

            // Save to disk
            do {
                try vmManager.saveVMConfiguration(updatedVM)
                refreshTable()
                showAlert(message: "VM configuration updated successfully.\n\nChanges will take effect on next VM start.")
            } catch {
                showAlert(message: "Failed to save VM configuration: \(error.localizedDescription)")
            }
        }
    }
}
