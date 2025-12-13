//
//  VirtualNetworkSwitchTests.swift
//  SecVFTests
//
//  Unit tests for VirtualNetworkSwitch functionality
//

import XCTest
@testable import SecVF

final class VirtualNetworkSwitchTests: XCTestCase {

    // MARK: - Network Mode Tests

    func testNetworkModeEnumValues() {
        XCTAssertEqual(NetworkMode.nat.rawValue, "nat")
        XCTAssertEqual(NetworkMode.virtual.rawValue, "virtual")
    }

    func testNetworkModeEncodingDecoding() throws {
        // Test NAT mode
        let natMode = NetworkMode.nat
        let natData = try JSONEncoder().encode(natMode)
        let decodedNAT = try JSONDecoder().decode(NetworkMode.self, from: natData)
        XCTAssertEqual(decodedNAT, .nat)

        // Test Virtual mode
        let virtualMode = NetworkMode.virtual
        let virtualData = try JSONEncoder().encode(virtualMode)
        let decodedVirtual = try JSONDecoder().decode(NetworkMode.self, from: virtualData)
        XCTAssertEqual(decodedVirtual, .virtual)
    }

    // MARK: - Virtual Network Configuration Tests

    func testDefaultVirtualNetworkConfig() {
        // Given
        let config = VirtualNetworkConfig()

        // Then
        XCTAssertEqual(config.mode, .nat)
        XCTAssertNil(config.routerVMId)
        XCTAssertFalse(config.isRouter)
    }

    func testVirtualNetworkConfigCodable() throws {
        // Given
        var config = VirtualNetworkConfig()
        config.mode = .virtual
        config.routerVMId = UUID()
        config.isRouter = true

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VirtualNetworkConfig.self, from: data)

