//
//  DNCCaptureBridgeTests.swift
//  SecVFMCPCoreTests
//
//  TDD for DNCCaptureBridge — mirrors DNCVMBridge for the packet capture
//  pipeline. start/stop post com.secvf.cli.capture-start /
//  capture-stop notifications that SecVF.app's AppDelegate listens for;
//  status() returns "not addressable from MCP" placeholder until we
//  add a query-back DNC channel (out of scope here).
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("DNCCaptureBridge")
struct DNCCaptureBridgeTests {

    @Test("start posts com.secvf.cli.capture-start")
    func startPosts() async throws {
        let poster = MockNotificationPoster()
        let bridge = DNCCaptureBridge(poster: poster)
        let outcome = await bridge.start(
            vm: nil,
            bpfFilter: nil,
            pcapPath: nil
        )
        #expect(outcome.success == true)
        let posted = await poster.posted
        #expect(posted.count == 1)
        #expect(posted.first?.name == "com.secvf.cli.capture-start")
        #expect(posted.first?.deliverImmediately == true)
    }

    @Test("start forwards bpf_filter and pcap_path through userInfo")
    func startForwardsParams() async throws {
        let poster = MockNotificationPoster()
        let bridge = DNCCaptureBridge(poster: poster)
        _ = await bridge.start(
            vm: "kali",
            bpfFilter: "tcp port 443",
            pcapPath: "/tmp/out.pcap"
        )
        let posted = await poster.posted
        let info = posted.first?.userInfo ?? [:]
        #expect(info["vmName"] as? String == "kali")
        #expect(info["bpfFilter"] as? String == "tcp port 443")
        #expect(info["pcapPath"] as? String == "/tmp/out.pcap")
    }

    @Test("start omits absent userInfo keys")
    func startOmitsAbsentKeys() async throws {
        let poster = MockNotificationPoster()
        let bridge = DNCCaptureBridge(poster: poster)
        _ = await bridge.start(vm: nil, bpfFilter: nil, pcapPath: nil)
        let info = await poster.posted.first?.userInfo ?? [:]
        // No vmName / bpfFilter / pcapPath keys should be present when caller
        // passed nil — avoids forging values the GUI handler would parse.
        #expect(info["vmName"] == nil)
        #expect(info["bpfFilter"] == nil)
        #expect(info["pcapPath"] == nil)
    }

    @Test("stop posts com.secvf.cli.capture-stop with empty userInfo")
    func stopPosts() async throws {
        let poster = MockNotificationPoster()
        let bridge = DNCCaptureBridge(poster: poster)
        let outcome = await bridge.stop()
        #expect(outcome.success == true)
        let posted = await poster.posted
        #expect(posted.count == 1)
        #expect(posted.first?.name == "com.secvf.cli.capture-stop")
        #expect(posted.first?.userInfo.isEmpty == true)
    }

    @Test("poster failure surfaces as host_app_post_failed")
    func posterFailureSurfaces() async throws {
        let poster = MockNotificationPoster(shouldFail: true)
        let bridge = DNCCaptureBridge(poster: poster)
        let outcome = await bridge.start(vm: nil, bpfFilter: nil, pcapPath: nil)
        #expect(outcome.success == false)
        #expect(outcome.errorCode == "host_app_post_failed")
    }

    @Test("status returns the fire-and-forget placeholder")
    func statusReturnsPlaceholder() async throws {
        let poster = MockNotificationPoster()
        let bridge = DNCCaptureBridge(poster: poster)
        // No DNC query path yet for capture state — the bridge has to
        // return SOMETHING for status. We document the semantics: running
        // = false, packetsCaptured = 0, with a note that real status
        // requires a future query-back DNC channel.
        let s = await bridge.status()
        #expect(s.running == false)
        #expect(s.packetsCaptured == 0)
    }
}
