//
//  TacticalSidebarSection.swift
//  SecVF
//
//  Sidebar section composed of a label header and a list of selectable
//  rows, each showing a leading glyph + title + trailing count. Used
//  for the mockup-spec navigation panes (Filters / Operating System /
//  Network) and for the Logs shortcut group, so the four blocks share
//  the same tactical look + interaction surface.
//
//  Each row is a single-selection radio within its section: clicking a
//  row sets the section's `selectedID` and invokes the supplied
//  `onSelect` closure with the row's identifier. Sections are
//  independent — the controller composes their selections into a
//  combined filter over the VM list.
//

import Cocoa

final class TacticalSidebarSection: NSView {

    /// Row definition. `id` is the value handed back via `onSelect`;
    /// `title` is the visible label; `glyph` is the leading icon
    /// character; `count` is the trailing count badge (nil = no badge).
    struct Row {
        let id: String
        let glyph: String
        let title: String
        var count: Int?
    }

    /// Externally-mutated selection. Setting this updates the visual
    /// state and does NOT fire `onSelect` (so callers can drive the
    /// selection programmatically without recursion).
    var selectedID: String? {
        didSet { refreshSelectionStyling() }
    }

    /// Called when the user clicks a row. The row's `id` is supplied.
    /// Empty `onSelect` (the default) means the section is display-only.
    var onSelect: (String) -> Void = { _ in }

    private let titleLabel: NSTextField
    private var rowViews: [String: SidebarRowView] = [:]

    /// Convenience: total height the section currently lays out to. Use
    /// when stacking sections vertically — caller positions origin.y
    /// and reads `intrinsicHeight` to advance.
    var intrinsicHeight: CGFloat { _intrinsicHeight }
    private var _intrinsicHeight: CGFloat = 0

    init(title: String, rows: [Row]) {
        titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = AppColors.textSubtle

        super.init(frame: .zero)

        rebuild(rows: rows)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(title:rows:)")
    }

    // Layout constants captured so `layout()` can re-flow without a
    // second `rebuild` call when the frame finally resolves.
    private static let labelH: CGFloat = 14
    private static let rowH: CGFloat = 26
    private static let rowGap: CGFloat = 2
    private static let belowLabelGap: CGFloat = 6
    private static let inset: CGFloat = 12

    /// Replace the row set in place. Called when counts update (which
    /// happens on every VM list reload — see refreshCounts(rows:)).
    /// Frame is recomputed; caller is responsible for re-laying out
    /// any sections stacked below this one if `intrinsicHeight` changes.
    func rebuild(rows: [Row]) {
        // Tear down existing rows
        rowViews.values.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        let totalRowsHeight = CGFloat(rows.count) * Self.rowH +
                              CGFloat(max(0, rows.count - 1)) * Self.rowGap
        let total = Self.labelH + Self.belowLabelGap + totalRowsHeight
        _intrinsicHeight = total

        autoresizingMask = [.width]

        // Build views without trying to size them yet — `layoutSubviews`
        // (called once the section's frame is set by the controller)
        // gives them their final widths based on the section's real
        // bounds. This avoids the "bounds.width is 0 during init →
        // sub-views get width = -24" trap that previously truncated
        // section titles to "ERATING SYSTEM" / "TWORK" / "GS".
        titleLabel.autoresizingMask = [.width, .minYMargin]
        addSubview(titleLabel)

        for row in rows {
            let view = SidebarRowView(row: row, height: Self.rowH)
            view.autoresizingMask = [.width, .minYMargin]
            view.onTap = { [weak self] id in
                guard let self = self else { return }
                if self.selectedID != id {
                    self.selectedID = id
                }
                self.onSelect(id)
            }
            addSubview(view)
            rowViews[row.id] = view
        }

        refreshSelectionStyling()
        relayoutContents()
    }

    /// Position the title + rows based on the section's CURRENT bounds.
    /// Called from `layout()` (Cocoa hook fired after frame resolves
    /// from the parent) and from `rebuild` so initial paint is right.
    private func relayoutContents() {
        let usableW = max(0, bounds.width - Self.inset * 2)
        let total = _intrinsicHeight

        titleLabel.frame = NSRect(x: Self.inset, y: total - Self.labelH,
                                  width: usableW, height: Self.labelH)

        // Rows below, top-down. Iterate in the same order rebuild built
        // them so the visual order matches the data order.
        var y = total - Self.labelH - Self.belowLabelGap - Self.rowH
        for subview in subviews {
            guard let row = subview as? SidebarRowView else { continue }
            row.frame = NSRect(x: Self.inset, y: y, width: usableW, height: Self.rowH)
            y -= (Self.rowH + Self.rowGap)
        }
    }

