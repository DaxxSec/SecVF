//
//  VMConfigurationBackwardCompatTests.swift
//  SecVFTests
//
//  Tests for the parts of VMConfiguration that defend against bad data
//  on disk: the custom decoder's "missing networkConfig" fallback (so
//  metadata.json files written before the network-mode work still
//  load) and the CPU/memory clamps that guarantee any decoded config
//  is bootable through Apple's Virtualization framework.
//
//  These are quiet invariants — a regression here only surfaces when
//  a user's library has an old or hand-edited bundle, at which point
//  it manifests as a VM that refuses to start with a generic "config
//  validation failed" error. Pinning them in tests keeps the failure
//  mode loud and local.
//

import XCTest
import Virtualization
@testable import SecVF

final class VMConfigurationBackwardCompatTests: XCTestCase {

    // MARK: - Decoder backward compatibility

    func testDecoderAcceptsMetadataMissingNetworkConfig() throws {
        // Old metadata.json files predating the network-mode work
        // didn't have a `networkConfig` field. The decoder must fall
        // back to a default VirtualNetworkConfig rather than throwing.
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "name": "Legacy VM",
            "bundlePath": "/tmp/Legacy.bundle/",
            "cpuCount": 2,
            "memorySize": 4294967296,
            "diskSize": 21474836480,
            "createdDate": 0,
            "osType": "Linux"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(VMConfiguration.self, from: json)

        XCTAssertEqual(config.name, "Legacy VM")
        XCTAssertEqual(config.networkConfig.mode, .nat,
                       "Missing networkConfig must fall back to a default (.nat)")
        XCTAssertNil(config.networkConfig.routerVMId)
        XCTAssertFalse(config.networkConfig.isRouter)
    }

    func testDecoderForcesStatusToStoppedEvenIfPersistedJunkExists() throws {
        // `status` is intentionally not in CodingKeys, but a hand-
        // edited file could include it. The decoder must hard-set
        // status = .stopped — running VM windows are runtime state.
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "name": "VM",
            "bundlePath": "/tmp/X.bundle/",
            "cpuCount": 2,
            "memorySize": 4294967296,
            "diskSize": 21474836480,
            "createdDate": 0,
            "osType": "Linux",
            "status": "running"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(VMConfiguration.self, from: json)

        XCTAssertEqual(config.status, .stopped,
                       "Decoder must always set status to .stopped — runtime state never persists")
    }

    func testDecoderClampsHandEditedZeroCPUCount() throws {
        // metadata.json with `cpuCount: 0` would otherwise pass decode
        // and only fail at VM-start with a generic error. The decoder
        // clamps it to VZ's minimum so the user gets a deterministic
        // boot.
        let id = UUID().uuidString
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let json = """
        {
            "id": "\(id)",
            "name": "Junk VM",
            "bundlePath": "/tmp/X.bundle/",
            "cpuCount": 0,
            "memorySize": 4294967296,
            "diskSize": 21474836480,
            "createdDate": 0,
            "osType": "Linux"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(VMConfiguration.self, from: json)

        XCTAssertGreaterThanOrEqual(config.cpuCount, minCPU,
                                    "Decoder must clamp cpuCount up to VZ's minimum")
    }

    func testDecoderClampsHandEditedSingleByteMemory() throws {
        // memorySize=1 (one byte) would fail VZ validation. Clamp to
        // the framework's minimum.
        let id = UUID().uuidString
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let json = """
        {
            "id": "\(id)",
            "name": "Junk VM",
            "bundlePath": "/tmp/X.bundle/",
            "cpuCount": 2,
            "memorySize": 1,
            "diskSize": 21474836480,
            "createdDate": 0,
            "osType": "Linux"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(VMConfiguration.self, from: json)

        XCTAssertGreaterThanOrEqual(config.memorySize, minMem,
                                    "Decoder must clamp memorySize up to VZ's minimum")
    }

    // MARK: - clampCPU / clampMemory direct contract

    func testClampCPUClampsAboveMaximum() {
        let hi = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let oversized = hi + 100
        let clamped = VMConfiguration.clampCPU(oversized)
        XCTAssertLessThanOrEqual(clamped, hi,
                                 "CPU count above max must be clamped down to VZ's max")
    }

    func testClampCPUClampsBelowMinimum() {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        XCTAssertEqual(VMConfiguration.clampCPU(0), lo)
        XCTAssertEqual(VMConfiguration.clampCPU(-5), lo)
    }

    func testClampCPULeavesValidValuesAlone() {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let hi = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let middle = (lo + hi) / 2
        XCTAssertEqual(VMConfiguration.clampCPU(middle), middle)
        XCTAssertEqual(VMConfiguration.clampCPU(lo), lo)
        XCTAssertEqual(VMConfiguration.clampCPU(hi), hi)
    }

    func testClampMemoryClampsAboveMaximum() {
        let hi = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        // UInt64.max would obviously overflow VZ — verify clamp.
        let clamped = VMConfiguration.clampMemory(UInt64.max)
        XCTAssertLessThanOrEqual(clamped, hi)
    }

    func testClampMemoryClampsBelowMinimum() {
        let lo = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        XCTAssertEqual(VMConfiguration.clampMemory(0), lo)
        XCTAssertEqual(VMConfiguration.clampMemory(1), lo)
    }

    // MARK: - Programmatic init also clamps

    func testProgrammaticInitClampsCPUTooLow() {
        let lo = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let vm = VMConfiguration(name: "X", bundlePath: "/tmp/X.bundle/", cpuCount: 0)
        XCTAssertGreaterThanOrEqual(vm.cpuCount, lo,
                                    "Programmatic init must clamp invalid CPU counts too")
    }

    func testProgrammaticInitClampsMemoryTooLow() {
        let lo = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let vm = VMConfiguration(name: "X", bundlePath: "/tmp/X.bundle/", memorySize: 1)
        XCTAssertGreaterThanOrEqual(vm.memorySize, lo,
                                    "Programmatic init must clamp invalid memory sizes too")
    }
}
