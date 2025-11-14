//
//  VMManager.swift
//  GUILinuxVirtualMachineSampleApp
//

import Foundation
import Virtualization

/// Manages virtual machine configurations and storage
class VMManager {
    static let shared = VMManager()

    // Base directory for all VMs
    private let avfBasePath: String
    private let macOSLibraryPath: String
    private let linuxLibraryPath: String

    // Legacy VM library directory (for migration)
    private let legacyVMLibraryPath: String

    // In-memory cache of VMs
    private(set) var virtualMachines: [VMConfiguration] = []

    private init() {
        // New structure: ~/.avf/MacOS/ and ~/.avf/Linux/
        avfBasePath = NSHomeDirectory() + "/.avf/"
        macOSLibraryPath = avfBasePath + "MacOS/"
        linuxLibraryPath = avfBasePath + "Linux/"

        // Legacy path for migration
        legacyVMLibraryPath = NSHomeDirectory() + "/VirtualMachines/"

        // Create library directories if they don't exist
        createLibraryDirectoryIfNeeded()

        // Load VMs from disk
        loadVirtualMachines()

        // Migrate old VMs if they exist
        migrateOldVMIfNeeded()
    }

    // Get the appropriate library path for a given OS type
    private func libraryPath(for osType: String) -> String {
        if osType.lowercased().contains("mac") {
            return macOSLibraryPath
        } else {
            return linuxLibraryPath
        }
    }

    // MARK: - Directory Management

    private func createLibraryDirectoryIfNeeded() {
        // Create base .avf directory
        if !FileManager.default.fileExists(atPath: avfBasePath) {
            do {
                try FileManager.default.createDirectory(atPath: avfBasePath,
                                                       withIntermediateDirectories: true)
                print("Created AVF base directory at: \(avfBasePath)")
            } catch {
                print("Failed to create AVF base directory: \(error)")
            }
        }

        // Create MacOS directory
        if !FileManager.default.fileExists(atPath: macOSLibraryPath) {
            do {
                try FileManager.default.createDirectory(atPath: macOSLibraryPath,
                                                       withIntermediateDirectories: true)
                print("Created macOS VM library directory at: \(macOSLibraryPath)")
            } catch {
                print("Failed to create macOS VM library directory: \(error)")
            }
        }

        // Create Linux directory
        if !FileManager.default.fileExists(atPath: linuxLibraryPath) {
            do {
                try FileManager.default.createDirectory(atPath: linuxLibraryPath,
                                                       withIntermediateDirectories: true)
                print("Created Linux VM library directory at: \(linuxLibraryPath)")
            } catch {
                print("Failed to create Linux VM library directory: \(error)")
            }
        }
    }

