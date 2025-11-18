//
//  VMLibraryWindowController.swift
//  SecVF
//

import Cocoa
import Virtualization

class VMLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    @IBOutlet weak var tableView: NSTableView?
    @IBOutlet weak var startButton: NSButton?
    @IBOutlet weak var newButton: NSButton?
    @IBOutlet weak var deleteButton: NSButton?
    @IBOutlet weak var renameButton: NSButton?
    @IBOutlet weak var cloneButton: NSButton?
    @IBOutlet weak var importButton: NSButton?

    private var vmManager = VMManager.shared
    var selectedVM: VMConfiguration?
    private var statusBar: NSView?
    private var statusLabel: NSTextField?
    private var runningVMsContainer: NSStackView?

    override var windowNibName: NSNib.Name? {
        return "VMLibraryWindow"
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
            print("DEBUG: VM initialization complete - VM count: \(self.vmManager.virtualMachines.count)")
            self.tableView?.reloadData()
            self.refreshStatusBar()
        }

        // Force the table to use view-based mode
        tableView?.rowSizeStyle = .default

        // Debug: Print all table columns and their identifiers
        if let tableView = tableView {
            print("DEBUG: Table has \(tableView.tableColumns.count) columns:")
            for column in tableView.tableColumns {
                print("  - Column identifier: \(column.identifier.rawValue)")
            }
        } else {
            print("WARNING: tableView is nil in windowDidLoad!")
        }

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
    }

    private func addSidebar() {
        guard let window = window, let contentView = window.contentView else { return }

        let sidebarWidth: CGFloat = 220

        // Create sidebar view
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

        // Logo
        let logoView = NSImageView(frame: NSRect(x: 40, y: contentView.bounds.height - 180, width: 170, height: 120))
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.image = createStylizedLogo()
        logoView.autoresizingMask = [.minYMargin]
        sidebar.addSubview(logoView)

        // Title - Two-tone: "security" in neon cyan, "VF" in olive green
        let titleLabel = NSTextField()
        titleLabel.frame = NSRect(x: 20, y: contentView.bounds.height - 220, width: sidebarWidth - 40, height: 35)
        titleLabel.alignment = .center
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.autoresizingMask = [.minYMargin]

        // Create attributed string with two colors and center alignment
        let attributedTitle = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .heavy)

        // Create paragraph style for centering
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // "security" in neon cyan
        let securityPart = NSAttributedString(string: "security", attributes: [
            .font: font,
            .foregroundColor: NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(securityPart)

        // "VF" in cool olive green
        let vfPart = NSAttributedString(string: "VF", attributes: [
            .font: font,
            .foregroundColor: NSColor(red: 0.5, green: 0.85, blue: 0.3, alpha: 1.0),  // Cool olive green
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(vfPart)

        titleLabel.attributedStringValue = attributedTitle
        sidebar.addSubview(titleLabel)

        // Subtitle - Light cyan
        let subtitleLabel = NSTextField(labelWithString: "VM Sandbox Environment")
        subtitleLabel.frame = NSRect(x: 20, y: contentView.bounds.height - 245, width: sidebarWidth - 40, height: 20)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        subtitleLabel.textColor = NSColor(red: 0.5, green: 0.75, blue: 0.8, alpha: 1.0)
        subtitleLabel.isBordered = false
        subtitleLabel.isEditable = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.autoresizingMask = [.minYMargin]
        sidebar.addSubview(subtitleLabel)

        // Separator line
        let separator1 = createSeparator(y: contentView.bounds.height - 270, width: sidebarWidth)
        separator1.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(separator1)

        // Stats/Info below title - Neon green accents - centered
        let statsLabel = NSTextField(labelWithString: "▸ Malware Analysis\n▸ Isolated Sandbox\n▸ Virtual Networking")
        statsLabel.frame = NSRect(x: 20, y: contentView.bounds.height - 360, width: sidebarWidth - 40, height: 80)
        statsLabel.alignment = .center
        statsLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        statsLabel.textColor = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 0.9)  // Neon green
        statsLabel.isBordered = false
        statsLabel.isEditable = false
        statsLabel.drawsBackground = false
        statsLabel.autoresizingMask = [.minYMargin]
        sidebar.addSubview(statsLabel)

        // Separator line
        let separator2 = createSeparator(y: 160, width: sidebarWidth)
        separator2.autoresizingMask = [.maxYMargin, .width]
        sidebar.addSubview(separator2)

        // Developer info section at bottom - centered
        let infoY: CGFloat = 120
        addInfoLabel(to: sidebar, text: "Developed by", y: infoY, bold: false)
        addInfoLabel(to: sidebar, text: "ItzDaxxy", y: infoY - 25, bold: true)
        addInfoLabel(to: sidebar, text: "", y: infoY - 55, bold: false, color: NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0))
        addInfoLabel(to: sidebar, text: "itzdaxxy@users.noreply.github.com", y: infoY - 80, bold: false, color: NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0))

        // Add sidebar to window
        contentView.addSubview(sidebar, positioned: .above, relativeTo: nil)

        // Adjust existing content to make room for sidebar
        adjustContentForSidebar(sidebarWidth: sidebarWidth)
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

    private func addInfoLabel(to view: NSView, text: String, y: CGFloat, bold: Bool, color: NSColor = NSColor(white: 0.8, alpha: 1.0)) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: y, width: 210, height: 20)
        label.alignment = .center
        label.font = bold ? NSFont.systemFont(ofSize: 13, weight: .bold) : NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
    }

    private func adjustContentForSidebar(sidebarWidth: CGFloat) {
        guard let window = window, let contentView = window.contentView else { return }

        // Find the scroll view containing the table
        let scrollView = tableView?.enclosingScrollView

        // Adjust all existing content to move right by sidebar width
        for subview in contentView.subviews {
            // Skip the sidebar itself (it's the last subview we added)
            if subview.frame.minX == 0 && subview.frame.width == sidebarWidth {
                continue
            }

            // Move subview to the right of the sidebar
            var frame = subview.frame
            frame.origin.x += sidebarWidth

            // If it's a scroll view (table container), reduce its width
            if subview == scrollView {
                frame.size.width = max(contentView.bounds.width - sidebarWidth, 400)
            }

            subview.frame = frame

            // Set autoresizing mask for dynamic layout
            if subview == scrollView {
                subview.autoresizingMask = [.width, .height]
            } else {
                subview.autoresizingMask = [.maxXMargin, .minYMargin]
            }
        }

        // Increase window minimum size to show all buttons AND status bar (60px)
        // Status bar is at y=0, so we need enough height to show: table view + buttons + status bar
        let minHeightForStatusBar: CGFloat = 650  // Increased from 500 to ensure status bar is visible
        window.minSize = NSSize(width: sidebarWidth + 800, height: minHeightForStatusBar)

        // Set default window size to ensure all controls are visible including status bar
        var windowFrame = window.frame
        if windowFrame.size.width < sidebarWidth + 1000 || windowFrame.size.height < minHeightForStatusBar {
            windowFrame.size.width = sidebarWidth + 1000
            windowFrame.size.height = minHeightForStatusBar
            windowFrame.origin.x -= (sidebarWidth + 1000 - window.frame.width) / 2  // Keep window centered
            windowFrame.origin.y -= (minHeightForStatusBar - window.frame.height) / 2
            window.setFrame(windowFrame, display: true, animate: false)
        }
    }

    private func addStatusBar() {
        guard let window = window, let contentView = window.contentView else { return }

        let statusBarHeight: CGFloat = 60
        let sidebarWidth: CGFloat = 220

        // First, move ALL existing subviews up by statusBarHeight (except sidebar)
        for subview in contentView.subviews {
            // Skip the sidebar (it's at x=0, width=220)
            if subview.frame.minX == 0 && subview.frame.width == sidebarWidth {
                continue
            }

            // Move everything else up
            var frame = subview.frame
            if frame.origin.y < contentView.bounds.height / 2 {
                // Only move things in the bottom half up
                frame.origin.y += statusBarHeight
            }
            subview.frame = frame
        }

        // Adjust table view specifically
        if let scrollView = tableView?.enclosingScrollView {
            var frame = scrollView.frame
            frame.size.height -= statusBarHeight
            scrollView.frame = frame
        }

        // Create status bar view
        let statusBarView = NSView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: statusBarHeight))
        statusBarView.wantsLayer = true
        statusBarView.autoresizingMask = [.width, .maxYMargin]

        // Cybersecurity dark background with subtle gradient
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = statusBarView.bounds
        gradientLayer.colors = [
            NSColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 0.95).cgColor,
            NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 0.95).cgColor
        ]
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        statusBarView.layer?.addSublayer(gradientLayer)

        // Add top border with neon cyan
        let borderView = NSBox(frame: NSRect(x: 0, y: statusBarHeight - 1, width: contentView.bounds.width, height: 1))
        borderView.boxType = .separator
        borderView.fillColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.5)
        borderView.autoresizingMask = [.width, .maxYMargin]
        statusBarView.addSubview(borderView)

        // Status label - shows running VMs count
        let label = NSTextField(labelWithString: "● RUNNING VMs: 0")
        label.frame = NSRect(x: sidebarWidth + 15, y: 25, width: 200, height: 20)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)  // Neon green
        label.autoresizingMask = [.maxXMargin]
        statusBarView.addSubview(label)
        statusLabel = label

        // Container for running VMs (horizontally scrollable) - increased height
        let scrollView = NSScrollView(frame: NSRect(x: sidebarWidth + 15, y: 2, width: contentView.bounds.width - sidebarWidth - 30, height: 28))
        scrollView.autoresizingMask = [.width]
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        stackView.orientation = .horizontal
        stackView.spacing = 15
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)

        scrollView.documentView = stackView
        statusBarView.addSubview(scrollView)
        runningVMsContainer = stackView

        // Add status bar to window - add it LAST so it's on top
        contentView.addSubview(statusBarView)
        statusBar = statusBarView

        print("DEBUG: Status bar created with frame: \(statusBarView.frame)")
        print("DEBUG: Content view bounds: \(contentView.bounds)")
        print("DEBUG: Status bar subviews count: \(statusBarView.subviews.count)")
        print("DEBUG: Status bar is hidden: \(statusBarView.isHidden)")
    }

    func updateStatusBar(runningVMs: [(vm: VMConfiguration, state: String)]) {
        guard let container = runningVMsContainer, let label = statusLabel else {
            print("DEBUG: Status bar container or label is nil!")
            return
        }

        print("DEBUG: Updating status bar with \(runningVMs.count) running VMs")

        // Update count
        label.stringValue = "● RUNNING VMs: \(runningVMs.count)"

        // Clear existing VM status items
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Add status item for each running VM
        for (vm, state) in runningVMs {
            print("DEBUG: Adding status item for VM: \(vm.name), state: \(state)")
            let itemView = createVMStatusItem(vm: vm, state: state)
            container.addArrangedSubview(itemView)
        }

        // Force layout update
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        print("DEBUG: Status bar updated, container has \(container.arrangedSubviews.count) views")
    }

    private func createVMStatusItem(vm: VMConfiguration, state: String) -> NSView {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 0.8).cgColor
        containerView.layer?.cornerRadius = 4
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.4).cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Set explicit size constraints
        containerView.widthAnchor.constraint(equalToConstant: 280).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // VM name and state
        let stateColor: NSColor
        let stateIcon: String
        switch state.lowercased() {
        case "running":
            stateColor = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)  // Neon green
            stateIcon = "▶"
        case "paused":
            stateColor = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)  // Yellow
            stateIcon = "⏸"
        case "stopped":
            stateColor = NSColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 1.0)  // Red
            stateIcon = "⏹"
        default:
            stateColor = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)  // Grey
            stateIcon = "●"
        }

        let nameLabel = NSTextField(labelWithString: "\(stateIcon) \(vm.name)")
        nameLabel.frame = NSRect(x: 8, y: 2, width: 150, height: 20)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = stateColor
        nameLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(nameLabel)

        // Action buttons
        let buttonY: CGFloat = 3
        let buttonHeight: CGFloat = 18
        let buttonWidth: CGFloat = 38

        // Stop button
        let stopButton = NSButton(frame: NSRect(x: 165, y: buttonY, width: buttonWidth, height: buttonHeight))
        stopButton.title = "Stop"
        stopButton.bezelStyle = .roundRect
        stopButton.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        stopButton.controlSize = .mini
        stopButton.target = self
        stopButton.action = #selector(stopVMFromStatusBar(_:))
        stopButton.tag = vm.id.hashValue
        containerView.addSubview(stopButton)

        // Restart button
        let restartButton = NSButton(frame: NSRect(x: 207, y: buttonY, width: buttonWidth, height: buttonHeight))
        restartButton.title = "⟳"
        restartButton.bezelStyle = .roundRect
        restartButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        restartButton.controlSize = .mini
        restartButton.target = self
        restartButton.action = #selector(restartVMFromStatusBar(_:))
        restartButton.tag = vm.id.hashValue
        containerView.addSubview(restartButton)

        // Pause button
        let pauseButton = NSButton(frame: NSRect(x: 249, y: buttonY, width: 25, height: buttonHeight))
        pauseButton.title = "⏸"
        pauseButton.bezelStyle = .roundRect
        pauseButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        pauseButton.controlSize = .mini
        pauseButton.target = self
        pauseButton.action = #selector(pauseVMFromStatusBar(_:))
        pauseButton.tag = vm.id.hashValue
        containerView.addSubview(pauseButton)

        return containerView
    }

    @objc private func stopVMFromStatusBar(_ sender: NSButton) {
        // TODO: Implement stop VM functionality
        print("Stop VM with hash: \(sender.tag)")
    }

    @objc private func restartVMFromStatusBar(_ sender: NSButton) {
        // TODO: Implement restart VM functionality
        print("Restart VM with hash: \(sender.tag)")
    }

    @objc private func pauseVMFromStatusBar(_ sender: NSButton) {
        // TODO: Implement pause VM functionality
        print("Pause VM with hash: \(sender.tag)")
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // When user clicks the close button on the library window, quit the app
        NSApplication.shared.terminate(nil)
        return false
    }

    @objc private func handleVMStatusChanged(_ notification: Notification) {
        // Refresh the table to show updated status
        DispatchQueue.main.async {
            print("DEBUG: VM status changed, refreshing table")
            self.tableView?.reloadData()

            // Update status bar with current running VMs
            self.refreshStatusBar()
        }
    }

    private func refreshStatusBar() {
        let runningVMs = vmManager.getRunningVMs()
        print("DEBUG: Refreshing status bar - \(runningVMs.count) running VMs")
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
            print("  - VM: \(vm.name), Status: \(stateString)")
            return (vm: vm, state: stateString)
        }
        updateStatusBar(runningVMs: vmStates)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        let count = vmManager.virtualMachines.count
        print("DEBUG: numberOfRows called, returning \(count)")
        return count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        print("DEBUG: viewFor tableColumn called for row \(row), column identifier: \(tableColumn?.identifier.rawValue ?? "nil")")

        guard row < vmManager.virtualMachines.count else {
            print("DEBUG: Row \(row) out of bounds!")
            return nil
        }

        let vm = vmManager.virtualMachines[row]

        // Try to get existing cell, or create new one programmatically
        var cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTableCellView

        if cell == nil {
            print("DEBUG: Creating new cell programmatically for identifier: \(tableColumn?.identifier.rawValue ?? "nil")")
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
            print("DEBUG: Failed to create cell")
            return nil
        }

        print("DEBUG: Cell ready for row \(row), column \(tableColumn?.identifier.rawValue ?? "nil")")

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
        DispatchQueue.main.async { [weak self] in
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
                    progressAlert.informativeText = message
                    let percentage = progress * 100.0
                    progressIndicator.doubleValue = percentage
                    percentageLabel.stringValue = String(format: "%.1f%%", percentage)
                    // Force visual update during modal run loop
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

    private func downloadAndPrepareLinuxVM(_ vmConfig: VMConfiguration, distro: LinuxDistro, isRouter: Bool) {
        NSLog("[VMLibrary] === downloadAndPrepareLinuxVM() ENTERED ===")
        NSLog("[VMLibrary] VM config: %@, distro: %@, isRouter: %d", vmConfig.name, distro.rawValue, isRouter)

        // Check if ISO is already cached
        let imageType = VMImageType.linux(distro: distro, version: distro.version, isSecurityRouter: isRouter)
        if let cachedISO = ISOCacheManager.shared.getCachedImage(for: imageType) {
            NSLog("[VMLibrary] ISO already cached at: %@", cachedISO.path)
            // Start VM immediately with cached ISO
            selectedVM = vmConfig
            vmManager.updateLastUsedDate(vmConfig)
            NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": vmConfig, "iso": cachedISO])
            return
        }

        NSLog("[VMLibrary] ISO not cached, will download")

        // Create progress alert
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading \(distro.rawValue) ISO"
        progressAlert.informativeText = "Initializing..."
        progressAlert.alertStyle = .informational
        progressAlert.addButton(withTitle: "Cancel")

        // Create a container view for progress bar, percentage label, and URL
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 75))

        // Add source URL label at top for security transparency
        let urlLabel = NSTextField(labelWithString: "Source: \(distro.downloadURL)")
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

        cacheManager.downloadImage(
            for: imageType,
            progressHandler: { progress, message in
                // Use performSelector for modal dialog compatibility
                RunLoop.main.perform(inModes: [.common], block: {
                    progressAlert.informativeText = message
                    let percentage = progress * 100.0
                    progressIndicator.doubleValue = percentage
                    percentageLabel.stringValue = String(format: "%.1f%%", percentage)
                    // Force visual update during modal run loop
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
            guard let self = self else { return }
            print("DEBUG: Refreshing table with \(self.vmManager.virtualMachines.count) VMs")
            for (index, vm) in self.vmManager.virtualMachines.enumerated() {
                print("  - [\(index)] \(vm.name)")
            }
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 340))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 310, width: 100, height: 20)
        view.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 110, y: 308, width: 280, height: 24))
        nameField.stringValue = "New VM"
        view.addSubview(nameField)

        // OS Type dropdown
        let osLabel = NSTextField(labelWithString: "OS Type:")
        osLabel.frame = NSRect(x: 0, y: 280, width: 100, height: 20)
        view.addSubview(osLabel)

        let osPopup = NSPopUpButton(frame: NSRect(x: 110, y: 275, width: 150, height: 26), pullsDown: false)
        osPopup.addItem(withTitle: "Linux")
        osPopup.addItem(withTitle: "macOS")
        osPopup.selectItem(at: 0) // Default to Linux
        view.addSubview(osPopup)

        // Linux Distribution dropdown (only visible for Linux VMs)
        let distroLabel = NSTextField(labelWithString: "Distribution:")
        distroLabel.frame = NSRect(x: 0, y: 250, width: 100, height: 20)
        view.addSubview(distroLabel)

        let distroPopup = NSPopUpButton(frame: NSRect(x: 110, y: 245, width: 200, height: 26), pullsDown: false)
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

        // ISO Cache Status Label (below distro dropdown)
        let isoCacheStatusLabel = NSTextField(labelWithString: "")
        isoCacheStatusLabel.frame = NSRect(x: 110, y: 220, width: 280, height: 20)
        isoCacheStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        isoCacheStatusLabel.isEditable = false
        isoCacheStatusLabel.isBordered = false
        isoCacheStatusLabel.drawsBackground = false
        view.addSubview(isoCacheStatusLabel)

        // Delegate to handle dynamic UI updates
        class VMConfigDelegate: NSObject {
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
            weak var isoCacheStatusLabel: NSTextField?
            weak var vmManager: VMManager?

            @objc func osTypeChanged(_ sender: NSPopUpButton) {
                let isMacOS = sender.titleOfSelectedItem == "macOS"
                isoCheckbox?.isHidden = isMacOS
                createButton?.title = isMacOS ? "Create" : "Select ISO"

                // Show/hide Linux-specific controls
                distroPopup?.isHidden = isMacOS
                distroLabel?.isHidden = isMacOS

                // Update ISO cache status when showing Linux controls
                if !isMacOS {
                    updateISOCacheStatus()
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
        configDelegate.isoCacheStatusLabel = isoCacheStatusLabel

        // Set up delegate actions
        osPopup.target = configDelegate
        osPopup.action = #selector(VMConfigDelegate.osTypeChanged(_:))
        networkPopup.target = configDelegate
        networkPopup.action = #selector(VMConfigDelegate.networkModeChanged(_:))
        linuxRouterCheckbox.target = configDelegate
        linuxRouterCheckbox.action = #selector(VMConfigDelegate.linuxRouterCheckboxChanged(_:))
        distroPopup.target = configDelegate
        distroPopup.action = #selector(VMConfigDelegate.distroChanged(_:))

        // Initialize ISO cache status check for Kali (default selection)
        configDelegate.updateISOCacheStatus()

        alert.accessoryView = view

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue
            let osType = osPopup.titleOfSelectedItem ?? "Linux"
            let cpuCount = Int(cpuField.stringValue) ?? 2
            let memoryGB = UInt64(memField.stringValue) ?? 4
            let diskGB = UInt64(diskField.stringValue) ?? 64
            let enableRosetta = rosettaCheckbox.state == .on
            let needsISO = isoCheckbox.state == .on
            let networkModeIndex = networkPopup.indexOfSelectedItem
            let isLinuxRouter = routerCheckbox.state == .on || linuxRouterCheckbox.state == .on
            let selectedRouterName = routerPopup.titleOfSelectedItem
            let selectedDistro = distroPopup.titleOfSelectedItem ?? "Kali"

            print("DEBUG: Creating VM with Rosetta: \(enableRosetta)")
            print("DEBUG: Selected distro: \(selectedDistro)")
            print("DEBUG: Is Linux Router: \(isLinuxRouter)")

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
                    // Map distro name to version
                    let distroEnum = mapDistroNameToEnum(selectedDistro)
                    newVM.linuxVersion = distroEnum.version
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
                    downloadAndPrepareLinuxVM(newVM, distro: distroEnum, isRouter: isLinuxRouter)
                }
            } catch {
                showAlert(message: "Failed to create VM: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startVM = Notification.Name("startVM")
    static let startVMWithISO = Notification.Name("startVMWithISO")
    static let vmStatusChanged = Notification.Name("vmStatusChanged")
}

// MARK: - UTType Extensions

import UniformTypeIdentifiers

extension UTType {
    static let iso = UTType(filenameExtension: "iso")!
    static let bundle = UTType(filenameExtension: "bundle")!
}
