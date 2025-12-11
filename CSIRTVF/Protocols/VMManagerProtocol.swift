//
//  VMManagerProtocol.swift
//  SecVF
//
//  Protocol abstraction for VMManager to enable dependency injection and testing.
//  Controllers can depend on this protocol rather than the concrete VMManager.shared singleton.
//

import Foundation

/// Protocol defining the interface for VM management operations
/// Enables dependency injection and mock implementations for testing
protocol VMManagerProtocol: AnyObject {
    /// In-memory cache of all VMs
    var virtualMachines: [VMConfiguration] { get }

    /// Initialize the manager asynchronously
    func initializeAsync(completion: @escaping () -> Void)

    /// Save VM configuration to disk
    func saveVMConfiguration(_ vmConfig: VMConfiguration) throws

    /// Create a new VM with the specified parameters
    func createVM(name: String, cpuCount: Int, memorySize: UInt64, diskSize: UInt64,
                  osType: String) throws -> VMConfiguration

    /// Delete a VM and its associated files
    func deleteVM(_ vmConfig: VMConfiguration) throws

    /// Rename a VM
    func renameVM(_ vmConfig: VMConfiguration, newName: String) throws

    /// Clone a VM to a new name
    func cloneVM(_ vmConfig: VMConfiguration, newName: String) throws -> VMConfiguration

    /// Import a VM from an external path
    func importVM(from sourcePath: String, name: String, osType: String) throws -> VMConfiguration

    /// Update the last used timestamp for a VM
    func updateLastUsedDate(_ vmConfig: VMConfiguration)

    /// Get count of currently running VMs
    func getRunningVMsCount() -> Int

    /// Get list of currently running VMs
    func getRunningVMs() -> [VMConfiguration]

    /// Update VM status (running, stopped, paused)
    func updateVMStatus(_ vmConfig: VMConfiguration, status: VMStatus)
}

// MARK: - VMManager Conformance

extension VMManager: VMManagerProtocol {}
