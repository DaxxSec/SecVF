//
//  VMManagerTests.swift
//  SecVFTests
//
//  Unit tests for VMManager functionality
//

import XCTest
@testable import SecVF

final class VMManagerTests: XCTestCase {

    var testDirectory: URL!

    override func setUp() {
        super.setUp()
        // Create a temporary directory for testing
        testDirectory = TestFileSystemHelper.createTemporaryTestDirectory()
    }

    override func tearDown() {
        // Clean up test directory
        if let testDir = testDirectory {
            TestFileSystemHelper.removeTestDirectory(testDir)
        }
        testDirectory = nil
        super.tearDown()
    }

    // MARK: - VM Bundle Structure Tests

    func testCreateMockVMBundle() throws {
        // Given
        let vmName = "TestVM"

        // When
        let bundlePath = try TestFileSystemHelper.createMockVMBundle(at: testDirectory, name: vmName)

        // Then
        XCTAssertDirectoryExists(bundlePath)
        XCTAssertFileExists(bundlePath.appendingPathComponent("metadata.json"))
        XCTAssertFileExists(bundlePath.appendingPathComponent("disk.img"))
        XCTAssertFileExists(bundlePath.appendingPathComponent("NVRAM"))

        let isValid = TestFileSystemHelper.verifyVMBundleStructure(at: bundlePath)
        XCTAssertTrue(isValid)
    }

    func testVMBundleMetadataLoading() throws {
        // Given
        let vmName = "TestLinuxVM"
        let bundlePath = try TestFileSystemHelper.createMockVMBundle(at: testDirectory, name: vmName)
        let metadataPath = bundlePath.appendingPathComponent("metadata.json")

        // When
        let data = try Data(contentsOf: metadataPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["name"] as? String, vmName)
        XCTAssertEqual(json?["cpuCount"] as? Int, 2)
        XCTAssertEqual(json?["memorySize"] as? Int, 4294967296)
        XCTAssertEqual(json?["networkMode"] as? String, "NAT")
        XCTAssertEqual(json?["osType"] as? String, "Linux")
    }

    // MARK: - VMConfiguration Initialization Tests

    func testVMConfigurationWithValidParameters() {
        // Given
        let name = TestDataGenerator.randomVMName()
        let cpuCount = TestDataGenerator.validCPUCount()
        let memorySize = TestDataGenerator.validMemorySize()
        let diskSize = TestDataGenerator.validDiskSize()

        // When
        let config = VMConfiguration(
            name: name,
            bundlePath: testDirectory.path,
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskSize: diskSize
        )

        // Then
        XCTAssertEqual(config.name, name)
        XCTAssertEqual(config.cpuCount, cpuCount)
        XCTAssertEqual(config.memorySize, memorySize)
        XCTAssertEqual(config.diskSize, diskSize)
        XCTAssertNotNil(config.id)
        XCTAssertNotNil(config.createdDate)
    }

    func testVMConfigurationPathComputation() {
        // Given
        let bundlePath = "/test/vm.bundle/"
        let config = VMConfiguration(name: "TestVM", bundlePath: bundlePath)

        // When/Then
        XCTAssertEqual(config.diskImagePath, "/test/vm.bundle/Disk.img")
        XCTAssertEqual(config.nvramPath, "/test/vm.bundle/NVRAM")
        XCTAssertEqual(config.machineIdentifierPath, "/test/vm.bundle/MachineIdentifier")
        XCTAssertEqual(config.metadataPath, "/test/vm.bundle/metadata.json")
    }

    // MARK: - VM Name Validation Tests

    func testValidVMNames() {
        let validNames = [
            "TestVM",
            "My Linux VM",
            "Ubuntu-Server-2024",
            "VM_01",
            "Test.VM"
        ]

        for name in validNames {
            XCTAssertTrue(name.isValidVMName, "'\(name)' should be a valid VM name")
        }
    }

    func testInvalidVMNames() {
        let invalidNames = [
            "Test/VM",          // Contains /
            "Test\\VM",         // Contains \
            "Test:VM",          // Contains :
            "Test*VM",          // Contains *
            "Test?VM",          // Contains ?
            "Test\"VM",         // Contains "
            "Test<VM",          // Contains <
            "Test>VM",          // Contains >
            "Test|VM",          // Contains |
            ""                  // Empty string
        ]

        for name in invalidNames {
            XCTAssertFalse(name.isValidVMName, "'\(name)' should be an invalid VM name")
        }
    }

    // MARK: - Configuration Persistence Tests

    func testSaveAndLoadConfiguration() throws {
        // Given
        let vmName = "PersistenceTestVM"
        let bundlePath = testDirectory.appendingPathComponent("\(vmName).bundle")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

        var config = VMConfiguration(
            name: vmName,
            bundlePath: bundlePath.path,
            cpuCount: 4,
            memorySize: 8 * 1024 * 1024 * 1024,
            diskSize: 50 * 1024 * 1024 * 1024,
            osType: "Ubuntu"
        )
        config.networkConfig.mode = .virtual

        // When - Save
        let metadataPath = bundlePath.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: metadataPath)

        // Then - Load
        let loadedData = try Data(contentsOf: metadataPath)
        let decoder = JSONDecoder()
        let loadedConfig = try decoder.decode(VMConfiguration.self, from: loadedData)

        XCTAssertEqual(loadedConfig.name, vmName)
        XCTAssertEqual(loadedConfig.cpuCount, 4)
        XCTAssertEqual(loadedConfig.memorySize, 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(loadedConfig.diskSize, 50 * 1024 * 1024 * 1024)
        XCTAssertEqual(loadedConfig.osType, "Ubuntu")
        XCTAssertEqual(loadedConfig.networkConfig.mode, .virtual)
    }

