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

/// Network mode configuration
enum NetworkMode: String, Codable {
    case nat            // Standard NAT (default)
    case virtual        // Virtual switch networking (VM-to-VM)
}

/// Configuration for a VM's virtual network connection
struct VirtualNetworkConfig: Codable {
    var mode: NetworkMode = .nat
    var routerVMId: UUID?           // For macOS VMs - which Linux VM to route through
    var isRouter: Bool = false       // For Linux VMs - acts as router for other VMs

    var description: String {
        switch mode {
        case .nat:
            return "NAT (Internet access)"
        case .virtual:
            if isRouter {
                return "Virtual Network Router"
            } else if routerVMId != nil {
                return "Routes via Linux VM"
            } else {
                return "Virtual Network Client"
            }
        }
    }
}

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
    var osType: String // e.g., "Linux", "macOS"
    var macOSInstalled: Bool? // For macOS VMs - tracks if OS has been installed (nil for Linux VMs)
    var osInstalled: Bool? // For Linux VMs - tracks if OS has been installed (nil for macOS VMs)
    var linuxDistribution: String? // For Linux VMs - e.g., "Kali", "Ubuntu", "Debian"
    var linuxVersion: String? // For Linux VMs - e.g., "2024.1", "24.04"

    // Network configuration
    var networkConfig: VirtualNetworkConfig = VirtualNetworkConfig()

    // Runtime status (not saved to disk)
    var status: VMStatus = .stopped

    // Custom decoder to handle missing networkConfig in old metadata files
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bundlePath = try container.decode(String.self, forKey: .bundlePath)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memorySize = try container.decode(UInt64.self, forKey: .memorySize)
        diskSize = try container.decode(UInt64.self, forKey: .diskSize)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        lastUsedDate = try container.decodeIfPresent(Date.self, forKey: .lastUsedDate)
        osType = try container.decode(String.self, forKey: .osType)
        macOSInstalled = try container.decodeIfPresent(Bool.self, forKey: .macOSInstalled)
        osInstalled = try container.decodeIfPresent(Bool.self, forKey: .osInstalled)
        linuxDistribution = try container.decodeIfPresent(String.self, forKey: .linuxDistribution)
        linuxVersion = try container.decodeIfPresent(String.self, forKey: .linuxVersion)

        // Provide default if networkConfig is missing (for backward compatibility)
        networkConfig = (try? container.decode(VirtualNetworkConfig.self, forKey: .networkConfig)) ?? VirtualNetworkConfig()

        // status is not encoded/decoded (runtime only)
        status = .stopped
    }

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
        case createdDate, lastUsedDate, osType, macOSInstalled, osInstalled
        case linuxDistribution, linuxVersion, networkConfig
    }
}