        // Then
        XCTAssertEqual(decodedConfig.mode, .virtual)
        XCTAssertEqual(decodedConfig.routerVMId, config.routerVMId)
        XCTAssertTrue(decodedConfig.isRouter)
    }

    func testVirtualNetworkConfigDescriptions() {
        var config = VirtualNetworkConfig()

        // Test NAT description
        config.mode = .nat
        XCTAssertEqual(config.description, "NAT (Internet access)")

        // Test Router description
        config.mode = .virtual
        config.isRouter = true
        XCTAssertEqual(config.description, "Virtual Network Router")

        // Test Client with router description
        config.mode = .virtual
        config.isRouter = false
        config.routerVMId = UUID()
        XCTAssertEqual(config.description, "Routes via Linux VM")

        // Test Virtual Client description
        config.mode = .virtual
        config.isRouter = false
        config.routerVMId = nil
        XCTAssertEqual(config.description, "Virtual Network Client")
    }

    // MARK: - Router Configuration Tests

    func testLinuxVMConfiguredAsRouter() {
        // Given
        var linuxConfig = VMConfiguration(name: "LinuxRouter", bundlePath: "/test/", osType: "Linux")

        // When
        linuxConfig.networkConfig.mode = .virtual
        linuxConfig.networkConfig.isRouter = true

        // Then
        XCTAssertTrue(linuxConfig.networkConfig.isRouter)
        XCTAssertEqual(linuxConfig.networkConfig.mode, .virtual)
        XCTAssertEqual(linuxConfig.networkConfig.description, "Virtual Network Router")
    }

    func testMacOSVMConfiguredWithRouter() {
        // Given
        var macOSConfig = VMConfiguration(name: "macOSClient", bundlePath: "/test/", osType: "macOS")
        let routerID = UUID()

        // When
        macOSConfig.networkConfig.mode = .virtual
        macOSConfig.networkConfig.routerVMId = routerID

        // Then
        XCTAssertEqual(macOSConfig.networkConfig.routerVMId, routerID)
        XCTAssertEqual(macOSConfig.networkConfig.mode, .virtual)
        XCTAssertFalse(macOSConfig.networkConfig.isRouter)
    }

    func testMultipleMacOSVMsSameRouter() {
        // Given
        let routerID = UUID()

        var macOS1 = VMConfiguration(name: "macOS-1", bundlePath: "/test/1/", osType: "macOS")
        var macOS2 = VMConfiguration(name: "macOS-2", bundlePath: "/test/2/", osType: "macOS")
        var macOS3 = VMConfiguration(name: "macOS-3", bundlePath: "/test/3/", osType: "macOS")

        // When
        macOS1.networkConfig.mode = .virtual
        macOS1.networkConfig.routerVMId = routerID

        macOS2.networkConfig.mode = .virtual
        macOS2.networkConfig.routerVMId = routerID

        macOS3.networkConfig.mode = .virtual
        macOS3.networkConfig.routerVMId = routerID

        // Then - All should route through the same router
        XCTAssertEqual(macOS1.networkConfig.routerVMId, routerID)
        XCTAssertEqual(macOS2.networkConfig.routerVMId, routerID)
        XCTAssertEqual(macOS3.networkConfig.routerVMId, routerID)
    }

    // MARK: - Network Configuration Persistence Tests

    func testNetworkConfigurationPersistence() throws {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        let routerID = UUID()

        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = routerID
        config.networkConfig.isRouter = false

        // When - Encode and decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then
        XCTAssertEqual(decodedConfig.networkConfig.mode, .virtual)
        XCTAssertEqual(decodedConfig.networkConfig.routerVMId, routerID)
        XCTAssertFalse(decodedConfig.networkConfig.isRouter)
    }

    func testNATConfigurationPersistence() throws {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.networkConfig.mode = .nat

        // When - Encode and decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then
        XCTAssertEqual(decodedConfig.networkConfig.mode, .nat)
        XCTAssertNil(decodedConfig.networkConfig.routerVMId)
        XCTAssertFalse(decodedConfig.networkConfig.isRouter)
    }

    // MARK: - Network Mode Switching Tests

    func testSwitchFromNATToVirtual() {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        XCTAssertEqual(config.networkConfig.mode, .nat)

        // When
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = UUID()

        // Then
        XCTAssertEqual(config.networkConfig.mode, .virtual)
        XCTAssertNotNil(config.networkConfig.routerVMId)
    }

    func testSwitchFromVirtualToNAT() {
        // Given
        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = UUID()

        // When
        config.networkConfig.mode = .nat
        config.networkConfig.routerVMId = nil

        // Then
        XCTAssertEqual(config.networkConfig.mode, .nat)
        XCTAssertNil(config.networkConfig.routerVMId)
    }

    // MARK: - Edge Cases

    func testRouterWithoutVirtualMode() {
        // Given - A misconfigured router (router flag set but not in virtual mode)
        var config = VMConfiguration(name: "MisconfiguredRouter", bundlePath: "/test/")
        config.networkConfig.mode = .nat // Should be .virtual for router
        config.networkConfig.isRouter = true

        // Then - Description should still reflect NAT mode
        XCTAssertEqual(config.networkConfig.description, "NAT (Internet access)")
    }

    func testVirtualModeWithoutRouter() {
        // Given - VM in virtual mode but no router specified (valid for isolated network)
        var config = VMConfiguration(name: "IsolatedVM", bundlePath: "/test/")
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = nil
        config.networkConfig.isRouter = false

        // Then
        XCTAssertEqual(config.networkConfig.description, "Virtual Network Client")
    }

    func testRouterIDPersistence() throws {
        // Given - Specific router ID
        let specificRouterID = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!

        var config = VMConfiguration(name: "TestVM", bundlePath: "/test/")
        config.networkConfig.mode = .virtual
        config.networkConfig.routerVMId = specificRouterID

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(VMConfiguration.self, from: data)

        // Then - Exact UUID should be preserved
        XCTAssertEqual(decodedConfig.networkConfig.routerVMId, specificRouterID)
    }

    // MARK: - Multiple Router Scenarios

    func testMultipleRoutersInNetwork() {
        // Given - Multiple Linux VMs acting as routers
        var router1 = VMConfiguration(name: "Router1", bundlePath: "/test/r1/", osType: "Linux")
        var router2 = VMConfiguration(name: "Router2", bundlePath: "/test/r2/", osType: "Linux")

        // When
        router1.networkConfig.mode = .virtual
        router1.networkConfig.isRouter = true

        router2.networkConfig.mode = .virtual
        router2.networkConfig.isRouter = true

        // Then - Both should be configured as routers
        XCTAssertTrue(router1.networkConfig.isRouter)
        XCTAssertTrue(router2.networkConfig.isRouter)
        XCTAssertEqual(router1.networkConfig.description, "Virtual Network Router")
        XCTAssertEqual(router2.networkConfig.description, "Virtual Network Router")
    }

    func testClientVMsSplitBetweenRouters() {
        // Given
        let router1ID = UUID()
        let router2ID = UUID()

        var client1 = VMConfiguration(name: "Client1", bundlePath: "/test/c1/", osType: "macOS")
        var client2 = VMConfiguration(name: "Client2", bundlePath: "/test/c2/", osType: "macOS")
        var client3 = VMConfiguration(name: "Client3", bundlePath: "/test/c3/", osType: "macOS")

        // When - Distribute clients across two routers
        client1.networkConfig.mode = .virtual
        client1.networkConfig.routerVMId = router1ID

        client2.networkConfig.mode = .virtual
        client2.networkConfig.routerVMId = router1ID

        client3.networkConfig.mode = .virtual
        client3.networkConfig.routerVMId = router2ID

        // Then
        XCTAssertEqual(client1.networkConfig.routerVMId, router1ID)
        XCTAssertEqual(client2.networkConfig.routerVMId, router1ID)
        XCTAssertEqual(client3.networkConfig.routerVMId, router2ID)
    }

    // MARK: - Mock Network Configuration Helpers Tests

    func testMockNATConfiguration() {
        // Given/When
        let (mode, routerID) = MockNetworkConfiguration.createNATConfig()

        // Then
        XCTAssertEqual(mode, "NAT")
        XCTAssertNil(routerID)
    }

    func testMockVirtualNetworkConfiguration() {
        // Given
        let expectedRouterID = "router-123"

        // When
        let (mode, routerID) = MockNetworkConfiguration.createVirtualNetworkConfig(routerID: expectedRouterID)

        // Then
        XCTAssertEqual(mode, "Virtual")
        XCTAssertEqual(routerID, expectedRouterID)
    }
}
