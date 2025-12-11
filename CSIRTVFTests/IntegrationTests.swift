//
//  IntegrationTests.swift
//  SecVFTests
//
//  Integration tests for SecVF components working together.
//  Tests component interactions, data flow, and system behavior.
//

import XCTest
import Combine
@testable import SecVF

// MARK: - Packet Capture Integration Tests

final class PacketCaptureIntegrationTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testCombinePublishersExist() {
        // Given
        let manager = PacketCaptureManager.shared

        // Then - Verify publishers are available
        XCTAssertNotNil(manager.packetsPublisher)
        XCTAssertNotNil(manager.protocolStatsPublisher)
        XCTAssertNotNil(manager.captureStatePublisher)
    }

    func testCaptureStatePublisherInitialValue() {
        // Given
        let manager = PacketCaptureManager.shared
        let expectation = XCTestExpectation(description: "Receive initial state")
        var receivedState: Bool?

        // When
        manager.captureStatePublisher
            .first()
            .sink { state in
                receivedState = state
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedState)
        // Initial state should be false (not capturing) unless capture is running
        XCTAssertEqual(receivedState, manager.isCapturing)
    }

    func testTsharkAvailabilityCheck() {
        // Given
        let manager = PacketCaptureManager.shared

        // When/Then - Just verify the property is accessible
        // (actual availability depends on system configuration)
        let _ = manager.isTsharkAvailable
        // Test passes if no crash occurs
    }

    func testPacketCountTracking() {
        // Given
        let manager = PacketCaptureManager.shared

        // When
        let initialCount = manager.totalPacketCount

        // Then
        XCTAssertGreaterThanOrEqual(initialCount, 0)
    }

    func testProtocolStatsRetrieval() {
        // Given
        let manager = PacketCaptureManager.shared

        // When
        let stats = manager.getProtocolStats()

        // Then - Should return an array (empty is OK)
        XCTAssertNotNil(stats)
    }

    func testRecentPacketsRetrieval() {
        // Given
        let manager = PacketCaptureManager.shared

        // When
        let packets = manager.getRecentPackets(count: 10)

        // Then - Should return an array (empty is OK)
        XCTAssertNotNil(packets)
        XCTAssertLessThanOrEqual(packets.count, 10)
    }
}

// MARK: - Distro Configuration Integration Tests

final class DistroConfigurationIntegrationTests: XCTestCase {

    func testDistroConfigurationManagerLoads() {
        // Given
        let manager = DistroConfigurationManager.shared

        // Then
        XCTAssertTrue(manager.isLoaded, "Configuration should be loaded")
    }

    func testAllDistributionsAvailable() {
        // Given
        let manager = DistroConfigurationManager.shared

        // When
        let distributions = manager.allDistributions

        // Then
        XCTAssertFalse(distributions.isEmpty, "Should have at least one distribution")
    }

    func testKnownDistributionLookup() {
        // Given
        let manager = DistroConfigurationManager.shared

        // When
        let kaliConfig = manager.configuration(for: .kali)

        // Then
        XCTAssertNotNil(kaliConfig, "Kali configuration should exist")
        XCTAssertEqual(kaliConfig?.id, "Kali")
    }

    func testApprovedDomainsNotEmpty() {
        // Given
        let manager = DistroConfigurationManager.shared

        // When
        let domains = manager.approvedDomains

        // Then
        XCTAssertFalse(domains.isEmpty, "Should have approved domains")
        XCTAssertTrue(domains.contains("cdimage.kali.org"), "Should include Kali CDN")
    }

    func testDistroConfigurationHasRequiredFields() {
        // Given
        let manager = DistroConfigurationManager.shared

        // When
        for distro in manager.allDistributions {
            // Then
            XCTAssertFalse(distro.id.isEmpty, "ID should not be empty for \(distro.displayName)")
            XCTAssertFalse(distro.displayName.isEmpty, "Display name should not be empty")
            XCTAssertFalse(distro.version.isEmpty, "Version should not be empty for \(distro.id)")
            XCTAssertFalse(distro.downloadURL.isEmpty, "Download URL should not be empty for \(distro.id)")
            XCTAssertTrue(distro.downloadURL.hasPrefix("https://"), "URL should use HTTPS for \(distro.id)")
            XCTAssertGreaterThan(distro.expectedMaxSizeGB, 0, "Max size should be positive for \(distro.id)")
        }
    }

    func testLinuxDistroEnumDelegatesToConfig() {
        // Given/When
        let kaliVersion = LinuxDistro.kali.version
        let kaliURL = LinuxDistro.kali.downloadURL

        // Then - Should return values (from config or fallback)
        XCTAssertFalse(kaliVersion.isEmpty)
        XCTAssertTrue(kaliURL.hasPrefix("https://"))
    }

