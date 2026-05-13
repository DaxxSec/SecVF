//
//  BridgeInterfaceStatsTests.swift
//  SecVFTests
//
//  Unit tests for the NAT-bridge byte-counter reader added in the
//  tactical UI redesign. The system `getifaddrs()` call itself is
//  outside our control — these tests focus on the deterministic
//  parts: rate computation, wraparound defense, and empty-sample
//  handling.
//

import XCTest
@testable import SecVF

final class BridgeInterfaceStatsTests: XCTestCase {

    // MARK: - rate(from:to:) — basic delta

    func testRateComputesDeltaPerSecond() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 2)   // 2 s later
        let s0 = BridgeSample(bytesIn: 1000, bytesOut: 500, interfaceName: "vmenet0", ts: t0)
        let s1 = BridgeSample(bytesIn: 3000, bytesOut: 1500, interfaceName: "vmenet0", ts: t1)

        let r = BridgeInterfaceStats.rate(from: s0, to: s1)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.down ?? 0, 1000, accuracy: 0.001)   // 2000 bytes / 2s
        XCTAssertEqual(r?.up   ?? 0, 500,  accuracy: 0.001)   // 1000 bytes / 2s
    }

    func testRateZeroDeltaReturnsZero() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = Date(timeIntervalSinceReferenceDate: 1)
        let s0 = BridgeSample(bytesIn: 5000, bytesOut: 5000, interfaceName: "vmenet0", ts: t0)
        let s1 = BridgeSample(bytesIn: 5000, bytesOut: 5000, interfaceName: "vmenet0", ts: t1)

        let r = BridgeInterfaceStats.rate(from: s0, to: s1)
        XCTAssertEqual(r?.down ?? -1, 0)
        XCTAssertEqual(r?.up   ?? -1, 0)
    }

    // MARK: - rate(from:to:) — defense paths

    func testRateNilWhenPreviousMissing() {
        let s1 = BridgeSample(bytesIn: 100, bytesOut: 50, interfaceName: nil, ts: Date())
        XCTAssertNil(BridgeInterfaceStats.rate(from: nil, to: s1))
    }

    func testRateNilWhenCurrentMissing() {
        let s0 = BridgeSample(bytesIn: 100, bytesOut: 50, interfaceName: nil, ts: Date())
        XCTAssertNil(BridgeInterfaceStats.rate(from: s0, to: nil))
    }

    func testRateNilForSubMillisecondDelta() {
        // Avoid division blow-up + nonsensical "infinite" rates when the
        // sampling timer fires faster than expected.
        let t0 = Date()
        let s0 = BridgeSample(bytesIn: 100, bytesOut: 50, interfaceName: "vmenet0", ts: t0)
        let s1 = BridgeSample(bytesIn: 200, bytesOut: 100, interfaceName: "vmenet0",
                              ts: t0.addingTimeInterval(0.0005))
        XCTAssertNil(BridgeInterfaceStats.rate(from: s0, to: s1))
    }

    func testRateClampsCounterRegression() {
        // If kernel counters reset (interface re-created during a session)
        // the delta would go negative. Should clamp to zero, not produce
        // a huge negative rate that crashes the formatter cast.
        let t0 = Date()
        let s0 = BridgeSample(bytesIn: 10_000, bytesOut: 8_000, interfaceName: "vmenet0", ts: t0)
        let s1 = BridgeSample(bytesIn: 100,    bytesOut: 50,    interfaceName: "vmenet0",
                              ts: t0.addingTimeInterval(1))

        let r = BridgeInterfaceStats.rate(from: s0, to: s1)
        XCTAssertEqual(r?.down ?? -1, 0)
        XCTAssertEqual(r?.up   ?? -1, 0)
    }

    // MARK: - sample()
    //
    // `sample()` exercises real `getifaddrs()` so the result depends on
    // the host's network configuration. We can only assert it doesn't
    // crash + that the return shape is internally consistent.

    func testSampleDoesNotCrash() {
        _ = BridgeInterfaceStats.sample()   // any return is fine
    }

    func testSampleResultIsInternallyConsistent() {
        guard let s = BridgeInterfaceStats.sample() else {
            // No bridge interface present (CI / dev box with no VMs ever
            // booted). Nothing to assert beyond "the call returned cleanly".
            return
        }
        XCTAssertGreaterThanOrEqual(s.bytesIn,  0)
        XCTAssertGreaterThanOrEqual(s.bytesOut, 0)
        XCTAssertLessThanOrEqual(s.ts.timeIntervalSinceNow, 0,
                                 "sample timestamp must not be in the future")
    }
}
