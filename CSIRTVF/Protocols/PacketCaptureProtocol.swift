//
//  PacketCaptureProtocol.swift
//  SecVF
//
//  Protocol abstraction for PacketCaptureManager to enable dependency injection and testing.
//  Controllers can depend on this protocol rather than PacketCaptureManager.shared singleton.
//

import Foundation

/// Protocol defining the interface for packet capture operations
/// Enables dependency injection and mock implementations for testing
protocol PacketCaptureProtocol: AnyObject {
    /// Whether packet capture is currently active
    var isCapturing: Bool { get }

    /// Start packet capture
    /// - Returns: true if capture started successfully
    func startCapture() -> Bool

    /// Stop packet capture
    func stopCapture()

    /// Manually capture a packet (for internal VM-to-VM traffic)
    /// - Parameters:
    ///   - data: Raw packet data
    ///   - sourceVM: Name of the source VM
    ///   - destVM: Name of the destination VM
    func capturePacket(_ data: Data, sourceVM: String, destVM: String)

    /// Get the most recent captured packets
    /// - Parameter count: Maximum number of packets to return
    /// - Returns: Array of most recent CapturedPacket objects
    func getRecentPackets(count: Int) -> [CapturedPacket]

    /// Get all captured packets
    /// - Returns: Array of all CapturedPacket objects
    func getAllPackets() -> [CapturedPacket]

    /// Get protocol statistics
    /// - Returns: Array of ProtocolCount objects showing packet counts by protocol
    func getProtocolStats() -> [ProtocolCount]

    /// Clear all captured packets
    func clearPackets()

    /// Save captured packets to a PCAP file
    /// - Parameter url: Destination URL for the PCAP file
    func saveToPCAP(url: URL) throws

    /// Load packets from a PCAP file
    /// - Parameter url: Source URL of the PCAP file
    func loadFromPCAP(url: URL) throws
}

// MARK: - PacketCaptureManager Conformance

extension PacketCaptureManager: PacketCaptureProtocol {}