    // Migrate old VMs to new directory structure
    private func migrateOldVMIfNeeded() {
        // 1. Migrate the very old "GUI Linux VM.bundle" from home directory
        let veryOldBundlePath = NSHomeDirectory() + "/GUI Linux VM.bundle/"
        if FileManager.default.fileExists(atPath: veryOldBundlePath) {
            print("Found very old VM bundle, migrating to new structure...")
            migrateVM(from: veryOldBundlePath, name: "Ubuntu VM", osType: "Linux")
        }

        // 2. Migrate all VMs from ~/VirtualMachines/ to new structure
        if FileManager.default.fileExists(atPath: legacyVMLibraryPath) {
            print("Found legacy VM library directory, migrating all VMs to new structure...")

            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: legacyVMLibraryPath) else {
                return
            }

            for item in contents {
                if item.hasSuffix(".bundle") {
                    let oldBundlePath = legacyVMLibraryPath + item
                    let metadataPath = oldBundlePath + "/metadata.json"

                    // Try to load metadata to determine OS type
                    var osType = "Linux"
                    if let vmConfig = loadVMMetadata(from: oldBundlePath + "/") {
                        osType = vmConfig.osType
                    }

                    // Extract VM name from bundle name (remove .bundle extension)
                    let vmName = String(item.dropLast(7)) // Remove ".bundle"

                    print("Migrating VM: \(vmName) (OS: \(osType))")
                    migrateVM(from: oldBundlePath + "/", name: vmName, osType: osType)
                }
            }

            // After successful migration, remove the old directory
            do {
                try FileManager.default.removeItem(atPath: legacyVMLibraryPath)
                print("Removed legacy VM library directory")
            } catch {
                print("Warning: Failed to remove legacy directory: \(error)")
            }
        }
    }

    private func migrateVM(from sourcePath: String, name: String, osType: String) {
        let targetLibraryPath = libraryPath(for: osType)
        let newBundlePath = targetLibraryPath + name + ".bundle/"

        // Skip if already exists at destination
        if FileManager.default.fileExists(atPath: newBundlePath) {
            print("VM '\(name)' already exists at destination, skipping migration")
            return
        }

        do {
            try FileManager.default.moveItem(atPath: sourcePath, toPath: newBundlePath)

            // Load or create metadata
            var vmConfig = loadVMMetadata(from: newBundlePath) ?? VMConfiguration(
                name: name,
                bundlePath: newBundlePath,
                cpuCount: 2,
                memorySize: 4 * 1024 * 1024 * 1024,
                diskSize: 64 * 1024 * 1024 * 1024,
                osType: osType
            )

            // Ensure bundle path is updated
            vmConfig.bundlePath = newBundlePath

            // Save metadata
            saveVMMetadata(vmConfig)

            // Add to our list if not already present
            if !virtualMachines.contains(where: { $0.id == vmConfig.id }) {
                virtualMachines.append(vmConfig)
            }

            print("Successfully migrated VM '\(name)' to: \(newBundlePath)")
        } catch {
            print("Failed to migrate VM '\(name)': \(error)")
        }
    }

    // MARK: - VM Loading

    func loadVirtualMachines() {
        virtualMachines.removeAll()

        // Load from both MacOS and Linux directories
        loadVMsFromDirectory(macOSLibraryPath)
        loadVMsFromDirectory(linuxLibraryPath)

        // Sort by last used date (most recent first)
        virtualMachines.sort { vm1, vm2 in
            guard let date1 = vm1.lastUsedDate else { return false }
            guard let date2 = vm2.lastUsedDate else { return true }
            return date1 > date2
        }

        print("Loaded \(virtualMachines.count) VMs from library")
    }

    private func loadVMsFromDirectory(_ directoryPath: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return
        }

        for item in contents {
            if item.hasSuffix(".bundle") {
                let bundlePath = directoryPath + item + "/"
                if let vmConfig = loadVMMetadata(from: bundlePath) {
                    virtualMachines.append(vmConfig)
                }
            }
        }
    }

    private func loadVMMetadata(from bundlePath: String) -> VMConfiguration? {
        let metadataPath = bundlePath + "metadata.json"

        guard FileManager.default.fileExists(atPath: metadataPath) else {
            print("No metadata found at: \(metadataPath)")
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
            let vmConfig = try JSONDecoder().decode(VMConfiguration.self, from: data)
            return vmConfig
        } catch {
            print("Failed to load VM metadata: \(error)")
            return nil
        }
    }

    private func saveVMMetadata(_ vmConfig: VMConfiguration) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(vmConfig)
            try data.write(to: URL(fileURLWithPath: vmConfig.metadataPath))
            print("Saved VM metadata for: \(vmConfig.name)")
        } catch {
            print("Failed to save VM metadata: \(error)")
        }
    }

    // MARK: - VM Creation

    func createVM(name: String,
                  cpuCount: Int,
                  memorySize: UInt64,
                  diskSize: UInt64,
                  osType: String = "Linux") throws -> VMConfiguration {

        // Validate name
        guard !name.isEmpty else {
            throw VMError.invalidName
        }

        // Check for duplicate names
        if virtualMachines.contains(where: { $0.name == name }) {
            throw VMError.duplicateName
        }

        // Determine the appropriate library path based on OS type
        let targetLibraryPath = libraryPath(for: osType)

        // Create bundle path in the appropriate directory
        let bundlePath = targetLibraryPath + name + ".bundle/"

        // Check if bundle already exists
        if FileManager.default.fileExists(atPath: bundlePath) {
            throw VMError.bundleExists
        }

        // Create bundle directory
        try FileManager.default.createDirectory(atPath: bundlePath,
                                               withIntermediateDirectories: true)

        // Create VM configuration
        let vmConfig = VMConfiguration(
            name: name,
            bundlePath: bundlePath,
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskSize: diskSize,
            osType: osType
        )

        // Create disk image
        try createDiskImage(at: vmConfig.diskImagePath, size: diskSize)

        // Create EFI variable store
        try createEFIVariableStore(at: vmConfig.nvramPath)

        // Create machine identifier
        try createMachineIdentifier(at: vmConfig.machineIdentifierPath)

        // Save metadata
        saveVMMetadata(vmConfig)

        // Add to list
        virtualMachines.append(vmConfig)

        print("Created new VM: \(name) (OS: \(osType)) at \(bundlePath)")

        return vmConfig
    }

    private func createDiskImage(at path: String, size: UInt64) throws {
        let diskFd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        if diskFd == -1 {
            throw VMError.diskCreationFailed
        }

        // Using ftruncate to create a sparse file
        let result = ftruncate(diskFd, off_t(size))
        if result != 0 {
            close(diskFd)
            throw VMError.diskCreationFailed
        }

        close(diskFd)
    }

    private func createEFIVariableStore(at path: String) throws {
        _ = try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: path))
    }

    private func createMachineIdentifier(at path: String) throws {
        let machineIdentifier = VZGenericMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - VM Management

    func deleteVM(_ vmConfig: VMConfiguration) throws {
        // Remove bundle from disk
        try FileManager.default.removeItem(atPath: vmConfig.bundlePath)

        // Remove from list
        virtualMachines.removeAll { $0.id == vmConfig.id }

        print("Deleted VM: \(vmConfig.name)")
    }

    func renameVM(_ vmConfig: VMConfiguration, newName: String) throws {
        guard !newName.isEmpty else {
            throw VMError.invalidName
        }

        // Check for duplicate names
        if virtualMachines.contains(where: { $0.name == newName && $0.id != vmConfig.id }) {
            throw VMError.duplicateName
        }

        // Create new bundle path in the same library (preserve OS type)
        let targetLibraryPath = libraryPath(for: vmConfig.osType)
        let newBundlePath = targetLibraryPath + newName + ".bundle/"

        // Check if new bundle path already exists
        if FileManager.default.fileExists(atPath: newBundlePath) {
            throw VMError.bundleExists
        }

        // Move bundle
        try FileManager.default.moveItem(atPath: vmConfig.bundlePath, toPath: newBundlePath)

        // Update configuration
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index].name = newName
            virtualMachines[index].bundlePath = newBundlePath

            // Save updated metadata
            saveVMMetadata(virtualMachines[index])
        }

        print("Renamed VM from '\(vmConfig.name)' to '\(newName)'")
    }

    func cloneVM(_ vmConfig: VMConfiguration, newName: String) throws -> VMConfiguration {
        guard !newName.isEmpty else {
            throw VMError.invalidName
        }

        // Check for duplicate names
        if virtualMachines.contains(where: { $0.name == newName }) {
            throw VMError.duplicateName
        }

        // Create new bundle path in the same library (preserve OS type)
        let targetLibraryPath = libraryPath(for: vmConfig.osType)
        let newBundlePath = targetLibraryPath + newName + ".bundle/"

        // Check if new bundle path already exists
        if FileManager.default.fileExists(atPath: newBundlePath) {
            throw VMError.bundleExists
        }

        // Copy entire bundle while excluding .DS_Store and other hidden files
        try copyVMBundle(from: vmConfig.bundlePath, to: newBundlePath)

        // Create new VM configuration with new ID
        let newConfig = VMConfiguration(
            name: newName,
            bundlePath: newBundlePath,
            cpuCount: vmConfig.cpuCount,
            memorySize: vmConfig.memorySize,
            diskSize: vmConfig.diskSize,
            osType: vmConfig.osType
        )

        // Generate new machine identifier
        try createMachineIdentifier(at: newConfig.machineIdentifierPath)

        // Save metadata
        saveVMMetadata(newConfig)

        // Add to list
        virtualMachines.append(newConfig)

        print("Cloned VM '\(vmConfig.name)' to '\(newName)'")

        return newConfig
    }

    func importVM(from sourcePath: String, name: String, osType: String = "Linux") throws -> VMConfiguration {
        guard !name.isEmpty else {
            throw VMError.invalidName
        }

        // Check if source exists
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw VMError.importSourceNotFound
        }

        // Check for duplicate names
        if virtualMachines.contains(where: { $0.name == name }) {
            throw VMError.duplicateName
        }

        // Determine the appropriate library path based on OS type
        let targetLibraryPath = libraryPath(for: osType)

        // Create new bundle path
        let newBundlePath = targetLibraryPath + name + ".bundle/"

        // Check if new bundle path already exists
        if FileManager.default.fileExists(atPath: newBundlePath) {
            throw VMError.bundleExists
        }

        // Copy bundle while excluding .DS_Store and other hidden files
        try copyVMBundle(from: sourcePath, to: newBundlePath)

        // Try to load existing metadata or create new
        var vmConfig = loadVMMetadata(from: newBundlePath) ?? VMConfiguration(
            name: name,
            bundlePath: newBundlePath,
            cpuCount: 2,
            memorySize: 4 * 1024 * 1024 * 1024,
            diskSize: 64 * 1024 * 1024 * 1024,
            osType: osType
        )

        // Update name and OS type to match requested values
        vmConfig.name = name
        vmConfig.bundlePath = newBundlePath
        vmConfig.osType = osType

        // Save metadata
        saveVMMetadata(vmConfig)

        // Add to list
        virtualMachines.append(vmConfig)

        print("Imported VM from '\(sourcePath)' as '\(name)' (OS: \(osType))")

        return vmConfig
    }

    func updateLastUsedDate(_ vmConfig: VMConfiguration) {
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index].lastUsedDate = Date()
            saveVMMetadata(virtualMachines[index])
        }
    }

    func updateVMStatus(_ vmConfig: VMConfiguration, status: VMStatus) {
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index].status = status
            print("Updated VM '\(vmConfig.name)' status to: \(virtualMachines[index].statusDisplayString)")

            // Post notification so library window can refresh
            NotificationCenter.default.post(name: .vmStatusChanged, object: virtualMachines[index])
        }
    }

    // MARK: - Helper Methods

    private func copyVMBundle(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default

        // Create destination directory
        try fileManager.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)

        // Get contents of source directory
        let contents = try fileManager.contentsOfDirectory(atPath: sourcePath)

        // Files to exclude (system files and temporary files)
        let excludedFiles: Set<String> = [".DS_Store", ".localized", ".Trashes", ".Spotlight-V100", ".fseventsd"]

        for item in contents {
            // Skip hidden files, system files, and nested bundles
            if item.hasPrefix(".") || excludedFiles.contains(item) || item.hasSuffix(".bundle") {
                continue
            }

            let sourceItemPath = sourcePath.hasSuffix("/") ? sourcePath + item : sourcePath + "/" + item
            let destItemPath = destinationPath.hasSuffix("/") ? destinationPath + item : destinationPath + "/" + item

            // Copy the item
            do {
                try fileManager.copyItem(atPath: sourceItemPath, toPath: destItemPath)
            } catch {
                print("Warning: Failed to copy \(item): \(error.localizedDescription)")
                // Continue copying other files even if one fails
            }
        }
    }
}

// MARK: - Errors

enum VMError: LocalizedError {
    case invalidName
    case duplicateName
    case bundleExists
    case diskCreationFailed
    case importSourceNotFound

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "VM name cannot be empty"
        case .duplicateName:
            return "A VM with this name already exists"
        case .bundleExists:
            return "VM bundle already exists at this location"
        case .diskCreationFailed:
            return "Failed to create disk image"
        case .importSourceNotFound:
            return "Import source not found"
        }
    }
}
