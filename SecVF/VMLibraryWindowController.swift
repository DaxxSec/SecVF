//
//  VMLibraryWindowController.swift
//  SecVF
//

import Cocoa
import Virtualization

/// A single row in the AI Sandbox tab of the library. Wraps either the
/// shared base bundle or a per-session clone, with whatever metadata we
/// can scrape from the bundle's `manifest.json` and disk.img mtime.
struct AISandboxBundleRow {
    let url: URL
    let displayName: String
    let isBase: Bool
    let id: UUID?
    let createdAt: Date?
    let diskBytes: Int64

    /// Pulled from the bundle URL: `ai-sandbox-exec-<sessionID>.bundle`.
    /// Returns nil for the base bundle (which has no session id).
    var sessionID: String? {
        guard !isBase else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let prefix = "ai-sandbox-exec-"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }
}

/// Reference-typed wrapper used as NSOutlineView's "item". NSOutlineView
/// identifies items by object identity for reference types, which is the
/// only reliable way to track selection / expansion state across reloads.
/// `children` is nil for session leaves; non-nil (possibly empty) for the
/// base node.
final class AISandboxNode: NSObject {
    let bundle: AISandboxBundleRow
    var children: [AISandboxNode]?
    init(bundle: AISandboxBundleRow, children: [AISandboxNode]?) {
        self.bundle = bundle
        self.children = children
    }
}

