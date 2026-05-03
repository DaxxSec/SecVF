//
//  VMConfigurationTests.swift
//  SecVFTests
//
//  Unit tests for VMConfiguration data model
//

import XCTest
@testable import SecVF

final class VMConfigurationTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDefaultInitialization() {
        // Given
        let name = "TestVM"
        let bundlePath = "/test/path/"

        // When
        let config = VMConfiguration(name: name, bundlePath: bundlePath)

        // Then
        XCTAssertEqual(config.name, name)
        XCTAssertEqual(config.bundlePath, "/test/path/")
        XCTAssertEqual(config.cpuCount, 2)
        XCTAssertEqual(config.memorySize, 4 * 1024 * 1024 * 1024) // 4GB
        XCTAssertEqual(config.diskSize, 64 * 1024 * 1024 * 1024) // 64GB
        XCTAssertEqual(config.osType, "Linux")
        XCTAssertNil(config.lastUsedDate)
        XCTAssertEqual(config.status, .stopped)
        XCTAssertEqual(config.networkConfig.mode, .nat)
    }

    func testCustomInitialization() {
        // Given
        let id = UUID()
        let name = "CustomVM"
        let bundlePath = "/custom/path"
        let cpuCount = 8
        let memorySize: UInt64 = 16 * 1024 * 1024 * 1024
        let diskSize: UInt64 = 100 * 1024 * 1024 * 1024
        let createdDate = Date()
        let lastUsedDate = Date()
        let osType = "macOS"

        // When
        let config = VMConfiguration(
            id: id,
            name: name,
            bundlePath: bundlePath,
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskSize: diskSize,
            createdDate: createdDate,
            lastUsedDate: lastUsedDate,
            osType: osType
        )

        // Then
        XCTAssertEqual(config.id, id)
        XCTAssertEqual(config.name, name)
        XCTAssertEqual(config.bundlePath, "/custom/path/") // Should add trailing slash
        XCTAssertEqual(config.cpuCount, cpuCount)
        XCTAssertEqual(config.memorySize, memorySize)
        XCTAssertEqual(config.diskSize, diskSize)
        XCTAssertEqual(config.createdDate, createdDate)
        XCTAssertEqual(config.lastUsedDate, lastUsedDate)
        XCTAssertEqual(config.osType, osType)
    }

    func testBundlePathTrailingSlash() {
        // Given
        let pathWithSlash = "/test/path/"
        let pathWithoutSlash = "/test/path"

        // When
        let config1 = VMConfiguration(name: "VM1", bundlePath: pathWithSlash)
        let config2 = VMConfiguration(name: "VM2", bundlePath: pathWithoutSlash)

        // Then
        XCTAssertEqual(config1.bundlePath, "/test/path/")
        XCTAssertEqual(config2.bundlePath, "/test/path/")
    }

    // MARK: - Computed Properties Tests

    func testDiskImagePath() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/path/")

        // When
        let diskImagePath = config.diskImagePath

        // Then
        XCTAssertEqual(diskImagePath, "/test/path/Disk.img")
    }

    func testNVRAMPath() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/path/")

        // When
        let nvramPath = config.nvramPath

        // Then
        XCTAssertEqual(nvramPath, "/test/path/NVRAM")
    }

    func testMachineIdentifierPath() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/path/")

        // When
        let machineIdPath = config.machineIdentifierPath

        // Then
        XCTAssertEqual(machineIdPath, "/test/path/MachineIdentifier")
    }

    func testMetadataPath() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/path/")

        // When
        let metadataPath = config.metadataPath

        // Then
        XCTAssertEqual(metadataPath, "/test/path/metadata.json")
    }

    // MARK: - Display String Tests

    func testMemoryDisplayString() {
        // Given/When/Then
        let config1 = VMConfiguration(name: "VM1", bundlePath: "/test/", memorySize: 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(config1.memoryDisplayString, "4.0 GB")

        let config2 = VMConfiguration(name: "VM2", bundlePath: "/test/", memorySize: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(config2.memoryDisplayString, "8.0 GB")

        let config3 = VMConfiguration(name: "VM3", bundlePath: "/test/", memorySize: 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(config3.memoryDisplayString, "2.0 GB")
    }

    func testDiskDisplayString() {
        // Given/When/Then
        let config1 = VMConfiguration(name: "VM1", bundlePath: "/test/", diskSize: 64 * 1024 * 1024 * 1024)
        XCTAssertEqual(config1.diskDisplayString, "64 GB")

        let config2 = VMConfiguration(name: "VM2", bundlePath: "/test/", diskSize: 100 * 1024 * 1024 * 1024)
        XCTAssertEqual(config2.diskDisplayString, "100 GB")
    }

    func testStatusDisplayString() {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")

        // When/Then
        config.status = .stopped
        XCTAssertEqual(config.statusDisplayString, "Stopped")

        config.status = .starting
        XCTAssertEqual(config.statusDisplayString, "Starting...")

        config.status = .running
        XCTAssertEqual(config.statusDisplayString, "Running")

        config.status = .stopping
        XCTAssertEqual(config.statusDisplayString, "Stopping...")
    }

    // MARK: - JSON Encoding/Decoding Tests

    func testJSONEncodingAndDecoding() throws {
        // Given
        let originalConfig = VMConfiguration(
            id: UUID(),
            name: "TestVM",
            bundlePath: "/test/path/",
            cpuCount: 4,
            memorySize: 8 * 1024 * 1024 * 1024,
            diskSize: 100 * 1024 * 1024 * 1024,
            createdDate: Date(),
            lastUsedDate: Date(),
            osType: "Ubuntu"
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalConfig)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then
        XCTAssertEqual(decodedConfig.id, originalConfig.id)
        XCTAssertEqual(decodedConfig.name, originalConfig.name)
        XCTAssertEqual(decodedConfig.bundlePath, originalConfig.bundlePath)
        XCTAssertEqual(decodedConfig.cpuCount, originalConfig.cpuCount)
        XCTAssertEqual(decodedConfig.memorySize, originalConfig.memorySize)
        XCTAssertEqual(decodedConfig.diskSize, originalConfig.diskSize)
        XCTAssertEqual(decodedConfig.osType, originalConfig.osType)
    }

    func testStatusNotPersistedInJSON() throws {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.status = .running // Set non-default status

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then - status should be reset to default (.stopped)
        XCTAssertEqual(decodedConfig.status, .stopped)
    }

    // MARK: - Network Configuration Tests

    func testDefaultNetworkConfiguration() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/")

        // When/Then
        XCTAssertEqual(config.networkConfig.mode, .nat)
        XCTAssertNil(config.networkConfig.routerVMId)
        XCTAssertFalse(config.networkConfig.isRouter)
    }

    func testNetworkConfigurationPersistence() throws {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = UUID()
        config.networkConfig.isRouter = false

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then
        XCTAssertEqual(decodedConfig.networkConfig.mode, .virtual)
        XCTAssertEqual(decodedConfig.networkConfig.routerVMId, config.networkConfig.routerVMId)
        XCTAssertEqual(decodedConfig.networkConfig.isRouter, false)
    }

    // MARK: - VirtualNetworkConfig Tests

    func testVirtualNetworkConfigDescriptionNAT() {
        // Given
        var networkConfig = VirtualNetworkConfig()
        networkConfig.mode = .nat

        // When
        let description = networkConfig.description

        // Then
        XCTAssertEqual(description, "NAT (Internet access)")
    }

    func testVirtualNetworkConfigDescriptionRouter() {
        // Given
        var networkConfig = VirtualNetworkConfig()
        networkConfig.mode = .virtual
        networkConfig.isRouter = true

        // When
        let description = networkConfig.description

        // Then
        // Description was updated in 9a0f401 to reflect the dual-NIC layout
        // (router VM has both a switch leg and a NAT leg).
        XCTAssertEqual(description, "Router (Dual-NIC: Switch + NAT)")
    }

    func testVirtualNetworkConfigDescriptionClient() {
        // Given
        var networkConfig = VirtualNetworkConfig()
        networkConfig.mode = .virtual
        networkConfig.routerVMId = UUID()
        networkConfig.isRouter = false

        // When
        let description = networkConfig.description

        // Then
        XCTAssertEqual(description, "Routes via Linux VM")
    }

    func testVirtualNetworkConfigDescriptionVirtualOnly() {
        // Given
        var networkConfig = VirtualNetworkConfig()
        networkConfig.mode = .virtual
        networkConfig.isRouter = false
        networkConfig.routerVMId = nil

        // When
        let description = networkConfig.description

        // Then
        XCTAssertEqual(description, "Virtual Network Client")
    }

    // MARK: - Network Mode Tests

    func testNetworkModeRawValues() {
        XCTAssertEqual(NetworkMode.nat.rawValue, "nat")
        XCTAssertEqual(NetworkMode.virtual.rawValue, "virtual")
    }

    func testNetworkModeDecoding() throws {
        // Given
        let jsonData = """
        "nat"
        """.data(using: .utf8)!

        // When
        let mode = try JSONDecoder().decode(NetworkMode.self, from: jsonData)

        // Then
        XCTAssertEqual(mode, .nat)
    }
}
