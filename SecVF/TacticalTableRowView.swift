//
//  TacticalTableRowView.swift
//  SecVF
//
//  NSTableRowView subclass that replaces AppKit's default blue/grey
//  selection band with an OD-green tactical treatment matching the rest
//  of the redesigned UI:
//
//    ┌───────────────────────────────────────────┐
//    │██░░ kali-router         Running    ...    │   ← selected row
//    └───────────────────────────────────────────┘
//      ▲ 2pt accent stripe on the leading edge,
//        background tinted at ~12% alpha.
//
//  The default `drawSelection(in:)` paints a system-tinted rectangle; we
//  bypass that and paint our own. `drawSeparator(in:)` is also overridden
//  to a softer OD border instead of macOS's stock 1pt grey, so heavily-
//  populated tables read calmer.
//
//  Used by both the standard VM table and the AI Sandbox outline view —
//  NSOutlineView is an NSTableView subclass and inherits the same row-
//  view dispatch (`tableView(_:rowViewForRow:)`).
//

import Cocoa

final class TacticalTableRowView: NSTableRowView {

    /// Selection background tint. Falls back to OD-green when unset.
    var selectionTint: NSColor = AppColors.accentODGlow

    /// Width of the leading-edge accent stripe drawn when the row is
    /// selected. Zero disables the stripe (useful for the outline view
    /// where the disclosure triangle would clash with it).
    var accentStripeWidth: CGFloat = 2

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        // Tinted background — same hue as the live-data accent, low alpha
        // so the cell text stays the dominant layer.
        selectionTint.withAlphaComponent(0.14).setFill()
        bounds.fill()

        // Leading-edge accent stripe — drawn after the fill so it sits
        // above (and reads as a "you are here" indicator). RTL handled
        // automatically by `userInterfaceLayoutDirection`.
        guard accentStripeWidth > 0 else { return }
        selectionTint.setFill()
        let isRTL = userInterfaceLayoutDirection == .rightToLeft
        let stripeX = isRTL ? bounds.maxX - accentStripeWidth : 0
        NSRect(x: stripeX, y: 0,
               width: accentStripeWidth, height: bounds.height).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        // Soft OD separator at ~25% opacity. Hairline at the bottom of
        // the row, full width. The host NSTableView decides whether to
        // call drawSeparator at all for the last row (via its own
        // gridStyleMask / intercellSpacing logic), so we always draw
        // when called — no own-row trailing-edge skip needed here.
        AppColors.borderOD.withAlphaComponent(0.45).setFill()
        let separatorRect = NSRect(x: 0, y: bounds.maxY - 0.5,
                                   width: bounds.width, height: 0.5)
        separatorRect.fill()
    }
}
