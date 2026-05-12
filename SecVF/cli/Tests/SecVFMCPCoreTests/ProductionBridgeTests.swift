//
//  ProductionBridgeTests.swift
//  SecVFMCPCoreTests
//
//  TDD for the file-backed production bridges. These conform to the
//  VMBridge / SwitchBridge / CaptureBridge protocols by reading from
//  the on-disk SecVF state under ~/.avf (or a configurable root for
//  tests).
//
//  Read paths (list / status / iso list) are implemented here.
//  Mutating paths (start / stop) return a structured "host_app_required"
//  error pointing to the DistributedNotificationCenter bridge — only
//  the SecVF GUI app can actually drive VZ lifecycle, and that wiring
//  lives in main.swift via DNC, not in the bridges themselves.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("ProductionBridges")
struct ProductionBridgeTests {

    // MARK: - VM list / status

    @Test("FileBackedVMBridge discovers Linux + macOS bundles")
    func discoversBundles() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeBundle(at: root, osDir: "Linux", name: "kali",
                       metadata: ["id": "uuid-1", "name": "kali", "osType": "Linux"])
        try makeBundle(at: root, osDir: "MacOS", name: "macOS-sandbox",
                       metadata: ["id": "uuid-2", "name": "macOS-sandbox", "osType": "macOS"])

        let bridge = FileBackedVMBridge(avfRoot: root.path)
        let vms = await bridge.listVMs()

        let names = vms.map(\.name).sorted()
        #expect(names == ["kali", "macOS-sandbox"])
        let kali = vms.first(where: { $0.name == "kali" })
        #expect(kali?.osType == "Linux")
        #expect(kali?.id == "uuid-1")
    }

    @Test("FileBackedVMBridge skips non-bundle entries in the dir")
    func skipsNonBundleEntries() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Make a legitimate bundle + some noise that shouldn't be picked up.
        try makeBundle(at: root, osDir: "Linux", name: "kali",
                       metadata: ["id": "1", "name": "kali"])
        // Random file in Linux/
        let stray = root.appendingPathComponent("Linux/random.txt")
        try "hello".write(to: stray, atomically: true, encoding: .utf8)
        // Directory that's NOT a .bundle
        let weirdDir = root.appendingPathComponent("Linux/oops")
        try FileManager.default.createDirectory(at: weirdDir, withIntermediateDirectories: true)

        let bridge = FileBackedVMBridge(avfRoot: root.path)
        let vms = await bridge.listVMs()
        #expect(vms.count == 1)
        #expect(vms.first?.name == "kali")
    }

    @Test("FileBackedVMBridge.status returns the right VM")
    func statusReturnsRightVM() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeBundle(at: root, osDir: "Linux", name: "kali",
                       metadata: ["id": "abc", "name": "kali"])

        let bridge = FileBackedVMBridge(avfRoot: root.path)
        let result = await bridge.status(forVM: "kali")
        #expect(result?.id == "abc")
        #expect(result?.name == "kali")

        let missing = await bridge.status(forVM: "ghost")
        #expect(missing == nil)
    }

    @Test("FileBackedVMBridge handles missing root gracefully")
    func handlesMissingRoot() async throws {
        let bridge = FileBackedVMBridge(avfRoot: "/tmp/does-not-exist-\(UUID().uuidString)")
        let vms = await bridge.listVMs()
        #expect(vms.isEmpty)
    }

    @Test("FileBackedVMBridge.start returns host_app_required error")
    func startReturnsHostAppRequired() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(at: root, osDir: "Linux", name: "kali",
                       metadata: ["id": "1", "name": "kali"])

        let bridge = FileBackedVMBridge(avfRoot: root.path)
        let outcome = await bridge.start(vmNamed: "kali")
        #expect(outcome.success == false)
        #expect(outcome.errorCode == "host_app_required")
    }

    @Test("FileBackedVMBridge.start to unknown VM returns vm_not_found before host_app_required")
    func startUnknownVMReturnsNotFound() async throws {
        let root = try makeAVFRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = FileBackedVMBridge(avfRoot: root.path)
        let outcome = await bridge.start(vmNamed: "ghost")
        #expect(outcome.errorCode == "vm_not_found")
    }

    // MARK: - helpers

    private func makeAVFRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("avf-test-\(UUID().uuidString)")
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

    private func makeBundle(
        at root: URL,
        osDir: String,
        name: String,
        metadata: [String: Any]
    ) throws {
        let bundle = root
            .appendingPathComponent(osDir)
            .appendingPathComponent("\(name).bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: bundle.appendingPathComponent("metadata.json"))
    }
}
