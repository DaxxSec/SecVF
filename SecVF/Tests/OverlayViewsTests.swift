//
//  OverlayViewsTests.swift
//  SecVFTests
//
//  Property-level tests for the two transparent NSView overlays that
//  sit on top of the VM table:
//   - VMConnectionOverlayView: bracket connectors between rows of
//     running peers (router + guests)
//   - VMTrafficFallOverlayView: decorative falling-packet cascade
//     keyed off per-row activity intensities
//
//  Drawing requires a live CGContext (skipped — covered visually in
//  the running app). These tests pin the public property surface +
//  shared invariants (hitTest pass-through, isFlipped mirror, layer
//  setup, idempotent reset).
//

import XCTest
@testable import SecVF

@MainActor
final class OverlayViewsTests: XCTestCase {

    // MARK: - VMConnectionOverlayView

    func testConnectionOverlayStartsWithNoConnections() {
        let view = VMConnectionOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertTrue(view.connections.isEmpty)
    }

    func testConnectionOverlayHitTestAlwaysReturnsNil() {
        // Mouse events MUST pass through to the table — overlay must
        // never steal clicks / selection / double-click handling.
        let view = VMConnectionOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 300)))
        XCTAssertNil(view.hitTest(.zero))
    }

    func testConnectionOverlayAcceptsConnectionAssignment() {
        // didSet sets needsDisplay = true, but NSView short-circuits
        // that property to `false` when the view isn't in a window —
        // so we can't directly observe the dirty flag here. Just pin
        // the property's storage contract: the assignment round-trips.
        let view = VMConnectionOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        let pairs: [(fromRow: Int, toRow: Int)] = [(0, 2), (1, 3)]
        view.connections = pairs
        XCTAssertEqual(view.connections.count, 2)
        XCTAssertEqual(view.connections.first?.fromRow, 0)
        XCTAssertEqual(view.connections.first?.toRow, 2)
    }

    func testConnectionOverlayIsFlippedMirrorsHostTable() {
        let view = VMConnectionOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        let table = NSTableView()
        view.tableView = table
        XCTAssertEqual(view.isFlipped, table.isFlipped,
                       "Overlay coords must match the host table's flip orientation")
    }

    func testConnectionOverlayWantsLayerForTransparentBackground() {
        let view = VMConnectionOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertTrue(view.wantsLayer)
        XCTAssertNotNil(view.layer)
        // Background must be clear so the table cells underneath remain
        // visible — opaque background would mask the row data.
        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    // MARK: - VMTrafficFallOverlayView

    func testTrafficFallOverlayHitTestAlwaysReturnsNil() {
        let view = VMTrafficFallOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
    }

    func testTrafficFallOverlayWantsLayerForTransparentBackground() {
        let view = VMTrafficFallOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertTrue(view.wantsLayer)
        XCTAssertEqual(view.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    func testTrafficFallOverlaySetActiveRowsAcceptsEmpty() {
        let view = VMTrafficFallOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.setActiveRows([:])     // survival is the test
        view.reset()
    }

    func testTrafficFallOverlayResetDoesNotCrashOnFreshView() {
        let view = VMTrafficFallOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.reset()   // idempotent — must be safe even with no active timer
        view.reset()
    }

    func testTrafficFallOverlaySetActiveRowsClampsIntensityAboveOne() {
        // setActiveRows clamps intensities to 0...1 internally. We can't
        // observe the clamped dict directly (it's private), but the
        // method must not crash on out-of-range input — the clamp is
        // the safety net.
        let view = VMTrafficFallOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.setActiveRows([0: 100.0, 1: -50.0, 2: 0.5])   // survival is the test
        view.reset()
    }
}