@MainActor
class VMLibraryWindowController: NSWindowController,
                                 NSTableViewDataSource, NSTableViewDelegate,
                                 NSOutlineViewDataSource, NSOutlineViewDelegate,
                                 NSWindowDelegate {

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

    // Live network rates per VM, computed from VirtualNetworkSwitch port
    // byte counters polled every ~1.5s. `lastNetSample` stores the previous
    // counter + timestamp; `liveRateBps` is the latest rate the detail card
    // reads from. Only the virtual-switch path is sampled — NAT-mode VMs
    // don't show a per-VM rate (the host network stack doesn't expose one).
    private struct NetSample { let bytesRx: UInt64; let bytesTx: UInt64; let ts: Date }
    private var lastNetSample: [String: NetSample] = [:]
    private var liveRateBps: [String: (down: Double, up: Double)] = [:]
    private var liveRateTimer: Timer?

    /// Rolling per-VM buffer of (down + up) bytes/sec samples. Drives the
    /// Traffic column sparkline. `maxTrafficSamples` × the timer cadence
    /// (1.5s) defines the visible time window — 30 samples = ~45 s.
    private var trafficSamples: [String: [Double]] = [:]
    private static let maxTrafficSamples = 30

    // Right panel tabs (VMs / Tasks)
    private var rightPanelTabControl: NSSegmentedControl?
    private var vmsTabContent: NSView?
    private var tasksTabContent: NSView?
    private var tasksLogTextView: NSTextView?
    /// Count of log lines already rendered into `tasksLogTextView`. Used by
    /// `refreshTasksTab()` to append only new lines instead of rebuilding
    /// the entire text-view storage on every notification (S14 of PR #4 review).
    private var lastDisplayedLogCount = 0
    private var tasksStatusLabel: NSTextField?
    private var tasksProgressBar: NSProgressIndicator?
    private var vmsPlaceholderLabel: NSTextField?

    // Library tab — switches the table between the standard VM list and
    // the AI Sandbox bundle list. Recovery toggle is visible only in the
    // AI Sandbox tab.
    private enum LibraryTab: Int {
        case standard = 0
        case aiSandbox = 1
    }
    private var currentLibraryTab: LibraryTab = .standard
    private var libraryTabControl: NSSegmentedControl?
    private var recoveryModeCheckbox: NSButton?
    /// Cached scan of `~/.avf/AISandbox/` — base + each session bundle.
    /// Refreshed each time the AI Sandbox tab is selected.
    /// In tree-view mode this still backs the data: `[0]` is the base
    /// (root parent) and `[1...]` are sessions (children of the base),
    /// ordered newest-first.
    private var aiSandboxBundles: [AISandboxBundleRow] = []

    /// Separate outline view + scroll view for the AI Sandbox tab. Sits
    /// underneath the main NSTableView (same frame) and toggles visibility
    /// on tab switch. The standard NSTableView stays in charge of standard
    /// VMs; outline view shows the base→sessions tree.
    private var aiSandboxOutlineView: NSOutlineView?
    private var aiSandboxOutlineScroll: NSScrollView?

    /// Node tree backing `aiSandboxOutlineView`. Single root (the base)
    /// with the session bundles as children. Rebuilt whenever
    /// `aiSandboxBundles` is re-scanned.
    private var aiSandboxRootNode: AISandboxNode?

    // Empty-state overlay labels — one per tab, shown over the table /
    // outline view when there are no rows to display.
    private var standardEmptyStateLabel: NSTextField?
    private var aiSandboxEmptyStateLabel: NSTextField?

    // Top toolbar pill containers (Primary / Create / Modify / Destructive).
    // Tracked so windowDidResize can re-anchor them.
    private var toolbarPillContainers: [NSView] = []

    // Right-gutter overlay that draws bracket connectors between rows of
    // running VMs that share a virtual-switch network group (router and
    // guests). Refreshed whenever the table reloads or any VM status
    // changes.
    private var connectionOverlay: VMConnectionOverlayView?

    // Left-edge overlay that cascades small "packet" dots down each row
    // whose VM is running with non-zero network activity. Pure eyecandy
    // (relocated from the deleted right-panel NetworkTrafficView); the
    // overlay drives its own 30 fps timer and auto-stops when idle.
    private var trafficFallOverlay: VMTrafficFallOverlayView?

    /// Optional set of VM UUIDs to focus the standard-tab table on.
    /// `nil` (default) means "show every VM"; a non-nil set means
    /// "show only the rows whose IDs are in this set". Driven by the
    /// "Focus Running ▾" button in the tabs row.
    private var runningFilterIDs: Set<UUID>?

    /// Button that pops the running-VM filter menu. Hidden when no VMs
    /// are running (nothing to filter to). Title gets a count badge
    /// while a filter is active so the user can see at a glance.
    private var runningFilterButton: NSButton?

    // Bottom status bar — slim global-state strip pinned to the bottom of
    // the content view, under the packet panel.
    private var bottomStatusBar: NSView?
    private var statusBarRunningLabel: NSTextField?
    private var statusBarSwitchLabel: NSTextField?
    private var statusBarNATLabel: NSTextField?
    private var statusBarCaptureLabel: NSTextField?
    private var statusBarDiskLabel: NSTextField?
    private var statusBarPulseDot: CAShapeLayer?
    private var statusBarRefreshTimer: Timer?

    /// Previous NAT-bridge byte sample, used to compute a bytes/sec delta
    /// each tick of the status bar refresh.
    private var statusBarPreviousNATSample: BridgeSample?

    // Selected VM detail card (horizontal strip between table and packet panel)
    private var selectedVMDetailCard: NSView?
    private var detailNameLabel: NSTextField?
    private var detailStatusPill: NSTextField?
    private var detailOSLabel: NSTextField?
    private var detailResourcesLabel: NSTextField?
    // Thin progress bar that sits just below the CPU · RAM value cell in
    // the detail card. Shows VM's configured RAM as a fraction of total
    // host RAM — an honest "is this allocation heavy?" indicator since
    // live guest RAM usage isn't available without guest tools.
    private var detailMemoryBarTrack: NSView?
    private var detailMemoryBarFill: CALayer?
    // Uptime metric cell. Empty / "—" when the selected VM isn't running;
    // formatted as "Xh Ym" or "Ym Zs" when it is.
    private var detailUptimeLabel: NSTextField?
    // Packets-since-start metric cell. Reads the cumulative rx+tx packet
    // count for the VM's port on the virtual switch.
    private var detailPacketsLabel: NSTextField?
    // Quick-action buttons on the right edge of the detail card. Disabled
    // when no VM is selected; Console additionally disabled when the
    // selected VM isn't running.
    private var detailConsoleButton: NSButton?
    private var detailCaptureButton: NSButton?
    // Per-VM run timestamps, keyed by UUID. Populated when a VM
    // transitions to .running, cleared when it transitions away.
    private var vmStartedAt: [UUID: Date] = [:]
    private var detailDiskLabel: NSTextField?
    private var detailNetworkModeLabel: NSTextField?
    private var detailNetworkRateLabel: NSTextField?

    // Packet Log Panel
    private var packetLogPanel: NSView?
    private var packetLogTabControl: NSSegmentedControl?
    // CAPTURING pill + live rate readout (replaces the old Packets/Protocols
    // tab in the panel header; matches the mockup).
    private var packetCapturingPill: NSView?
    private var packetCapturingPillDot: CAShapeLayer?
    private var packetRateLabel: NSTextField?
    private var packetVMFilterControl: NSSegmentedControl?
    private var packetListContainer: NSScrollView?
    private var protocolStatsContainer: NSView?
    // Note: the PacketAnalysisWindowController is owned by AppDelegate (single
    // owner). This controller posts .openPacketAnalysis to surface that window
    // — see openPacketAnalysisWindow(_:) below.
    private var currentVMFilter: String = "macOS"  // Default to macOS packets
    private var filterARPEnabled: Bool = true  // Filter ARP by default
    private var arpFilteredCount: Int = 0
    private var arpFilterCountLabel: NSTextField?

    override var windowNibName: NSNib.Name? {
        return "VMLibraryWindow"
    }

    deinit {
        // Clean up timers and notification observers to prevent memory leaks
        statsUpdateTimer?.invalidate()
        liveRateTimer?.invalidate()
        statusBarRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        // Set window delegate to handle close button
        window?.delegate = self

        // Ensure window stays in front
        window?.level = .normal
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window?.minSize = NSSize(width: LayoutConstants.minWindowWidth,
                                 height: LayoutConstants.minWindowHeight)

        // If `frameAutosaveName` restored a frame that no current screen
        // overlaps (e.g., last run was on an external display that's no
        // longer attached), center the window on the primary screen so it
        // doesn't open off-screen.
        if let win = window, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(win.frame) }) {
            win.center()
        }

        // Apply dark theme, add sidebar, and add status bar
        applyDarkTheme()
        addSidebar()
        addStatusBar()
        addBottomStatusBar()

        // Configure table view
        tableView?.dataSource = self
        tableView?.delegate = self
        tableView?.target = self
        tableView?.doubleAction = #selector(startVM(_:))

        // Connection overlay — draws bracket connectors in the table's
        // right gutter between rows of running VMs that share a virtual-
        // switch network group (router + its guests). Added as a SUBVIEW
        // of the table so its coords match `tableView.rect(ofRow:)` 1:1
        // and it scrolls with the content automatically. Mouse events
        // pass through (hitTest returns nil) so table selection works.
        if let tableView = tableView, connectionOverlay == nil {
            let overlay = VMConnectionOverlayView(frame: tableView.bounds)
            overlay.tableView = tableView
            overlay.autoresizingMask = [.width, .height]
            tableView.addSubview(overlay)
            connectionOverlay = overlay
        }

        // Traffic-fall overlay sits on the LEFT edge of each row (4-10pt
        // strip) and is purely decorative. Added BELOW the connection
        // overlay z-wise (which lives on the right gutter) so the two
        // never visually overlap. Same coordinate trick: subview of the
        // table, autoresize to track.
        if let tableView = tableView, trafficFallOverlay == nil {
            let overlay = VMTrafficFallOverlayView(frame: tableView.bounds)
            overlay.tableView = tableView
            overlay.autoresizingMask = [.width, .height]
            tableView.addSubview(overlay, positioned: .below, relativeTo: connectionOverlay)
            trafficFallOverlay = overlay
        }

        // Programmatically append a Traffic column at the end of whatever
        // the XIB defined. Done in code (not the XIB) so the column can
        // host a custom NSView (SparklineView) rather than the default
        // NSTextField cell. The column is non-resizable and ~80pt wide —
        // enough for a glanceable line, not so wide it eats other columns.
        if let tableView = tableView,
           !tableView.tableColumns.contains(where: { $0.identifier.rawValue == "TrafficColumn" }) {
            let trafficCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TrafficColumn"))
            trafficCol.title = "Traffic"
            trafficCol.width = 80
            trafficCol.minWidth = 60
            trafficCol.maxWidth = 120
            trafficCol.headerCell.alignment = .center
            tableView.addTableColumn(trafficCol)
        }

        // Load VMs asynchronously to avoid blocking main thread
        vmManager.initializeAsync { [weak self] in
            guard let self = self else { return }
            self.tableView?.reloadData()
            self.refreshStatusBar()
            self.refreshEmptyStateOverlays()
            self.refreshConnectionOverlay()
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

        // Refresh the running-VMs sidebar whenever an AI Sandbox install
        // changes phase or progress so the user sees real-time state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAISandboxInstallTrackerChanged(_:)),
            name: .aiSandboxInstallTrackerChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIPSWDownloadTrackerChanged(_:)),
            name: .ipswDownloadTrackerChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVMBundleSizeUpdated(_:)),
            name: .vmBundleSizeUpdated,
            object: nil
        )

        // Start the live network-rate timer (1.5s cadence). Samples the
        // VirtualNetworkSwitch per-port byte counters and computes a moving
        // bytes/sec for each VM. Detail card reads from `liveRateBps`.
        liveRateTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLiveNetworkRates() }
        }

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
        contentView.layer?.backgroundColor = AppColors.backgroundPrimary.cgColor

        // Style table view with dark theme - darker grey
        tableView?.backgroundColor = AppColors.backgroundSecondary
        tableView?.enclosingScrollView?.backgroundColor = AppColors.backgroundSecondary
        tableView?.gridColor = AppColors.borderCyan

        // Style toolbar buttons to match session panel
        styleToolbarButtons()
    }

    private func styleToolbarButtons() {
        let buttons: [NSButton?] = [newButton, startButton, deleteButton, renameButton, cloneButton, importButton, configureButton]

        for button in buttons.compactMap({ $0 }) {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
            button.layer?.borderWidth = LayoutConstants.borderHairline
            applyButtonStyle(button)
        }

        // Primary (Start) gets a brighter border + filled background.
        // Destructive (Delete) gets a red border so it stands out.
        startButton?.layer?.borderColor = AppColors.accentNeonCyan.withAlphaComponent(0.8).cgColor
        startButton?.layer?.borderWidth = LayoutConstants.borderEmphasis
        deleteButton?.layer?.borderColor = AppColors.accentRed.withAlphaComponent(0.6).cgColor

        // Keyboard shortcuts. The XIB sets Start's keyEquivalent to Return
        // (no modifier) so it acts as the table's default action. Here we
        // add the Cmd-modified shortcuts for the other operations so they
        // don't capture bare keypresses.
        newButton?.keyEquivalent = "n"
        newButton?.keyEquivalentModifierMask = .command
        importButton?.keyEquivalent = "i"
        importButton?.keyEquivalentModifierMask = [.command, .shift]
        deleteButton?.keyEquivalent = String(Character(UnicodeScalar(NSDeleteCharacter)!))
        deleteButton?.keyEquivalentModifierMask = .command
    }

    /// Build the "● CAPTURING" pill for the packet panel header. Orange dot
    /// pulses while capture is active; the whole pill is hidden when capture
    /// is idle. Animation is opt-in via `setPacketCapturingActive(_:)`.
    private func makeCapturingPill() -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = AppColors.accentOrange.withAlphaComponent(0.10).cgColor
        pill.layer?.borderColor = AppColors.borderOrange.cgColor
        pill.layer?.borderWidth = LayoutConstants.borderHairline
        pill.layer?.cornerRadius = 10
        pill.isHidden = true   // shown when capture starts

        // Pulse dot — same idiom as the bottom status bar.
        let dotSize: CGFloat = 6
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize), transform: nil)
        dot.fillColor = AppColors.accentOrangeHot.cgColor
        dot.shadowColor = AppColors.accentOrangeHot.cgColor
        dot.shadowOpacity = 0.8
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.frame = CGRect(x: 8, y: (20 - dotSize) / 2, width: dotSize, height: dotSize)
        pill.layer?.addSublayer(dot)
        packetCapturingPillDot = dot

        let label = NSTextField(labelWithString: "CAPTURING")
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = AppColors.accentOrangeHot
        label.frame = NSRect(x: 22, y: 3, width: 80, height: 14)
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        pill.addSubview(label)

        return pill
    }

    /// Repaint the "↓ X/s ↑ Y/s · N pkts" rate readout in the packet panel
    /// header. Combines the aggregate switch + NAT bridge rates so the user
    /// sees one number that represents "all VM traffic flowing through the
    /// host", matching the panel's role as the multi-VM live preview.
    private func refreshPacketPanelRate(totalPackets: Int, capturing: Bool) {
        guard let rateLabel = packetRateLabel else { return }
        guard capturing else {
            rateLabel.stringValue = "capture idle"
            rateLabel.textColor = AppColors.textMuted
            return
        }
        // Sum the per-VM virtual switch rates (already in liveRateBps).
        var totalDown: Double = 0
        var totalUp: Double = 0
        for (_, rate) in liveRateBps {
            totalDown += rate.down
            totalUp += rate.up
        }
        // Add the aggregate NAT bridge sample if available — uses the
        // status bar's existing previous-sample state, so we recompute
        // from the latest pair to stay consistent.
        let natSample = BridgeInterfaceStats.sample()
        if let natRate = BridgeInterfaceStats.rate(from: statusBarPreviousNATSample,
                                                   to: natSample) {
            totalDown += natRate.down
            totalUp += natRate.up
        }
        let down = ByteCountFormatter.string(fromByteCount: Int64(totalDown), countStyle: .binary)
        let up = ByteCountFormatter.string(fromByteCount: Int64(totalUp), countStyle: .binary)
        rateLabel.stringValue = "↓ \(down)/s  ↑ \(up)/s  ·  \(formatCount(totalPackets)) pkts"
        // Hot tint when there's real traffic (>1 KiB/s combined)
        let hot = (totalDown + totalUp) > 1024
        rateLabel.textColor = hot ? AppColors.accentOrangeHot : AppColors.textMuted
    }

    /// Toggle the packet-capturing pill's visibility + pulse animation.
    private func setPacketCapturingActive(_ active: Bool) {
        packetCapturingPill?.isHidden = !active
        if active, packetCapturingPillDot?.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.4
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            packetCapturingPillDot?.add(pulse, forKey: "pulse")
        } else if !active {
            packetCapturingPillDot?.removeAnimation(forKey: "pulse")
        }
    }

    /// Tactical-themed `NSSegmentedControl`. Uses `.roundRect` (cleaner than
    /// the heavy `.texturedSquare`) and tints the selected segment with the
    /// OD-green primary accent so it reads as part of the SecVF palette
    /// instead of a stock blue Mac control. Falls back gracefully on older
    /// macOS where `selectedSegmentBezelColor` is unavailable.
    static func applyTacticalStyle(to control: NSSegmentedControl) {
        control.segmentStyle = .roundRect
        control.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody, weight: .medium)
        if #available(macOS 10.12.2, *) {
            control.selectedSegmentBezelColor = AppColors.accentOD
        }
    }

    /// Apply the tactical-theme button styling. Buttons now live INSIDE pill
    /// containers (see `makeButtonPillContainer`) which supply the visual
    /// frame, so each button's own border + fill are transparent — only the
    /// text styling stays. The pill itself color-codes the group (OD-glow
    /// for primary, red for destructive, plain OD for the rest).
    ///
    /// Tactical conventions:
    /// - **Primary** (Start) — semibold near-white text in an OD-glow pill.
    /// - **Destructive** (Delete) — red text in a red-bordered pill.
    /// - **Secondary** — OD text in a plain OD-bordered pill.
    private func applyButtonStyle(_ button: NSButton) {
        let isPrimary = (button === startButton)
        let isDestructive = (button === deleteButton)
        let enabled = button.isEnabled

        // Background + border are owned by the parent pill — keep the
        // button's own layer transparent so the pill's frame reads cleanly.
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderColor = NSColor.clear.cgColor

        let textColor: NSColor
        if isDestructive {
            textColor = AppColors.accentRed
        } else if isPrimary {
            textColor = AppColors.textPrimary
        } else {
            textColor = AppColors.textOD
        }
        let fontWeight: NSFont.Weight = isPrimary ? .semibold : .medium
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: textColor.withAlphaComponent(enabled ? 1.0 : 0.4),
            .font: NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody, weight: fontWeight)
        ])
        button.alphaValue = enabled ? 1.0 : 0.7
    }

    /// Wrap a set of NSButton instances in a rounded pill container with a
    /// shared background + border. Buttons sit edge-to-edge with thin
    /// vertical dividers between them. Used by the top toolbar to group
    /// related actions (Create / Modify / Destructive / Primary).
    ///
    /// The pill's frame is sized to fit its buttons; the caller positions
    /// the pill's origin.
    private func makeButtonPillContainer(_ buttons: [NSButton],
                                         borderColor: NSColor = AppColors.borderOD,
                                         fillColor: NSColor = AppColors.backgroundButton.withAlphaComponent(0.55)) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = fillColor.cgColor
        pill.layer?.borderColor = borderColor.cgColor
        pill.layer?.borderWidth = LayoutConstants.borderHairline
        pill.layer?.cornerRadius = LayoutConstants.cornerRadiusMD

        let buttonW: CGFloat = 80
        let buttonH: CGFloat = 32
        let innerPad: CGFloat = 3            // 3pt horizontal padding inside the pill
        let dividerInsetY: CGFloat = 6       // divider doesn't touch top/bottom

        var x: CGFloat = innerPad
        for (i, button) in buttons.enumerated() {
            // Remove from any current superview so addSubview reparents
            button.removeFromSuperview()
            button.frame = NSRect(x: x, y: 1, width: buttonW, height: buttonH)
            pill.addSubview(button)

            // Divider between consecutive buttons in the same pill
            if i > 0 {
                let divider = NSBox(frame: NSRect(x: x - 1, y: dividerInsetY,
                                                  width: 1,
                                                  height: buttonH - dividerInsetY * 2))
                divider.boxType = .custom
                divider.borderWidth = 0
                divider.fillColor = AppColors.borderOD.withAlphaComponent(0.5)
                pill.addSubview(divider)
            }
            x += buttonW
        }

        let totalW = CGFloat(buttons.count) * buttonW + innerPad * 2
        pill.frame = NSRect(x: 0, y: 0, width: totalW, height: buttonH + 2)
        return pill
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
            AppColors.gradientTop.cgColor,
            AppColors.gradientBottom.cgColor
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
            .foregroundColor: AppColors.textLight,
            .paragraphStyle: paragraphStyle
        ])
        attributedTitle.append(secPart)

        // "VF" in medium gray
        let vfPart = NSAttributedString(string: "VF", attributes: [
            .font: font,
            .foregroundColor: AppColors.textMuted,
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
        subtitleLabel.textColor = AppColors.textMuted
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
        statsLabel.textColor = AppColors.textSubtle
        statsLabel.isBordered = false
        statsLabel.isEditable = false
        statsLabel.drawsBackground = false
        statsLabel.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(statsLabel)

        // Logs section — surfaces the three log viewers from the Monitoring
        // menu in the sidebar so the user can hop to them without diving
        // into the menu bar. Buttons dispatch via responder chain so the
        // AppDelegate's existing @objc handlers are called directly (no
        // duplicate state, no new notifications needed).
        let logsHeaderY: CGFloat = sidebar.bounds.height - 340
        let logsHeader = NSTextField(labelWithString: "LOGS")
        logsHeader.frame = NSRect(x: 0, y: logsHeaderY, width: sidebarWidth, height: 14)
        logsHeader.alignment = .center
        logsHeader.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        logsHeader.textColor = AppColors.textSubtle
        logsHeader.isBordered = false
        logsHeader.isEditable = false
        logsHeader.drawsBackground = false
        logsHeader.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(logsHeader)

        let logButtonsTopY: CGFloat = logsHeaderY - 8
        let logEntries: [(title: String, selectorName: String, tooltip: String)] = [
            ("◆ Security",  "showSecurityLogs",
             "Security events captured by VMSecurityMonitor (suspicious activity, resource pressure, isolation breaches). ⇧⌘1"),
            ("◆ Network",   "showNetworkLogs",
             "Per-VM network logs (traffic summaries, switch events, NAT activity). ⇧⌘2"),
            ("◆ ISO Cache", "showISOCacheLogs",
             "Distro ISO download/verify activity from ISOCacheManager."),
        ]
        let buttonHeight: CGFloat = 26
        let buttonGap: CGFloat = 4
        let buttonInset: CGFloat = 16
        for (i, entry) in logEntries.enumerated() {
            let btnY = logButtonsTopY - CGFloat(i + 1) * (buttonHeight + buttonGap)
            let btn = TacticalHoverButton(title: entry.title,
                                          target: nil,
                                          action: NSSelectorFromString(entry.selectorName))
            btn.frame = NSRect(x: buttonInset, y: btnY,
                               width: sidebarWidth - buttonInset * 2,
                               height: buttonHeight)
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            btn.contentTintColor = AppColors.textPrimary
            btn.alignment = .left
            btn.layer?.backgroundColor = AppColors.backgroundButton.cgColor
            btn.layer?.borderColor = AppColors.borderOD.cgColor
            btn.layer?.borderWidth = 1.0
            btn.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
            btn.attributedTitle = NSAttributedString(string: "  " + entry.title, attributes: [
                .foregroundColor: AppColors.textPrimary,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ])
            btn.toolTip = entry.tooltip
            btn.autoresizingMask = [.minYMargin, .width]
            btn.setAccessibilityLabel(entry.title.replacingOccurrences(of: "◆ ", with: "") + " logs")
            btn.setHoverTreatment(hoverBorder: AppColors.accentODGlow)
            sidebar.addSubview(btn)
        }

        // Separator line above developer info
        let separator2 = createSeparator(y: 155, width: sidebarWidth)
        separator2.autoresizingMask = [.maxYMargin, .width]
        sidebar.addSubview(separator2)

        // Framework info section at bottom - CENTERED
        let infoY: CGFloat = 115
        addInfoLabel(to: sidebar, text: "Built on", y: infoY, bold: false, width: sidebarWidth)
        addInfoLabel(to: sidebar, text: "Apple Virtualization Framework", y: infoY - 28, bold: true, width: sidebarWidth)
        addInfoLabel(to: sidebar, text: "github.com/DaxxSec/SecVF", y: infoY - 58, bold: false, color: AppColors.textSubtle, width: sidebarWidth)

        // Add sidebar to window
        contentView.addSubview(sidebar, positioned: .above, relativeTo: nil)

        // Adjust existing content to make room for sidebar
        adjustContentForSidebar(sidebarWidth: sidebarWidth)
    }

    private func createProtocolLegend(width: CGFloat, height: CGFloat) -> NSView {
        let legendView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        legendView.wantsLayer = true
        legendView.layer?.backgroundColor = AppColors.backgroundSecondary.cgColor
        legendView.layer?.cornerRadius = 6
        legendView.layer?.borderWidth = 1
        legendView.layer?.borderColor = AppColors.borderOD.cgColor

        // Legend title
        let titleLabel = NSTextField(labelWithString: "⚡ PROTOCOL COLORS")
        titleLabel.frame = NSRect(x: 8, y: height - 18, width: width - 16, height: 14)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = AppColors.accentODGlow
        legendView.addSubview(titleLabel)

        // Protocol colors — sourced from AppColors.proto* so the legend
        // stays in lock-step with the per-packet row tinting.
        let protocols: [(String, NSColor)] = [
            ("TCP",  AppColors.protoTCP),
            ("UDP",  AppColors.protoUDP),
            ("DNS",  AppColors.protoDNS),
            ("HTTP", AppColors.protoHTTP),
            ("ARP",  AppColors.protoARP),
            ("ICMP", AppColors.protoICMP),
            ("IPv6", AppColors.protoIPv6),
            ("TLS",  AppColors.protoTLS)
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

        // OD glow stroke (was neon cyan)
        AppColors.accentODGlow.setStroke()
        hexPath.stroke()

        // Digital lock icon in center
        let lockWidth: CGFloat = 20
        let lockHeight: CGFloat = 24
        let lockX = centerX - lockWidth / 2
        let lockY = centerY - lockHeight / 2

        // Lock body
        let lockBody = NSBezierPath(roundedRect: NSRect(x: lockX, y: lockY, width: lockWidth, height: lockHeight * 0.6), xRadius: 2, yRadius: 2)
        AppColors.accentODGlow.withAlphaComponent(0.8).setFill()
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
        AppColors.accentODGlow.setStroke()
        shacklePath.stroke()

        // Keyhole
        let keyholePath = NSBezierPath(ovalIn: NSRect(x: centerX - 2, y: lockY + 5, width: 4, height: 4))
        let keyholeSlot = NSBezierPath(rect: NSRect(x: centerX - 1, y: lockY + 2, width: 2, height: 5))
        NSColor.black.setFill()
        keyholePath.fill()
        keyholeSlot.fill()

        // Circuit-board pattern in corners. Now uses safety orange — adds
        // a second-accent hit that ties the logo to the rest of the
        // tactical palette (status bar pulse, sparkline spikes, section
        // ticks all use the same orange).
        AppColors.accentOrange.withAlphaComponent(0.4).setStroke()

        // Top-left circuit
        let circuit1 = NSBezierPath()
        circuit1.move(to: CGPoint(x: 25, y: 85))
        circuit1.line(to: CGPoint(x: 45, y: 85))
        circuit1.line(to: CGPoint(x: 45, y: 75))
        circuit1.lineWidth = 1.2
        circuit1.stroke()

        // Draw nodes
        AppColors.accentOrangeHot.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 23, y: 83, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 43, y: 83, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 43, y: 73, width: 4, height: 4)).fill()

        // Bottom-right circuit
        let circuit2 = NSBezierPath()
        circuit2.move(to: CGPoint(x: 145, y: 35))
        circuit2.line(to: CGPoint(x: 125, y: 35))
        circuit2.line(to: CGPoint(x: 125, y: 45))
        circuit2.lineWidth = 1.2
        AppColors.accentOrange.withAlphaComponent(0.4).setStroke()
        circuit2.stroke()

        AppColors.accentOrangeHot.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 143, y: 33, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 123, y: 33, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 123, y: 43, width: 4, height: 4)).fill()

        image.unlockFocus()
        return image
    }

    private func createSeparator(y: CGFloat, width: CGFloat) -> NSBox {
        let separator = NSBox(frame: NSRect(x: 20, y: y, width: width - 40, height: 1))
        separator.boxType = .separator
        separator.fillColor = AppColors.borderCyan
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

        let padding: CGFloat = 15
        let buttonHeight: CGFloat = 32
        let toolbarGap: CGFloat = 8                  // gap below the toolbar row
        let libraryTabsHeight: CGFloat = 26
        let libraryTabsGap: CGFloat = 8              // gap below the library-tabs row
        let packetPanelHeight: CGFloat = 180
        let bottomStatusBarHeight: CGFloat = 24      // slim global status strip

        // Set window to proper size. Right-side "Active VMs / Tasks" panel
        // was removed — the 680pt main content area plus the sidebar +
        // padding gives a reasonable minimum.
        let minWidth: CGFloat = sidebarWidth + 680 + padding * 2
        let minHeight: CGFloat = 620
        window.minSize = NSSize(width: minWidth, height: minHeight)

        // Set default window size on launch
        var windowFrame = window.frame
        let defaultWidth: CGFloat = 1150
        let defaultHeight: CGFloat = 720
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

        // ── Vertical layout (top-down) ───────────────────────────────────
        //   contentHeight                                  ← top of content
        //     toolbar row    (h=32)   y = top - padding - 32
        //     gap            (8)
        //     library tabs   (h=26)
        //     gap            (8)
        //     table          (flex, fills middle)
        //     detail card    (h=70)
        //     packet panel   (h=180)
        //     gap            (padding)
        //     y=0                                          ← bottom of content
        //
        // The bottom button row was here historically. Moving it to the top
        // matches macOS NSToolbar convention and the design mockup at
        // docs/ui-redesign-mockup.html. We're not using NSToolbar itself
        // (the existing IBOutlet buttons still drive every action), just
        // re-anchoring them to the top of the content view.

        let toolbarY = contentHeight - padding - buttonHeight

        let libraryTabsY = toolbarY - toolbarGap - libraryTabsHeight

        let tableX = sidebarWidth + padding
        // Right-side panel is gone — table fills out to the right edge of
        // the content view (minus one padding).
        let tableWidth = contentWidth - sidebarWidth - padding * 2

        let detailCardHeight: CGFloat = 70
        let detailCardX = sidebarWidth + padding
        let detailCardWidth = tableWidth
        // Vertical stack from bottom (after the new bottom status bar):
        //   y=0: status bar (h=24)
        //   y=24+padding=39: packet panel top
        //   y=39+180+padding=234: detail card top
        let detailCardY = bottomStatusBarHeight + padding + packetPanelHeight + padding

        let tableY = detailCardY + detailCardHeight + padding     // 210 + 70 + 15 = 295
        let tableHeight = libraryTabsY - libraryTabsGap - tableY

        addLibraryTabsHeader(in: contentView,
                             frame: NSRect(x: tableX, y: libraryTabsY,
                                           width: tableWidth, height: libraryTabsHeight))

        // Position the table scroll view
        if let scrollView = tableView?.enclosingScrollView {
            scrollView.frame = NSRect(x: tableX, y: tableY, width: tableWidth, height: tableHeight)
            scrollView.autoresizingMask = [.width, .height]
            scrollView.wantsLayer = true
            scrollView.layer?.borderWidth = 1
            scrollView.layer?.borderColor = AppColors.borderCyanEmphasis.cgColor
            scrollView.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        }

        // Empty-state overlays — one per tab. Hidden when their respective
        // data source has rows. Centered over the table region.
        if standardEmptyStateLabel == nil {
            let label = makeEmptyStateLabel(
                title: "No virtual machines yet",
                hint: "Click ⊕ New to create your first VM,\nor Import to bring in an existing bundle.")
            label.frame = NSRect(x: tableX, y: tableY,
                                 width: tableWidth, height: tableHeight)
            label.autoresizingMask = [.width, .height]
            contentView.addSubview(label)
            standardEmptyStateLabel = label
        } else {
            standardEmptyStateLabel?.frame = NSRect(x: tableX, y: tableY,
                                                   width: tableWidth, height: tableHeight)
        }
        if aiSandboxEmptyStateLabel == nil {
            let label = makeEmptyStateLabel(
                title: "No AI Sandbox VM",
                hint: "Use Tools → Create AI Sandbox VM…\nto build the base bundle (30–60 min).")
            label.frame = NSRect(x: tableX, y: tableY,
                                 width: tableWidth, height: tableHeight)
            label.autoresizingMask = [.width, .height]
            label.isHidden = true   // Standard tab is default
            contentView.addSubview(label)
            aiSandboxEmptyStateLabel = label
        } else {
            aiSandboxEmptyStateLabel?.frame = NSRect(x: tableX, y: tableY,
                                                    width: tableWidth, height: tableHeight)
        }

        // AI Sandbox outline view — same frame as the table scroll view but
        // hidden until the AI Sandbox tab is selected. Created once; later
        // tab switches just toggle .isHidden.
        if aiSandboxOutlineScroll == nil {
            buildAISandboxOutlineView(in: contentView, frame: NSRect(
                x: tableX, y: tableY, width: tableWidth, height: tableHeight))
        } else {
            aiSandboxOutlineScroll?.frame = NSRect(
                x: tableX, y: tableY, width: tableWidth, height: tableHeight)
        }

        // Selected-VM detail card — at-a-glance summary for the highlighted
        // row. Sits between the table and the packet panel.
        addSelectedVMDetailCard(in: contentView,
                                frame: NSRect(x: detailCardX, y: detailCardY,
                                              width: detailCardWidth,
                                              height: detailCardHeight))

        // Top toolbar — pill-grouped containers matching the mockup at
        // docs/ui-redesign-mockup.html. Each pill owns its own border + fill;
        // the buttons inside are flat-styled (text-only). Four pills:
        //
        //   [▶ Start] · [+ New | ↧ Import] · [⚙ Configure | ⎘ Clone | ✎ Rename] · [🗑 Delete]
        //
        // Primary (Start) gets the brighter OD-glow border; destructive
        // (Delete) gets red. Inter-pill gap = spacingMD (12pt).
        let pillGap: CGFloat = LayoutConstants.spacingMD

        toolbarPillContainers.forEach { $0.removeFromSuperview() }

        let pills: [NSView] = [
            makeButtonPillContainer([startButton].compactMap { $0 },
                                    borderColor: AppColors.accentODGlow.withAlphaComponent(0.7),
                                    fillColor: AppColors.accentOD.withAlphaComponent(0.18)),
            makeButtonPillContainer([newButton, importButton].compactMap { $0 }),
            makeButtonPillContainer([configureButton, cloneButton, renameButton].compactMap { $0 }),
            makeButtonPillContainer([deleteButton].compactMap { $0 },
                                    borderColor: AppColors.accentRed.withAlphaComponent(0.6)),
        ]

        var px = tableX
        for pill in pills {
            // Each pill is `buttonHeight + 2` tall. Center it on toolbarY by
            // shifting up 1pt so its baseline matches button-only layouts.
            pill.frame.origin = CGPoint(x: px, y: toolbarY - 1)
            pill.autoresizingMask = [.minYMargin, .maxXMargin]
            contentView.addSubview(pill)
            px += pill.frame.width + pillGap
        }
        toolbarPillContainers = pills
    }

    // MARK: - Selected VM Detail Card

    /// Build the horizontal "selected VM" detail strip and add it to the
    /// content view. Cells are laid out in a single row:
    ///
    ///   [● STATUS] · name · OS · CPU·RAM · Disk · Network mode · ↓/↑ rate
    ///
    /// Empty state (no selection) shows a single muted hint.
    private func addSelectedVMDetailCard(in contentView: NSView, frame: NSRect) {
        // Remove the old card if we're being re-laid-out (window resize, etc.)
        selectedVMDetailCard?.removeFromSuperview()

        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = AppColors.backgroundPanel.cgColor
        card.layer?.borderColor = AppColors.borderOD.cgColor
        card.layer?.borderWidth = LayoutConstants.borderHairline
        card.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        // Stay anchored to a fixed bottom-Y (above the packet panel) and let
        // only the width flex with window resize. Mirrors the packet-panel
        // autoresize pattern so both elements move as a coherent unit.
        card.autoresizingMask = [.width]

        // Glow line along the top edge — visual cue that this card follows
        // the table selection above it.
        let glow = CAGradientLayer()
        glow.frame = CGRect(x: 0, y: frame.height - 1, width: frame.width, height: 1)
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.colors = [
            NSColor.clear.cgColor,
            AppColors.accentOD.cgColor,
            NSColor.clear.cgColor
        ]
        glow.opacity = 0.5
        card.layer?.addSublayer(glow)

        // Cell layout — every value sits on the same baseline (`valueY`),
        // every caption sits on `captionY` directly above it. Identity
        // (pill + name) is LEFT-anchored; the metric grid lives in a
        // right-anchored container so it stays glued to the right edge of
        // the card as the window widens, instead of leaving a half-card-
        // wide empty band in the middle.
        let cellPadding: CGFloat = LayoutConstants.spacingLG  // 16pt edge padding
        let valueY: CGFloat = 14
        let valueH: CGFloat = 20
        let captionY: CGFloat = 41
        let captionH: CGFloat = 12
        let pillW: CGFloat = 96       // bumped 84→96 so "◆ TEMPLATE" / "● RUNNING" have breathing room
        let pillH: CGFloat = 22
        let nameW: CGFloat = 200
        let gapMetric: CGFloat = LayoutConstants.spacingLG     // 16pt between metric cells (was 12)

        // ── LEFT: identity (pill + name) ─────────────────────────────────
        let pill = makeStatusPill()
        pill.frame = NSRect(x: cellPadding,
                            y: valueY + (valueH - pillH) / 2,
                            width: pillW, height: pillH)
        pill.setAccessibilityLabel("Selected VM status")
        card.addSubview(pill)
        detailStatusPill = pill

        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSubtitle, weight: .semibold)
        nameLabel.textColor = AppColors.textPrimary
        nameLabel.frame = NSRect(x: cellPadding + pillW + LayoutConstants.spacingSM,
                                 y: valueY,
                                 width: nameW, height: valueH)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityLabel("Selected VM name")
        card.addSubview(nameLabel)
        detailNameLabel = nameLabel

        // ── RIGHT: metrics container (right-anchored) ────────────────────
        // Compute total width: 5 cells with their widths + 4 gaps + leading
        // divider region. The container's x = card.width - totalW - cellPadding,
        // and .minXMargin autoresizing keeps it glued to the right edge.
        let osW: CGFloat = 120       // trimmed -10 to make room for action buttons
        let uptimeW: CGFloat = 80    // "12h 47m" / "—"
        let cpuW: CGFloat = 110
        let diskW: CGFloat = 110
        let netModeW: CGFloat = 100
        let rateW: CGFloat = 150     // trimmed -10; "host-routed" still fits
        let packetsW: CGFloat = 90   // "1,234,567" upper bound for a long capture
        let dividerW: CGFloat = 1
        let dividerGap: CGFloat = LayoutConstants.spacingLG  // gap divider → first metric cell
        let metricsW = dividerW + dividerGap
                       + osW + gapMetric
                       + uptimeW + gapMetric
                       + cpuW + gapMetric
                       + diskW + gapMetric
                       + netModeW + gapMetric
                       + rateW + gapMetric
                       + packetsW

        // Quick-action buttons (Console / Capture) live in their own small
        // container to the RIGHT of the metric grid. Icon-only with
        // tooltips so they stay compact — wider labelled versions would
        // eat too much horizontal space on narrower windows.
        let actionBtnSize: CGFloat = 24
        let actionGap: CGFloat = 6
        let actionsW: CGFloat = actionBtnSize * 2 + actionGap
        let actionsToMetricsGap: CGFloat = LayoutConstants.spacingMD

        let actions = NSView()
        actions.frame = NSRect(x: frame.width - actionsW - cellPadding,
                               y: (frame.height - actionBtnSize) / 2,
                               width: actionsW, height: actionBtnSize)
        actions.autoresizingMask = [.minXMargin]
        card.addSubview(actions)

        let consoleBtn = makeDetailCardActionButton(
            title: "🖥",
            tooltip: "Bring the running VM's console window to the front (no-op when stopped).",
            action: #selector(quickActionConsole(_:)))
        consoleBtn.frame = NSRect(x: 0, y: 0,
                                  width: actionBtnSize, height: actionBtnSize)
        consoleBtn.setAccessibilityLabel("Open console window")
        actions.addSubview(consoleBtn)
        detailConsoleButton = consoleBtn

        let captureBtn = makeDetailCardActionButton(
            title: "⌐",
            tooltip: "Open the Packet Analysis window (full filter / inspect view).",
            action: #selector(quickActionCapture(_:)))
        captureBtn.frame = NSRect(x: actionBtnSize + actionGap, y: 0,
                                  width: actionBtnSize, height: actionBtnSize)
        captureBtn.setAccessibilityLabel("Open packet analysis")
        actions.addSubview(captureBtn)
        detailCaptureButton = captureBtn

        let metrics = NSView()
        metrics.frame = NSRect(x: frame.width - metricsW - actionsW - actionsToMetricsGap - cellPadding,
                               y: 0,
                               width: metricsW, height: frame.height)
        metrics.autoresizingMask = [.minXMargin]
        card.addSubview(metrics)

        // Vertical divider between identity and metrics — sits at x=0 inside
        // the metrics container so it's flush with the metric grid's left
        // edge regardless of card width.
        let dividerYBottom = valueY - 4
        let dividerYTop = captionY + captionH + 4
        let divider = NSBox(frame: NSRect(x: 0,
                                          y: dividerYBottom,
                                          width: dividerW,
                                          height: dividerYTop - dividerYBottom))
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = AppColors.borderOD
        metrics.addSubview(divider)

        // Metric cells positioned inside the container at fixed x offsets
        var mx: CGFloat = dividerW + dividerGap

        let osCell = makeMetricLabel(caption: "OS", x: mx,
                                     valueY: valueY, valueH: valueH,
                                     captionY: captionY, captionH: captionH,
                                     width: osW)
        metrics.addSubview(osCell.caption)
        metrics.addSubview(osCell.value)
        detailOSLabel = osCell.value
        mx += osW + gapMetric

        let uptimeCell = makeMetricLabel(caption: "UPTIME", x: mx,
                                         valueY: valueY, valueH: valueH,
                                         captionY: captionY, captionH: captionH,
                                         width: uptimeW)
        metrics.addSubview(uptimeCell.caption)
        metrics.addSubview(uptimeCell.value)
        detailUptimeLabel = uptimeCell.value
        mx += uptimeW + gapMetric

        let cpuCell = makeMetricLabel(caption: "CPU · RAM", x: mx,
                                      valueY: valueY, valueH: valueH,
                                      captionY: captionY, captionH: captionH,
                                      width: cpuW)
        metrics.addSubview(cpuCell.caption)
        metrics.addSubview(cpuCell.value)
        detailResourcesLabel = cpuCell.value

        // Memory allocation bar — thin track underneath the value cell.
        // y=8 puts it 6pt below `valueY=14` (which is the value's bottom
        // edge after layout, since labels grow upward in flipped coords —
        // in our unflipped card the value text is at y=14..34, so y=8
        // gives a 4pt strip with 6pt to the card bottom).
        let barH: CGFloat = 4
        let barY: CGFloat = max(2, valueY - barH - 2)
        let track = NSView(frame: NSRect(x: mx, y: barY, width: cpuW, height: barH))
        track.wantsLayer = true
        track.layer?.backgroundColor = AppColors.borderOD.withAlphaComponent(0.45).cgColor
        track.layer?.cornerRadius = barH / 2
        let fill = CALayer()
        fill.frame = NSRect(x: 0, y: 0, width: 0, height: barH)
        fill.backgroundColor = AppColors.accentODGlow.cgColor
        fill.cornerRadius = barH / 2
        track.layer?.addSublayer(fill)
        metrics.addSubview(track)
        detailMemoryBarTrack = track
        detailMemoryBarFill = fill

        mx += cpuW + gapMetric

        let diskCell = makeMetricLabel(caption: "Disk", x: mx,
                                       valueY: valueY, valueH: valueH,
                                       captionY: captionY, captionH: captionH,
                                       width: diskW)
        metrics.addSubview(diskCell.caption)
        metrics.addSubview(diskCell.value)
        detailDiskLabel = diskCell.value
        mx += diskW + gapMetric

        let netModeCell = makeMetricLabel(caption: "Network", x: mx,
                                          valueY: valueY, valueH: valueH,
                                          captionY: captionY, captionH: captionH,
                                          width: netModeW)
        metrics.addSubview(netModeCell.caption)
        metrics.addSubview(netModeCell.value)
        detailNetworkModeLabel = netModeCell.value
        mx += netModeW + gapMetric

        let netRateCell = makeMetricLabel(caption: "↓ / ↑", x: mx,
                                          valueY: valueY, valueH: valueH,
                                          captionY: captionY, captionH: captionH,
                                          width: rateW)
        metrics.addSubview(netRateCell.caption)
        metrics.addSubview(netRateCell.value)
        detailNetworkRateLabel = netRateCell.value
        mx += rateW + gapMetric

        let packetsCell = makeMetricLabel(caption: "PACKETS", x: mx,
                                          valueY: valueY, valueH: valueH,
                                          captionY: captionY, captionH: captionH,
                                          width: packetsW)
        metrics.addSubview(packetsCell.caption)
        metrics.addSubview(packetsCell.value)
        detailPacketsLabel = packetsCell.value

        contentView.addSubview(card)
        selectedVMDetailCard = card

        // Populate with whatever the table currently has selected (if anything)
        updateSelectedVMDetailCard()
    }

    /// Small icon-button used by the right-edge quick-action stack in the
    /// detail card. Square, layer-backed, OD-border tactical aesthetic
    /// with built-in hover treatment via `TacticalHoverButton`.
    private func makeDetailCardActionButton(title: String,
                                            tooltip: String,
                                            action: Selector) -> NSButton {
        let btn = TacticalHoverButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.layer?.backgroundColor = AppColors.backgroundButton.cgColor
        btn.layer?.borderColor = AppColors.borderOD.cgColor
        btn.layer?.borderWidth = 1.0
        btn.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: AppColors.textPrimary,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        btn.toolTip = tooltip
        btn.setHoverTreatment(hoverBorder: AppColors.accentODGlow)
        return btn
    }

    /// Bring the selected VM's guest console window forward via the
    /// `.focusVMConsole` notification (AppDelegate owns vmWindows).
    /// No-op when no VM is selected or the VM isn't running.
    @objc private func quickActionConsole(_ sender: NSButton) {
        guard let vm = selectedStandardVM(), vm.status == .running else { return }
        NotificationCenter.default.post(name: .focusVMConsole, object: vm.id)
    }

    /// Open the Packet Analysis window via the existing `.openPacketAnalysis`
    /// notification (no preset — user picks once the window is up).
    @objc private func quickActionCapture(_ sender: NSButton) {
        NotificationCenter.default.post(name: .openPacketAnalysis, object: nil)
    }

    /// Shared selection lookup used by the quick-action buttons. Reads
    /// the standard-tab selection through `displayedStandardVMs` so the
    /// filter state is honored.
    private func selectedStandardVM() -> VMConfiguration? {
        guard currentLibraryTab == .standard else { return nil }
        let row = tableView?.selectedRow ?? -1
        return standardVM(at: row)
    }

    /// Enable/disable + tint quick-action buttons based on the current
    /// selection. Console is only useful for a running VM (window must
    /// exist); Capture is always available when any VM is selected.
    private func refreshQuickActionButtonsState() {
        let vm = selectedStandardVM()
        let isRunning = vm?.status == .running
        detailConsoleButton?.isEnabled = isRunning
        detailConsoleButton?.alphaValue = isRunning ? 1.0 : 0.4
        let hasAnySelection = (vm != nil) && currentLibraryTab == .standard
        detailCaptureButton?.isEnabled = hasAnySelection
        detailCaptureButton?.alphaValue = hasAnySelection ? 1.0 : 0.4
    }

    /// Build a `[CAPTION / value]` pair stacked vertically, with explicit Y
    /// positions for both rows so every cell across the card lines up.
    private func makeMetricLabel(caption: String,
                                 x: CGFloat,
                                 valueY: CGFloat, valueH: CGFloat,
                                 captionY: CGFloat, captionH: CGFloat,
                                 width: CGFloat)
        -> (caption: NSTextField, value: NSTextField)
    {
        let captionLabel = NSTextField(labelWithString: caption.uppercased())
        captionLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeCaption, weight: .medium)
        captionLabel.textColor = AppColors.textSubtle
        captionLabel.frame = NSRect(x: x, y: captionY, width: width, height: captionH)
        // Caption is decorative — the value label below carries the real
        // information. Hide the caption from accessibility to avoid
        // VoiceOver reading both "OS:" and the OS name redundantly.
        captionLabel.setAccessibilityElement(false)

        let valueLabel = NSTextField(labelWithString: "—")
        valueLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular)
        valueLabel.textColor = AppColors.textLight
        valueLabel.frame = NSRect(x: x, y: valueY, width: width, height: valueH)
        valueLabel.lineBreakMode = .byTruncatingTail
        // The value label is the focusable thing; label it with the
        // caption so VoiceOver reads "OS, Kali 2024.1".
        valueLabel.setAccessibilityLabel(caption)

        return (captionLabel, valueLabel)
    }

    /// Status pill: pill-shaped label with a leading dot, color-coded by
    /// `selectedVM` state. Background tinted with the same hue at ~12% alpha.
    /// cornerRadius is half the pill height = perfect capsule. Caller sizes
    /// the pill to ~96 × 22pt so the centered "◆ TEMPLATE" / "● RUNNING"
    /// content has ~10pt of horizontal breathing room.
    private func makeStatusPill() -> NSTextField {
        let pill = NSTextField(labelWithString: "—")
        pill.alignment = .center
        pill.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeCaption, weight: .semibold)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 11        // half the 22pt height — proper capsule
        pill.layer?.borderWidth = LayoutConstants.borderHairline
        pill.drawsBackground = false
        pill.isBordered = false              // no inset border around the text
        pill.lineBreakMode = .byClipping     // never wrap the pill label
        return pill
    }

    /// Update the memory-allocation bar beneath the CPU·RAM cell.
    /// `vmMemoryBytes == 0` clears the fill (empty state). Otherwise the
    /// fill width is the VM's configured RAM as a fraction of total host
    /// RAM, clamped to 100%. Color shifts green→orange→red as the share
    /// rises so an over-provisioned guest reads as a warning at a glance.
    ///
    /// Honest framing: this is allocation, not live usage. We don't have
    /// guest-tool channels for real RAM occupancy on macOS Virtualization,
    /// so the bar tells the user "how much host RAM you've committed to
    /// this VM" — useful when deciding whether to start a second VM.
    private func updateMemoryAllocationBar(vmMemoryBytes: UInt64) {
        guard let fill = detailMemoryBarFill,
              let track = detailMemoryBarTrack else { return }
        guard vmMemoryBytes > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = NSRect(x: 0, y: 0, width: 0, height: fill.frame.height)
            CATransaction.commit()
            track.toolTip = nil
            return
        }
        let hostBytes = ProcessInfo.processInfo.physicalMemory
        let ratio = hostBytes > 0
            ? min(1.0, Double(vmMemoryBytes) / Double(hostBytes))
            : 0
        let trackW = track.bounds.width
        let fillW = CGFloat(ratio) * trackW

        let color: NSColor
        switch ratio {
        case ..<0.25: color = AppColors.accentODGlow
        case ..<0.50: color = AppColors.accentYellow
        default:      color = AppColors.accentRed
        }

        // Disable implicit CALayer animations on layout updates so the
        // bar snaps to its new width instead of slow-easing on every
        // selection change (which feels laggy).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: fillW, height: fill.frame.height)
        fill.backgroundColor = color.cgColor
        CATransaction.commit()

        let vmGB = Double(vmMemoryBytes) / 1_073_741_824.0
        let hostGB = Double(hostBytes) / 1_073_741_824.0
        track.toolTip = String(
            format: "Configured to use %.1f GB of %.0f GB host RAM (%.0f%%). This is allocation, not live usage.",
            vmGB, hostGB, ratio * 100
        )
    }

    /// Refresh the detail card from `tableView`'s current selection. Called
    /// whenever the selection changes or a VM's status changes.
    private func updateSelectedVMDetailCard() {
        guard selectedVMDetailCard != nil else { return }
        defer { refreshQuickActionButtonsState() }

        // AI Sandbox tab pulls the row from the outline view, not the table.
        if currentLibraryTab == .aiSandbox {
            updateDetailCardForAISandbox(selectedNode: aiSandboxOutlineView.flatMap {
                $0.item(atRow: $0.selectedRow) as? AISandboxNode
            })
            return
        }

        let selectedRow = tableView?.selectedRow ?? -1

        let displayed = displayedStandardVMs

        guard selectedRow >= 0, selectedRow < displayed.count else {
            // Empty state — no VM picked
            detailNameLabel?.stringValue = "No VM selected"
            detailNameLabel?.textColor = AppColors.textMuted
            detailStatusPill?.stringValue = ""
            detailStatusPill?.layer?.backgroundColor = NSColor.clear.cgColor
            detailStatusPill?.layer?.borderColor = NSColor.clear.cgColor
            detailOSLabel?.stringValue = "—"
            detailResourcesLabel?.stringValue = "—"
            updateMemoryAllocationBar(vmMemoryBytes: 0)
            detailUptimeLabel?.stringValue = "—"
            detailDiskLabel?.stringValue = "—"
            detailNetworkModeLabel?.stringValue = "—"
            detailNetworkRateLabel?.stringValue = "—"
            detailNetworkRateLabel?.textColor = AppColors.textMuted
            detailPacketsLabel?.stringValue = "—"
            return
        }

        let vm = displayed[selectedRow]

        detailNameLabel?.stringValue = vm.name
        detailNameLabel?.textColor = AppColors.textPrimary

        // Status pill (uses VMStatus from VMConfiguration)
        let (pillText, pillColor): (String, NSColor) = {
            switch vm.status {
            case .running:  return ("● RUNNING",  AppColors.statusRunning)
            case .starting: return ("◐ STARTING", AppColors.statusPaused)
            case .stopping: return ("◐ STOPPING", AppColors.statusPaused)
            case .stopped:  return ("○ STOPPED",  AppColors.statusStopped)
            }
        }()
        detailStatusPill?.stringValue = pillText
        detailStatusPill?.textColor = pillColor
        detailStatusPill?.layer?.backgroundColor = pillColor.withAlphaComponent(0.12).cgColor
        detailStatusPill?.layer?.borderColor = pillColor.withAlphaComponent(0.45).cgColor

        // OS / distro — Linux VMs show "Kali 2024.1" style, macOS shows "macOS 15"
        if vm.osType == "Linux", let distro = vm.linuxDistribution {
            if let version = vm.linuxVersion, !version.isEmpty {
                detailOSLabel?.stringValue = "\(distro) \(version)"
            } else {
                detailOSLabel?.stringValue = distro
            }
        } else {
            detailOSLabel?.stringValue = vm.osType
        }

        // CPU · RAM (memorySize is bytes; convert to GB)
        let ramGB = Double(vm.memorySize) / 1_073_741_824.0
        detailResourcesLabel?.stringValue = String(format: "%d · %.1f GB", vm.cpuCount, ramGB)
        updateMemoryAllocationBar(vmMemoryBytes: vm.memorySize)

        // Disk — show "used / total". `onDiskBundleSize` returns the cached
        // value immediately and kicks a background re-scan if stale; the
        // detail card refreshes via `.vmBundleSizeUpdated` notification when
        // a fresh measurement lands. Until first measurement returns, fall
        // back to "— / total".
        let diskGB = Double(vm.diskSize) / 1_073_741_824.0
        if let usedBytes = vmManager.onDiskBundleSize(for: vm) {
            let usedGB = Double(usedBytes) / 1_073_741_824.0
            detailDiskLabel?.stringValue = String(format: "%.1f / %.0f GB", usedGB, diskGB)
        } else {
            detailDiskLabel?.stringValue = String(format: "— / %.0f GB", diskGB)
        }

        // Network mode (color-coded by safety)
        switch vm.networkConfig.mode {
        case .nat:
            detailNetworkModeLabel?.stringValue = "NAT"
            detailNetworkModeLabel?.textColor = AppColors.networkNAT
        case .virtual:
            detailNetworkModeLabel?.stringValue = vm.networkConfig.isRouter ? "ROUTER" : "VIRTUAL"
            detailNetworkModeLabel?.textColor = AppColors.networkIsolated
        }

        // Live rate ↓/↑ — sampled from VirtualNetworkSwitch per-port byte
        // counters on a 1.5s cadence. Only VMs connected to the virtual
        // switch (Virtual / Router modes) get a real rate; NAT-mode VMs
        // route through the host stack which the switch never sees, so
        // their rate cell explicitly says so instead of leaving a blank
        // dash that reads as "data missing".
        if vm.status == .running {
            switch vm.networkConfig.mode {
            case .virtual:
                let rate = liveRateBps[vm.name]
                let down = rate?.down ?? 0
                let up = rate?.up ?? 0
                let downStr = ByteCountFormatter.string(fromByteCount: Int64(down), countStyle: .binary)
                let upStr = ByteCountFormatter.string(fromByteCount: Int64(up), countStyle: .binary)
                detailNetworkRateLabel?.stringValue = "\(downStr)/s ↓  \(upStr)/s ↑"
                // Tint hot only when there's actual traffic — keeps the cell
                // visually quiet for idle VMs.
                let hot = (down + up) > 1024  // anything above ~1 KiB/s reads as live
                detailNetworkRateLabel?.textColor = hot ? AppColors.accentOrangeHot : AppColors.textMuted
                detailNetworkRateLabel?.toolTip = "Sampled every 1.5s from the virtual switch port counters."
            case .nat:
                detailNetworkRateLabel?.stringValue = "host-routed"
                detailNetworkRateLabel?.textColor = AppColors.textMuted
                detailNetworkRateLabel?.toolTip = "NAT-mode VMs route through the host's network stack — per-VM byte counters aren't surfaced through Apple's Virtualization framework."
            }
        } else {
            detailNetworkRateLabel?.stringValue = "—"
            detailNetworkRateLabel?.textColor = AppColors.textMuted
            detailNetworkRateLabel?.toolTip = nil
        }

        // Uptime — derived from the per-VM start stamp we capture on the
        // .running transition. Stopped VMs show "—".
        if vm.status == .running, let started = vmStartedAt[vm.id] {
            let elapsed = Date().timeIntervalSince(started)
            detailUptimeLabel?.stringValue = formatUptime(elapsed)
        } else {
            detailUptimeLabel?.stringValue = "—"
        }

        // Packets — cumulative rx+tx from the virtual switch port. NAT-mode
        // VMs aren't on the switch, so they show "—" the same way the rate
        // cell falls back to "host-routed".
        if vm.networkConfig.mode == .virtual {
            let total = currentPacketCount(forVMName: vm.name)
            if let total {
                detailPacketsLabel?.stringValue = Self.packetCountFormatter.string(
                    from: NSNumber(value: total)) ?? "\(total)"
            } else {
                detailPacketsLabel?.stringValue = "—"
            }
        } else {
            detailPacketsLabel?.stringValue = "—"
        }
    }

    /// Cumulative `packetsRx + packetsTx` for a VM from the virtual switch
    /// port stats. Returns nil if the switch isn't running or no port
    /// matches this VM name.
    private func currentPacketCount(forVMName name: String) -> UInt64? {
        let stats = VirtualNetworkSwitch.shared.getStatistics()
        guard let isRunning = stats["running"] as? Bool, isRunning,
              let ports = stats["ports"] as? [[String: Any]] else { return nil }
        for port in ports {
            guard let portName = port["vmName"] as? String, portName == name else { continue }
            let rx = (port["packetsRx"] as? NSNumber)?.uint64Value ?? 0
            let tx = (port["packetsTx"] as? NSNumber)?.uint64Value ?? 0
            return rx + tx
        }
        return nil
    }

    /// Cached NumberFormatter for thousands-separated packet counts.
    /// Reusable across every detail-card refresh.
    private static let packetCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    /// Poll the VirtualNetworkSwitch port stats and turn cumulative byte
    /// counters into a moving bytes/sec rate per VM. Called on a 1.5s timer
    /// from `windowDidLoad`. Skips entirely when the switch isn't running.
    private func sampleLiveNetworkRates() {
        let stats = VirtualNetworkSwitch.shared.getStatistics()
        guard let isRunning = stats["running"] as? Bool, isRunning,
              let portStats = stats["ports"] as? [[String: Any]] else {
            // Decay all live rates when the switch isn't running so stale
            // numbers don't linger.
            if !liveRateBps.isEmpty { liveRateBps.removeAll() }
            return
        }

        let now = Date()
        for port in portStats {
            guard let name = port["vmName"] as? String,
                  let rxAny = port["bytesRx"], let txAny = port["bytesTx"] else { continue }
            // Counters can come back as Int / UInt64 / NSNumber depending on
            // how the dict was serialised — normalize through NSNumber.
            let rx = (rxAny as? NSNumber)?.uint64Value ?? 0
            let tx = (txAny as? NSNumber)?.uint64Value ?? 0

            if let prev = lastNetSample[name] {
                let dt = now.timeIntervalSince(prev.ts)
                guard dt > 0.001 else { continue }  // avoid div-by-zero on rapid ticks
                // Defend against UInt64 wraparound — if counters went backwards
                // (e.g., port re-attached and reset), drop the sample.
                let dRx = rx >= prev.bytesRx ? Double(rx - prev.bytesRx) : 0
                let dTx = tx >= prev.bytesTx ? Double(tx - prev.bytesTx) : 0
                let down = dRx / dt
                let up = dTx / dt
                liveRateBps[name] = (down: down, up: up)
                appendTrafficSample(down + up, for: name)
            }
            lastNetSample[name] = NetSample(bytesRx: rx, bytesTx: tx, ts: now)
        }

        // Refresh the detail card if the selected VM has a live rate.
        // Cheap to call — most cells short-circuit when the selection
        // hasn't changed.
        if currentLibraryTab == .standard {
            updateSelectedVMDetailCard()
            // Update only the Traffic column to keep the sparklines fresh
            // without re-rendering every cell on every tick.
            refreshTrafficColumn()
            // Push per-row intensities into the falling-packets overlay
            // so the decorative cascade tracks real activity.
            refreshTrafficFallOverlay()
        }
    }

    /// Compute per-row intensities (0..1) from the latest rate samples and
    /// hand them to `trafficFallOverlay`. The overlay handles its own
    /// timer / spawning / drawing — the controller just needs to publish
    /// the activity map.
    ///
    /// Intensity is `min(1, totalBps / 1 MB/s)` clamped: 1 MB/s of mixed
    /// rx+tx maps to a fully-saturated cascade, anything heavier still
    /// caps at 1.0 so we don't burn a runaway spawn rate on busy guests.
    private func refreshTrafficFallOverlay() {
        guard let overlay = trafficFallOverlay,
              currentLibraryTab == .standard else { return }
        let vms = displayedStandardVMs
        var intensities: [Int: Double] = [:]
        let saturation: Double = 1_048_576.0   // 1 MB/s
        for (i, vm) in vms.enumerated() where vm.status == .running {
            guard let rate = liveRateBps[vm.name] else { continue }
            let total = rate.down + rate.up
            guard total > 0 else { continue }
            intensities[i] = min(1.0, total / saturation)
        }
        overlay.setActiveRows(intensities)
    }

    /// Append a (down + up) bytes/sec sample to the rolling buffer for `vmName`,
    /// trimming to `maxTrafficSamples` length.
    private func appendTrafficSample(_ value: Double, for vmName: String) {
        var buffer = trafficSamples[vmName] ?? []
        buffer.append(value)
        let cap = Self.maxTrafficSamples
        if buffer.count > cap {
            buffer.removeFirst(buffer.count - cap)
        }
        trafficSamples[vmName] = buffer
    }

    /// Repaint the Traffic column for every row. Cheap — each cell already
    /// holds a SparklineView, we just push fresh samples into it.
    private func refreshTrafficColumn() {
        guard let tableView = tableView else { return }
        guard let colIdx = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == "TrafficColumn"
        }) else { return }
        let rowRange = 0..<tableView.numberOfRows
        for row in rowRange {
            guard let cell = tableView.view(atColumn: colIdx, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let spark = cell.subviews.first(where: { $0 is SparklineView }) as? SparklineView else {
                continue
            }
            let vmName = standardVM(at: row)?.name ?? ""
            spark.samples = trafficSamples[vmName] ?? []
        }
    }

    /// Repaint the detail card from the currently-selected AI Sandbox
    /// outline node. AI Sandbox VMs have a fixed shape (macOS, isolated,
    /// 4 vCPU / 8 GB RAM via AISandboxDefaults), so several cells are
    /// constant.
    private func updateDetailCardForAISandbox(selectedNode: AISandboxNode?) {
        guard let node = selectedNode else {
            detailNameLabel?.stringValue = aiSandboxBundles.isEmpty ?
                "No AI Sandbox bundles" : "No bundle selected"
            detailNameLabel?.textColor = AppColors.textMuted
            detailStatusPill?.stringValue = ""
            detailStatusPill?.layer?.backgroundColor = NSColor.clear.cgColor
            detailStatusPill?.layer?.borderColor = NSColor.clear.cgColor
            detailOSLabel?.stringValue = "—"
            detailResourcesLabel?.stringValue = "—"
            updateMemoryAllocationBar(vmMemoryBytes: 0)
            detailUptimeLabel?.stringValue = "—"
            detailDiskLabel?.stringValue = "—"
            detailNetworkModeLabel?.stringValue = "—"
            detailNetworkRateLabel?.stringValue = "—"
            detailNetworkRateLabel?.textColor = AppColors.textMuted
            detailPacketsLabel?.stringValue = "—"
            return
        }

        let bundle = node.bundle

        detailNameLabel?.stringValue = bundle.displayName
        detailNameLabel?.textColor = AppColors.textPrimary

        let (pillText, pillColor): (String, NSColor) = bundle.isBase
            ? ("◆ TEMPLATE", AppColors.accentOrange)
            : ("● SESSION",  AppColors.statusRunning)
        detailStatusPill?.stringValue = pillText
        detailStatusPill?.textColor = pillColor
        detailStatusPill?.layer?.backgroundColor = pillColor.withAlphaComponent(0.12).cgColor
        detailStatusPill?.layer?.borderColor = pillColor.withAlphaComponent(0.45).cgColor

        detailOSLabel?.stringValue = "macOS"
        detailResourcesLabel?.stringValue = "4 · 8 GB"
        // AI Sandbox bundle is fixed at 8 GB. Drive the allocation bar
        // with that same value so the bar matches the text.
        updateMemoryAllocationBar(vmMemoryBytes: 8 * 1_073_741_824)
        // Uptime + packet counters don't apply to a bundle row (the bundle
        // isn't a runtime VM until it's booted into a session, at which
        // point that session would be selected separately).
        detailUptimeLabel?.stringValue = "—"
        detailPacketsLabel?.stringValue = "—"
        detailDiskLabel?.stringValue = ByteCountFormatter.string(
            fromByteCount: bundle.diskBytes, countStyle: .binary)

        detailNetworkModeLabel?.stringValue = "ISOLATED"
        detailNetworkModeLabel?.textColor = AppColors.networkIsolated

        if let created = bundle.createdAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            detailNetworkRateLabel?.stringValue = formatter.string(from: created)
            detailNetworkRateLabel?.textColor = AppColors.textMuted
        } else {
            detailNetworkRateLabel?.stringValue = "—"
            detailNetworkRateLabel?.textColor = AppColors.textMuted
        }
    }

    /// Build a centered "empty state" label with a title + hint line.
    /// Title is mono-medium textPrimary; hint is system-light textMuted.
    /// Used for the Standard / AI Sandbox tabs when the underlying data
    /// source is empty.
    private func makeEmptyStateLabel(title: String, hint: String) -> NSTextField {
        let label = NSTextField()
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.alignment = .center
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 4

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSubtitle,
                                               weight: .semibold),
            .foregroundColor: AppColors.textPrimary,
            .paragraphStyle: para
        ]))
        attr.append(NSAttributedString(string: "\n\n" + hint, attributes: [
            .font: NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular),
            .foregroundColor: AppColors.textMuted,
            .paragraphStyle: para
        ]))
        label.attributedStringValue = attr
        return label
    }

    /// VMs that should appear as rows in the Standard tab right now,
    /// accounting for any user-applied running-VM focus filter. When
    /// `runningFilterIDs` is nil the master list is returned unchanged.
    /// All table-row accessors (numberOfRows, viewFor, selection-based
    /// action handlers) must read through this — never `vmManager.virtualMachines`
    /// directly — so row indices stay consistent with what's on screen.
    private var displayedStandardVMs: [VMConfiguration] {
        let all = vmManager.virtualMachines
        guard let ids = runningFilterIDs, !ids.isEmpty else { return all }
        return all.filter { ids.contains($0.id) }
    }

    /// Safe row→VM lookup against the currently-displayed standard list.
    /// Returns nil if `row` is out of bounds (e.g. table reload race).
    private func standardVM(at row: Int) -> VMConfiguration? {
        let list = displayedStandardVMs
        guard row >= 0, row < list.count else { return nil }
        return list[row]
    }

    /// Recompute the (router, guest) row pairs that the connection overlay
    /// renders. Anchored on running router VMs so each link appears once
    /// (router→guest, never the reverse). Called whenever a VM status
    /// changes or the table reloads.
    ///
    /// Row indices are resolved against `displayedStandardVMs` (i.e. the
    /// filtered list the table is showing), not the master list, so the
    /// brackets stay aligned with the visible rows when a filter is on.
    private func refreshConnectionOverlay() {
        guard let overlay = connectionOverlay else { return }
        let vms = displayedStandardVMs
        var pairs: [(fromRow: Int, toRow: Int)] = []
        for (i, vm) in vms.enumerated() {
            guard vm.status == .running else { continue }
            guard vm.networkConfig.isRouter else { continue }
            for peer in vmManager.networkPeers(of: vm) where peer.status == .running {
                if let j = vms.firstIndex(where: { $0.id == peer.id }) {
                    pairs.append((fromRow: i, toRow: j))
                }
            }
        }
        overlay.connections = pairs
    }

    /// Refresh empty-state overlay visibility from the current data sources.
    /// Called whenever rows are added / removed / on tab switch.
    private func refreshEmptyStateOverlays() {
        let isStandard = (currentLibraryTab == .standard)

        // Standard tab: visible only when standard tab is active AND there
        // are no VMs at all.
        let showStandard = isStandard && vmManager.virtualMachines.isEmpty
        standardEmptyStateLabel?.isHidden = !showStandard

        // AI Sandbox tab: visible only when the AI tab is active AND there's
        // no base bundle (sessions can't exist without a base).
        let showSandbox = !isStandard && (aiSandboxRootNode == nil)
        aiSandboxEmptyStateLabel?.isHidden = !showSandbox
    }

    // MARK: - Library Tabs (Standard / AI Sandbox)

    /// Build the [Standard VMs] / [AI Sandbox] segmented header plus the
    /// recovery-mode checkbox that's only visible when the AI Sandbox tab
    /// is selected.
    private func addLibraryTabsHeader(in contentView: NSView, frame: NSRect) {
        libraryTabControl?.removeFromSuperview()
        recoveryModeCheckbox?.removeFromSuperview()
        runningFilterButton?.removeFromSuperview()

        let tabs = NSSegmentedControl(labels: ["Standard VMs", "AI Sandbox"],
                                      trackingMode: .selectOne,
                                      target: self,
                                      action: #selector(libraryTabChanged(_:)))
        tabs.frame = NSRect(x: frame.origin.x, y: frame.origin.y,
                            width: 240, height: frame.height)
        tabs.selectedSegment = currentLibraryTab.rawValue
        Self.applyTacticalStyle(to: tabs)
        tabs.autoresizingMask = [.minYMargin]  // stick to top of content view
        tabs.setAccessibilityLabel("Library view")
        tabs.toolTip = "Switch between standard VMs and the AI Sandbox tree view"
        contentView.addSubview(tabs)
        libraryTabControl = tabs

        // Recovery-mode checkbox — toggling this changes the boot path for
        // an AI Sandbox session VM. Hidden in the Standard tab so it never
        // confuses users browsing their regular VMs.
        let check = NSButton(checkboxWithTitle: "Boot in Recovery Mode",
                             target: self,
                             action: #selector(recoveryModeToggled(_:)))
        check.frame = NSRect(x: frame.origin.x + 240 + LayoutConstants.spacingLG,
                             y: frame.origin.y + (frame.height - 20) / 2,
                             width: 200,
                             height: 20)
        check.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody)
        check.toolTip = "When checked, AI Sandbox sessions boot into macOS Recovery instead of normal startup. Useful for disk repair or reinstalling macOS inside the sandbox."
        check.state = .off
        check.isHidden = (currentLibraryTab != .aiSandbox)
        check.autoresizingMask = [.minYMargin]
        contentView.addSubview(check)
        recoveryModeCheckbox = check

        // "▼ Focus Running" button — opens a menu of currently-running VMs
        // with check marks. Selecting one or more focuses the table to only
        // those rows (great when 6+ VMs are listed but you only care about
        // the 2 that are firing right now). "Show all" clears the filter.
        // Anchored to the right side of the tabs row.
        let filterBtnWidth: CGFloat = 150
        let filterBtnX = frame.origin.x + frame.width - filterBtnWidth
        let filterBtn = TacticalHoverButton(title: "▼ Focus Running",
                                            target: self,
                                            action: #selector(showRunningFilterMenu(_:)))
        filterBtn.setHoverTreatment(hoverBorder: AppColors.accentODGlow)
        filterBtn.frame = NSRect(x: filterBtnX,
                                 y: frame.origin.y + (frame.height - 22) / 2,
                                 width: filterBtnWidth,
                                 height: 22)
        filterBtn.isBordered = false
        filterBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        filterBtn.wantsLayer = true
        filterBtn.layer?.backgroundColor = AppColors.backgroundButton.cgColor
        filterBtn.layer?.borderColor = AppColors.borderOD.cgColor
        filterBtn.layer?.borderWidth = 1.0
        filterBtn.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
        filterBtn.attributedTitle = NSAttributedString(string: "▼ Focus Running", attributes: [
            .foregroundColor: AppColors.textPrimary,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        filterBtn.toolTip = "Focus the table on specific running VMs (multi-select). Useful when many VMs are listed but only a couple are operationally relevant right now."
        filterBtn.autoresizingMask = [.minXMargin, .minYMargin]
        filterBtn.setAccessibilityLabel("Focus running VMs")
        contentView.addSubview(filterBtn)
        runningFilterButton = filterBtn
        updateRunningFilterButtonTitle()
    }

    /// Sync the focus-filter button title with current filter state. Shows
    /// the count when a filter is active so the user knows the table is
    /// trimmed without having to expand the menu.
    private func updateRunningFilterButtonTitle() {
        guard let btn = runningFilterButton else { return }
        let title: String
        if let ids = runningFilterIDs, !ids.isEmpty {
            title = "▼ Focus: \(ids.count)"
        } else {
            title = "▼ Focus Running"
        }
        btn.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: AppColors.textPrimary,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        let isActive = runningFilterIDs != nil && !(runningFilterIDs?.isEmpty ?? true)
        // When the filter is active, the button stays glowing green
        // even when not hovered — push the same color into the hover-
        // button's idle slot so it doesn't get reset on mouse exit.
        let activeIdleBorder = isActive ? AppColors.accentODGlow : AppColors.borderOD
        if let hoverBtn = btn as? TacticalHoverButton {
            hoverBtn.setHoverTreatment(idleBorder: activeIdleBorder,
                                       hoverBorder: AppColors.accentODGlow)
        } else {
            btn.layer?.borderColor = activeIdleBorder.cgColor
        }
    }

    /// Pop a menu of running VMs with check marks. Toggling an item edits
    /// `runningFilterIDs`; the "Show all" item resets to nil. Empty list
    /// when nothing is running so the user sees that explicitly rather
    /// than a confusing empty menu.
    @objc private func showRunningFilterMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let showAll = NSMenuItem(title: "Show all VMs",
                                 action: #selector(focusClearFilter(_:)),
                                 keyEquivalent: "")
        showAll.target = self
        if runningFilterIDs == nil || runningFilterIDs?.isEmpty == true {
            showAll.state = .on
        }
        menu.addItem(showAll)
        menu.addItem(.separator())

        let running = vmManager.virtualMachines.filter { $0.status == .running }
        if running.isEmpty {
            let none = NSMenuItem(title: "— No VMs running —",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for vm in running {
                let item = NSMenuItem(title: vm.name,
                                      action: #selector(focusToggleVM(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = vm.id
                if runningFilterIDs?.contains(vm.id) == true {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        let origin = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func focusClearFilter(_ sender: NSMenuItem) {
        runningFilterIDs = nil
        applyRunningFilterChange()
    }

    @objc private func focusToggleVM(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        var set = runningFilterIDs ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        runningFilterIDs = set.isEmpty ? nil : set
        applyRunningFilterChange()
    }

    /// Common after-edit path: refresh the table + supporting overlays so
    /// the change is visible immediately, and update the button title so
    /// the user sees the new active-count badge.
    private func applyRunningFilterChange() {
        tableView?.reloadData()
        updateRunningFilterButtonTitle()
        updateButtonStates()
        updateSelectedVMDetailCard()
        refreshEmptyStateOverlays()
        refreshConnectionOverlay()
    }

    @objc private func libraryTabChanged(_ sender: NSSegmentedControl) {
        guard let newTab = LibraryTab(rawValue: sender.selectedSegment) else { return }
        currentLibraryTab = newTab

        // Toggle the recovery checkbox visibility
        recoveryModeCheckbox?.isHidden = (newTab != .aiSandbox)

        // Show the outline view in the AI Sandbox tab; keep the standard
        // NSTableView for the Standard tab. They share the same frame.
        let showOutline = (newTab == .aiSandbox)
        tableView?.enclosingScrollView?.isHidden = showOutline
        aiSandboxOutlineScroll?.isHidden = !showOutline

        if showOutline {
            aiSandboxBundles = scanAISandboxBundles()
            rebuildAISandboxNodeTree()
        }
        tableView?.reloadData()
        updateButtonStates()
        updateSelectedVMDetailCard()
        refreshEmptyStateOverlays()
    }

    @objc private func recoveryModeToggled(_ sender: NSButton) {
        // State is read at Start-button click time; nothing to do here
        // besides log so the user gets feedback the toggle took.
        NSLog("[Library] Recovery mode toggle → %@", sender.state == .on ? "ON" : "OFF")
    }

    // MARK: AI Sandbox outline view

    /// Build the NSOutlineView used by the AI Sandbox tab. Columns mirror
    /// the standard table's set (Name, Status, OS, CPU, Memory, Disk,
    /// LastUsed) so the visual rhythm stays consistent on tab swap. The
    /// first column gets the disclosure triangle.
    private func buildAISandboxOutlineView(in contentView: NSView, frame: NSRect) {
        let scroll = NSScrollView(frame: frame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.borderWidth = LayoutConstants.borderHairline
        scroll.layer?.borderColor = AppColors.borderCyanEmphasis.cgColor
        scroll.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        scroll.backgroundColor = AppColors.backgroundSecondary
        scroll.drawsBackground = true
        scroll.isHidden = true   // Standard tab is default; reveal on switch

        let outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = AppColors.backgroundSecondary
        outline.gridColor = AppColors.borderOD
        outline.gridStyleMask = []
        outline.style = .plain
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 16
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(startVM(_:))

        // Columns — same identifiers as the XIB so cell-render code can be
        // shared (we still branch by `currentLibraryTab`).
        let columnSpecs: [(id: String, title: String, width: CGFloat)] = [
            ("NameColumn",    "Name",      220),
            ("StatusColumn",  "Status",     90),
            ("OSColumn",      "OS",         90),
            ("CPUColumn",     "Session ID", 110),
            ("MemoryColumn",  "Memory",     80),
            ("DiskColumn",    "Disk",      100),
            ("LastUsedColumn","Created",   140),
        ]
        for spec in columnSpecs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = spec.title
            col.width = spec.width
            col.minWidth = 60
            outline.addTableColumn(col)
        }
        outline.outlineTableColumn = outline.tableColumns.first  // Name column gets the disclosure ▶

        scroll.documentView = outline
        contentView.addSubview(scroll)
        aiSandboxOutlineScroll = scroll
        aiSandboxOutlineView = outline
    }

    /// Rebuild the node tree from `aiSandboxBundles`, reload the outline,
    /// auto-expand the base node.
    private func rebuildAISandboxNodeTree() {
        guard let baseRow = aiSandboxBundles.first(where: { $0.isBase }) else {
            aiSandboxRootNode = nil
            aiSandboxOutlineView?.reloadData()
            return
        }
        let sessionRows = aiSandboxBundles.filter { !$0.isBase }
        let sessionNodes = sessionRows.map { AISandboxNode(bundle: $0, children: nil) }
        aiSandboxRootNode = AISandboxNode(bundle: baseRow, children: sessionNodes)
        aiSandboxOutlineView?.reloadData()
        if let root = aiSandboxRootNode {
            aiSandboxOutlineView?.expandItem(root)
        }
    }

    /// Find the most-recently-created session node, or nil if there are no
    /// session children. Used by Start-on-base routing.
    private func latestAISandboxSessionNode() -> AISandboxNode? {
        guard let children = aiSandboxRootNode?.children, !children.isEmpty else { return nil }
        return children.max(by: { ($0.bundle.createdAt ?? .distantPast) < ($1.bundle.createdAt ?? .distantPast) })
    }

    /// Scan `~/.avf/AISandbox/` for bundle directories. Returns a list of
    /// rows ordered: base first (if present), then sessions sorted by
    /// creation time descending (newest first).
    private func scanAISandboxBundles() -> [AISandboxBundleRow] {
        let fm = FileManager.default
        let aiRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".avf/AISandbox")
        var rows: [AISandboxBundleRow] = []

        // Base bundle (one only)
        let baseURL = aiRoot.appendingPathComponent("ai-sandbox-base-v1.bundle")
        if fm.fileExists(atPath: baseURL.path) {
            rows.append(makeBundleRow(url: baseURL, isBase: true))
        }

        // Sessions (zero or more)
        let sessionsURL = aiRoot.appendingPathComponent("sessions")
        if let contents = try? fm.contentsOfDirectory(at: sessionsURL,
                                                     includingPropertiesForKeys: [.creationDateKey],
                                                     options: [.skipsHiddenFiles]) {
            let sessionRows = contents
                .filter { $0.pathExtension == "bundle" }
                .map { makeBundleRow(url: $0, isBase: false) }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            rows.append(contentsOf: sessionRows)
        }

        return rows
    }

    private func makeBundleRow(url: URL, isBase: Bool) -> AISandboxBundleRow {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        var name: String?
        var id: UUID?
        if let data = try? Data(contentsOf: manifestURL),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            name = dict["name"] as? String
            if let s = dict["id"] as? String { id = UUID(uuidString: s) }
        }
        let display: String = {
            if isBase { return name ?? "ai-sandbox-base" }
            return name ?? url.deletingPathExtension().lastPathComponent
        }()

        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let diskURL = url.appendingPathComponent("disk.img")
        let diskBytes: Int64 = {
            guard let attr = try? fm.attributesOfItem(atPath: diskURL.path),
                  let size = attr[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }()

        return AISandboxBundleRow(url: url, displayName: display,
                                  isBase: isBase, id: id,
                                  createdAt: createdAt, diskBytes: diskBytes)
    }

    // MARK: - Bottom status bar

    /// Slim 24pt status strip pinned to the bottom of the content view.
    /// Shows: pulse-dot + running VM count · switch state · capture state ·
    /// disk free · build. Updated on a 1s timer.
    private func addBottomStatusBar() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 15
        let height: CGFloat = 24
        let width = contentView.bounds.width

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = AppColors.backgroundTertiary.cgColor
        bar.autoresizingMask = [.width, .maxYMargin]
        bottomStatusBar = bar

        // Hairline OD divider along the top edge — signals "bar is part of
        // the chrome, not floating".
        let topDivider = CALayer()
        topDivider.frame = CGRect(x: 0, y: height - 1, width: width, height: 1)
        topDivider.backgroundColor = AppColors.borderOD.cgColor
        topDivider.autoresizingMask = [.layerWidthSizable]
        bar.layer?.addSublayer(topDivider)

        // Live pulse dot — same idiom as the mockup's status bar
        let dot = CAShapeLayer()
        let dotSize: CGFloat = 8
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dotSize, height: dotSize), transform: nil)
        dot.fillColor = AppColors.statusRunning.cgColor
        dot.shadowColor = AppColors.statusRunning.cgColor
        dot.shadowOpacity = 0.8
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.frame = CGRect(x: padding, y: (height - dotSize) / 2, width: dotSize, height: dotSize)
        bar.layer?.addSublayer(dot)
        statusBarPulseDot = dot
        // Subtle pulse animation so the dot reads as "live"
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 1.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")

        // Three label segments left-to-right + a right-anchored disk/version
        var x = padding + dotSize + LayoutConstants.spacingSM

        statusBarRunningLabel = makeStatusBarLabel(text: "—", x: x, width: 140, height: height, alignment: .left)
        statusBarRunningLabel?.setAccessibilityLabel("Running VM count")
        bar.addSubview(statusBarRunningLabel!)
        x += 140 + LayoutConstants.spacingLG

        statusBarSwitchLabel = makeStatusBarLabel(text: "—", x: x, width: 200, height: height, alignment: .left)
        statusBarSwitchLabel?.setAccessibilityLabel("Virtual switch state")
        bar.addSubview(statusBarSwitchLabel!)
        x += 200 + LayoutConstants.spacingLG

        statusBarNATLabel = makeStatusBarLabel(text: "", x: x, width: 170, height: height, alignment: .left)
        statusBarNATLabel?.toolTip = "Aggregate bytes/sec across all VZ NAT bridge interfaces. Apple's Virtualization framework doesn't expose per-VM counters in NAT mode — this is the combined total."
        statusBarNATLabel?.setAccessibilityLabel("Aggregate NAT bridge bytes per second")
        bar.addSubview(statusBarNATLabel!)
        x += 170 + LayoutConstants.spacingLG

        statusBarCaptureLabel = makeStatusBarLabel(text: "—", x: x, width: 160, height: height, alignment: .left)
        statusBarCaptureLabel?.setAccessibilityLabel("Packet capture state")
        bar.addSubview(statusBarCaptureLabel!)

        // Right-anchored: disk free + build. Single label, autoresizes off
        // the right edge of the bar.
        let rightW: CGFloat = 280
        statusBarDiskLabel = makeStatusBarLabel(text: "—",
                                                x: width - rightW - padding,
                                                width: rightW, height: height,
                                                alignment: .right)
        statusBarDiskLabel?.autoresizingMask = [.minXMargin]
        statusBarDiskLabel?.setAccessibilityLabel("Disk free and build version")
        bar.addSubview(statusBarDiskLabel!)

        contentView.addSubview(bar)

        // Initial fill + 1s refresh
        refreshBottomStatusBar()
        statusBarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBottomStatusBar() }
        }
    }

    private func makeStatusBarLabel(text: String, x: CGFloat, width: CGFloat,
                                    height: CGFloat, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: (height - 14) / 2, width: width, height: 14)
        label.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSmall, weight: .regular)
        label.textColor = AppColors.textMuted
        label.alignment = alignment
        label.isBordered = false
        label.drawsBackground = false
        label.isEditable = false
        return label
    }

    /// Pull current state from the singletons and repaint the labels.
    /// Cheap — just string interpolation + a single ByteCountFormatter call.
    private func refreshBottomStatusBar() {
        guard bottomStatusBar != nil else { return }

        // Running / total VMs
        let runningCount = vmManager.getRunningVMsCount()
        let totalCount = vmManager.virtualMachines.count
        statusBarRunningLabel?.stringValue = "\(runningCount) of \(totalCount) running"
        statusBarPulseDot?.fillColor = (runningCount > 0
            ? AppColors.statusRunning : AppColors.statusStopped).cgColor

        // Switch state
        let stats = VirtualNetworkSwitch.shared.getStatistics()
        let switchOn = (stats["running"] as? Bool) ?? false
        let ports = (stats["connectedPorts"] as? Int) ?? 0
        let fwd = (stats["packetsForwarded"] as? UInt64).map { Int($0) } ?? 0
        statusBarSwitchLabel?.stringValue = switchOn
            ? "Switch · \(ports) ports · \(formatCount(fwd)) pkts"
            : "Switch · idle"
        statusBarSwitchLabel?.textColor = switchOn ? AppColors.textOD : AppColors.textMuted

        // NAT bridge bytes/sec — aggregate across all VZ NAT bridge
        // interfaces (vmenet*, bridge1*). Hidden when no bridge interface
        // exists on the system (no NAT VM has ever booted in this session).
        let currentNATSample = BridgeInterfaceStats.sample()
        let natRate = BridgeInterfaceStats.rate(from: statusBarPreviousNATSample,
                                                to: currentNATSample)
        statusBarPreviousNATSample = currentNATSample
        if currentNATSample == nil {
            statusBarNATLabel?.stringValue = ""
        } else if let rate = natRate {
            let down = ByteCountFormatter.string(fromByteCount: Int64(rate.down), countStyle: .binary)
            let up   = ByteCountFormatter.string(fromByteCount: Int64(rate.up),   countStyle: .binary)
            statusBarNATLabel?.stringValue = "NAT · \(down)/s ↓ \(up)/s ↑"
            let hot = (rate.down + rate.up) > 1024
            statusBarNATLabel?.textColor = hot ? AppColors.accentOrangeHot : AppColors.textMuted
        } else {
            // First sample after launch — no delta yet
            statusBarNATLabel?.stringValue = "NAT · sampling…"
            statusBarNATLabel?.textColor = AppColors.textMuted
        }

        // Capture / install state — the capture cell triple-roles:
        //   1. While an AI Sandbox install is in flight (build / provision /
        //      seal), show the phase + magenta tint so the user knows
        //      something significant is happening.
        //   2. Else if packet capture is running, show packet count in
        //      hot-orange.
        //   3. Else show "Capture · idle" in muted text.
        let installPhase = AISandboxInstallTracker.shared.phase
        let installInProgress: Bool = {
            switch installPhase {
            case .installing, .provisioning, .sealing: return true
            default: return false
            }
        }()
        if installInProgress {
            statusBarCaptureLabel?.stringValue = "AI Sandbox · \(installPhase.humanLabel)"
            statusBarCaptureLabel?.textColor = AppColors.accentMagenta
        } else {
            let capturing = PacketCaptureManager.shared.isCapturing
            let totalPackets = PacketCaptureManager.shared.totalPacketCount
            statusBarCaptureLabel?.stringValue = capturing
                ? "Capture · \(formatCount(totalPackets)) pkts"
                : "Capture · idle"
            statusBarCaptureLabel?.textColor = capturing ? AppColors.accentOrangeHot : AppColors.textMuted

            // Packet panel header: toggle the CAPTURING pill + repaint
            // the rate readout from the same data source.
            setPacketCapturingActive(capturing)
            refreshPacketPanelRate(totalPackets: totalPackets, capturing: capturing)
        }

        // Disk free + version
        var diskStr = "—"
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            diskStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
        }
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        statusBarDiskLabel?.stringValue = "~/.avf · \(diskStr) free  ·  v\(version) (\(build))"
    }

    private func formatCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func addStatusBar() {
        guard let window = window, let contentView = window.contentView else { return }

        // Right-side "Active VMs / Tasks" panel and the protocol legend
        // panel were removed in the mockup-driven cleanup so the VM table +
        // detail card + packet panel can fill the full width. The packet
        // flow eyecandy (NetworkTrafficView) lived in the Active VMs panel
        // and is intentionally not relocated here — a falling-packet
        // animation across each VM row is planned as a follow-up.
        let sidebarWidth: CGFloat = 220
        let padding: CGFloat = 15
        let packetPanelHeight: CGFloat = 180
        let bottomStatusBarHeight: CGFloat = 24

        let contentWidth = contentView.bounds.width

        // ═══════════════════════════════════════════════════════════════
        // (removed: ACTIVE VMs PANEL — right-side panel + VMs/Tasks tabs)
        // ═══════════════════════════════════════════════════════════════
        // ═══════════════════════════════════════════════════════════════
        // PACKET LOG PANEL (Horizontal - below VM Table, above the bottom)
        // ═══════════════════════════════════════════════════════════════
        // Packet panel sits just above the new bottom status bar — single
        // padding gap separates them.
        let packetPanelX = sidebarWidth + padding
        let packetPanelY = bottomStatusBarHeight + padding
        // Width: full content minus sidebar minus left/right padding.
        // Right-side panel is gone now so the packet panel stretches across.
        let packetPanelWidth = contentWidth - sidebarWidth - padding * 2

        let packetPanel = NSView(frame: NSRect(x: packetPanelX, y: packetPanelY, width: packetPanelWidth, height: packetPanelHeight))
        packetPanel.wantsLayer = true
        packetPanel.autoresizingMask = [.width]

        // Tactical-styled panel: OD border, panel background. Drops the
        // yellow/amber border that read as "warning"; the panel is just
        // ambient live data now.
        packetPanel.layer?.backgroundColor = AppColors.backgroundPanel.cgColor
        packetPanel.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        packetPanel.layer?.borderWidth = LayoutConstants.borderHairline
        packetPanel.layer?.borderColor = AppColors.borderOD.cgColor

        // Panel title — "▸ LIVE TRAFFIC" with an orange tick prefix matches
        // the sidebar section-label treatment in the mockup. The orange
        // arrow signals "data flow / attention"; the title itself stays in
        // muted mono so it reads as a section header, not a button.
        let packetTitle = NSTextField(labelWithString: "")
        packetTitle.attributedStringValue = {
            let tick = NSAttributedString(string: "▸ ", attributes: [
                .foregroundColor: AppColors.accentOrange,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            ])
            let title = NSAttributedString(string: "LIVE TRAFFIC", attributes: [
                .foregroundColor: AppColors.textPrimary,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            ])
            let combined = NSMutableAttributedString()
            combined.append(tick)
            combined.append(title)
            return combined
        }()
        packetTitle.frame = NSRect(x: 12, y: packetPanelHeight - 28, width: 140, height: 20)
        packetPanel.addSubview(packetTitle)

        // CAPTURING pill — sits next to the title with a pulsing orange dot.
        // Hidden when not capturing; visible (with the pulse animation) when
        // PacketCaptureManager is actively recording.
        let capturingPill = makeCapturingPill()
        capturingPill.frame = NSRect(x: 160, y: packetPanelHeight - 28, width: 110, height: 20)
        packetPanel.addSubview(capturingPill)
        packetCapturingPill = capturingPill

        // Live rate readout — "↓ 12.4 MB/s ↑ 0.3 MB/s · 1,284 pkts".
        // Right-anchored so it autoresizes off the right edge of the panel.
        let rateLabel = NSTextField(labelWithString: "")
        rateLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        rateLabel.textColor = AppColors.textMuted
        rateLabel.alignment = .right
        rateLabel.isBordered = false
        rateLabel.drawsBackground = false
        rateLabel.isEditable = false
        let rateW: CGFloat = 280
        rateLabel.frame = NSRect(x: packetPanelWidth - rateW - 160,
                                 y: packetPanelHeight - 28,
                                 width: rateW, height: 20)
        rateLabel.autoresizingMask = [.minXMargin]
        packetPanel.addSubview(rateLabel)
        packetRateLabel = rateLabel

        // VM Filter tabs (macOS / Kali / All) — moved to a second header
        // row below the rate readout so they don't fight the title bar.
        // Widened "macOS" segment from 45 → 60 so the full label fits at 11pt
        // (the previous 45pt clipped to "ma..." on Aqua's roundRect style).
        let vmFilterControl = NSSegmentedControl(labels: ["macOS", "Kali", "All"], trackingMode: .selectOne, target: self, action: #selector(vmFilterChanged(_:)))
        vmFilterControl.frame = NSRect(x: 12, y: packetPanelHeight - 56, width: 160, height: 22)
        vmFilterControl.selectedSegment = 0  // Default to macOS
        Self.applyTacticalStyle(to: vmFilterControl)
        vmFilterControl.setWidth(60, forSegment: 0)  // macOS — was 45 (truncated)
        vmFilterControl.setWidth(50, forSegment: 1)  // Kali
        vmFilterControl.setWidth(45, forSegment: 2)  // All
        packetPanel.addSubview(vmFilterControl)
        packetVMFilterControl = vmFilterControl

        // Filter ARP checkbox (checked by default) — on row 2 next to the
        // VM filter.
        let arpCheckbox = NSButton(checkboxWithTitle: "Filter ARP", target: self, action: #selector(toggleARPFilter(_:)))
        arpCheckbox.frame = NSRect(x: 188, y: packetPanelHeight - 56, width: 90, height: 22)
        arpCheckbox.state = .on  // Checked by default
        arpCheckbox.font = NSFont.systemFont(ofSize: 11)
        arpCheckbox.contentTintColor = NSColor.white
        packetPanel.addSubview(arpCheckbox)

        // ARP filtered count label.
        let arpCountLabel = NSTextField(labelWithString: "(0)")
        arpCountLabel.frame = NSRect(x: 276, y: packetPanelHeight - 54, width: 45, height: 18)
        arpCountLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        arpCountLabel.textColor = AppColors.accentYellow
        arpCountLabel.alignment = .left
        packetPanel.addSubview(arpCountLabel)
        arpFilterCountLabel = arpCountLabel

        // "⌕ Filter ▾" button — pops the same malware-analysis preset menu
        // that PacketAnalysisWindowController uses. Picking a preset opens
        // the full Packet Analysis window with that filter pre-applied so
        // the user can dig in. Right-anchored, sits to the left of Expand.
        let filterButton = TacticalHoverButton(title: "⌕ Filter ▾",
                                               target: self,
                                               action: #selector(showPacketFilterMenu(_:)))
        filterButton.frame = NSRect(x: packetPanelWidth - 190, y: packetPanelHeight - 56,
                                    width: 90, height: 22)
        filterButton.isBordered = false
        filterButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        filterButton.layer?.backgroundColor = AppColors.backgroundButton.cgColor
        filterButton.layer?.borderColor = AppColors.borderOD.cgColor
        filterButton.layer?.borderWidth = 1.0
        filterButton.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
        filterButton.attributedTitle = NSAttributedString(string: "⌕ Filter ▾", attributes: [
            .foregroundColor: AppColors.textOD,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        filterButton.toolTip = "Apply a malware-analysis filter preset — opens the full Packet Analysis window with the selected filter."
        filterButton.autoresizingMask = [.minXMargin]
        filterButton.setHoverTreatment(hoverBorder: AppColors.accentODGlow)
        packetPanel.addSubview(filterButton)

        // "Expand →" button (was "Open Full Analysis"). Pops the dedicated
        // Packet Analysis window. Right-anchored on row 2.
        let openButton = NSButton(title: "Expand →", target: self, action: #selector(openPacketAnalysisWindow(_:)))
        openButton.frame = NSRect(x: packetPanelWidth - 95, y: packetPanelHeight - 56,
                                  width: 85, height: 22)
        openButton.isBordered = false
        openButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        openButton.wantsLayer = true
        openButton.layer?.backgroundColor = AppColors.backgroundButton.cgColor
        openButton.layer?.borderColor = AppColors.borderOD.cgColor
        openButton.layer?.borderWidth = 1.0
        openButton.layer?.cornerRadius = LayoutConstants.cornerRadiusSM
        openButton.attributedTitle = NSAttributedString(string: "Expand →", attributes: [
            .foregroundColor: AppColors.textOD,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        openButton.toolTip = "Open the full Packet Analysis window with deep filters and packet inspection"
        openButton.autoresizingMask = [.minXMargin]
        packetPanel.addSubview(openButton)

        // Separator below row 2 — OD hairline.
        let packetSeparator = NSBox(frame: NSRect(x: 10, y: packetPanelHeight - 66,
                                                  width: packetPanelWidth - 20, height: 1))
        packetSeparator.boxType = .custom
        packetSeparator.borderWidth = 0
        packetSeparator.fillColor = AppColors.borderOD
        packetSeparator.autoresizingMask = [.width]
        packetPanel.addSubview(packetSeparator)

        // Packets list container - shifted down to clear the two-row header.
        let listTopMargin: CGFloat = 70   // was 60
        let packetsScrollView = NSScrollView(frame: NSRect(x: 8, y: 8,
                                                          width: packetPanelWidth - 16,
                                                          height: packetPanelHeight - listTopMargin))
        packetsScrollView.autoresizingMask = [.width]
        packetsScrollView.hasHorizontalScroller = false
        packetsScrollView.hasVerticalScroller = true
        packetsScrollView.autohidesScrollers = true
        packetsScrollView.drawsBackground = false
        packetsScrollView.borderType = .noBorder

        let packetsTextView = NSTextView(frame: NSRect(x: 0, y: 0,
                                                       width: packetPanelWidth - 16,
                                                       height: packetPanelHeight - listTopMargin))
        packetsTextView.isEditable = false
        packetsTextView.drawsBackground = false
        packetsTextView.textColor = AppColors.textOD
        packetsTextView.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        packetsTextView.autoresizingMask = [.width]
        packetsScrollView.documentView = packetsTextView

        packetPanel.addSubview(packetsScrollView)
        packetListContainer = packetsScrollView

        // Protocol stats container (hidden — Protocols tab removed; full
        // stats live in the Packet Analysis window).
        let protocolView = NSView(frame: NSRect(x: 8, y: 8,
                                                width: packetPanelWidth - 16,
                                                height: packetPanelHeight - listTopMargin))
        protocolView.wantsLayer = true
        protocolView.isHidden = true
        protocolView.autoresizingMask = [.width]
        packetPanel.addSubview(protocolView)
        protocolStatsContainer = protocolView

        contentView.addSubview(packetPanel)
        packetLogPanel = packetPanel

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
        // Defer to AppDelegate's singleton — avoids two analysis windows
        // rendering the same packet stream independently.
        NotificationCenter.default.post(name: .openPacketAnalysis, object: nil)
    }

    /// Pop the malware-analysis preset menu anchored to the Filter button.
    /// Selecting a preset opens the Packet Analysis window with that filter
    /// pre-applied (see `presetFilterChosen(_:)`).
    @objc private func showPacketFilterMenu(_ sender: NSButton) {
        let menu = PacketFilterPresets.buildMenu(target: self,
                                                 action: #selector(presetFilterChosen(_:)))
        // Anchor the menu below the button's left edge.
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    /// Called when the user picks a preset from the library packet panel's
    /// Filter button. Opens the full Packet Analysis window with that
    /// preset pre-applied — the library panel is a quick preview, deep
    /// filtering happens in the dedicated window.
    @objc private func presetFilterChosen(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .openPacketAnalysis,
            object: nil,
            userInfo: ["presetTitle": sender.title]
        )
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
        let hasContent = !runningVMs.isEmpty || AISandboxInstallTracker.shared.isActive || IPSWDownloadTracker.shared.isActive
        vmsPlaceholderLabel?.isHidden = hasContent

        // Check if we have a router VM running with other VMs
        let routerVM = runningVMs.first { $0.vm.networkConfig.isRouter }
        let clientVMs = runningVMs.filter { !$0.vm.networkConfig.isRouter }
        let hasActiveNetwork = routerVM != nil && !clientVMs.isEmpty

        // Prepend an AI Sandbox install entry when a build is active, so the
        // user can see real-time phase + progress in the same panel they
        // already watch for running VMs.
        if AISandboxInstallTracker.shared.isActive {
            container.addArrangedSubview(createInstallProgressItem())
        }

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
            // Bind weak self to let to avoid 'reference to captured var' in @Sendable Task closure
            guard let self else { return }
            Task { @MainActor in
                self.updateNetworkStats()
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

    /// Synthetic sidebar card showing AI Sandbox install state. Mirrors the
    /// dimensions of `createVMStatusItem` so the layout stays consistent;
    /// uses a magenta border to distinguish it from real VM cards.
    private func createInstallProgressItem() -> NSView {
        let cardWidth: CGFloat  = 188
        let cardHeight: CGFloat = 85

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
        containerView.wantsLayer = true
        // Magenta-tinted card distinguishes the AI Sandbox install progress
        // from the standard VM status cards (which use OD/cyan).
        containerView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.06, blue: 0.16, alpha: 1.0).cgColor
        containerView.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        containerView.layer?.borderWidth = LayoutConstants.borderHairline
        containerView.layer?.borderColor = AppColors.borderMagenta.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true

        let tracker = AISandboxInstallTracker.shared

        // Title — building / done / failed
        let titleLabel = NSTextField(labelWithString: "⚙ AI Sandbox VM (building)")
        titleLabel.frame = NSRect(x: 8, y: cardHeight - 22, width: cardWidth - 16, height: 16)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = AppColors.accentMagenta
        titleLabel.lineBreakMode = .byTruncatingTail
        containerView.addSubview(titleLabel)

        // Phase label
        let phaseLabel = NSTextField(labelWithString: tracker.phase.humanLabel)
        phaseLabel.frame = NSRect(x: 8, y: cardHeight - 38, width: cardWidth - 16, height: 14)
        phaseLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeCaption)
        phaseLabel.textColor = AppColors.textMuted
        containerView.addSubview(phaseLabel)

        // Progress bar — determinate during install (we have a real fraction
        // from VZMacOSInstaller's progress KVO), indeterminate otherwise.
        let progressBar = NSProgressIndicator(frame: NSRect(x: 8, y: 18, width: cardWidth - 16, height: 8))
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = (tracker.phase != .installing)
        if tracker.phase == .installing {
            progressBar.doubleValue = tracker.fraction
        } else {
            progressBar.startAnimation(nil)
        }
        containerView.addSubview(progressBar)

        // Percent / phase number text
        // Two-phase install (S8 of PR #4 review removed the dead .provisioning
        // case — vsock provisioning is deferred until a guest-side agent ships).
        let footerText: String
        switch tracker.phase {
        case .installing:
            footerText = "Phase 1/2 · \(Int(tracker.fraction * 100))%"
        case .sealing:
            footerText = "Phase 2/2"
        default:
            footerText = ""
        }
        let footerLabel = NSTextField(labelWithString: footerText)
        footerLabel.frame = NSRect(x: 8, y: 2, width: cardWidth - 16, height: 12)
        footerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        footerLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        containerView.addSubview(footerLabel)

        return containerView
    }

    private func createVMStatusItem(vm: VMConfiguration, state: String) -> NSView {
        // Vertical card layout for each VM - fits in 200px wide panel
        let cardWidth: CGFloat = 188
        let cardHeight: CGFloat = 85  // Taller to fit network toggle

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = AppColors.backgroundSecondary.cgColor
        containerView.layer?.cornerRadius = LayoutConstants.cornerRadiusMD
        containerView.layer?.borderWidth = LayoutConstants.borderHairline
        containerView.layer?.borderColor = AppColors.borderODEmphasis.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Store VM ID in layer name for button lookups (safer than hash)
        containerView.layer?.name = vm.id.uuidString

        // Size constraints
        containerView.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
        containerView.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true

        // State color and icon — all five states read from semantic tokens
        // so they stay in sync with the status pills + sparkline tinting.
        let stateColor: NSColor
        let stateIcon: String
        switch state.lowercased() {
        case "running":
            stateColor = AppColors.statusRunning   // OD green
            stateIcon = "▶"
        case "starting":
            stateColor = AppColors.accentODGlow    // light OD — transitioning toward running
            stateIcon = "◐"
        case "paused":
            stateColor = AppColors.statusPaused    // amber
            stateIcon = "⏸"
        case "stopping":
            stateColor = AppColors.accentOrange    // safety orange — attention
            stateIcon = "◑"
        default:
            stateColor = AppColors.statusStopped   // slate
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
        // Recalculate layout when window is resized. Mirrors the math in
        // adjustContentForSidebar (toolbar at top, packet panel + legend at
        // bottom, table + detail card in the middle). Autoresizing masks
        // handle a chunk of this already, but a few panels (Active VMs
        // height, library tabs Y, detail card Y) are calculated from
        // contentHeight at layout time and need re-anchoring here.
        guard let contentView = window?.contentView else { return }

        let sidebarWidth: CGFloat = 220
        let padding: CGFloat = 15
        let buttonHeight: CGFloat = 32
        let toolbarGap: CGFloat = 8
        let libraryTabsHeight: CGFloat = 26
        let libraryTabsGap: CGFloat = 8
        let detailCardHeight: CGFloat = 70
        let packetPanelHeight: CGFloat = 180
        let bottomStatusBarHeight: CGFloat = 24

        let contentWidth = contentView.bounds.width
        let contentHeight = contentView.bounds.height

        // Vertical anchors — match adjustContentForSidebar()
        let toolbarY = contentHeight - padding - buttonHeight
        let libraryTabsY = toolbarY - toolbarGap - libraryTabsHeight

        let tableX = sidebarWidth + padding
        // Right-side panel is gone — table fills out to the right edge of
        // the content view (minus one padding).
        let tableWidth = contentWidth - sidebarWidth - padding * 2
        let detailCardY = bottomStatusBarHeight + padding + packetPanelHeight + padding
        let tableY = detailCardY + detailCardHeight + padding
        let tableHeight = libraryTabsY - libraryTabsGap - tableY

        if let scrollView = tableView?.enclosingScrollView {
            scrollView.frame = NSRect(x: tableX, y: tableY, width: tableWidth, height: tableHeight)
        }
        aiSandboxOutlineScroll?.frame = NSRect(x: tableX, y: tableY,
                                               width: tableWidth, height: tableHeight)

        // Library tabs header + recovery checkbox stay glued under the toolbar.
        libraryTabControl?.frame.origin.y = libraryTabsY
        recoveryModeCheckbox?.frame.origin.y = libraryTabsY + (libraryTabsHeight - 20) / 2

        // Toolbar pill containers re-anchor to the new top Y. Each pill's
        // X / width stays the same (group sizes are fixed), only the Y of
        // the row needs updating.
        for pill in toolbarPillContainers {
            pill.frame.origin.y = toolbarY - 1
        }

        // Detail card stays at fixed Y (autoresize handles its width).
        selectedVMDetailCard?.frame.origin.y = detailCardY

        // (Active VMs / Legend panels were removed; no right-side re-anchor.)

        // Packet panel sits just above the bottom status bar.
        if let packetPanel = packetLogPanel {
            let packetWidth = contentWidth - sidebarWidth - padding * 2
            packetPanel.frame = NSRect(x: sidebarWidth + padding,
                                       y: bottomStatusBarHeight + padding,
                                       width: packetWidth, height: packetPanelHeight)
        }

        // Bottom status bar stretches the full width along y=0.
        bottomStatusBar?.frame = NSRect(x: 0, y: 0,
                                        width: contentWidth,
                                        height: bottomStatusBarHeight)
    }

    @objc private func handleVMStatusChanged(_ notification: Notification) {
        // Refresh the table to show updated status
        DispatchQueue.main.async {
            // Track per-VM start time so the Uptime metric in the detail
            // card has a reference point. We don't persist this on the
            // VMConfiguration model — start times are intrinsically a
            // runtime concern and reset every launch.
            self.refreshVMStartTimes()

            self.tableView?.reloadData()

            // Update status bar with current running VMs
            self.refreshStatusBar()

            // Selected VM's pill + live rate also depend on status
            self.updateSelectedVMDetailCard()

            // Re-evaluate VM-VM connection brackets on running pills
            self.refreshConnectionOverlay()
        }
    }

    /// Walk the current VM list. For each VM newly in `.running` state,
    /// stamp `Date()` if we don't already have one. For each VM not in
    /// `.running`, drop any stored stamp. Idempotent — safe to call on
    /// every status-change notification.
    private func refreshVMStartTimes() {
        let now = Date()
        var seen = Set<UUID>()
        for vm in vmManager.virtualMachines {
            seen.insert(vm.id)
            if vm.status == .running {
                if vmStartedAt[vm.id] == nil {
                    vmStartedAt[vm.id] = now
                }
            } else {
                vmStartedAt.removeValue(forKey: vm.id)
            }
        }
        // GC entries for VMs that were deleted while running.
        vmStartedAt = vmStartedAt.filter { seen.contains($0.key) }
    }

    /// Format a TimeInterval as compact uptime ("2h 14m", "47m 12s",
    /// "3d 4h"). Picks the highest two non-zero units.
    private func formatUptime(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "<1s" }
        let total = Int(seconds)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    @objc private func handleVMBundleSizeUpdated(_ notification: Notification) {
        // Bundle-size scan is per-VM. If the updated VM matches the currently
        // selected row, refresh the detail card so the Disk cell jumps from
        // "—" to the real measurement (or updates from a stale value).
        guard let updatedId = notification.object as? UUID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let selectedRow = self.tableView?.selectedRow ?? -1
            guard let vm = self.standardVM(at: selectedRow) else { return }
            if vm.id == updatedId {
                self.updateSelectedVMDetailCard()
            }
        }
    }

    @objc private func handleAISandboxInstallTrackerChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshStatusBar()
            // Keep Tasks tab live when it's visible
            if self.rightPanelTabControl?.selectedSegment == 1 {
                self.refreshTasksTab()
            }
            // If the user is currently viewing the AI Sandbox tab, re-scan
            // so a newly-installed base / new session appears without
            // requiring a tab toggle. The empty-state overlay flips off
            // automatically when the base appears.
            if self.currentLibraryTab == .aiSandbox {
                self.aiSandboxBundles = self.scanAISandboxBundles()
                self.rebuildAISandboxNodeTree()
                self.updateSelectedVMDetailCard()
                self.refreshEmptyStateOverlays()
            }
        }
    }

    @objc private func rightPanelTabChanged(_ sender: NSSegmentedControl) {
        let showVMs = sender.selectedSegment == 0
        vmsTabContent?.isHidden = !showVMs
        tasksTabContent?.isHidden = showVMs
        if !showVMs { refreshTasksTab() }
    }

    @objc private func handleIPSWDownloadTrackerChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshStatusBar()
            if self.rightPanelTabControl?.selectedSegment == 1 {
                self.refreshTasksTab()
            }
        }
    }

    private func refreshTasksTab() {
        let sandbox = AISandboxInstallTracker.shared
        let ipsw = IPSWDownloadTracker.shared

        let sandboxActive = sandbox.isActive || sandbox.phase == .finished || sandbox.phase == .failed
        let ipswActive = ipsw.isActive || ipsw.phase == .finished || ipsw.phase == .failed

        // Status label — show whichever task is active (prefer sandbox if both)
        if sandboxActive {
            let pctStr = sandbox.phase == .installing ? " · \(Int(sandbox.fraction * 100))%" : ""
            tasksStatusLabel?.stringValue = "AI Sandbox: \(sandbox.phase.humanLabel)\(pctStr)"
            tasksStatusLabel?.textColor = sandbox.phase == .failed
                ? NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
                : NSColor(red: 0.86, green: 0.50, blue: 1.00, alpha: 1.0)

            tasksProgressBar?.isHidden = false
            if sandbox.phase == .installing {
                tasksProgressBar?.isIndeterminate = false
                tasksProgressBar?.doubleValue = sandbox.fraction
            } else {
                tasksProgressBar?.isIndeterminate = true
                tasksProgressBar?.startAnimation(nil)
            }
        } else if ipswActive {
            let pctStr: String
            if ipsw.phase == .downloading {
                if ipsw.totalBytes > 0 {
                    let mbDone = ipsw.receivedBytes / (1024 * 1024)
                    let mbTotal = ipsw.totalBytes / (1024 * 1024)
                    pctStr = " · \(Int(ipsw.fraction * 100))% (\(mbDone)/\(mbTotal) MB)"
                } else {
                    let mbDone = ipsw.receivedBytes / (1024 * 1024)
                    pctStr = " · \(mbDone) MB"
                }
            } else { pctStr = "" }

            tasksStatusLabel?.stringValue = "IPSW Download: \(ipsw.phase.humanLabel)\(pctStr)"
            tasksStatusLabel?.textColor = ipsw.phase == .failed
                ? NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
                : NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)

            tasksProgressBar?.isHidden = false
            if ipsw.totalBytes > 0 {
                tasksProgressBar?.isIndeterminate = false
                tasksProgressBar?.doubleValue = ipsw.fraction
            } else {
                tasksProgressBar?.isIndeterminate = true
                tasksProgressBar?.startAnimation(nil)
            }
        } else {
            tasksStatusLabel?.stringValue = "No tasks running."
            tasksStatusLabel?.textColor = NSColor(white: 0.45, alpha: 1.0)
            tasksProgressBar?.isHidden = true
            tasksProgressBar?.stopAnimation(nil)
        }

        // Merge logs from both trackers — show whichever has content
        var allLogs: [String] = []
        if sandboxActive || !sandbox.logMessages.isEmpty {
            allLogs.append(contentsOf: sandbox.logMessages)
        }
        if ipswActive || !ipsw.logMessages.isEmpty {
            if !allLogs.isEmpty && !ipsw.logMessages.isEmpty { allLogs.append("---") }
            allLogs.append(contentsOf: ipsw.logMessages)
        }

        // S14: append-only updates instead of `tv.string = newLog` rebuild.
        // The previous approach rebuilt the entire NSTextStorage on every
        // tracker notification (~100 rebuilds per IPSW download), causing
        // visible flicker and pointless work. Now we only render the new
        // tail. Reset on shrink (when a tracker's begin() clears its log).
        guard let tv = tasksLogTextView else { return }
        if allLogs.count < lastDisplayedLogCount {
            tv.string = ""
            lastDisplayedLogCount = 0
        }
        if allLogs.count > lastDisplayedLogCount {
            let newLines = allLogs[lastDisplayedLogCount..<allLogs.count]
            let prefix = lastDisplayedLogCount == 0 ? "" : "\n"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor(white: 0.7, alpha: 1.0)
            ]
            tv.textStorage?.append(NSAttributedString(
                string: prefix + newLines.joined(separator: "\n"),
                attributes: attrs
            ))
            lastDisplayedLogCount = allLogs.count
            tv.scrollToEndOfDocument(nil)
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
        switch currentLibraryTab {
        case .standard:  return displayedStandardVMs.count
        case .aiSandbox: return aiSandboxBundles.count
        }
    }

    // MARK: - NSTableViewDelegate

    /// Dequeue (or build) the cell for the Traffic column. The cell hosts a
    /// `SparklineView` configured from the per-VM rolling buffer in
    /// `trafficSamples`. AI Sandbox tab gets an empty sparkline because we
    /// don't sample those bundles through the virtual switch.
    private func trafficColumnCell(tableView: NSTableView, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TrafficColumn")
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        var spark: SparklineView!
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = id
            spark = SparklineView(frame: NSRect(x: 6, y: 2, width: 68, height: 16))
            spark.autoresizingMask = [.width, .height]
            cell?.addSubview(spark)
        } else {
            spark = cell?.subviews.first(where: { $0 is SparklineView }) as? SparklineView
        }

        let vmName: String? = {
            if currentLibraryTab == .standard {
                return standardVM(at: row)?.name
            }
            return nil
        }()
        spark.samples = vmName.flatMap { trafficSamples[$0] } ?? []
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Traffic column gets a custom SparklineView cell instead of the
        // shared NSTextField cell used by every other column. We intercept
        // here before the text-cell construction below.
        if tableColumn?.identifier.rawValue == "TrafficColumn" {
            return trafficColumnCell(tableView: tableView, row: row)
        }

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

        guard let finalCell = cell else { return nil }

        // AI Sandbox tab uses the same columns but filled from the bundle row
        if currentLibraryTab == .aiSandbox {
            guard row < aiSandboxBundles.count else { return nil }
            let bundle = aiSandboxBundles[row]
            let columnId = tableColumn?.identifier.rawValue ?? ""

            switch columnId {
            case "NameColumn":
                finalCell.textField?.stringValue = bundle.displayName + (bundle.isBase ? " (base)" : "")
            case "StatusColumn":
                finalCell.textField?.stringValue = bundle.isBase ? "Template" : "Session"
            case "OSColumn":
                finalCell.textField?.stringValue = "macOS"
            case "CPUColumn":
                finalCell.textField?.stringValue = bundle.id?.uuidString.prefix(8).description ?? "—"
            case "MemoryColumn":
                finalCell.textField?.stringValue = bundle.isBase ? "8 GB" : "—"
            case "DiskColumn":
                finalCell.textField?.stringValue = ByteCountFormatter.string(
                    fromByteCount: bundle.diskBytes, countStyle: .binary)
            case "LastUsedColumn":
                if let created = bundle.createdAt {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    finalCell.textField?.stringValue = formatter.string(from: created)
                } else {
                    finalCell.textField?.stringValue = "—"
                }
            default:
                finalCell.textField?.stringValue = ""
            }
            return finalCell
        }

        // Standard VMs tab — existing behavior
        guard let vm = standardVM(at: row) else { return nil }

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

    // MARK: - NSOutlineViewDataSource / Delegate (AI Sandbox tab)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return aiSandboxRootNode == nil ? 0 : 1
        }
        return (item as? AISandboxNode)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return aiSandboxRootNode! }
        return (item as! AISandboxNode).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return ((item as? AISandboxNode)?.children?.isEmpty == false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? AISandboxNode, let colId = tableColumn?.identifier.rawValue else {
            return nil
        }
        let bundle = node.bundle
        let cellId = NSUserInterfaceItemIdentifier("AISandboxOutlineCell_\(colId)")
        var cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellId
            let text = NSTextField()
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell?.addSubview(text)
            cell?.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }

        switch colId {
        case "NameColumn":
            // Sessions get a "↳" arrow prefix so the parent-child link reads
            // visually even when the disclosure triangle is collapsed. Base
            // bundle gets a "◆" diamond marker to distinguish it as the
            // template.
            let prefix = bundle.isBase ? "◆  " : "↳  "
            let suffix = bundle.isBase ? "  (base)" : ""
            cell?.textField?.stringValue = prefix + bundle.displayName + suffix
            cell?.textField?.font = bundle.isBase
                ? NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .semibold)
                : NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular)
            cell?.textField?.textColor = bundle.isBase ? AppColors.accentODGlow : AppColors.textPrimary
        case "StatusColumn":
            cell?.textField?.stringValue = bundle.isBase ? "TEMPLATE" : "SESSION"
            cell?.textField?.textColor = bundle.isBase ? AppColors.accentOrange : AppColors.statusRunning
            cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeCaption, weight: .semibold)
        case "OSColumn":
            cell?.textField?.stringValue = "macOS"
            cell?.textField?.textColor = AppColors.textMuted
        case "CPUColumn":  // repurposed for session id prefix
            cell?.textField?.stringValue = bundle.sessionID ?? "—"
            cell?.textField?.textColor = AppColors.textMuted
            cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular)
        case "MemoryColumn":
            cell?.textField?.stringValue = bundle.isBase ? "8 GB" : "—"
            cell?.textField?.textColor = AppColors.textMuted
        case "DiskColumn":
            cell?.textField?.stringValue = ByteCountFormatter.string(
                fromByteCount: bundle.diskBytes, countStyle: .binary)
            cell?.textField?.textColor = AppColors.textMuted
        case "LastUsedColumn":
            if let created = bundle.createdAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                cell?.textField?.stringValue = formatter.string(from: created)
            } else {
                cell?.textField?.stringValue = "—"
            }
            cell?.textField?.textColor = AppColors.textMuted
        default:
            cell?.textField?.stringValue = ""
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
        updateSelectedVMDetailCard()
    }

    // MARK: - NSTableViewDelegate (cont.)

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
        updateSelectedVMDetailCard()
    }

    // MARK: - Actions

    @IBAction func startVM(_ sender: Any) {
        // AI Sandbox tab: read from the outline view (not the table). Two
        // routing rules:
        //
        //  - Base node selected: if any sessions exist, boot the latest
        //    one in place ("Start" on the parent means "boot the most
        //    recent child"). If no sessions, fall through with reuseID
        //    = nil so AppDelegate clones+boots a fresh one.
        //  - Session node selected: boot THAT specific session.
        //
        // Either way the recovery-mode checkbox state controls boot path.
        if currentLibraryTab == .aiSandbox {
            guard let outline = aiSandboxOutlineView,
                  let node = outline.item(atRow: outline.selectedRow) as? AISandboxNode else {
                return
            }
            let inRecovery = (recoveryModeCheckbox?.state == .on)
            var reuseID: String? = nil
            var isBase = node.bundle.isBase
            if node.bundle.isBase {
                if let latest = latestAISandboxSessionNode() {
                    reuseID = latest.bundle.sessionID
                    isBase = false   // We're effectively booting a session
                }
                // else reuseID stays nil → fresh clone path
            } else {
                reuseID = node.bundle.sessionID
            }
            var userInfo: [String: Any] = [
                "inRecoveryMode": inRecovery,
                "isBaseBundle": isBase
            ]
            if let id = reuseID { userInfo["reusingSessionID"] = id }
            NotificationCenter.default.post(
                name: .bootAISandbox, object: nil, userInfo: userInfo)
            return
        }

        // Standard tab — needs a VM selected in the NSTableView
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

        guard let vmToStart = standardVM(at: selectedRow) else { return }
        selectedVM = vmToStart

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
        // AI Sandbox tab — delete the selected session bundle off disk.
        // updateButtonStates() already disables the Delete button for the
        // base bundle, but we double-check here to defend against keyboard
        // shortcut paths.
        if currentLibraryTab == .aiSandbox {
            guard let outline = aiSandboxOutlineView,
                  let node = outline.item(atRow: outline.selectedRow) as? AISandboxNode else {
                return
            }
            let bundle = node.bundle
            guard !bundle.isBase else {
                showAlert(message: "The AI Sandbox base bundle cannot be deleted from here. Use Tools → Create AI Sandbox VM to rebuild it.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Delete AI Sandbox session?"
            alert.informativeText = "Permanently remove the bundle at:\n\(bundle.url.path)\n\nThis action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.removeItem(at: bundle.url)
                aiSandboxBundles = scanAISandboxBundles()
                rebuildAISandboxNodeTree()
                updateButtonStates()
                updateSelectedVMDetailCard()
            } catch {
                showAlert(message: "Failed to delete bundle: \(error.localizedDescription)")
            }
            return
        }

        // Standard tab — needs a VM selected in the table
        guard let tableView = tableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to delete")
            return
        }
        guard let vm = standardVM(at: selectedRow) else { return }

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

        guard let vm = standardVM(at: selectedRow) else { return }

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

        guard let vm = standardVM(at: selectedRow) else { return }

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

        guard let vm = standardVM(at: selectedRow) else { return }
        showConfigureVMDialog(vm)
    }

    @IBAction func refreshVMList(_ sender: Any) {
        refreshTable()
    }

    // MARK: - macOS VM Download

    /// First checks `~/.avf/MacOS/` for a cached IPSW before starting any
    /// download. If a cached IPSW exists, use it directly and skip the
    /// download path. If not, prompt the user to run Tools → Download macOS
    /// IPSW first instead of triggering an in-flow download from this window.
    private func prepareMacOSVMUsingCachedIPSW(_ vmConfig: VMConfiguration) {
        let macOSDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".avf/MacOS", isDirectory: true)
        let cachedIPSW = (try? FileManager.default.contentsOfDirectory(
            at: macOSDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.first(where: { $0.pathExtension.lowercased() == "ipsw" })

        if let cached = cachedIPSW {
            NSLog("[VMLibrary] Reusing cached IPSW: %@", cached.path)
            selectedVM = vmConfig
            vmManager.updateLastUsedDate(vmConfig)
            NotificationCenter.default.post(
                name: .startVMWithISO,
                object: ["vm": vmConfig, "iso": cached]
            )
            return
        }

        // No cache — point the user at the dedicated download tool instead
        // of starting an in-flow download from this dialog.
        let alert = NSAlert()
        alert.messageText = "No cached macOS IPSW"
        alert.informativeText = """
        New macOS VMs reuse a cached IPSW from \(macOSDir.path) — no copy is
        currently there.

        Use Tools → Download macOS IPSW… to fetch one (one-time, ~13-16 GB).
        Then create this VM again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

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
            self.refreshEmptyStateOverlays()
            self.refreshConnectionOverlay()
        }
    }

    private func updateButtonStates() {
        let isAITab = (currentLibraryTab == .aiSandbox)
        let hasSelection: Bool = {
            if isAITab {
                return (aiSandboxOutlineView?.selectedRow ?? -1) >= 0
            }
            return (tableView?.selectedRow ?? -1) >= 0
        }()

        // AI Sandbox bundles have their own lifecycle (create via Tools menu,
        // boot via Start, otherwise managed on disk). The standard Configure
        // / Clone / Rename / Import / New flows don't apply, so we disable
        // them in the AI Sandbox tab to avoid silent no-ops.
        startButton?.isEnabled = hasSelection
        deleteButton?.isEnabled = hasSelection && (!isAITab || isAITabSessionRowSelected())
        configureButton?.isEnabled = hasSelection && !isAITab
        cloneButton?.isEnabled     = hasSelection && !isAITab
        renameButton?.isEnabled    = hasSelection && !isAITab
        newButton?.isEnabled       = !isAITab
        importButton?.isEnabled    = !isAITab

        let allButtons: [NSButton?] = [startButton, deleteButton, renameButton,
                                       cloneButton, configureButton, newButton, importButton]
        allButtons.compactMap({ $0 }).forEach(applyButtonStyle)
    }

    /// True when the AI Sandbox tab is active AND the currently selected
    /// outline-view row is a session (not the base bundle). The base bundle
    /// must not be deletable from the library — that's a Tools-menu admin
    /// action only.
    private func isAITabSessionRowSelected() -> Bool {
        guard currentLibraryTab == .aiSandbox,
              let outline = aiSandboxOutlineView,
              let node = outline.item(atRow: outline.selectedRow) as? AISandboxNode else {
            return false
        }
        return !node.bundle.isBase
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

        // ISO Cache Status Label (below version dropdown). Two lines tall:
        // line 1 shows version, line 2 shows download date. Frame height
        // bumped to 32 to fit both at 11pt; .byWordWrapping handles the
        // wrap on the explicit "\n" we insert when populating the value.
        let isoCacheStatusLabel = NSTextField(labelWithString: "")
        isoCacheStatusLabel.frame = NSRect(x: 110, y: 218, width: 280, height: 32)
        isoCacheStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        isoCacheStatusLabel.isEditable = false
        isoCacheStatusLabel.isBordered = false
        isoCacheStatusLabel.drawsBackground = false
        isoCacheStatusLabel.usesSingleLineMode = false
        isoCacheStatusLabel.maximumNumberOfLines = 2
        isoCacheStatusLabel.lineBreakMode = .byWordWrapping
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
                    // ISO is cached — show version + date on two lines so
                    // the user sees what "Latest" actually resolved to last
                    // time it downloaded.
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    let dateString = formatter.string(from: downloadDate)

                    let versionLine: String
                    if let v = distroInfo.cachedVersion, !v.isEmpty {
                        versionLine = "ISO Cached · v\(v)"
                    } else {
                        versionLine = "ISO Cached"
                    }
                    isoCacheStatusLabel.stringValue =
                        "\(versionLine)\ndownloaded \(dateString)"
                    isoCacheStatusLabel.textColor = AppColors.statusRunning
                    isoCacheStatusLabel.maximumNumberOfLines = 2
                    isoCacheStatusLabel.lineBreakMode = .byWordWrapping
                } else {
                    // ISO not cached - show red text
                    isoCacheStatusLabel.stringValue = "Will download latest ISO"
                    isoCacheStatusLabel.textColor = AppColors.accentRed
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
                    // macOS VMs reuse a cached IPSW from ~/.avf/MacOS/. If
                    // none is present, the user is pointed at Tools →
                    // Download macOS IPSW…. The legacy in-flow download via
                    // downloadAndPrepareMacOSVM is kept around for now but
                    // not the default path.
                    NSLog("[VMLibrary] OS type is macOS, using cached IPSW path...")
                    prepareMacOSVMUsingCachedIPSW(newVM)
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
