//
//  VMCardCellAndCycleTests.swift
//  SecVFTests
//
//  Tests for the multi-line VM card cell and the network-mode cycle.
//  Cycle logic is the priority — the cell view tests just verify the
//  card's public configuration surface (full UI rendering is covered
//  visually).
//

import XCTest
@testable import SecVF

@MainActor
final class VMCardCellAndCycleTests: XCTestCase {

    // MARK: - Network-mode cycle (pure logic)

    func testCycleNATGoesToVirtualIsolated() {
        let nat = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        let next = VMManager.nextNetworkConfig(after: nat)
        XCTAssertEqual(next.mode, .virtual)
        XCTAssertFalse(next.isRouter)
        XCTAssertNil(next.routerVMId)
    }

    func testCycleVirtualIsolatedGoesToRouter() {
        let virt = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: false)
        let next = VMManager.nextNetworkConfig(after: virt)
        XCTAssertEqual(next.mode, .virtual)
        XCTAssertTrue(next.isRouter)
        XCTAssertNil(next.routerVMId)
    }

    func testCycleRouterGoesToNAT() {
        let router = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: true)
        let next = VMManager.nextNetworkConfig(after: router)
        XCTAssertEqual(next.mode, .nat)
        XCTAssertFalse(next.isRouter)
        XCTAssertNil(next.routerVMId)
    }

    func testCycleVirtualGuestDropsToNATCleanly() {
        // A virtual-mode VM with a routerVMId set (guest of someone)
        // shouldn't drag its stale guest-of relationship through the
        // cycle. The cycle drops it to NAT and clears the routerVMId.
        let guest = VirtualNetworkConfig(mode: .virtual,
                                         routerVMId: UUID(),
                                         isRouter: false)
        let next = VMManager.nextNetworkConfig(after: guest)
        XCTAssertEqual(next.mode, .nat)
        XCTAssertNil(next.routerVMId)
        XCTAssertFalse(next.isRouter)
    }

    func testCycleIsCircular() {
        // Four cycles from NAT returns to NAT-equivalent state. Note:
        // a guest VM short-circuits to NAT in one step, so this test
        // walks the canonical NAT → Virtual → Router → NAT path.
        var cfg = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        let initial = cfg
        cfg = VMManager.nextNetworkConfig(after: cfg)   // → Virtual
        cfg = VMManager.nextNetworkConfig(after: cfg)   // → Router
        cfg = VMManager.nextNetworkConfig(after: cfg)   // → NAT
        XCTAssertEqual(cfg.mode, initial.mode)
        XCTAssertEqual(cfg.isRouter, initial.isRouter)
        XCTAssertEqual(cfg.routerVMId, initial.routerVMId)
    }

    // MARK: - Network chip rendering

    func testNetworkChipShowsNATForNATMode() {
        let cfg = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        let (text, _) = VMCardCellView.networkChipSpec(for: cfg)
        XCTAssertTrue(text.contains("NAT"),
                      "NAT chip must mention NAT in its label, got: \(text)")
    }

    func testNetworkChipShowsRouterForRouterMode() {
        let cfg = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: true)
        let (text, _) = VMCardCellView.networkChipSpec(for: cfg)
        XCTAssertTrue(text.uppercased().contains("ROUTER"),
                      "Router chip must mention ROUTER, got: \(text)")
    }

    func testNetworkChipShowsGuestForGuestMode() {
        let cfg = VirtualNetworkConfig(mode: .virtual,
                                       routerVMId: UUID(),
                                       isRouter: false)
        let (text, _) = VMCardCellView.networkChipSpec(for: cfg)
        XCTAssertTrue(text.uppercased().contains("GUEST"),
                      "Guest chip must mention GUEST, got: \(text)")
    }

    func testNetworkChipShowsIsolatedForVirtualNoRouter() {
        let cfg = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: false)
        let (text, _) = VMCardCellView.networkChipSpec(for: cfg)
        XCTAssertTrue(text.uppercased().contains("ISOLATED"),
                      "Isolated chip must mention ISOLATED, got: \(text)")
    }

    // MARK: - Status pill spec

    func testStatusPillTextMatchesEachStatus() {
        let cases: [(VMStatus, String)] = [
            (.running,  "RUNNING"),
            (.starting, "STARTING"),
            (.stopping, "STOPPING"),
            (.stopped,  "STOPPED"),
        ]
        for (status, expected) in cases {
            let (_, text, _) = VMCardCellView.statusPillSpec(for: status)
            XCTAssertEqual(text, expected,
                           "Status \(status) should pill-render as \(expected), got \(text)")
        }
    }

    // MARK: - Formatters

    func testFormatPacketCountUsesGroupingSeparator() {
        XCTAssertEqual(VMCardCellView.formatPacketCount(0),        "0")
        XCTAssertEqual(VMCardCellView.formatPacketCount(42),       "42")
        XCTAssertEqual(VMCardCellView.formatPacketCount(1_234),    "1,234")
        XCTAssertEqual(VMCardCellView.formatPacketCount(1_234_567),"1,234,567")
    }

    func testFormatBpsCrossesUnitThresholds() {
        XCTAssertTrue(VMCardCellView.formatBps(500).contains("B/s"),
                      "Sub-kB rates show as raw B/s")
        XCTAssertTrue(VMCardCellView.formatBps(2_048).contains("kB/s"),
                      "2 kB ≥ 1024 should render as kB/s")
        XCTAssertTrue(VMCardCellView.formatBps(5_000_000).contains("MB/s"),
                      "5 MB ≥ 1 MB should render as MB/s")
        XCTAssertTrue(VMCardCellView.formatBps(3_000_000_000).contains("GB/s"),
                      "3 GB ≥ 1 GB should render as GB/s")
    }

    // MARK: - Cell construction sanity

    func testVMCardCellInitialFrameIsRowHeight() {
        let cell = VMCardCellView(frame: NSRect(x: 0, y: 0, width: 400,
                                                height: VMCardCellView.rowHeight))
        XCTAssertEqual(cell.frame.height, VMCardCellView.rowHeight)
        XCTAssertEqual(cell.identifier, VMCardCellView.identifier)
    }

    func testVMCardCellConfigureSurvivesAllStatuses() {
        // Survival-only — fully painting the cell requires a graphics
        // context that we don't have in a unit test. Verifying the
        // configure() method doesn't crash for any status keeps the
        // happy-path bound for table reload integrity.
        let cell = VMCardCellView(frame: NSRect(x: 0, y: 0, width: 400,
                                                height: VMCardCellView.rowHeight))
        var vm = VMConfiguration(name: "X", bundlePath: "/tmp/X.bundle/")
        for status in [VMStatus.running, .starting, .stopping, .stopped] {
            vm.status = status
            cell.configure(with: vm,
                           liveDownBps: 100.0,
                           liveUpBps: 50.0,
                           trafficSamples: [1, 2, 3],
                           packetCount: 42)
        }
    }
}
