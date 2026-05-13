//
//  TacticalTableHeaderCell.swift
//  SecVF
//
//  NSTableHeaderCell subclass that paints column headers with the
//  tactical palette instead of AppKit's stock grey gradient. Applied
//  to both the standard VM table and the AI Sandbox outline view by
//  swapping `column.headerCell = TacticalTableHeaderCell(...)`.
//
//  Spec:
//   - Background: backgroundSecondary (dark slate)
//   - Bottom rule: borderOD at ~45% opacity, hairline
//   - Caption: monospaced, weight=medium, color=textSubtle, uppercased
//   - Padding: 8pt leading
//

import Cocoa

final class TacticalTableHeaderCell: NSTableHeaderCell {

    override init(textCell string: String) {
        super.init(textCell: string)
        configure(string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure(stringValue)
    }

    private func configure(_ raw: String) {
        // NSTableHeaderCell still picks up `stringValue`; we set the
        // formatted version once at construction so AppKit doesn't have
        // to redo work on every draw.
        stringValue = raw.uppercased()
        font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        textColor = AppColors.textSubtle
        alignment = .left
        isBordered = false
        backgroundColor = AppColors.backgroundSecondary
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Fill the background ourselves — the default cell paints a
        // platform-tinted gradient that fights the tactical palette.
        AppColors.backgroundSecondary.setFill()
        cellFrame.fill()

        // Hairline rule along the bottom edge to separate header from
        // data rows. Same colour the row-view separator uses, so the
        // whole table reads as one visual unit.
        AppColors.borderOD.withAlphaComponent(0.45).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 0.5,
               width: cellFrame.width, height: 0.5).fill()

        // Inset the caption 8pt from the leading edge for breathing room.
        let inset: CGFloat = 8
        let textRect = NSRect(x: cellFrame.minX + inset,
                              y: cellFrame.minY,
                              width: cellFrame.width - inset * 2,
                              height: cellFrame.height)
        drawInterior(withFrame: textRect, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: textColor ?? AppColors.textSubtle
        ]
        let attributed = NSAttributedString(string: stringValue, attributes: attrs)
        let textSize = attributed.size()
        // Center the text vertically inside the cell.
        let textOrigin = NSPoint(
            x: cellFrame.minX,
            y: cellFrame.minY + (cellFrame.height - textSize.height) / 2
        )
        attributed.draw(at: textOrigin)
    }
}