    override func layout() {
        super.layout()
        relayoutContents()
    }

    /// Update just the count badges + (optionally) the selection state
    /// without rebuilding the row layout. Cheaper than `rebuild` for
    /// the common "VM list changed, counts shifted" path.
    func refreshCounts(_ counts: [String: Int]) {
        for (id, view) in rowViews {
            view.setCount(counts[id])
        }
    }

    private func refreshSelectionStyling() {
        for (id, view) in rowViews {
            view.isSelected = (id == selectedID)
        }
    }
}

// MARK: - SidebarRowView

/// Visual row inside a TacticalSidebarSection. Custom NSView (rather
/// than NSButton) because the layered selection band + leading glyph
/// + trailing count layout doesn't fit NSButton's title-only API.
private final class SidebarRowView: NSView {

    private let glyphLabel: NSTextField
    private let titleLabel: NSTextField
    private let countLabel: NSTextField
    private let rowID: String

    var onTap: (String) -> Void = { _ in }

    var isSelected: Bool = false {
        didSet { refreshStyling() }
    }

    private var isHovered: Bool = false {
        didSet { refreshStyling() }
    }

    init(row: TacticalSidebarSection.Row, height: CGFloat) {
        self.rowID = row.id

        glyphLabel = NSTextField(labelWithString: row.glyph)
        glyphLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        glyphLabel.alignment = .center

        titleLabel = NSTextField(labelWithString: row.title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)

        countLabel = NSTextField(labelWithString: row.count.map { String($0) } ?? "")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.alignment = .right
        countLabel.textColor = AppColors.textSubtle

        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))

        wantsLayer = true
        layer?.cornerRadius = LayoutConstants.cornerRadiusSM

        let glyphW: CGFloat = 18
        let countW: CGFloat = 32
        let textPadL: CGFloat = 6
        let textPadR: CGFloat = 4

        glyphLabel.frame = NSRect(x: 6, y: 0, width: glyphW, height: height)
        glyphLabel.autoresizingMask = [.maxXMargin]
        addSubview(glyphLabel)

        countLabel.frame = NSRect(x: bounds.width - countW - 8, y: 0,
                                  width: countW, height: height)
        countLabel.autoresizingMask = [.minXMargin]
        addSubview(countLabel)

        let titleX = 6 + glyphW + textPadL
        titleLabel.frame = NSRect(x: titleX, y: 0,
                                  width: bounds.width - titleX - countW - textPadR - 8,
                                  height: height)
        titleLabel.autoresizingMask = [.width]
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        refreshStyling()

        // Click handling — install a tracking area for hover; mouseDown
        // fires the tap callback.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited,
                                            .activeInActiveApp,
                                            .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)

        setAccessibilityRole(.button)
        setAccessibilityLabel("\(row.title)\(row.count.map { " (\($0))" } ?? "")")
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(row:height:)")
    }

    func setCount(_ count: Int?) {
        countLabel.stringValue = count.map { String($0) } ?? ""
    }

    private func refreshStyling() {
        let bgColor: NSColor
        let glyphColor: NSColor
        let titleColor: NSColor
        let countColor: NSColor

        if isSelected {
            bgColor    = AppColors.backgroundRowSelected.withAlphaComponent(0.55)
            glyphColor = AppColors.accentODGlow
            titleColor = AppColors.textPrimary
            countColor = AppColors.textPrimary
        } else if isHovered {
            bgColor    = AppColors.backgroundRowHover.withAlphaComponent(0.4)
            glyphColor = AppColors.textPrimary
            titleColor = AppColors.textPrimary
            countColor = AppColors.textSubtle
        } else {
            bgColor    = .clear
            glyphColor = AppColors.textMuted
            titleColor = AppColors.textMuted
            countColor = AppColors.textSubtle
        }

        layer?.backgroundColor = bgColor.cgColor
        glyphLabel.textColor = glyphColor
        titleLabel.textColor = titleColor
        countLabel.textColor = countColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onTap(rowID)
    }
}