    // MARK: - Network Configuration Tests

    func testDefaultNetworkConfiguration() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/")

        // Then
        XCTAssertEqual(config.networkConfig.mode, .nat)
        XCTAssertNil(config.networkConfig.routerVMId)
        XCTAssertFalse(config.networkConfig.isRouter)
    }

    func testVirtualNetworkConfiguration() {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        let routerID = UUID()

        // When
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = routerID

        // Then
        XCTAssertEqual(config.networkConfig.mode, .virtual)
        XCTAssertEqual(config.networkConfig.routerVMId, routerID)
    }

    func testLinuxVMAsRouter() {
        // Given
        var config = VMConfiguration(name: "LinuxRouter", bundlePath: "/test/", osType: "Linux")

        // When
        config.networkConfig.mode = .virtual
        config.networkConfig.isRouter = true

        // Then
        XCTAssertEqual(config.networkConfig.mode, .virtual)
        XCTAssertTrue(config.networkConfig.isRouter)
        XCTAssertEqual(config.networkConfig.description, "Virtual Network Router")
    }

    func testMacOSVMRoutingThroughLinux() {
        // Given
        var macOSConfig = VMConfiguration(name: "macOSVM", bundlePath: "/test/", osType: "macOS")
        let linuxRouterID = UUID()

        // When
        macOSConfig.networkConfig.mode = .virtual
        macOSConfig.networkConfig.routerVMId = linuxRouterID

        // Then
        XCTAssertEqual(macOSConfig.networkConfig.mode, .virtual)
        XCTAssertEqual(macOSConfig.networkConfig.routerVMId, linuxRouterID)
        XCTAssertEqual(macOSConfig.networkConfig.description, "Routes via Linux VM")
    }

    // MARK: - VM Status Tests

    func testVMStatusTransitions() {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")

        // When/Then - Test all status transitions
        config.status = .stopped
        XCTAssertEqual(config.statusDisplayString, "Stopped")

        config.status = .starting
        XCTAssertEqual(config.statusDisplayString, "Starting...")

        config.status = .running
        XCTAssertEqual(config.statusDisplayString, "Running")

        config.status = .stopping
        XCTAssertEqual(config.statusDisplayString, "Stopping...")
    }

    func testStatusNotPersistedInJSON() throws {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.status = .running

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then - Status should reset to .stopped
        XCTAssertEqual(decodedConfig.status, .stopped)
    }

    // MARK: - Display Formatting Tests

    func testMemorySizeFormatting() {
        let testCases: [(UInt64, String)] = [
            (2 * 1024 * 1024 * 1024, "2.0 GB"),
            (4 * 1024 * 1024 * 1024, "4.0 GB"),
            (8 * 1024 * 1024 * 1024, "8.0 GB"),
            (16 * 1024 * 1024 * 1024, "16.0 GB")
        ]

        for (memorySize, expectedDisplay) in testCases {
            let config = VMConfiguration(name: "TestVM", bundlePath: "/test/", memorySize: memorySize)
            XCTAssertEqual(config.memoryDisplayString, expectedDisplay)
        }
    }

    func testDiskSizeFormatting() {
        let testCases: [(UInt64, String)] = [
            (20 * 1024 * 1024 * 1024, "20 GB"),
            (50 * 1024 * 1024 * 1024, "50 GB"),
            (64 * 1024 * 1024 * 1024, "64 GB"),
            (100 * 1024 * 1024 * 1024, "100 GB")
        ]

        for (diskSize, expectedDisplay) in testCases {
            let config = VMConfiguration(name: "TestVM", bundlePath: "/test/", diskSize: diskSize)
            XCTAssertEqual(config.diskDisplayString, expectedDisplay)
        }
    }

    // MARK: - UUID and Date Tests

    func testUniqueVMIdentifiers() {
        // Given
        let vm1 = VMConfiguration(name: "VM1", bundlePath: "/test/")
        let vm2 = VMConfiguration(name: "VM2", bundlePath: "/test/")

        // Then
        XCTAssertNotEqual(vm1.id, vm2.id)
    }

    func testCreatedDateSet() {
        // Given
        let before = Date()
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        let after = Date()

        // Then
        XCTAssertGreaterThanOrEqual(config.createdDate, before)
        XCTAssertLessThanOrEqual(config.createdDate, after)
    }

    func testLastUsedDateInitiallyNil() {
        // Given
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/")

        // Then
        XCTAssertNil(config.lastUsedDate)
    }

    // MARK: - Edge Cases and Error Handling

    func testBundlePathNormalization() {
        let testCases: [(input: String, expected: String)] = [
            ("/path/to/vm", "/path/to/vm/"),
            ("/path/to/vm/", "/path/to/vm/"),
            ("/path/to/vm//", "/path/to/vm//"), // Multiple slashes preserved
            ("relative/path", "relative/path/")
        ]

        for (input, expected) in testCases {
            let config = VMConfiguration(name: "TestVM", bundlePath: input)
            XCTAssertEqual(config.bundlePath, expected, "Path '\(input)' should normalize to '\(expected)'")
        }
    }

    func testZeroMemorySize() {
        // Edge case: zero memory
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/", memorySize: 0)
        XCTAssertEqual(config.memoryDisplayString, "0.0 GB")
    }

    func testZeroDiskSize() {
        // Edge case: zero disk
        let config = VMConfiguration(name: "TestVM", bundlePath: "/test/", diskSize: 0)
        XCTAssertEqual(config.diskDisplayString, "0 GB")
    }
}
