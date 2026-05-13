//
//  VMCardCellView.swift
//  SecVF
//
//  Multi-line table cell for the VM library. Replaces the previous
//  flat per-column NSTextField cells with a single dense card that
//  shows three rows of metadata:
//
//      ┌──────────────────────────────────────────────────────────┐
//      │ kali-router                              ● RUNNING       │
//      │ Kali Linux 2025.1  ·  4 cores · 4 GB  ·  12 / 32 GB      │
//      │ [⇄ VIRTUAL ▾]   ↓ 12 kB/s · ↑ 0.3 kB/s   1,284 pkts  ▁▄▇ │
//      └──────────────────────────────────────────────────────────┘
//
//  The network-mode chip on the third line is a click target — tapping
//  it cycles the VM's mode (NAT → Virtual → Router → NAT) via the
//  owning controller. The cycle is blocked when the VM is running,
//  per Apple's Virtualization framework's one-shot network-attachment
//  semantics; the click handler still fires but the controller
//  surfaces a brief alert instead of mutating state.
//
//  The cell is mode-aware: AI Sandbox bundles use the same view with
//  the third line repurposed for "TEMPLATE" / "SESSION" badging.
//

import Cocoa

@MainActor
final class VMCardCellView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("VMCardCellView")
    static let rowHeight: CGFloat = 62

    // MARK: - Subviews

    private let nameLabel = NSTextField(labelWithString: "")
    private let statusPill = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let networkChip = NSButton(title: "—", target: nil, action: nil)
    private let rateLabel = NSTextField(labelWithString: "")
    private let packetsLabel = NSTextField(labelWithString: "")
    let sparkline = SparklineView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))

    // MARK: - Bound VM

    /// Called when the user clicks the network-mode chip. The owning
    /// controller looks up the VM by id and calls VMManager.cycleNetworkMode.
    var onCycleNetworkMode: ((UUID) -> Void)?

    /// VM ID currently rendered. Used by the click handler to route
    /// the cycle request back to the controller without retaining the
    /// full VMConfiguration value.
    private var renderedVMID: UUID?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        buildLayout()
    }

    // MARK: - Layout

    private func buildLayout() {
        let padL: CGFloat = 14
        let padR: CGFloat = 14

        // Row 1 — Name (left) + Status pill (right)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = AppColors.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: padL, y: 42, width: 200, height: 18)
        nameLabel.autoresizingMask = [.width, .minYMargin]
        addSubview(nameLabel)

        statusPill.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        statusPill.alignment = .center
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 9
        statusPill.layer?.borderWidth = 1.0
        statusPill.isBordered = false
        statusPill.drawsBackground = false
        statusPill.lineBreakMode = .byClipping
        statusPill.frame = NSRect(x: 0, y: 42, width: 84, height: 18)
        statusPill.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(statusPill)

        // Row 2 — Meta line (OS · CPU·RAM · Disk)
        metaLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = AppColors.textMuted
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.frame = NSRect(x: padL, y: 24, width: 400, height: 14)
        metaLabel.autoresizingMask = [.width, .minYMargin]
        addSubview(metaLabel)

        // Row 3 — Network chip (clickable) + Rate + Packets + Sparkline
        networkChip.target = self
        networkChip.action = #selector(handleNetworkChipClick)
        networkChip.isBordered = false
        networkChip.wantsLayer = true
        networkChip.layer?.borderWidth = 1.0
        networkChip.layer?.cornerRadius = 8
        networkChip.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        networkChip.alignment = .center
        networkChip.frame = NSRect(x: padL, y: 4, width: 110, height: 16)
        networkChip.autoresizingMask = [.minYMargin]
        addSubview(networkChip)

        rateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rateLabel.textColor = AppColors.textSubtle
        rateLabel.frame = NSRect(x: padL + 120, y: 5, width: 180, height: 14)
        rateLabel.autoresizingMask = [.minYMargin]
        addSubview(rateLabel)

        packetsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        packetsLabel.textColor = AppColors.textSubtle
        packetsLabel.alignment = .right
        packetsLabel.frame = NSRect(x: 0, y: 5, width: 110, height: 14)
        packetsLabel.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(packetsLabel)

        sparkline.frame = NSRect(x: 0, y: 2, width: 60, height: 18)
        sparkline.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(sparkline)

        // Re-anchor right-edge subviews on layout pass
        anchorRightEdgeSubviews()
    }

    override func layout() {
        super.layout()
        anchorRightEdgeSubviews()
    }

    private func anchorRightEdgeSubviews() {
        let padR: CGFloat = 14
        let pillW: CGFloat = 84
        let pillH: CGFloat = 18
        statusPill.frame = NSRect(x: bounds.width - padR - pillW, y: 42,
                                  width: pillW, height: pillH)

        let sparkW: CGFloat = 60
        let sparkH: CGFloat = 18
        sparkline.frame = NSRect(x: bounds.width - padR - sparkW, y: 2,
                                 width: sparkW, height: sparkH)

        let packetsW: CGFloat = 110
        packetsLabel.frame = NSRect(x: bounds.width - padR - sparkW - 8 - packetsW, y: 5,
                                    width: packetsW, height: 14)

        // Name + meta line widths track the available space minus the
        // right-anchored elements + a small gap.
        let rightStop = bounds.width - padR - pillW - 8
        nameLabel.frame.size.width = max(40, rightStop - nameLabel.frame.origin.x)

        let metaRightStop = bounds.width - padR
        metaLabel.frame.size.width = max(40, metaRightStop - metaLabel.frame.origin.x)

        let rateRightStop = bounds.width - padR - sparkW - 8 - packetsW - 12
        rateLabel.frame.size.width = max(40, rateRightStop - rateLabel.frame.origin.x)
    }

    // MARK: - Configuration

    /// Populate the cell from a standard VM. The owning controller
    /// calls this whenever the row needs to render — once on initial
    /// reuse and again on any state change that doesn't move rows.
    func configure(with vm: VMConfiguration,
                   liveDownBps: Double?,
                   liveUpBps: Double?,
                   trafficSamples: [Double],
                   packetCount: UInt64?) {
        renderedVMID = vm.id

        // Row 1
        nameLabel.stringValue = vm.name + (vm.networkConfig.isRouter ? "  ⬡ ROUTER" : "")

        let (pillGlyph, pillText, pillColor) = Self.statusPillSpec(for: vm.status)
        let pillAttr = NSMutableAttributedString(string: pillGlyph + " ", attributes: [
            .foregroundColor: pillColor
        ])
        pillAttr.append(NSAttributedString(string: pillText, attributes: [
            .foregroundColor: pillColor.withAlphaComponent(0.95)
        ]))
        statusPill.attributedStringValue = pillAttr
        statusPill.layer?.backgroundColor = pillColor.withAlphaComponent(0.12).cgColor
        statusPill.layer?.borderColor = pillColor.withAlphaComponent(0.45).cgColor

        // Row 2 — meta
        let osStr: String = {
            if vm.osType == "Linux", let distro = vm.linuxDistribution {
                if let v = vm.linuxVersion, !v.isEmpty { return "\(distro) \(v)" }
                return distro
            }
            return vm.osType
        }()
        let ramGB = Double(vm.memorySize) / 1_073_741_824.0
        let diskGB = Double(vm.diskSize) / 1_073_741_824.0
        metaLabel.stringValue = String(format: "%@  ·  %d cores · %.1f GB  ·  %.0f GB disk",
                                       osStr, vm.cpuCount, ramGB, diskGB)

        // Row 3 — network chip
        let (chipText, chipColor) = Self.networkChipSpec(for: vm.networkConfig)
        let chipAttr = NSAttributedString(string: chipText, attributes: [
            .foregroundColor: chipColor,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        ])
        networkChip.attributedTitle = chipAttr
        networkChip.layer?.backgroundColor = chipColor.withAlphaComponent(0.10).cgColor
        networkChip.layer?.borderColor = chipColor.withAlphaComponent(0.45).cgColor
        networkChip.toolTip = (vm.status == .stopped)
            ? "Click to cycle network mode (NAT → Virtual → Router → NAT)"
            : "Stop the VM to change network mode — Apple's Virtualization framework attaches the network device once at boot"

        // Row 3 — rate readout
        if vm.status == .running, vm.networkConfig.mode == .virtual,
           let down = liveDownBps, let up = liveUpBps, (down + up) > 0 {
            let downStr = Self.formatBps(down)
            let upStr   = Self.formatBps(up)
            rateLabel.stringValue = "↓ \(downStr) · ↑ \(upStr)"
        } else if vm.status == .running, vm.networkConfig.mode == .nat {
            rateLabel.stringValue = "host-routed"
        } else {
            rateLabel.stringValue = "—"
        }

        // Row 3 — packets
        if let pkts = packetCount {
            packetsLabel.stringValue = Self.formatPacketCount(pkts) + " pkts"
        } else {
            packetsLabel.stringValue = "—"
        }

        // Sparkline
        sparkline.samples = trafficSamples

        anchorRightEdgeSubviews()
    }

    /// Configuration entry point for an AI Sandbox bundle row. Same
    /// three-line layout, but row 3 collapses to a static badge
    /// (TEMPLATE / SESSION) instead of a clickable network chip.
    func configureForSandbox(bundle: AISandboxBundleRow) {
        renderedVMID = nil   // network click is disabled for sandbox rows

        let suffix = bundle.isBase ? "  (base)" : ""
        nameLabel.stringValue = bundle.displayName + suffix

        let (pillGlyph, pillText, pillColor): (String, String, NSColor) = bundle.isBase
            ? ("◆", "TEMPLATE", AppColors.accentOrange)
            : ("●", "SESSION",  AppColors.statusRunning)
        let pillAttr = NSMutableAttributedString(string: pillGlyph + " ", attributes: [
            .foregroundColor: pillColor
        ])
        pillAttr.append(NSAttributedString(string: pillText, attributes: [
            .foregroundColor: pillColor.withAlphaComponent(0.95)
        ]))
        statusPill.attributedStringValue = pillAttr
        statusPill.layer?.backgroundColor = pillColor.withAlphaComponent(0.12).cgColor
        statusPill.layer?.borderColor = pillColor.withAlphaComponent(0.45).cgColor

        let diskStr = ByteCountFormatter.string(fromByteCount: bundle.diskBytes,
                                                countStyle: .binary)
        let ramStr = bundle.isBase ? "8 GB" : "—"
        metaLabel.stringValue = "macOS  ·  4 cores · \(ramStr)  ·  \(diskStr)"

        let chipText = bundle.isBase ? "⬡ BASE BUNDLE" : "↳ SESSION"
        let chipColor = bundle.isBase ? AppColors.accentOrange : AppColors.statusRunning
        let chipAttr = NSAttributedString(string: chipText, attributes: [
            .foregroundColor: chipColor,
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        ])
        networkChip.attributedTitle = chipAttr
        networkChip.layer?.backgroundColor = chipColor.withAlphaComponent(0.10).cgColor
        networkChip.layer?.borderColor = chipColor.withAlphaComponent(0.45).cgColor
        networkChip.toolTip = nil

        rateLabel.stringValue = "—"
        if let created = bundle.createdAt {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            packetsLabel.stringValue = f.string(from: created)
        } else {
            packetsLabel.stringValue = "—"
        }

        sparkline.samples = []
        anchorRightEdgeSubviews()
    }

    // MARK: - Actions

    @objc private func handleNetworkChipClick() {
        guard let id = renderedVMID else { return }
        onCycleNetworkMode?(id)
    }

    // MARK: - Static helpers

    static func statusPillSpec(for status: VMStatus) -> (glyph: String, text: String, color: NSColor) {
        switch status {
        case .running:  return ("●", "RUNNING",  AppColors.statusRunning)
        case .starting: return ("◐", "STARTING", AppColors.statusPaused)
        case .stopping: return ("◐", "STOPPING", AppColors.statusPaused)
        case .stopped:  return ("○", "STOPPED",  AppColors.statusStopped)
        }
    }

    static func networkChipSpec(for config: VirtualNetworkConfig)
        -> (text: String, color: NSColor)
    {
        switch config.mode {
        case .nat:
            return ("🌐 NAT", AppColors.networkNAT)
        case .virtual:
            if config.isRouter {
                return ("⬢ ROUTER", AppColors.accentOrange)
            } else if config.routerVMId != nil {
                return ("↳ GUEST", AppColors.accentODGlow)
            } else {
                return ("⊘ ISOLATED", AppColors.accentODGlow)
            }
        }
    }

    private static let packetCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    static func formatPacketCount(_ count: UInt64) -> String {
        return packetCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    static func formatBps(_ bps: Double) -> String {
        let units: [(threshold: Double, label: String)] = [
            (1_073_741_824, "GB/s"),
            (1_048_576,     "MB/s"),
            (1_024,         "kB/s"),
        ]
        for (threshold, label) in units {
            if bps >= threshold {
                return String(format: "%.1f %@", bps / threshold, label)
            }
        }
        return String(format: "%.0f B/s", bps)
    }
}
