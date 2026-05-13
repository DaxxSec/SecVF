//
//  SidebarFilterTests.swift
//  SecVFTests
//
//  Tests for the three pure filter predicates that drive the
//  TacticalSidebarSection navigation: status / OS / network. These run
//  against `VMLibraryWindowController.matches…Filter` statics so the
//  test surface doesn't need the live window.
//

import XCTest
@testable import SecVF

@MainActor
final class SidebarFilterTests: XCTestCase {

    // MARK: - Status

    func testStatusFilterRunning() {
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.running, id: "running"))
        XCTAssertFalse(VMLibraryWindowController.matchesStatusFilter(.stopped, id: "running"))
        XCTAssertFalse(VMLibraryWindowController.matchesStatusFilter(.starting, id: "running"))
    }

    func testStatusFilterStopped() {
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.stopped, id: "stopped"))
        XCTAssertFalse(VMLibraryWindowController.matchesStatusFilter(.running, id: "stopped"))
    }

    func testStatusFilterPausedCoversTransitionStates() {
        // "Paused" in the sidebar covers both .starting and .stopping —
        // the framework's two transient states. Pure .stopped or
        // .running do NOT count.
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.starting, id: "paused"))
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.stopping, id: "paused"))
        XCTAssertFalse(VMLibraryWindowController.matchesStatusFilter(.running, id: "paused"))
        XCTAssertFalse(VMLibraryWindowController.matchesStatusFilter(.stopped, id: "paused"))
    }

    func testStatusFilterUnknownIDLetEverythingPass() {
        // Unknown id ("all" or anything else) means "no filter applied"
        // — the controller skips the predicate entirely, but defensive
        // check the static returns true so a callsite that DID call it
        // doesn't accidentally drop everything.
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.running, id: "all"))
        XCTAssertTrue(VMLibraryWindowController.matchesStatusFilter(.stopped, id: "garbage"))
    }

    // MARK: - OS

    func testOSFilterLinux() {
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("Linux", id: "linux"))
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("linux", id: "linux"))
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("Kali Linux", id: "linux"))
        XCTAssertFalse(VMLibraryWindowController.matchesOSFilter("macOS", id: "linux"))
        XCTAssertFalse(VMLibraryWindowController.matchesOSFilter("Windows", id: "linux"))
    }

    func testOSFilterMacOS() {
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("macOS", id: "macos"))
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("Apple Mac OS", id: "macos"))
        XCTAssertFalse(VMLibraryWindowController.matchesOSFilter("Linux", id: "macos"))
    }

    func testOSFilterWindows() {
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("Windows", id: "windows"))
        XCTAssertTrue(VMLibraryWindowController.matchesOSFilter("Windows 10", id: "windows"))
        XCTAssertFalse(VMLibraryWindowController.matchesOSFilter("Linux", id: "windows"))
    }

    // MARK: - Network

    func testNetworkFilterNAT() {
        let nat = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        let virt = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: false)
        XCTAssertTrue(VMLibraryWindowController.matchesNetworkFilter(nat, id: "nat"))
        XCTAssertFalse(VMLibraryWindowController.matchesNetworkFilter(virt, id: "nat"))
    }

    func testNetworkFilterVirtual() {
        let virt = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: false)
        let nat = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        XCTAssertTrue(VMLibraryWindowController.matchesNetworkFilter(virt, id: "virtual"))
        XCTAssertFalse(VMLibraryWindowController.matchesNetworkFilter(nat, id: "virtual"))
    }

    func testNetworkFilterIsolatedExcludesRoutersAndGuests() {
        // "Isolated" means virtual-mode WITHOUT a router relationship —
        // a guest pinned to a router doesn't count; a router doesn't
        // count; only a virtual-mode VM with no router connection at
        // all matches.
        let isolated = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: false)
        let router   = VirtualNetworkConfig(mode: .virtual, routerVMId: nil, isRouter: true)
        let guest    = VirtualNetworkConfig(mode: .virtual, routerVMId: UUID(), isRouter: false)
        let nat      = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)

        XCTAssertTrue(VMLibraryWindowController.matchesNetworkFilter(isolated, id: "isolated"))
        XCTAssertFalse(VMLibraryWindowController.matchesNetworkFilter(router, id: "isolated"))
        XCTAssertFalse(VMLibraryWindowController.matchesNetworkFilter(guest, id: "isolated"))
        XCTAssertFalse(VMLibraryWindowController.matchesNetworkFilter(nat, id: "isolated"))
    }

    func testNetworkFilterUnknownIDLetEverythingPass() {
        let cfg = VirtualNetworkConfig(mode: .nat, routerVMId: nil, isRouter: false)
        XCTAssertTrue(VMLibraryWindowController.matchesNetworkFilter(cfg, id: "all"))
        XCTAssertTrue(VMLibraryWindowController.matchesNetworkFilter(cfg, id: "garbage"))
    }
}
