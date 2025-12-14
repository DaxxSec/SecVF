//
//  NetworkSwitchProtocol.swift
//  SecVF
//
//  Protocol abstraction for VirtualNetworkSwitch to enable dependency injection and testing.
//  Controllers can depend on this protocol rather than VirtualNetworkSwitch.shared singleton.
//

import Foundation

/// Protocol defining the interface for virtual network switch operations
/// Enables dependency injection and mock implementations for testing
protocol NetworkSwitchProtocol: AnyObject {
    /// Connect a VM to the virtual switch
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - vmName: Display name of the VM
    /// - Returns: FileHandle for the network connection, or nil if connection failed
    func connectVM(vmId: UUID, vmName: String) -> FileHandle?

    /// Disconnect a VM from the virtual switch
    /// - Parameter vmId: Unique identifier of the VM to disconnect
    func disconnectPort(vmId: UUID)

    /// Shutdown the entire virtual switch
    func shutdown()

    /// Get statistics about the virtual switch
    /// - Returns: Dictionary containing statistics (packetsForwarded, packetsDropped, etc.)
    func getStatistics() -> [String: Any]

    /// Print statistics to the console (for debugging)
    func printStatistics()
}

// MARK: - VirtualNetworkSwitch Conformance

extension VirtualNetworkSwitch: NetworkSwitchProtocol {}
