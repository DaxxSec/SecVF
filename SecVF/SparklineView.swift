//
//  SparklineView.swift
//  SecVF
//
//  Tiny line chart for the per-VM traffic column of the library table.
//  Draws a rolling buffer of bytes/sec samples as a single polyline; no
//  axis labels, no gridlines — just an at-a-glance "is this VM busy?"
//  cue, matching the design mockup at docs/ui-redesign-mockup.html.
//

import Cocoa

/// A minimal sparkline renderer. Pass it a fresh `samples` array on each
/// reuse — internal state lives in the parent (VMLibraryWindowController's
/// `trafficSamples` dict, keyed by VM name) so the view itself is cheap to
/// recycle across NSTableView dequeues.
final class SparklineView: NSView {

    var samples: [Double] = [] {
        didSet { needsDisplay = true }
    }

    /// Stroke color. Defaults to OD; callers may override for protocol-
    /// tinted rows.
    var strokeColor: NSColor = AppColors.accentOD {
        didSet { needsDisplay = true }
    }

    /// When `samples.max()` is below this floor, the polyline is drawn
    /// against the floor as the y-axis ceiling. Prevents tiny noise
    /// (a few hundred bytes/sec) from rendering as towering spikes.
    var noiseFloor: Double = 4096   // ~4 KiB/s

    override var isFlipped: Bool { false }   // y=0 at bottom — matches Cocoa

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
        guard samples.count >= 2, bounds.height > 2 else { return }

        let maxValue = max(samples.max() ?? noiseFloor, noiseFloor)
        let topInset: CGFloat = 2
        let bottomInset: CGFloat = 2
        let usableHeight = bounds.height - topInset - bottomInset
        let stepX = bounds.width / CGFloat(max(samples.count - 1, 1))

        // Build the polyline.
        let path = NSBezierPath()
        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = max(0, min(1, CGFloat(sample / maxValue)))
            let y = bottomInset + normalized * usableHeight
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.line(to: CGPoint(x: x, y: y))
            }
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round

        strokeColor.setStroke()
        path.stroke()
    }
}
