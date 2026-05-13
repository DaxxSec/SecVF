//
//  VMConnectionOverlayView.swift
//  SecVF
//
//  Transparent overlay placed on top of the VM library NSTableView that
//  draws bracket connectors between rows of network-linked VMs that are
//  currently running. Mouse events pass through untouched, so the table's
//  selection and double-click behaviour are unaffected.
//
//  Each "connection" is a (fromRow, toRow) pair. The overlay draws a small
//  bracket on the right edge of each row pair:
//
//      ─┐
//       │
//      ─┘
//
//  Multiple pairs (e.g. one router with three guests) produce multiple
//  brackets stacked in the gutter. Stroke color: AppColors.accentODGlow
//  so it reads as "these are operational and linked".
//

import Cocoa

final class VMConnectionOverlayView: NSView {

    /// (fromRow, toRow) pairs of row indices to connect. Set this from
    /// the library window controller after a table reload or VM status
    /// change. Empty array → nothing drawn.
    var connections: [(fromRow: Int, toRow: Int)] = [] {
        didSet { needsDisplay = true }
    }

    /// The table view this overlay sits over. Used to look up row rects.
    weak var tableView: NSTableView?

    override var isFlipped: Bool { tableView?.isFlipped ?? false }

    /// Mouse events pass through to the table view so the overlay never
    /// steals clicks / double-clicks / selection.
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView, !connections.isEmpty else { return }

        // Bracket sits in the right gutter, 8pt from the right edge.
        let gutterX = bounds.maxX - 8
        let stubLen: CGFloat = 6

        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        for conn in connections {
            // tableView.rect(ofRow:) returns coords in the table's own
            // coordinate system. Because this overlay is a SUBVIEW of the
            // table, those coords correspond 1:1 to ours — no conversion.
            let r1 = table.rect(ofRow: conn.fromRow)
            let r2 = table.rect(ofRow: conn.toRow)
            guard r1.height > 0, r2.height > 0 else { continue }

            let yTop = min(r1.midY, r2.midY)
            let yBot = max(r1.midY, r2.midY)

            // Top stub
            path.move(to: CGPoint(x: gutterX - stubLen, y: r1.midY))
            path.line(to: CGPoint(x: gutterX,            y: r1.midY))
            // Vertical
            path.move(to: CGPoint(x: gutterX, y: yTop))
            path.line(to: CGPoint(x: gutterX, y: yBot))
            // Bottom stub
            path.move(to: CGPoint(x: gutterX - stubLen, y: r2.midY))
            path.line(to: CGPoint(x: gutterX,            y: r2.midY))
        }

        AppColors.accentODGlow.setStroke()
        path.stroke()

        // Tiny end-caps as dots at each row tap-point for visual emphasis.
        AppColors.accentODGlow.withAlphaComponent(0.9).setFill()
        for conn in connections {
            let r1 = table.rect(ofRow: conn.fromRow)
            let r2 = table.rect(ofRow: conn.toRow)
            for y in [r1.midY, r2.midY] {
                let dotRect = NSRect(x: gutterX - 2, y: y - 2, width: 4, height: 4)
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }
}
