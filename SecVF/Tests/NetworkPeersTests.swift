//
//  NetworkPeersTests.swift
//  SecVFTests
//
//  Tests for `VMManager.networkPeers(of:in:)` — the pure-logic helper
//  that decides which VMs share a virtual-switch network group with a
//  given VM. The library window draws connector brackets between
//  running peers; these tests pin the rules so a future refactor of
//  the connection-indicator overlay can't accidentally re-route them.
//
//  Rules under test:
//    - NAT-mode VMs have no peers (they don't share an L2 network).
//    - Virtual-mode VM with no router assignment yet has no peers.
//    - A router VM's peers are the guests routing through it.
//    - A guest VM's peers are the router + sibling guests sharing it.
//    - The subject VM is never in its own peer list.
//    - Mixed NAT/virtual lists return only the virtual-mode matches.
//

import XCTest
@testable import SecVF

final class NetworkPeersTests: XCTestCase {

    // MARK: - Helpers

    private func makeVM(name: String,
                        mode: NetworkMode = .virtual,
                        isRouter: Bool = false,
                        routerVMId: UUID? = nil) -> VMConfiguration {
        var vm = VMConfiguration(name: name, bundlePath: "/tmp/\(name).bundle")
        vm.networkConfig = VirtualNetworkConfig(
            mode: mode,
            routerVMId: routerVMId,
            isRouter: isRouter
        )
        return vm
    }

    // MARK: - NAT mode

    func testNATModeVMHasNoPeers() {
        let nat = makeVM(name: "NAT-A", mode: .nat)
        let other = makeVM(name: "NAT-B", mode: .nat)
        let peers = VMManager.networkPeers(of: nat, in: [nat, other])
        XCTAssertEqual(peers.count, 0)
    }

    // MARK: - Virtual mode, unconfigured

    func testVirtualVMWithNoRouterAndNotRouterHasNoPeers() {
        let lonely = makeVM(name: "lonely")    // mode .virtual, no router, not a router
        XCTAssertEqual(VMManager.networkPeers(of: lonely, in: [lonely]).count, 0)
    }

    // MARK: - Router → guests

    func testRouterReturnsAllGuestsRoutingThroughIt() {
        let router = makeVM(name: "kali", isRouter: true)
        let g1 = makeVM(name: "guest1", routerVMId: router.id)
        let g2 = makeVM(name: "guest2", routerVMId: router.id)
        let stranger = makeVM(name: "stranger")   // no router assigned

        let peers = VMManager.networkPeers(of: router, in: [router, g1, g2, stranger])
        XCTAssertEqual(peers.count, 2)
        XCTAssertTrue(peers.contains { $0.id == g1.id })
        XCTAssertTrue(peers.contains { $0.id == g2.id })
        XCTAssertFalse(peers.contains { $0.id == stranger.id })
        XCTAssertFalse(peers.contains { $0.id == router.id },
                       "Subject VM must never appear in its own peer list")
    }

    // MARK: - Guest → router + siblings

    func testGuestReturnsRouterAndSiblings() {
        let router = makeVM(name: "kali", isRouter: true)
        let g1 = makeVM(name: "guest1", routerVMId: router.id)
        let g2 = makeVM(name: "guest2", routerVMId: router.id)
        let g3 = makeVM(name: "guest3", routerVMId: router.id)

        let peers = VMManager.networkPeers(of: g2, in: [router, g1, g2, g3])
        XCTAssertEqual(peers.count, 3, "g2's peers: router + g1 + g3")
        XCTAssertTrue(peers.contains { $0.id == router.id })
        XCTAssertTrue(peers.contains { $0.id == g1.id })
        XCTAssertTrue(peers.contains { $0.id == g3.id })
        XCTAssertFalse(peers.contains { $0.id == g2.id })
    }

    // MARK: - Mixed router groups don't bleed

    func testGuestPeersDoNotIncludeGuestsOfOtherRouters() {
        let routerA = makeVM(name: "kaliA", isRouter: true)
        let routerB = makeVM(name: "kaliB", isRouter: true)
        let g1A = makeVM(name: "g1A", routerVMId: routerA.id)
        let g1B = makeVM(name: "g1B", routerVMId: routerB.id)

        let peersOfg1A = VMManager.networkPeers(of: g1A, in: [routerA, routerB, g1A, g1B])
        XCTAssertEqual(peersOfg1A.count, 1)
        XCTAssertEqual(peersOfg1A.first?.id, routerA.id)
        XCTAssertFalse(peersOfg1A.contains { $0.id == g1B.id })
        XCTAssertFalse(peersOfg1A.contains { $0.id == routerB.id })
    }

    // MARK: - Mode mixing

    func testNATPeersAreFilteredOutEvenWhenSharingRouterID() {
        let router = makeVM(name: "kali", isRouter: true)
        let virtualGuest = makeVM(name: "virtGuest", routerVMId: router.id)
        // A NAT-mode VM that *would* match if mode wasn't checked
        var natWithStaleRouter = makeVM(name: "natGuest", routerVMId: router.id)
        natWithStaleRouter.networkConfig.mode = .nat

        let peers = VMManager.networkPeers(
            of: router,
            in: [router, virtualGuest, natWithStaleRouter]
        )
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.id, virtualGuest.id)
    }
}
