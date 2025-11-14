//
//  VMConfiguration.swift
//  SecVF
//

import Foundation
import Virtualization

/// VM runtime status (not persisted to disk)
enum VMStatus {
    case stopped
    case starting
    case running
    case stopping
}

/// Network mode configuration (defined in VirtualNetworkSwitch.swift)
/// - nat: Standard NAT networking (default) - VM has internet access
/// - virtual: Virtual switch networking - VM-to-VM communication only
// Note: NetworkMode and VirtualNetworkConfig are defined in VirtualNetworkSwitch.swift

/// Represents a virtual machine configuration and metadata
struct VMConfiguration: Codable {
    var id: UUID
    var name: String
    var bundlePath: String
    var cpuCount: Int
    var memorySize: UInt64 // in bytes
    var diskSize: UInt64 // in bytes
    var createdDate: Date
    var lastUsedDate: Date?
    var osType: String // e.g., "Linux", "Ubuntu", etc.

    // Network configuration
    var networkConfig: VirtualNetworkConfig = VirtualNetworkConfig()

    // Runtime status (not saved to disk)
    var status: VMStatus = .stopped

    // Computed properties for file paths
    var diskImagePath: String {
        bundlePath + "Disk.img"
    }

    var nvramPath: String {
        bundlePath + "NVRAM"
    }

    var machineIdentifierPath: String {
        bundlePath + "MachineIdentifier"
    }

    var metadataPath: String {
        bundlePath + "metadata.json"
    }

    // Initialize with defaults
    init(id: UUID = UUID(),
         name: String,
         bundlePath: String,
         cpuCount: Int = 2,
         memorySize: UInt64 = 4 * 1024 * 1024 * 1024, // 4 GB default
         diskSize: UInt64 = 64 * 1024 * 1024 * 1024, // 64 GB default
         createdDate: Date = Date(),
         lastUsedDate: Date? = nil,
         osType: String = "Linux") {

        self.id = id
        self.name = name
        self.bundlePath = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.createdDate = createdDate
        self.lastUsedDate = lastUsedDate
        self.osType = osType
    }

    // Format memory size for display
    var memoryDisplayString: String {
        let gb = Double(memorySize) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }

    // Format disk size for display
    var diskDisplayString: String {
        let gb = Double(diskSize) / (1024 * 1024 * 1024)
        return String(format: "%.0f GB", gb)
    }

    // Check if VM bundle exists
    var exists: Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }

    // Display string for status
    var statusDisplayString: String {
        switch status {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running:
            return "Running"
        case .stopping:
            return "Stopping..."
        }
    }

    // Custom coding keys to exclude status from persistence
    enum CodingKeys: String, CodingKey {
        case id, name, bundlePath, cpuCount, memorySize, diskSize
        case createdDate, lastUsedDate, osType, networkConfig
    }
}
