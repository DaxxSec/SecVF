//
//  TacticalHoverButton.swift
//  SecVF
//
//  NSButton subclass that maintains its own NSTrackingArea and applies a
//  subtle hover treatment on mouseEntered: border brightens, background
//  shifts a few percent lighter. The tactical UI uses dim OD borders by
//  default so a hovered control needs a clear "you're about to click
//  this" cue without flashing brightly.
//
//  Configuration is via three colour pairs — idle and hover variants for
//  background, border, and (optional) text. The helper falls back to
//  sensible defaults from AppColors so most callers can use a single
//  `setHoverTreatment()` call.
//
//  Hover state is also stripped when the button is disabled so a greyed-
//  out button never flashes a hover ring.
//

import Cocoa

final class TacticalHoverButton: NSButton {

    /// Color used for `layer.borderColor` while the cursor is outside.
    var idleBorderColor: NSColor = AppColors.borderOD
    /// Color used for `layer.borderColor` while the cursor is over the button.
    var hoverBorderColor: NSColor = AppColors.borderODEmphasis
    /// Background color while idle. Nil keeps whatever was set before.
    var idleBackgroundColor: NSColor? = AppColors.backgroundButton
    /// Background color while hovered. Defaults to a slightly brighter
    /// blend of `idleBackgroundColor` if left nil.
    var hoverBackgroundColor: NSColor?

    /// Tracking area is rebuilt whenever the button's bounds change so
    /// we never miss enters/exits after a resize.
    private var trackingArea: NSTrackingArea?

    /// Latched so a disabled button never paints a hover state.
    private var isHovered: Bool = false {
        didSet { applyVisualState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: - Tracking area lifecycle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// AppKit doesn't repaint a button when its enabled state flips, so
    /// re-apply the visual when the property changes (it's a property,
    /// not a notification, so this is the cleanest hook).
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHovered = false }
            applyVisualState()
        }
    }

    // MARK: - Visual state

    /// Caller convenience for the most common setup — pass nil to keep
    /// the current ivar values for that slot.
    func setHoverTreatment(idleBorder: NSColor? = nil,
                           hoverBorder: NSColor? = nil,
                           idleBackground: NSColor? = nil,
                           hoverBackground: NSColor? = nil) {
        if let v = idleBorder       { idleBorderColor = v }
        if let v = hoverBorder      { hoverBorderColor = v }
        if let v = idleBackground   { idleBackgroundColor = v }
        if let v = hoverBackground  { hoverBackgroundColor = v }
        applyVisualState()
    }

    private func applyVisualState() {
        guard let layer = layer else { return }
        let useHover = isHovered && isEnabled
        layer.borderColor = (useHover ? hoverBorderColor : idleBorderColor).cgColor
        let bg: NSColor? = useHover
            ? (hoverBackgroundColor ?? idleBackgroundColor?.blended(withFraction: 0.18, of: .white))
            : idleBackgroundColor
        if let bg = bg {
            layer.backgroundColor = bg.cgColor
        }
    }
}
