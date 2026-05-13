//
//  VMManager.swift
//  SecVF
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

    private var isInitialized = false
    private let initQueue = DispatchQueue(label: "com.secvf.vmmanager.init", qos: .userInitiated)

    private init() {
        // New structure: ~/.avf/MacOS/ and ~/.avf/Linux/
        avfBasePath = NSHomeDirectory() + "/.avf/"
        macOSLibraryPath = avfBasePath + "MacOS/"
        linuxLibraryPath = avfBasePath + "Linux/"

        // Legacy path for migration
        legacyVMLibraryPath = NSHomeDirectory() + "/VirtualMachines/"

        // DO NOT perform blocking operations here!
        // Initialization happens asynchronously via initializeAsync()
    }

    /// Asynchronously initialize VMManager (create directories, load VMs, migrate)
    /// - Parameter completion: Called on main thread when initialization is complete
    func initializeAsync(completion: @escaping () -> Void) {
        // Only initialize once
        guard !isInitialized else {
            DispatchQueue.main.async { completion() }
            return
        }

        initQueue.async { [weak self] in
            guard let self = self else { return }

            // Create library directories if they don't exist (I/O on background thread is OK)
            self.createLibraryDirectoryIfNeeded()

            // Migrate old VMs if they exist (BEFORE loading so we pick up migrated VMs)
            self.migrateOldVMIfNeeded()

            // Load VMs from disk on background thread
            var loadedVMs: [VMConfiguration] = []
            self.loadVMsFromDirectory(self.macOSLibraryPath, into: &loadedVMs)
            self.loadVMsFromDirectory(self.linuxLibraryPath, into: &loadedVMs)

            // Sort by last used date
            loadedVMs.sort { vm1, vm2 in
                guard let date1 = vm1.lastUsedDate else { return false }
                guard let date2 = vm2.lastUsedDate else { return true }
                return date1 > date2
            }

            // Update virtualMachines array on MAIN THREAD to avoid race conditions
            DispatchQueue.main.async {
                self.virtualMachines = loadedVMs
                self.isInitialized = true
                print("Loaded \(self.virtualMachines.count) VMs from library")
                completion()
            }
        }
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

            // Save metadata — propagate to outer do/catch on failure.
            try saveVMMetadata(vmConfig)

            // Don't add to virtualMachines here - it will be loaded by loadVMsFromDirectory
            // This avoids race conditions with the main thread

            print("Successfully migrated VM '\(name)' to: \(newBundlePath)")
        } catch {
            print("Failed to migrate VM '\(name)': \(error)")
        }
    }

    // MARK: - VM Loading
    // Note: VM loading now happens via initializeAsync() to avoid blocking the main thread

    private func loadVMsFromDirectory(_ directoryPath: String, into vms: inout [VMConfiguration]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
            return
        }

        for item in contents {
            if item.hasSuffix(".bundle") {
                let bundlePath = directoryPath + item + "/"
                if let vmConfig = loadVMMetadata(from: bundlePath) {
                    vms.append(vmConfig)
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

    /// Persist a VM's metadata.json. THROWS so callers can detect disk-full
    /// or read-only-volume failures and roll back the rest of the operation.
    ///
    /// Before this was `throws`, a failed write silently left the VM in the
    /// in-memory `virtualMachines` array with no metadata on disk — next
    /// launch couldn't see it. Migration/rename/update paths that genuinely
    /// can't fail loudly should use `try?` and log the error.
    private func saveVMMetadata(_ vmConfig: VMConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(vmConfig)
        try data.write(to: URL(fileURLWithPath: vmConfig.metadataPath))
        print("Saved VM metadata for: \(vmConfig.name)")
    }

    /// Public method to save VM configuration (for updating network settings, etc.)
    func saveVMConfiguration(_ vmConfig: VMConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(vmConfig)
        try data.write(to: URL(fileURLWithPath: vmConfig.metadataPath))
        print("Saved VM configuration for: \(vmConfig.name)")

        // Update in-memory copy
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index] = vmConfig
        }
    }

    // MARK: - VM Creation

    func createVM(name: String,
                  cpuCount: Int,
                  memorySize: UInt64,
                  diskSize: UInt64,
                  osType: String = "Linux") throws -> VMConfiguration {

        // SECURITY: Validate name and prevent path traversal attacks
        // Reject empty names, path separators, parent directory references, hidden files, and overly long names
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(".."),
              !name.hasPrefix("."),
              name.utf8.count <= 255 else {
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

        // From here on, ANY failure must roll back the partial bundle
        // directory — otherwise the next `createVM(name:)` with the same
        // name hits a `bundleExists` error against stale junk from a
        // previous half-finished attempt, with no UI hint that it's stale.
        do {
            try createDiskImage(at: vmConfig.diskImagePath, size: diskSize)
            try createEFIVariableStore(at: vmConfig.nvramPath)
            try createMachineIdentifier(at: vmConfig.machineIdentifierPath)
            try saveVMMetadata(vmConfig)
        } catch {
            // Rollback: remove the partial bundle and re-throw so the
            // caller (UI alert / CLI) sees the real underlying error.
            try? FileManager.default.removeItem(atPath: bundlePath)
            throw error
        }

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
        // SECURITY: Validate name and prevent path traversal attacks
        guard !newName.isEmpty,
              !newName.contains("/"),
              !newName.contains("\\"),
              !newName.contains(".."),
              !newName.hasPrefix("."),
              newName.utf8.count <= 255 else {
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

            // Save updated metadata — propagate failures (function is throws).
            // If this fails after the directory move succeeded, the bundle is
            // already at the new path; we surface the error so the user can
            // re-attempt the save rather than silently end up with a VM whose
            // on-disk metadata still has the old name.
            try saveVMMetadata(virtualMachines[index])
        }

        print("Renamed VM from '\(vmConfig.name)' to '\(newName)'")
    }

    func cloneVM(_ vmConfig: VMConfiguration, newName: String) throws -> VMConfiguration {
        // SECURITY: Validate name and prevent path traversal attacks
        guard !newName.isEmpty,
              !newName.contains("/"),
              !newName.contains("\\"),
              !newName.contains(".."),
              !newName.hasPrefix("."),
              newName.utf8.count <= 255 else {
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

        // From here on, ANY failure must roll back the copied bundle —
        // see same rationale as createVM (avoid stale-junk collisions on
        // the next attempt).
        do {
            try createMachineIdentifier(at: newConfig.machineIdentifierPath)
            try saveVMMetadata(newConfig)
        } catch {
            try? FileManager.default.removeItem(atPath: newBundlePath)
            throw error
        }

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

        // Roll back the copied bundle if save fails — same rationale as
        // createVM and cloneVM (avoid stale-junk collisions on next attempt).
        do {
            try saveVMMetadata(vmConfig)
        } catch {
            try? FileManager.default.removeItem(atPath: newBundlePath)
            throw error
        }

        // Add to list
        virtualMachines.append(vmConfig)

        print("Imported VM from '\(sourcePath)' as '\(name)' (OS: \(osType))")

        return vmConfig
    }

    func updateLastUsedDate(_ vmConfig: VMConfiguration) {
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index].lastUsedDate = Date()
            // Fire-and-forget — losing the last-used timestamp on disk-full
            // doesn't justify breaking the UI flow. Log and move on.
            do {
                try saveVMMetadata(virtualMachines[index])
            } catch {
                print("Warning: failed to persist last-used date for \(vmConfig.name): \(error)")
            }
        }
    }

    func getRunningVMsCount() -> Int {
        return virtualMachines.filter { $0.status == .running || $0.status == .starting }.count
    }

    func getRunningVMs() -> [VMConfiguration] {
        return virtualMachines.filter { $0.status == .running || $0.status == .starting }
    }

    func updateVMStatus(_ vmConfig: VMConfiguration, status: VMStatus) {
        if let index = virtualMachines.firstIndex(where: { $0.id == vmConfig.id }) {
            virtualMachines[index].status = status
            print("Updated VM '\(vmConfig.name)' status to: \(virtualMachines[index].statusDisplayString)")

            // Post notification on main thread to ensure UI observers run consistently
            // (delegate callbacks may come from background threads)
            let updatedVM = virtualMachines[index]
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .vmStatusChanged, object: updatedVM)
            }
        }
    }

    // MARK: - Network peers

    /// Other VMs that share a virtual-switch network group with `vm`. The
    /// group is defined by the router relationship:
    ///   - Router VM (isRouter == true): peers = all VMs that route
    ///     through it (routerVMId == vm.id).
    ///   - Guest VM (routerVMId != nil): peers = the router + every
    ///     other guest sharing the same router.
    /// Returns empty for NAT-mode VMs (they don't share an L2 network),
    /// and empty for virtual-mode VMs with no router assignment yet.
    ///
    /// The library window's table draws connector brackets between rows
    /// of running peers so the operator can see "these two VMs are
    /// talking to each other" at a glance.
    func networkPeers(of vm: VMConfiguration) -> [VMConfiguration] {
        guard vm.networkConfig.mode == .virtual else { return [] }

        if vm.networkConfig.isRouter {
            // Router → return its guests (any VMs whose routerVMId matches us)
            return virtualMachines.filter {
                $0.id != vm.id &&
                $0.networkConfig.mode == .virtual &&
                $0.networkConfig.routerVMId == vm.id
            }
        }
        if let routerId = vm.networkConfig.routerVMId {
            // Guest → return the router + all sibling guests
            return virtualMachines.filter {
                $0.id != vm.id &&
                $0.networkConfig.mode == .virtual &&
                ($0.id == routerId || $0.networkConfig.routerVMId == routerId)
            }
        }
        return []
    }

    // MARK: - Disk usage

    /// Per-bundle on-disk size cache. Keys: bundle path. Values: (bytes, asOf).
    /// Background-refreshed by `onDiskBundleSize(for:)`. Walking a 64 GB sparse
    /// disk.img to sum its physical size can take 100–300 ms even with
    /// `URLResourceKey.totalFileAllocatedSizeKey`, so we never block the main
    /// thread on it — the UI reads the cached value and a background task
    /// updates the cache + posts a notification when it's done.
    private var bundleSizeCache: [String: (bytes: Int64, asOf: Date)] = [:]
    private let bundleSizeCacheLock = NSLock()
    private static let bundleSizeStaleAfter: TimeInterval = 30  // seconds

    /// Returns the cached on-disk size for a VM bundle (bytes). Triggers a
    /// background refresh if the cache entry is missing or older than 30s.
    /// Callers should observe `.vmBundleSizeUpdated` on the main run loop
    /// and re-read this value when it fires.
    func onDiskBundleSize(for vm: VMConfiguration) -> Int64? {
        let path = vm.bundlePath
        let now = Date()

        bundleSizeCacheLock.lock()
        let cached = bundleSizeCache[path]
        bundleSizeCacheLock.unlock()

        let isStale = cached.map { now.timeIntervalSince($0.asOf) > Self.bundleSizeStaleAfter } ?? true
        if isStale {
            refreshBundleSize(forBundleAt: path, vmId: vm.id)
        }
        return cached?.bytes
    }

    private func refreshBundleSize(forBundleAt path: String, vmId: UUID) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let size = Self.measureBundleSize(at: path)

            self.bundleSizeCacheLock.lock()
            self.bundleSizeCache[path] = (size, Date())
            self.bundleSizeCacheLock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .vmBundleSizeUpdated,
                    object: vmId,
                    userInfo: ["bytes": size]
                )
            }
        }
    }

    /// Sum the allocated-on-disk size of every file inside the bundle.
    /// Uses `totalFileAllocatedSize` so we count the physical disk usage of
    /// sparse files (a 64 GB disk.img with 12 GB written returns ~12 GB,
    /// not 64 GB).
    private static func measureBundleSize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey,
                                                                     .totalFileAllocatedSizeKey,
                                                                     .fileAllocatedSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
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
