//
//  VMTrafficFallOverlayView.swift
//  SecVF
//
//  Decorative animated overlay on top of the VM library NSTableView that
//  cascades small "packet" dots top→bottom across each running VM's row
//  whose network activity is non-zero. Visual replacement for the legacy
//  right-panel NetworkTrafficView; the per-row variant keeps the eyecandy
//  while removing the column itself.
//
//  Per-row activity intensity (0..1) is pushed from the window controller
//  every traffic-sample tick via `setActiveRows(_:)`. The overlay owns its
//  own 30 fps timer and spawns particles at a rate proportional to that
//  intensity. Idle rows produce nothing; the timer stops itself whenever
//  no particles are alive AND no rows are active, so the overlay imposes
//  zero runtime cost when no VMs are running.
//
//  Mouse events pass through (hitTest → nil). Draws at low alpha so cell
//  text stays the dominant layer. Color: AppColors.accentODGlow.
//

import Cocoa

final class VMTrafficFallOverlayView: NSView {

    /// Single particle on its way down a row. `y` is the local vertical
    /// offset inside the row in row-coords (0 = row top, growing down).
    /// `age` advances on each tick and drives fade-out near the bottom.
    private struct Particle {
        var y: CGFloat
        var age: CGFloat        // 0..1, where 1 = dead
        var x: CGFloat          // jitter within the band
        var speed: CGFloat      // pt per tick
    }

    /// The table view this overlay sits over. Used to look up row rects.
    weak var tableView: NSTableView?

    /// Active rows + their per-row intensity (0..1). Drives spawn cadence.
    /// Push fresh values whenever the traffic sample tick fires.
    private var activeRows: [Int: CGFloat] = [:]

    /// Live particles keyed by row index. Particles are short-lived (≤2 s)
    /// so the buffer never grows unboundedly even under sustained traffic.
    private var particles: [Int: [Particle]] = [:]

    /// 30 fps animation tick. Lazy — only running when at least one row
    /// is active or has alive particles, so an empty library imposes no
    /// cost.
    private var timer: Timer?

    /// Counter used to throttle particle spawn cadence without
    /// allocating a per-row timestamp dictionary.
    private var spawnTick: Int = 0

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

    override var isFlipped: Bool { tableView?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }

    /// Push the current set of active rows with their intensity weights.
    /// `intensities[rowIndex] = 0..1`. Rows missing from the map (or with
    /// 0) stop spawning new particles but existing ones still finish their
    /// fall so the wind-down feels natural.
    func setActiveRows(_ intensities: [Int: Double]) {
        var clamped: [Int: CGFloat] = [:]
        for (k, v) in intensities {
            clamped[k] = CGFloat(max(0, min(1, v)))
        }
        activeRows = clamped
        ensureTimerRunning()
    }

    /// Stop the animation cleanly and drop all particles. Call when the
    /// overlay's host window closes or the table is rebuilt.
    func reset() {
        activeRows.removeAll()
        particles.removeAll()
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    private func ensureTimerRunning() {
        if timer != nil { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` so the animation keeps running while the user is
        // scrolling the table or tracking a menu — otherwise particles
        // would freeze the instant a mouse is held down.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One animation tick: advance particles, spawn new ones for active
    /// rows, garbage-collect dead ones, request repaint. Auto-stops the
    /// timer when there's nothing to animate.
    private func tick() {
        spawnTick &+= 1

        // Advance + filter existing particles
        var didAdvance = false
        for (row, list) in particles {
            var nextList: [Particle] = []
            nextList.reserveCapacity(list.count)
            for var p in list {
                p.y += p.speed
                p.age += 0.022
                if p.age < 1.0 {
                    nextList.append(p)
                    didAdvance = true
                }
            }
            if nextList.isEmpty {
                particles.removeValue(forKey: row)
            } else {
                particles[row] = nextList
            }
        }

        // Spawn new ones. Higher intensity → faster cadence. At intensity
        // 1.0 we attempt a spawn every 4 ticks (~7/sec); at 0.1 every 40
        // ticks (~0.75/sec). Below 0.05 intensity rows stop spawning.
        for (row, intensity) in activeRows where intensity >= 0.05 {
            let interval = max(4, Int(40.0 - 36.0 * intensity))
            if spawnTick % interval == 0 {
                let p = Particle(
                    y: 0,
                    age: 0,
                    x: CGFloat.random(in: 0...4),
                    speed: CGFloat.random(in: 0.8...1.4)
                )
                particles[row, default: []].append(p)
                if (particles[row]?.count ?? 0) > 12 {
                    particles[row]?.removeFirst()
                }
            }
        }

        if didAdvance || !particles.isEmpty {
            needsDisplay = true
        }

        // Park the timer if there's no animation left to drive — the
        // window controller will start it again on the next setActiveRows.
        if particles.isEmpty && activeRows.values.allSatisfy({ $0 < 0.05 }) {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView, !particles.isEmpty else { return }

        let bandX: CGFloat = 4    // 4pt strip on the left edge
        let bandWidth: CGFloat = 6

        for (row, list) in particles {
            let rowRect = table.rect(ofRow: row)
            guard rowRect.height > 0 else { continue }
            let topY = rowRect.minY
            let rowHeight = rowRect.height

            for p in list {
                let py = topY + p.y
                guard py <= rowRect.maxY else { continue }
                // Alpha eases in at the top, holds, then fades into the
                // bottom third so the dot looks like it's dropping out of
                // the row rather than getting clipped.
                let fadeIn  = min(1.0, p.y / 4.0)
                let fadeOut = 1.0 - max(0, (p.y - rowHeight * 0.55) / (rowHeight * 0.45))
                let alpha = max(0, min(fadeIn, fadeOut)) * 0.55

                let color = AppColors.accentODGlow.withAlphaComponent(alpha)
                color.setFill()
                let dotRect = NSRect(x: bandX + p.x, y: py - 1,
                                     width: bandWidth - 2, height: 2)
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }
}
