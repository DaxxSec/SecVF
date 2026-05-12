//
//  DNCVMBridgeTests.swift
//  SecVFMCPCoreTests
//
//  TDD for DNCVMBridge — the bridge that closes the host_app_required
//  gap by posting DistributedNotificationCenter notifications to the
//  SecVF.app GUI process. Reads still go through the file-backed bridge;
//  mutating ops (start/stop/force-stop) post `com.secvf.cli.<action>`
//  notifications with userInfo {"vmName": ...} that SecVF.app's
//  AppDelegate is already listening for.
//
//  Tests use a MockNotificationPoster that records posted notifications
//  so we can assert the right name + userInfo without spinning up the
//  real DNC.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("DNCVMBridge")
struct DNCVMBridgeTests {

    // MARK: - reads still come from file-backed bridge

    @Test("listVMs delegates to the file-backed bridge")
    func listDelegatesToFile() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(
            avfRoot: root.path,
            poster: poster
        )
        let vms = await bridge.listVMs()
        #expect(vms.count == 1)
        #expect(vms.first?.name == "kali")
        // No notifications posted for a read.
        let posted = await poster.posted
        #expect(posted.isEmpty)
    }

    @Test("status delegates to the file-backed bridge")
    func statusDelegates() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let vm = await bridge.status(forVM: "kali")
        #expect(vm?.id == "uuid-1")
    }

    // MARK: - start posts com.secvf.cli.start with vmName

    @Test("start posts com.secvf.cli.start with vmName userInfo")
    func startPostsCorrectNotification() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.start(vmNamed: "kali")

        #expect(outcome.success == true)

        let posted = await poster.posted
        #expect(posted.count == 1)
        let p = posted.first!
        #expect(p.name == "com.secvf.cli.start")
        #expect(p.userInfo["vmName"] as? String == "kali")
        #expect(p.deliverImmediately == true)
    }

    @Test("start refuses unknown VM before posting")
    func startRefusesUnknownVM() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No bundles created.

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.start(vmNamed: "ghost")

        #expect(outcome.success == false)
        #expect(outcome.errorCode == "vm_not_found")
        // No notification posted for an unknown VM — protects against
        // an agent triggering an arbitrary userInfo payload to the GUI.
        let posted = await poster.posted
        #expect(posted.isEmpty)
    }

    // MARK: - stop posts com.secvf.cli.stop

    @Test("stop posts com.secvf.cli.stop with vmName userInfo")
    func stopPostsCorrectNotification() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.stop(vmNamed: "kali")

        #expect(outcome.success == true)
        let posted = await poster.posted
        #expect(posted.count == 1)
        #expect(posted.first?.name == "com.secvf.cli.stop")
        #expect(posted.first?.userInfo["vmName"] as? String == "kali")
    }

    @Test("stop refuses unknown VM")
    func stopRefusesUnknownVM() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.stop(vmNamed: "ghost")

        #expect(outcome.errorCode == "vm_not_found")
        let posted = await poster.posted
        #expect(posted.isEmpty)
    }

    // MARK: - success/error from poster surfaces

    @Test("poster failure surfaces as bridge error")
    func posterFailureSurfaces() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster(shouldFail: true)
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.start(vmNamed: "kali")

        #expect(outcome.success == false)
        #expect(outcome.errorCode == "host_app_post_failed")
    }

    // MARK: - response semantics
    //
    // DNC is fire-and-forget. The bridge can't synchronously confirm the
    // VM actually started. The returned BridgeOutcome.success means
    // "request was posted to the GUI app"; the agent should poll
    // secvf_vm_status to confirm the boot completed.

    @Test("start success is described as 'request posted'")
    func startSuccessIsRequestPosted() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, name: "kali", id: "uuid-1")

        let poster = MockNotificationPoster()
        let bridge = DNCVMBridge(avfRoot: root.path, poster: poster)
        let outcome = await bridge.start(vmNamed: "kali")
        // success but the error fields stay nil — the caller surfaces this
        // through structured handler output that includes a "note" field
        // telling the agent to poll for status.
        #expect(outcome.success == true)
        #expect(outcome.errorCode == nil)
    }

    // MARK: - helpers

    private func makeAVFRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dnc-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Linux"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("MacOS"),
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeBundle(at root: URL, name: String, id: String) throws {
        let bundle = root
            .appendingPathComponent("Linux")
            .appendingPathComponent("\(name).bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["id": id, "name": name]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: bundle.appendingPathComponent("metadata.json"))
    }
}

// MARK: - test double

actor MockNotificationPoster: NotificationPoster {
    struct PostedNotification: Sendable {
        let name: String
        // [String: Any] kept loose so tests can drop in arbitrary types
        // (matches the production interface).
        private let _userInfo: [String: Any]
        let deliverImmediately: Bool

        var userInfo: [String: Any] { _userInfo }

        init(name: String, userInfo: [String: Any], deliverImmediately: Bool) {
            self.name = name
            self._userInfo = userInfo
            self.deliverImmediately = deliverImmediately
        }
    }

    private(set) var posted: [PostedNotification] = []
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func post(
        name: String,
        userInfo: [String: Any],
        deliverImmediately: Bool
    ) async -> Bool {
        if shouldFail { return false }
        posted.append(PostedNotification(
            name: name,
            userInfo: userInfo,
            deliverImmediately: deliverImmediately
        ))
        return true
    }
}
