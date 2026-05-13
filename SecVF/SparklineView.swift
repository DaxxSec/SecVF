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
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
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
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configureAccessibility()
    }

    // MARK: - Accessibility
    //
    // VoiceOver can't read a polyline, so we expose the sparkline as an
    // ImageView-role element with a label ("Traffic sparkline") and a
    // dynamic value summarising the latest sample. Sighted users see the
    // line; VoiceOver users hear "12.4 KB/s, 30 samples over 45 seconds".

    private func configureAccessibility() {
        setAccessibilityRole(.image)
        setAccessibilityLabel("Traffic sparkline")
        setAccessibilityRoleDescription("Network traffic over time")
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        guard !samples.isEmpty else {
            setAccessibilityValue("No traffic samples")
            return
        }
        let latest = samples.last ?? 0
        let peak = samples.max() ?? 0
        let bcf = ByteCountFormatter()
        bcf.countStyle = .binary
        let latestStr = bcf.string(fromByteCount: Int64(latest))
        let peakStr = bcf.string(fromByteCount: Int64(peak))
        setAccessibilityValue("Latest \(latestStr)/s · peak \(peakStr)/s · \(samples.count) samples")
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
