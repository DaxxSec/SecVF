//
//  SparklineViewTests.swift
//  SecVFTests
//
//  Unit tests for the per-VM traffic sparkline view added in the
//  tactical UI redesign (`feat/ui-tactical-redesign`).
//

import XCTest
@testable import SecVF

@MainActor
final class SparklineViewTests: XCTestCase {

    // MARK: - Initialization

    func testInitWithFrameStartsEmpty() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        XCTAssertEqual(view.samples, [])
        XCTAssertEqual(view.noiseFloor, 4096)
    }

    func testSamplesStoreValueAssigned() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        let values: [Double] = [1, 2, 3, 4, 5]
        view.samples = values
        XCTAssertEqual(view.samples, values)
    }

    func testStrokeColorIsMutable() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.strokeColor = AppColors.accentOrangeHot
        XCTAssertEqual(view.strokeColor, AppColors.accentOrangeHot)
    }

    // MARK: - draw() shouldn't crash on edge inputs
    //
    // SparklineView's draw() guards on `samples.count >= 2` and `height > 2`
    // — verify those guards keep us safe against the obvious degenerate
    // inputs. We use `cacheDisplay(in:to:)` to force a draw cycle into a
    // bitmap so the path actually runs.

    private func forceDraw(_ view: NSView) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep = bitmap {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
    }

    func testDrawWithZeroSamplesDoesNothing() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.samples = []
        forceDraw(view)   // must not crash
    }

    func testDrawWithSingleSampleDoesNothing() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.samples = [1000]
        forceDraw(view)
    }

    func testDrawWithFlatSamples() {
        // All-zero buffer is a common case: idle VM. Should noise-floor
        // to the bottom of the view, no crash.
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.samples = Array(repeating: 0, count: 30)
        forceDraw(view)
    }

    func testDrawWithVaryingSamples() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.samples = (0..<30).map { Double($0 * 1024) }
        forceDraw(view)
    }

    func testDrawWithTinyHeightDoesNothing() {
        // Below the `bounds.height > 2` guard.
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 1))
        view.samples = [10, 20, 30, 40]
        forceDraw(view)
    }

    // MARK: - noiseFloor

    func testNoiseFloorCanBeRaised() {
        let view = SparklineView(frame: NSRect(x: 0, y: 0, width: 80, height: 16))
        view.noiseFloor = 1_048_576   // 1 MiB/s
        XCTAssertEqual(view.noiseFloor, 1_048_576)
        view.samples = [1024, 2048, 4096]  // all well below the new floor
        forceDraw(view)  // line should hug the bottom, no crash
    }
}