    func testApprovedDomainsIncludeAllDistros() {
        // Given
        let domains = LinuxDistro.approvedDomains

        // Then - Should include known official CDNs
        XCTAssertTrue(domains.contains("cdimage.ubuntu.com"))
        XCTAssertTrue(domains.contains("cdimage.debian.org"))
        XCTAssertTrue(domains.contains("cdimage.kali.org"))
    }
}

// MARK: - Protocol Abstraction Integration Tests

final class ProtocolAbstractionTests: XCTestCase {

    func testVMManagerConformsToProtocol() {
        // Given
        let manager: VMManagerProtocol = VMManager.shared

        // Then - Verify protocol methods are accessible
        XCTAssertNotNil(manager.virtualMachines)
        XCTAssertGreaterThanOrEqual(manager.getRunningVMsCount(), 0)
    }

    func testVirtualNetworkSwitchConformsToProtocol() {
        // Given
        let networkSwitch: NetworkSwitchProtocol = VirtualNetworkSwitch.shared

        // Then - Verify protocol methods are accessible
        let stats = networkSwitch.getStatistics()
        XCTAssertNotNil(stats)
    }

    func testPacketCaptureManagerConformsToProtocol() {
        // Given
        let captureManager: PacketCaptureProtocol = PacketCaptureManager.shared

        // Then - Verify protocol properties and methods are accessible
        let _ = captureManager.isCapturing
        let packets = captureManager.getAllPackets()
        XCTAssertNotNil(packets)
    }
}

// MARK: - Network Traffic View Tests

final class NetworkTrafficViewTests: XCTestCase {

    func testNetworkTrafficViewInitialization() {
        // Given/When
        let view = NetworkTrafficView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))

        // Then
        XCTAssertNotNil(view)
        XCTAssertEqual(view.packetsForwarded, 0)
        XCTAssertEqual(view.packetsBroadcast, 0)
        XCTAssertEqual(view.bytesTransferred, 0)
        XCTAssertEqual(view.connectedPorts, 0)
    }

    func testNetworkTrafficViewStatsUpdate() {
        // Given
        let view = NetworkTrafficView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))

        // When
        view.updateStats(forwarded: 100, broadcast: 10, bytes: 50000, ports: 3)

        // Then
        XCTAssertEqual(view.packetsForwarded, 100)
        XCTAssertEqual(view.packetsBroadcast, 10)
        XCTAssertEqual(view.bytesTransferred, 50000)
        XCTAssertEqual(view.connectedPorts, 3)
    }

    func testNetworkTrafficViewAnimationControl() {
        // Given
        let view = NetworkTrafficView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))

        // When/Then - These should not crash
        view.startAnimation()
        view.stopAnimation()
    }
}

// MARK: - Notification Names Tests

final class NotificationNamesTests: XCTestCase {

    func testVMNotificationNamesExist() {
        // Then - Verify notification names are defined
        XCTAssertNotNil(Notification.Name.startVM)
        XCTAssertNotNil(Notification.Name.stopVM)
        XCTAssertNotNil(Notification.Name.pauseVM)
        XCTAssertNotNil(Notification.Name.vmStatusChanged)
    }

    func testPacketNotificationNamesExist() {
        // Then - Verify notification names are defined
        XCTAssertNotNil(Notification.Name.packetCaptured)
        XCTAssertNotNil(Notification.Name.captureStarted)
        XCTAssertNotNil(Notification.Name.captureStopped)
        XCTAssertNotNil(Notification.Name.protocolStatsUpdated)
    }
}

// MARK: - Color and Layout Constants Tests

final class AppConstantsTests: XCTestCase {

    func testAppColorsExist() {
        // Then - Verify colors are defined and accessible
        XCTAssertNotNil(AppColors.backgroundPrimary)
        XCTAssertNotNil(AppColors.accentCyan)
        XCTAssertNotNil(AppColors.textLight)
    }

    func testLayoutConstantsExist() {
        // Then - Verify layout constants are defined
        XCTAssertGreaterThan(LayoutConstants.sidebarWidth, 0)
        XCTAssertGreaterThan(LayoutConstants.activePanelWidth, 0)
        XCTAssertGreaterThan(LayoutConstants.buttonRowHeight, 0)
    }

    func testNetworkProtocolColorsExist() {
        // Then - Verify protocol colors are accessible
        let tcpColor = NetworkProtocolColors.color(for: "TCP")
        let udpColor = NetworkProtocolColors.color(for: "UDP")
        let unknownColor = NetworkProtocolColors.color(for: "UNKNOWN_PROTOCOL")

        XCTAssertNotNil(tcpColor)
        XCTAssertNotNil(udpColor)
        XCTAssertNotNil(unknownColor) // Should return default color
    }
}
