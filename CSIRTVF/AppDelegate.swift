/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app delegate that sets up and starts the virtual machine.
*/

import Virtualization

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate, NSWindowDelegate {

    // Multi-VM architecture - manage separate windows for each running VM
    private var vmWindows: [UUID: NSWindow] = [:]
    private var virtualMachines: [UUID: VZVirtualMachine] = [:]
    private var vmConfigs: [UUID: VMConfiguration] = [:]
    private var vmViews: [UUID: VZVirtualMachineView] = [:]
    private var installerISOPaths: [UUID: URL] = [:]
    private var needsInstallFlags: [UUID: Bool] = [:]

    private var libraryWindowController: VMLibraryWindowController?

    // Log viewer windows (retained to prevent deallocation)
    private var securityLogViewer: LogViewerWindowController?
    private var networkLogViewer: LogViewerWindowController?

    // Installation status overlay
    private var installationStatusView: NSTextField?
    private var isoCacheLogViewer: LogViewerWindowController?

    // Scripts USB attachment tracking
    private var attachScriptsUSBFlags: [UUID: Bool] = [:]

    // Switch statistics window (retained to prevent deallocation)
    // TODO: Uncomment when SwitchStatisticsWindowController.swift is added to Xcode project
    // private var switchStatisticsWindow: SwitchStatisticsWindowController?

    // Packet Analysis window (retained to prevent deallocation)
    private var packetAnalysisWindow: PacketAnalysisWindowController?

    // ISO Cache Manager window (retained to prevent deallocation)
    // TODO: Add ISOCacheManagerWindow.swift to Xcode project
    // private var isoCacheManagerWindow: ISOCacheManagerWindow?

    // Splash screen (retained while showing)
    private var splashScreen: SplashScreenWindow?

    override init() {
        super.init()

        // Register for notifications from library window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStartVM(_:)),
            name: .startVM,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStartVMWithISO(_:)),
            name: .startVMWithISO,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopVM(_:)),
            name: .stopVM,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePauseVM(_:)),
            name: .pauseVM,
            object: nil
        )

        // Register for CLI distributed notifications (cross-process)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIStartVM(_:)),
            name: NSNotification.Name("com.secvf.cli.start"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIStopVM(_:)),
            name: NSNotification.Name("com.secvf.cli.stop"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIForceStopVM(_:)),
            name: NSNotification.Name("com.secvf.cli.force-stop"),
            object: nil
        )
    }

    // MARK: - Notification Handlers

    @objc private func handleStartVM(_ notification: Notification) {
        guard let vm = notification.object as? VMConfiguration else { return }

        // Store VM config in dictionary
        vmConfigs[vm.id] = vm

        var needsInstall = false
        var installerISOPath: URL? = nil

        // For macOS VMs, check if installation is needed by checking the macOSInstalled flag
        if vm.osType == "macOS" {
            // If macOSInstalled is nil or false, VM needs installation
            if vm.macOSInstalled != true {
                // macOS VM needs installation - find and attach cached IPSW
                NSLog("[macOS VM] macOS not yet installed (macOSInstalled=%@), VM needs installation",
                      vm.macOSInstalled == nil ? "nil" : "false")
                needsInstall = true

                // Find cached IPSW in ~/.avf/MacOS/
                let macOSCacheDir = NSHomeDirectory() + "/.avf/MacOS/"
                if let cachedIPSW = findCachedIPSW(in: macOSCacheDir) {
                    NSLog("[macOS VM] Found cached IPSW: %@", cachedIPSW.path)
                    installerISOPath = cachedIPSW
                } else {
                    NSLog("[macOS VM] ERROR: No cached IPSW found in %@", macOSCacheDir)
                    // Show error to user
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "macOS Install Image Not Found"
                        alert.informativeText = "This macOS VM needs to be installed, but no IPSW file was found in ~/.avf/MacOS/\n\nPlease download the macOS restore image first."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
            } else {
                // macOS is already installed
                NSLog("[macOS VM] macOS already installed")
                needsInstall = false
                installerISOPath = nil
            }
        } else {
            // Linux VM - check if OS is installed
            if vm.osInstalled == false {
                // Linux VM needs installation - find cached ISO
                NSLog("[Linux VM] OS not yet installed (osInstalled=%@), VM needs installation",
                      vm.osInstalled == nil ? "nil" : "false")
                needsInstall = true

                // Find cached ISO based on distro in metadata
                // For legacy VMs without distro info, try to infer from VM name
                var linuxDistro = vm.linuxDistribution
                var linuxVersion = vm.linuxVersion

                if linuxDistro == nil || linuxVersion == nil {
                    NSLog("[Linux VM] Missing distro/version in metadata, inferring from VM name: %@", vm.name)
                    // Try to infer from VM name (e.g., "Kali Router" -> Kali 2024.1)
                    let vmNameLower = vm.name.lowercased()
                    if vmNameLower.contains("kali") {
                        linuxDistro = "Kali"
                        linuxVersion = "2024.1"
                        NSLog("[Linux VM] Inferred: Kali 2024.1")
                    } else if vmNameLower.contains("ubuntu") {
                        linuxDistro = "Ubuntu Desktop"
                        linuxVersion = "24.04"
                        NSLog("[Linux VM] Inferred: Ubuntu Desktop 24.04")
                    } else if vmNameLower.contains("debian") {
                        linuxDistro = "Debian"
                        linuxVersion = "12.0"
                        NSLog("[Linux VM] Inferred: Debian 12.0")
                    } else {
                        NSLog("[Linux VM] ERROR: Cannot infer distro from VM name")
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Linux VM Configuration Error"
                            alert.informativeText = "This Linux VM is missing distribution information.\n\nVM Name: \(vm.name)\n\nPlease recreate the VM or add distro info to metadata manually."
                            alert.alertStyle = .critical
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                        return
                    }
                }

                guard let distro = linuxDistro, let version = linuxVersion else {
                    return  // Should not reach here
                }

                // Check if ISO is already cached using ISOCacheManager
                let vmImageType = VMImageType.linux(distro: LinuxDistro(rawValue: distro) ?? .kali, version: version, isSecurityRouter: vm.networkConfig.isRouter)

                if let cachedISO = ISOCacheManager.shared.getCachedImage(for: vmImageType) {
                    NSLog("[Linux VM] Found cached ISO: %@", cachedISO.path)
                    installerISOPath = cachedISO
                } else {
                    NSLog("[Linux VM] ERROR: No cached ISO found for %@ %@", distro, version)
                    // Show error to user - they should have downloaded during VM creation
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Linux Install Image Not Found"
                        alert.informativeText = "This VM needs to be installed, but no cached ISO was found for \(distro) \(version).\n\nPlease delete this VM and create a new one to download the ISO."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
            } else {
                // Linux OS is already installed
                NSLog("[Linux VM] OS already installed")
                needsInstall = false
                installerISOPath = nil
            }
        }

        // Store installation info for this VM
        needsInstallFlags[vm.id] = needsInstall
        if let isoPath = installerISOPath {
            installerISOPaths[vm.id] = isoPath
        }

        // Validate network configuration before starting VM
        if let error = validateNetworkConfiguration(vm) {
            NSLog("[Network] VM start blocked: %@", error)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Network Configuration Error"
                alert.informativeText = error
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            // Clean up stored config since we're not starting the VM
            vmConfigs.removeValue(forKey: vm.id)
            needsInstallFlags.removeValue(forKey: vm.id)
            installerISOPaths.removeValue(forKey: vm.id)
            return
        }

        showMainWindowAndStartVM(for: vm.id)
    }

    /// Validates that the network configuration is valid before starting a VM
    /// Returns nil if valid, or an error message string if invalid
    private func validateNetworkConfiguration(_ vm: VMConfiguration) -> String? {
        // Only validate VM-to-VM (virtual) network mode
        guard vm.networkConfig.mode == .virtual else { return nil }

        // For macOS VMs using VM-to-VM networking, validate router VM is available and running
        if vm.osType == "macOS", let routerVMId = vm.networkConfig.routerVMId {
            // Check if router VM exists
            guard let routerVM = VMManager.shared.virtualMachines.first(where: { $0.id == routerVMId }) else {
                return "Router VM not found.\n\nThis macOS VM is configured to route through a Linux router VM, but the router VM no longer exists. Please reconfigure the VM's network settings."
            }

            // Check if router VM is actually configured as a router
            guard routerVM.networkConfig.isRouter else {
                return "The VM '\(routerVM.name)' is not configured as a router.\n\nThis macOS VM requires a router VM, but '\(routerVM.name)' is not set up as a router. Please select a different router VM or configure '\(routerVM.name)' as a router."
            }

            // Check if router VM is running
            guard routerVM.status == .running else {
                return "Router VM '\(routerVM.name)' is not running.\n\nThis macOS VM requires the router VM to be running first. Please start '\(routerVM.name)' before starting this VM."
            }

            NSLog("[Network] Validated: macOS VM '%@' will route through running router VM '%@'", vm.name, routerVM.name)
        }

        // For Linux router VMs, just log that they're starting as routers
        if vm.networkConfig.isRouter {
            NSLog("[Network] Starting Linux router VM '%@'", vm.name)
        }

        return nil  // Validation passed
    }

    private func findCachedIPSW(in directory: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        // Look for any .ipsw file
        for file in contents {
            if file.hasSuffix(".ipsw") {
                let ipswPath = directory + file
                if FileManager.default.fileExists(atPath: ipswPath) {
                    return URL(fileURLWithPath: ipswPath)
                }
            }
        }

        return nil
    }

    private func findCachedISO(in directory: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        // Look for any .iso file
        for file in contents {
            if file.hasSuffix(".iso") {
                let isoPath = directory + file
                if FileManager.default.fileExists(atPath: isoPath) {
                    return URL(fileURLWithPath: isoPath)
                }
            }
        }

        return nil
    }

    @objc private func handleStartVMWithISO(_ notification: Notification) {
        guard let info = notification.object as? [String: Any],
              let vm = info["vm"] as? VMConfiguration,
              let iso = info["iso"] as? URL else { return }

        // Store VM config in dictionary
        vmConfigs[vm.id] = vm
        needsInstallFlags[vm.id] = true
        installerISOPaths[vm.id] = iso

        showMainWindowAndStartVM(for: vm.id)
    }

    @objc private func handleStopVM(_ notification: Notification) {
        guard let vm = notification.object as? VMConfiguration else { return }

        NSLog("[AppDelegate] Stop VM requested: \(vm.name)")

        // Find the running VZVirtualMachine for this VM
        guard let virtualMachine = virtualMachines[vm.id] else {
            NSLog("[AppDelegate] VM \(vm.name) is not running")
            return
        }

        // Request graceful stop
        virtualMachine.stop { error in
            if let error = error {
                NSLog("[AppDelegate] Error stopping VM \(vm.name): \(error)")
                // If graceful stop fails, try requestStop (sends ACPI power button)
                do {
                    try virtualMachine.requestStop()
                    NSLog("[AppDelegate] Sent stop request to VM \(vm.name)")
                } catch let stopError {
                    NSLog("[AppDelegate] Failed to request stop for VM \(vm.name): \(stopError)")
                }
            } else {
                NSLog("[AppDelegate] VM \(vm.name) stopped successfully")
            }
        }
    }

    @objc private func handlePauseVM(_ notification: Notification) {
        guard let vm = notification.object as? VMConfiguration else { return }

        NSLog("[AppDelegate] Pause/Resume VM requested: \(vm.name)")

        // Find the running VZVirtualMachine for this VM
        guard let virtualMachine = virtualMachines[vm.id] else {
            NSLog("[AppDelegate] VM \(vm.name) is not running")
            return
        }

        // Toggle pause state
        if virtualMachine.state == .paused {
            virtualMachine.resume { result in
                switch result {
                case .success:
                    NSLog("[AppDelegate] VM \(vm.name) resumed")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .vmStatusChanged, object: nil)
                    }
                case .failure(let error):
                    NSLog("[AppDelegate] Error resuming VM \(vm.name): \(error)")
                }
            }
        } else if virtualMachine.state == .running {
            virtualMachine.pause { result in
                switch result {
                case .success:
                    NSLog("[AppDelegate] VM \(vm.name) paused")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .vmStatusChanged, object: nil)
                    }
                case .failure(let error):
                    NSLog("[AppDelegate] Error pausing VM \(vm.name): \(error)")
                }
            }
        } else {
            NSLog("[AppDelegate] Cannot pause/resume VM \(vm.name) in state: \(virtualMachine.state.rawValue)")
        }
    }

    // MARK: - CLI Notification Handlers (Distributed Notifications)

    @objc private func handleCLIStartVM(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let vmName = userInfo["vmName"] as? String else {
            NSLog("[CLI] Start VM notification missing vmName")
            return
        }

        NSLog("[CLI] Start VM requested: \(vmName)")

        // Find VM by name from VMManager
        let allVMs = VMManager.shared.virtualMachines

        guard let vm = allVMs.first(where: { $0.name == vmName }) else {
            NSLog("[CLI] VM not found: \(vmName)")
            return
        }

        // Dispatch to main thread and start VM using existing mechanism
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .startVM, object: vm)
        }
    }

    @objc private func handleCLIStopVM(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let vmName = userInfo["vmName"] as? String else {
            NSLog("[CLI] Stop VM notification missing vmName")
            return
        }

        NSLog("[CLI] Stop VM requested: \(vmName)")

        // Find VM by name from VMManager
        let allVMs = VMManager.shared.virtualMachines

        guard let vm = allVMs.first(where: { $0.name == vmName }) else {
            NSLog("[CLI] VM not found: \(vmName)")
            return
        }

        // Dispatch to main thread and stop VM using existing mechanism
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .stopVM, object: vm)
        }
    }

    @objc private func handleCLIForceStopVM(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let vmName = userInfo["vmName"] as? String else {
            NSLog("[CLI] Force-stop VM notification missing vmName")
            return
        }

        NSLog("[CLI] Force-stop VM requested: \(vmName)")

        // Find the running VM by name and force stop it
        for (vmId, vm) in vmConfigs {
            if vm.name == vmName {
                if let virtualMachine = virtualMachines[vmId] {
                    NSLog("[CLI] Force stopping VM: \(vmName)")
                    Task { @MainActor in
                        do {
                            try await virtualMachine.stop()
                            NSLog("[CLI] VM force stopped: \(vmName)")
                            NotificationCenter.default.post(name: .vmStatusChanged, object: nil)
                        } catch {
                            NSLog("[CLI] Error force stopping VM: \(error)")
                        }
                    }
                }
                return
            }
        }
        NSLog("[CLI] VM not running or not found: \(vmName)")
    }

    private func showMainWindowAndStartVM(for vmId: UUID) {
        guard let vm = vmConfigs[vmId] else { return }

        // Create a new window for this VM
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SecVF - \(vm.name)"
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(vmId.uuidString)

        // Create a VZVirtualMachineView for this VM
        let vmView = VZVirtualMachineView()
        vmView.frame = window.contentView!.bounds
        vmView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(vmView)

        // Store window and view
        vmWindows[vmId] = window
        vmViews[vmId] = vmView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        configureAndStartVirtualMachine(for: vmId)
    }

    // MARK: Create device configuration objects for the virtual machine.

    private func createBlockDeviceConfiguration(for vmId: UUID) throws -> VZVirtioBlockDeviceConfiguration {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let mainDiskAttachment: VZDiskImageStorageDeviceAttachment
        do {
            mainDiskAttachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: vmConfig.diskImagePath),
                readOnly: false
            )
        } catch {
            throw SecVFError.diskAttachmentFailed(path: vmConfig.diskImagePath, underlying: error)
        }

        return VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
    }

    private func computeCPUCount(for vmId: UUID) -> Int {
        guard let vmConfig = vmConfigs[vmId] else { return VZVirtualMachineConfiguration.minimumAllowedCPUCount }
        var virtualCPUCount = vmConfig.cpuCount
        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

        return virtualCPUCount
    }

    private func computeMemorySize(for vmId: UUID) -> UInt64 {
        guard let vmConfig = vmConfigs[vmId] else { return VZVirtualMachineConfiguration.minimumAllowedMemorySize }
        var memorySize = vmConfig.memorySize
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        return memorySize
    }
    
    private func checkRosetta() {
        switch rosettaAvailability {
        case .notSupported:
            // Alert the user the capability isn't available; offer
            // continuation options according to your app's requirements.
            print("Rosetta is not supported on this system")

        case .notInstalled:
            // Ask the user for permission to install Rosetta, and
            // start the installation process if they grant permission.
            print("Rosetta is not installed")

        case .installed:
            print("Rosetta is available")

        @unknown default:
            break
        }
    }

    private func createAndSaveMachineIdentifier(for vmId: UUID) throws -> VZGenericMachineIdentifier {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let machineIdentifier = VZGenericMachineIdentifier()

        // Store the machine identifier to disk so you can retrieve it for subsequent boots.
        do {
            try machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmConfig.machineIdentifierPath))
        } catch {
            throw SecVFError.machineIdentifierCreationFailed
        }
        return machineIdentifier
    }

    private func retrieveMachineIdentifier(for vmId: UUID) throws -> VZGenericMachineIdentifier {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        // Retrieve the machine identifier.
        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: vmConfig.machineIdentifierPath)) else {
            throw SecVFError.machineIdentifierNotFound(path: vmConfig.machineIdentifierPath)
        }

        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            throw SecVFError.machineIdentifierDataInvalid
        }

        return machineIdentifier
    }

    private func createEFIVariableStore(for vmId: UUID) throws -> VZEFIVariableStore {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let nvramURL = URL(fileURLWithPath: vmConfig.nvramPath)

        // Remove existing NVRAM file if it exists
        if FileManager.default.fileExists(atPath: vmConfig.nvramPath) {
            try? FileManager.default.removeItem(at: nvramURL)
        }

        guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: nvramURL) else {
            throw SecVFError.nvramCreationFailed(path: vmConfig.nvramPath)
        }

        return efiVariableStore
    }

    private func retrieveEFIVariableStore(for vmId: UUID) throws -> VZEFIVariableStore {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        if !FileManager.default.fileExists(atPath: vmConfig.nvramPath) {
            throw SecVFError.nvramNotFound(path: vmConfig.nvramPath)
        }

        return VZEFIVariableStore(url: URL(fileURLWithPath: vmConfig.nvramPath))
    }

    private func createUSBMassStorageDeviceConfiguration(for vmId: UUID) throws -> VZUSBMassStorageDeviceConfiguration {
        guard let installerISOPath = installerISOPaths[vmId] else {
            throw SecVFError.installerISONotFound(vmId: vmId)
        }

        guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: installerISOPath, readOnly: true) else {
            throw SecVFError.installerAttachmentFailed(path: installerISOPath.path)
        }

        return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
    }

    private func createScriptsUSBConfiguration(forMacOS: Bool) -> VZUSBMassStorageDeviceConfiguration? {
        if forMacOS {
            // macOS: Use read-only ISO (macOS can run scripts directly)
            guard let scriptsISOURL = ScriptsUSBManager.shared.scriptsISOURL else {
                NSLog("[ScriptsUSB] Scripts ISO not found")
                return nil
            }

            guard let scriptsAttachment = try? VZDiskImageStorageDeviceAttachment(url: scriptsISOURL, readOnly: true) else {
                NSLog("[ScriptsUSB] Failed to create scripts ISO attachment")
                return nil
            }

            return VZUSBMassStorageDeviceConfiguration(attachment: scriptsAttachment)
        } else {
            // Linux: Use writable FAT32 disk image (user can chmod +x)
            guard let scriptsDiskURL = ScriptsUSBManager.shared.scriptsDiskURL else {
                NSLog("[ScriptsUSB] Scripts disk image not found")
                return nil
            }

            guard let scriptsAttachment = try? VZDiskImageStorageDeviceAttachment(url: scriptsDiskURL, readOnly: false) else {
                NSLog("[ScriptsUSB] Failed to create scripts disk attachment")
                return nil
            }

            return VZUSBMassStorageDeviceConfiguration(attachment: scriptsAttachment)
        }
    }

    private func createNetworkDeviceConfiguration(for vmId: UUID) throws -> VZVirtioNetworkDeviceConfiguration {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let networkDevice = VZVirtioNetworkDeviceConfiguration()

        // Configure network attachment based on VM's network mode
        switch vmConfig.networkConfig.mode {
        case .nat:
            // Standard NAT networking - VM has internet access
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            print("[Network] Configuring NAT networking for \(vmConfig.name)")

        case .virtual:
            // Virtual switch networking - VM-to-VM communication only
            if let fileHandle = VirtualNetworkSwitch.shared.connectVM(
                vmId: vmConfig.id,
                vmName: vmConfig.name
            ) {
                networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
                print("[Network] Configuring virtual switch networking for \(vmConfig.name)")

                // Log router configuration if applicable
                if vmConfig.networkConfig.isRouter {
                    print("[Network] \(vmConfig.name) configured as virtual network router")
                } else if let routerVMId = vmConfig.networkConfig.routerVMId {
                    print("[Network] \(vmConfig.name) will route through VM: \(routerVMId)")
                }
            } else {
                // Fallback to NAT if virtual switch connection fails
                print("[Network] WARNING: Failed to connect to virtual switch, falling back to NAT")
                networkDevice.attachment = VZNATNetworkDeviceAttachment()
            }
        }

        return networkDevice
    }

    private func createGraphicsDeviceConfiguration(isMacOS: Bool) throws -> VZGraphicsDeviceConfiguration {
        if isMacOS {
            #if arch(arm64)
            // macOS VMs require VZMacGraphicsDeviceConfiguration (Apple Silicon only)
            if #available(macOS 12.0, *) {
                let graphicsDevice = VZMacGraphicsDeviceConfiguration()
                graphicsDevice.displays = [
                    VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)
                ]
                return graphicsDevice
            } else {
                throw SecVFError.macOSVersionTooOld(required: "12.0", current: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            #else
            throw SecVFError.appleSiliconRequired
            #endif
        } else {
            // Linux VMs use VZVirtioGraphicsDeviceConfiguration
            let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
            graphicsDevice.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
            ]
            return graphicsDevice
        }
    }

    private func createInputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let inputAudioDevice = VZVirtioSoundDeviceConfiguration()

        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()

        inputAudioDevice.streams = [inputStream]
        return inputAudioDevice
    }

    private func createOutputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let outputAudioDevice = VZVirtioSoundDeviceConfiguration()

        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()

        outputAudioDevice.streams = [outputStream]
        return outputAudioDevice
    }

    private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()

        let spiceAgentPort = VZVirtioConsolePortConfiguration()
        spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spiceAgentPort

        return consoleDevice
    }

    // MARK: macOS-specific configuration helpers

    #if arch(arm64)
    @available(macOS 12.0, *)
    private func createAndSaveMacMachineIdentifier(for vmId: UUID) throws -> VZMacMachineIdentifier {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let machineIdentifier = VZMacMachineIdentifier()
        do {
            try machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmConfig.machineIdentifierPath))
        } catch {
            throw SecVFError.machineIdentifierCreationFailed
        }
        return machineIdentifier
    }

    @available(macOS 12.0, *)
    private func retrieveMacMachineIdentifier(for vmId: UUID) throws -> VZMacMachineIdentifier {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: vmConfig.machineIdentifierPath)) else {
            throw SecVFError.machineIdentifierNotFound(path: vmConfig.machineIdentifierPath)
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            throw SecVFError.machineIdentifierDataInvalid
        }
        return machineIdentifier
    }

    @available(macOS 12.0, *)
    private func createMacAuxiliaryStorage(for vmId: UUID, hardwareModel: VZMacHardwareModel) throws -> VZMacAuxiliaryStorage {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let auxiliaryStoragePath = vmConfig.bundlePath + "AuxiliaryStorage"
        let auxiliaryStorageURL = URL(fileURLWithPath: auxiliaryStoragePath)

        // Remove existing AuxiliaryStorage if it exists (from incomplete VM creation)
        if FileManager.default.fileExists(atPath: auxiliaryStoragePath) {
            NSLog("[macOS VM] Removing existing AuxiliaryStorage to recreate with proper hardware model")
            try? FileManager.default.removeItem(at: auxiliaryStorageURL)
        }

        guard let auxiliaryStorage = try? VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryStorageURL, hardwareModel: hardwareModel) else {
            throw SecVFError.auxiliaryStorageFailed(path: auxiliaryStoragePath)
        }
        return auxiliaryStorage
    }

    @available(macOS 12.0, *)
    private func retrieveMacAuxiliaryStorage(for vmId: UUID) throws -> VZMacAuxiliaryStorage {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let auxiliaryStoragePath = vmConfig.bundlePath + "AuxiliaryStorage"
        return VZMacAuxiliaryStorage(contentsOf: URL(fileURLWithPath: auxiliaryStoragePath))
    }

    @available(macOS 12.0, *)
    private func createMacHardwareModel(for vmId: UUID) throws -> VZMacHardwareModel {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        // Get hardware model from the IPSW restore image
        guard let restoreImageURL = installerISOPaths[vmId] else {
            throw SecVFError.restoreImageNotProvided
        }

        // Load the restore image to get the hardware model
        let semaphore = DispatchSemaphore(value: 0)
        var hardwareModel: VZMacHardwareModel?

        VZMacOSRestoreImage.load(from: restoreImageURL) { result in
            switch result {
            case .success(let restoreImage):
                hardwareModel = restoreImage.mostFeaturefulSupportedConfiguration?.hardwareModel
            case .failure(let error):
                print("Failed to load restore image: \(error)")
            }
            semaphore.signal()
        }

        semaphore.wait()

        guard let model = hardwareModel else {
            throw SecVFError.restoreImageHardwareModelFailed
        }

        // Save hardware model to disk
        let hardwareModelPath = vmConfig.bundlePath + "HardwareModel"
        do {
            try model.dataRepresentation.write(to: URL(fileURLWithPath: hardwareModelPath))
        } catch {
            throw SecVFError.hardwareModelCreationFailed
        }

        return model
    }

    @available(macOS 12.0, *)
    private func retrieveMacHardwareModel(for vmId: UUID) throws -> VZMacHardwareModel {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let hardwareModelPath = vmConfig.bundlePath + "HardwareModel"
        guard let hardwareModelData = try? Data(contentsOf: URL(fileURLWithPath: hardwareModelPath)) else {
            throw SecVFError.hardwareModelNotFound
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw SecVFError.hardwareModelDataInvalid
        }
        return hardwareModel
    }

    @available(macOS 12.0, *)
    private func installMacOS(for vmId: UUID) {
        NSLog("[macOS Install] Starting macOS installation from IPSW")

        guard let ipswURL = installerISOPaths[vmId] else {
            NSLog("[macOS Install] ERROR: No IPSW URL available for vmId: \(vmId)")
            return
        }

        guard let virtualMachine = virtualMachines[vmId] else {
            NSLog("[macOS Install] ERROR: No virtual machine found for vmId: \(vmId)")
            return
        }

        // Load the restore image
        VZMacOSRestoreImage.load(from: ipswURL) { result in
            switch result {
            case .success(let restoreImage):
                NSLog("[macOS Install] Loaded restore image for macOS \(restoreImage.operatingSystemVersion)")

                // IMPORTANT: VZMacOSInstaller must be created on the main thread
                DispatchQueue.main.async {
                    NSLog("[macOS Install] Creating VZMacOSInstaller...")
                    NSLog("[macOS Install] VM state: \(virtualMachine.state.rawValue)")
                    NSLog("[macOS Install] IPSW URL: \(ipswURL.path)")

                    // Create installer
                    let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: ipswURL)
                    NSLog("[macOS Install] VZMacOSInstaller created successfully")

                NSLog("[macOS Install] Starting installation...")
                // Observe installation progress
                installer.install { [weak self] result in
                    guard let self = self else { return }
                    NSLog("[macOS Install] Install callback received")
                    switch result {
                    case .success:
                        NSLog("[macOS Install] Installation completed successfully!")
                        // Mark as installed and save metadata
                        if var vmConfig = self.vmConfigs[vmId] {
                            vmConfig.macOSInstalled = true
                            self.vmConfigs[vmId] = vmConfig
                            self.needsInstallFlags[vmId] = false

                            // Save metadata AND update VMManager's in-memory copy
                            do {
                                try VMManager.shared.saveVMConfiguration(vmConfig)
                                NSLog("[macOS Install] Metadata saved - macOS marked as installed")
                            } catch {
                                NSLog("[macOS Install] ERROR: Failed to save metadata: \(error)")
                            }
                        }

                        // VM will automatically boot into installed macOS (no restart needed)
                        NSLog("[macOS Install] Installation complete - VM will boot into macOS automatically")

                    case .failure(let error):
                        NSLog("[macOS Install] ERROR: Installation failed: \(error.localizedDescription)")
                    }
                }
                }  // End DispatchQueue.main.async

            case .failure(let error):
                NSLog("[macOS Install] ERROR: Failed to load restore image: \(error.localizedDescription)")
            }
        }
    }
    #endif // arch(arm64) - end of macOS-specific helper functions

    // MARK: Create the virtual machine configuration and instantiate the virtual machine.

    func createVirtualMachine(for vmId: UUID) throws {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.cpuCount = computeCPUCount(for: vmId)
        virtualMachineConfiguration.memorySize = computeMemorySize(for: vmId)

        NSLog("[VM Config] Creating VM with \(virtualMachineConfiguration.cpuCount) CPUs, \(virtualMachineConfiguration.memorySize / 1024 / 1024 / 1024) GB RAM")

        let isMacOS = vmConfig.osType == "macOS"
        let needsInstall = needsInstallFlags[vmId] ?? false
        let disksArray = NSMutableArray()

        if isMacOS {
            #if arch(arm64)
            // macOS VM configuration (Apple Silicon only)
            if #available(macOS 12.0, *) {
                let platform = VZMacPlatformConfiguration()
                let bootloader = VZMacOSBootLoader()

                if needsInstall {
                    // Fresh macOS install from IPSW
                    // Create hardware model first, as it's needed for auxiliary storage
                    let hardwareModel = try createMacHardwareModel(for: vmId)
                    platform.machineIdentifier = try createAndSaveMacMachineIdentifier(for: vmId)
                    platform.auxiliaryStorage = try createMacAuxiliaryStorage(for: vmId, hardwareModel: hardwareModel)
                    platform.hardwareModel = hardwareModel
                    // Note: macOS IPSW is NOT attached as USB storage - installation handled by VZMacOSInstaller after VM creation
                } else {
                    // Boot existing macOS install
                    platform.machineIdentifier = try retrieveMacMachineIdentifier(for: vmId)
                    platform.hardwareModel = try retrieveMacHardwareModel(for: vmId)
                    platform.auxiliaryStorage = try retrieveMacAuxiliaryStorage(for: vmId)
                }

                virtualMachineConfiguration.platform = platform
                virtualMachineConfiguration.bootLoader = bootloader
            } else {
                throw SecVFError.macOSVersionTooOld(required: "12.0", current: ProcessInfo.processInfo.operatingSystemVersionString)
            }
            #else
            throw SecVFError.appleSiliconRequired
            #endif
        } else {
            // Linux VM configuration
            let platform = VZGenericPlatformConfiguration()
            let bootloader = VZEFIBootLoader()

            if needsInstall {
                // Fresh Linux install from ISO
                platform.machineIdentifier = try createAndSaveMachineIdentifier(for: vmId)
                bootloader.variableStore = try createEFIVariableStore(for: vmId)
                disksArray.add(try createUSBMassStorageDeviceConfiguration(for: vmId))
            } else {
                // Boot existing Linux install
                NSLog("[Linux VM] Retrieving existing EFI variable store from: %@", vmConfig.nvramPath)
                platform.machineIdentifier = try retrieveMachineIdentifier(for: vmId)
                bootloader.variableStore = try retrieveEFIVariableStore(for: vmId)
                NSLog("[Linux VM] EFI variable store retrieved successfully")
            }

            virtualMachineConfiguration.platform = platform
            virtualMachineConfiguration.bootLoader = bootloader
        }

        disksArray.add(try createBlockDeviceConfiguration(for: vmId))

        // Check if scripts USB should be attached
        if attachScriptsUSBFlags[vmId] == true {
            if let scriptsUSB = createScriptsUSBConfiguration(forMacOS: isMacOS) {
                disksArray.add(scriptsUSB)
                NSLog("[ScriptsUSB] Attached scripts \(isMacOS ? "ISO" : "disk image") to VM")
            }
            // Clear the flag after use
            attachScriptsUSBFlags.removeValue(forKey: vmId)
        }

        guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
            throw SecVFError.invalidDiskConfiguration
        }
        virtualMachineConfiguration.storageDevices = disks

        virtualMachineConfiguration.networkDevices = [try createNetworkDeviceConfiguration(for: vmId)]
        virtualMachineConfiguration.graphicsDevices = [try createGraphicsDeviceConfiguration(isMacOS: isMacOS)]
        virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]

        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Add XHCI USB controller for hot-plug support (macOS 15+)
        if #available(macOS 15.0, *) {
            let xhciController = VZXHCIControllerConfiguration()
            virtualMachineConfiguration.usbControllers = [xhciController]
            NSLog("[VM] Added XHCI USB controller for hot-plug support")
        }

        if !isMacOS {
            // SPICE agent is only for Linux VMs
            virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]
        }

        NSLog("[VM] Validating virtual machine configuration...")
        do {
            try virtualMachineConfiguration.validate()
            NSLog("[VM] Configuration validation successful")
        } catch {
            // Log to both NSLog and a file
            let errorMsg = """
            [CRITICAL] VM configuration validation failed!
            Error: \(error.localizedDescription)
            Full error: \(String(describing: error))
            VM: \(vmConfig.name)
            """
            NSLog("%@", errorMsg)

            // Write to secure debug file (user-only permissions)
            let logsDir = NSHomeDirectory() + "/.avf/logs/"
            try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let debugPath = logsDir + "secvf-crash-debug.txt"
            try? errorMsg.write(toFile: debugPath, atomically: true, encoding: .utf8)

            throw SecVFError.configurationValidationFailed(underlying: error)
        }

        let virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
        virtualMachines[vmId] = virtualMachine
    }

    // MARK: Start the virtual machine.

    func configureAndStartVirtualMachine(for vmId: UUID) {
        guard let vmConfig = vmConfigs[vmId] else {
            NSLog("[VM] ERROR: VM configuration not found for vmId: \(vmId)")
            return
        }

        let rosettaAvailability = VZLinuxRosettaDirectoryShare.availability
        switch rosettaAvailability {
            case .notSupported:
                // Alert the user the capability isn't available; offer
                // continuation options according to your app's requirements.
                print("Rosetta is not supported on this system")
            case .notInstalled:
                // Ask the user for permission to install Rosetta, and
                // start the installation process if they grant permission.
                print("Rosetta is not installed")
            case .installed:
                print("Rosetta is available")
            @unknown default:
                break
            }

        // Update VM status to starting
        VMManager.shared.updateVMStatus(vmConfig, status: .starting)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Only create VM if it doesn't already exist (prevents disk re-attachment errors)
            if self.virtualMachines[vmId] == nil {
                do {
                    try self.createVirtualMachine(for: vmId)
                } catch {
                    VMManager.shared.updateVMStatus(vmConfig, status: .stopped)
                    let secvfError = (error as? SecVFError) ?? SecVFError.vmConfigInvalid(reason: error.localizedDescription)
                    AlertPresenter.showVMErrorWithLogOption(secvfError, vmName: vmConfig.name)
                    return
                }
            }

            guard let virtualMachine = self.virtualMachines[vmId],
                  let virtualMachineView = self.vmViews[vmId] else {
                NSLog("[VM] ERROR: VM or view not found for vmId: \(vmId)")
                VMManager.shared.updateVMStatus(vmConfig, status: .stopped)
                return
            }

            virtualMachineView.virtualMachine = virtualMachine

            if #available(macOS 14.0, *) {
                // Configure the app to automatically respond changes in the display size.
                virtualMachineView.automaticallyReconfiguresDisplay = true
            }

            virtualMachine.delegate = self

            // SECURITY: Start security monitoring for this VM
            VMSecurityMonitor.shared.startMonitoring(vm: vmConfig, virtualMachine: virtualMachine)

            let needsInstall = self.needsInstallFlags[vmId] ?? false

            // For macOS installation, use the installer instead of manually starting the VM
            if needsInstall && vmConfig.osType == "macOS" {
                #if arch(arm64)
                if #available(macOS 12.0, *) {
                    self.installMacOS(for: vmId)
                    return
                }
                #endif
                // If we reach here on non-ARM or old macOS, show error
                VMManager.shared.updateVMStatus(vmConfig, status: .stopped)
                AlertPresenter.showVMError(SecVFError.appleSiliconRequired, vmName: vmConfig.name)
                return
            }

            NSLog("[VM] Starting virtual machine: %@", vmConfig.name)
            virtualMachine.start(completionHandler: { [weak self] (result) in
                guard let self = self else { return }
                guard let vmConfig = self.vmConfigs[vmId] else { return }

                switch result {
                case let .failure(error):
                    VMManager.shared.updateVMStatus(vmConfig, status: .stopped)
                    // Stop security monitoring on failure
                    VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)
                    // Disconnect from virtual switch on failure
                    if vmConfig.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
                    }

                    // Log to both NSLog and file
                    let errorMsg = """
                    [CRITICAL] VM failed to start!
                    VM: \(vmConfig.name)
                    Error: \(error.localizedDescription)
                    Full error: \(String(describing: error))
                    OS Type: \(vmConfig.osType)
                    Needs Install: \(needsInstall)
                    """
                    NSLog("%@", errorMsg)

                    // Write to secure debug file (user-only permissions)
                    let logsDir = NSHomeDirectory() + "/.avf/logs/"
                    try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let debugPath = logsDir + "secvf-crash-debug.txt"
                    try? errorMsg.write(toFile: debugPath, atomically: true, encoding: .utf8)

                    // Show error to user instead of crashing
                    let vmError = SecVFError.vmStartFailed(underlying: error)
                    AlertPresenter.showVMErrorWithLogOption(vmError, vmName: vmConfig.name)

                default:
                    print("Virtual machine successfully started.")
                    VMManager.shared.updateVMStatus(vmConfig, status: .running)

                    // Log security recommendations
                    let recommendations = VMSecurityMonitor.shared.getSecurityRecommendations(for: vmConfig)
                    print("\n⚠️ SECURITY RECOMMENDATIONS:")
                    for rec in recommendations {
                        print("  \(rec)")
                    }
                    print("")
                }
            })
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Clean up any stray windows from previous sessions (macOS window restoration)
        closeAllVMWindows()

        // Setup Monitoring menu
        setupMonitoringMenu()

        // Show splash screen
        showSplashScreen()

        // Show the VM library window after splash
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.showLibraryWindow()
        }
    }

    private func closeAllVMWindows() {
        // Close any VM windows that might have been restored by macOS
        for window in NSApp.windows {
            // Check if this is a VM window (not the library window or other system windows)
            if let identifier = window.identifier?.rawValue,
               UUID(uuidString: identifier) != nil,
               window.title.starts(with: "SecVF -") {
                NSLog("[AppDelegate] Closing stray VM window from previous session: \(window.title)")
                window.close()
            }
        }

        // Clear all VM-related state
        vmWindows.removeAll()
        vmViews.removeAll()
        virtualMachines.removeAll()
        vmConfigs.removeAll()
        installerISOPaths.removeAll()
        needsInstallFlags.removeAll()
    }

    private func showSplashScreen() {
        splashScreen = SplashScreenWindow()
        splashScreen?.orderFront(nil) // Don't make it key since it can't become key

        // Splash screen will close itself and deallocate naturally
    }

    // MARK: - Monitoring Menu Setup

    private func setupMonitoringMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Create Monitoring menu
        let monitoringMenu = NSMenu(title: "Monitoring")

        // Security Logs menu item
        let securityLogsItem = NSMenuItem(
            title: "Security Logs",
            action: #selector(showSecurityLogs),
            keyEquivalent: "1"
        )
        securityLogsItem.keyEquivalentModifierMask = [.command, .shift]
        securityLogsItem.target = self
        monitoringMenu.addItem(securityLogsItem)

        // Network Logs menu item
        let networkLogsItem = NSMenuItem(
            title: "Network Logs",
            action: #selector(showNetworkLogs),
            keyEquivalent: "2"
        )
        networkLogsItem.keyEquivalentModifierMask = [.command, .shift]
        networkLogsItem.target = self
        monitoringMenu.addItem(networkLogsItem)

        monitoringMenu.addItem(NSMenuItem.separator())

        // Packet Analysis menu item
        let packetAnalysisItem = NSMenuItem(
            title: "Packet Analysis",
            action: #selector(showPacketAnalysis),
            keyEquivalent: "p"
        )
        packetAnalysisItem.keyEquivalentModifierMask = [.command, .shift]
        packetAnalysisItem.target = self
        monitoringMenu.addItem(packetAnalysisItem)

        // Virtual Switch Statistics
        let switchStatsItem = NSMenuItem(
            title: "Virtual Switch Statistics",
            action: #selector(showSwitchStatistics),
            keyEquivalent: "3"
        )
        switchStatsItem.keyEquivalentModifierMask = [.command, .shift]
        switchStatsItem.target = self
        monitoringMenu.addItem(switchStatsItem)

        monitoringMenu.addItem(NSMenuItem.separator())

        // ISO Cache Audit Logs
        let isoCacheLogsItem = NSMenuItem(
            title: "ISO Cache Audit",
            action: #selector(showISOCacheLogs),
            keyEquivalent: "4"
        )
        isoCacheLogsItem.keyEquivalentModifierMask = [.command, .shift]
        isoCacheLogsItem.target = self
        monitoringMenu.addItem(isoCacheLogsItem)

        monitoringMenu.addItem(NSMenuItem.separator())

        // ISO Cache Manager
        let isoCacheManagerItem = NSMenuItem(
            title: "Manage ISO Cache",
            action: #selector(showISOCacheManager),
            keyEquivalent: "5"
        )
        isoCacheManagerItem.keyEquivalentModifierMask = [.command, .shift]
        isoCacheManagerItem.target = self
        monitoringMenu.addItem(isoCacheManagerItem)

        // Create top-level menu item
        let monitoringMenuItem = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: "")
        monitoringMenuItem.submenu = monitoringMenu

        // Insert after the application menu (index 0) and before Window menu
        // Typical order: App, File, Edit, View, Window, Help
        // We'll insert at index 1 (after App menu)
        mainMenu.insertItem(monitoringMenuItem, at: 1)

        // Create Tools menu
        setupToolsMenu(mainMenu: mainMenu)
    }

    private func setupToolsMenu(mainMenu: NSMenu) {
        let toolsMenu = NSMenu(title: "Tools")

        // Install CLI
        let installCLIItem = NSMenuItem(
            title: "Install CLI Tool...",
            action: #selector(installCLITool),
            keyEquivalent: "i"
        )
        installCLIItem.keyEquivalentModifierMask = [.command, .shift]
        installCLIItem.target = self
        toolsMenu.addItem(installCLIItem)

        toolsMenu.addItem(NSMenuItem.separator())

        // Mount Scripts USB to VM
        let scriptsUSBItem = NSMenuItem(
            title: "Mount Scripts USB to VM...",
            action: #selector(showMountScriptsDialog),
            keyEquivalent: "u"
        )
        scriptsUSBItem.keyEquivalentModifierMask = [.command, .shift]
        scriptsUSBItem.target = self
        toolsMenu.addItem(scriptsUSBItem)

        toolsMenu.addItem(NSMenuItem.separator())

        // Rebuild Scripts ISO
        let rebuildISOItem = NSMenuItem(
            title: "Rebuild Scripts ISO",
            action: #selector(rebuildScriptsISO),
            keyEquivalent: ""
        )
        rebuildISOItem.target = self
        toolsMenu.addItem(rebuildISOItem)

        // Create top-level menu item
        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsMenuItem.submenu = toolsMenu

        // Insert after Monitoring menu (index 2)
        mainMenu.insertItem(toolsMenuItem, at: 2)
    }

    @objc private func showSecurityLogs() {
        // Create new viewer if nil or window was closed
        if securityLogViewer == nil || securityLogViewer?.window == nil {
            securityLogViewer = LogViewerWindowController(logType: .security)
        }
        securityLogViewer?.showWindow(nil)
        securityLogViewer?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showNetworkLogs() {
        // Create new viewer if nil or window was closed
        if networkLogViewer == nil || networkLogViewer?.window == nil {
            networkLogViewer = LogViewerWindowController(logType: .network)
        }
        networkLogViewer?.showWindow(nil)
        networkLogViewer?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPacketAnalysis() {
        // Create new viewer if nil or window was closed
        if packetAnalysisWindow == nil || packetAnalysisWindow?.window == nil {
            packetAnalysisWindow = PacketAnalysisWindowController()
        }
        packetAnalysisWindow?.showWindow(nil)
        packetAnalysisWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showISOCacheLogs() {
        // Create new viewer if nil or window was closed
        if isoCacheLogViewer == nil || isoCacheLogViewer?.window == nil {
            isoCacheLogViewer = LogViewerWindowController(logType: .isoCache)
        }
        isoCacheLogViewer?.showWindow(nil)
        isoCacheLogViewer?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showISOCacheManager() {
        // TODO: Add ISOCacheManagerWindow.swift to Xcode project first
        NSLog("ISO Cache Manager feature coming soon - file needs to be added to Xcode project")
        // Commented out implementation:
        // if isoCacheManagerWindow == nil || isoCacheManagerWindow?.window == nil {
        //     isoCacheManagerWindow = ISOCacheManagerWindow()
        // }
        // isoCacheManagerWindow?.showWindow(nil)
        // isoCacheManagerWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSwitchStatistics() {
        // Print switch statistics to console for debugging
        VirtualNetworkSwitch.shared.printStatistics()

        // TODO: Uncomment when SwitchStatisticsWindowController.swift is added to Xcode project
        // Create new viewer if nil or window was closed
        // if switchStatisticsWindow == nil || switchStatisticsWindow?.window == nil {
        //     switchStatisticsWindow = SwitchStatisticsWindowController()
        // }
        // switchStatisticsWindow?.showWindow(nil)
        // switchStatisticsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Tools Menu Handlers

    @objc private func installCLITool() {
        // Find the CLI binary - check app bundle first, then build directory
        let fm = FileManager.default
        var cliSourcePath: String?

        // Check app bundle Resources
        if let bundleCLI = Bundle.main.path(forResource: "secvf-cli", ofType: nil) {
            cliSourcePath = bundleCLI
            NSLog("[CLI Install] Found CLI in app bundle: \(bundleCLI)")
        }

        // Check build directory (for development)
        if cliSourcePath == nil {
            let projectDir = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let devCLI = projectDir.appendingPathComponent("SecVF/cli/.build/debug/secvf-cli").path
            if fm.fileExists(atPath: devCLI) {
                cliSourcePath = devCLI
                NSLog("[CLI Install] Found CLI in build directory: \(devCLI)")
            }
        }

        // Check common development locations
        if cliSourcePath == nil {
            let commonPaths = [
                NSHomeDirectory() + "/Code/Sandboxes/SecVF/SecVF/cli/.build/debug/secvf-cli",
                NSHomeDirectory() + "/Developer/SecVF/SecVF/cli/.build/debug/secvf-cli",
            ]
            for path in commonPaths {
                if fm.fileExists(atPath: path) {
                    cliSourcePath = path
                    NSLog("[CLI Install] Found CLI at: \(path)")
                    break
                }
            }
        }

        guard let sourcePath = cliSourcePath else {
            showAlert(title: "CLI Not Found",
                      message: "The CLI binary was not found.\n\nBuild it first with:\ncd SecVF/cli && swift build")
            return
        }

        // Destination path
        let destPath = "/usr/local/bin/secvf"

        // Check if already installed and same version
        if fm.fileExists(atPath: destPath) {
            let alert = NSAlert()
            alert.messageText = "CLI Already Installed"
            alert.informativeText = "The CLI tool is already installed at \(destPath).\n\nWould you like to reinstall/update it?"
            alert.addButton(withTitle: "Reinstall")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        // Find entitlements file
        var entitlementsPath: String?
        let projectDir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entitlementsFile = projectDir.appendingPathComponent("secvf-cli.entitlements").path

        if fm.fileExists(atPath: entitlementsFile) {
            entitlementsPath = entitlementsFile
            NSLog("[CLI Install] Found entitlements: \(entitlementsFile)")
        }

        // Create temporary copy with entitlements signed
        let tempDir = NSTemporaryDirectory()
        let tempCLI = tempDir + "secvf-cli-signed"

        do {
            // Remove any existing temp file
            try? fm.removeItem(atPath: tempCLI)

            // Copy to temp
            try fm.copyItem(atPath: sourcePath, toPath: tempCLI)

            // Sign with entitlements if available
            let signProcess = Process()
            signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            if let entPath = entitlementsPath {
                signProcess.arguments = ["--sign", "-", "--entitlements", entPath, "--force", tempCLI]
            } else {
                signProcess.arguments = ["--sign", "-", "--force", tempCLI]
            }

            let pipe = Pipe()
            signProcess.standardError = pipe
            try signProcess.run()
            signProcess.waitUntilExit()

            if signProcess.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                NSLog("[CLI Install] Signing failed: \(errorMsg)")
                // Continue anyway - signing isn't strictly required for basic operation
            } else {
                NSLog("[CLI Install] Signed CLI with entitlements")
            }
        } catch {
            showAlert(title: "Error", message: "Failed to prepare CLI binary: \(error.localizedDescription)")
            return
        }

        // Use osascript to get admin privileges and copy
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp '\(tempCLI)' '\(destPath)' && chmod 755 '\(destPath)'" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?

        NSLog("[CLI Install] Requesting admin privileges to install to \(destPath)")

        let result = appleScript?.executeAndReturnError(&errorDict)

        // Clean up temp file
        try? fm.removeItem(atPath: tempCLI)

        if result != nil && errorDict == nil {
            NSLog("[CLI Install] Successfully installed CLI to \(destPath)")
            showAlert(title: "CLI Installed",
                      message: "The SecVF CLI has been installed successfully!\n\nYou can now use it from any terminal:\n\n  secvf vm list\n  secvf vm start <name>\n  secvf --help")
        } else {
            let errorMsg = errorDict?[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if errorMsg.contains("User canceled") || errorMsg.contains("cancelled") {
                NSLog("[CLI Install] User cancelled installation")
            } else {
                NSLog("[CLI Install] Installation failed: \(errorMsg)")
                showAlert(title: "Installation Failed",
                          message: "Failed to install CLI: \(errorMsg)")
            }
        }
    }

    @objc private func showMountScriptsDialog() {
        // Get list of VMs from VMManager
        let allVMs = VMManager.shared.virtualMachines

        if allVMs.isEmpty {
            showAlert(title: "No VMs Available", message: "Create a VM first before mounting scripts.")
            return
        }

        // Ensure scripts ISO exists
        if !ScriptsUSBManager.shared.scriptsISOExists {
            let alert = NSAlert()
            alert.messageText = "Scripts ISO Not Found"
            alert.informativeText = "The scripts ISO needs to be created first. Would you like to create it now?"
            alert.addButton(withTitle: "Create ISO")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                rebuildScriptsISO()
            }
            return
        }

        // Create VM selection dialog
        let alert = NSAlert()
        alert.messageText = "Mount Scripts USB to VM"
        alert.informativeText = "Select a VM to attach the SecVF scripts USB.\n\nNote: If the VM is running, it will be stopped and restarted with the scripts USB attached."

        // Create popup button for VM selection
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        for vm in allVMs {
            let title = "\(vm.name) (\(vm.osType))"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = vm
        }
        alert.accessoryView = popup

        alert.addButton(withTitle: "Mount & Start VM")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            guard let selectedVM = popup.selectedItem?.representedObject as? VMConfiguration else { return }

            // Check if VM is running - use hot-plug if available (macOS 15+)
            if let runningVM = virtualMachines[selectedVM.id], runningVM.state == .running {
                if #available(macOS 15.0, *) {
                    // Hot-plug the scripts USB to the running VM
                    hotPlugScriptsUSB(to: runningVM, vmName: selectedVM.name)
                } else {
                    // Fallback: restart VM with scripts attached (macOS < 15)
                    restartVMWithScripts(selectedVM, runningVM: runningVM)
                }
                return
            }

            // VM not running - start it with scripts attached
            startVMWithScripts(selectedVM)
        }
    }

    @available(macOS 15.0, *)
    private func hotPlugScriptsUSB(to vm: VZVirtualMachine, vmName: String) {
        guard let scriptsISOURL = ScriptsUSBManager.shared.scriptsISOURL else {
            showAlert(title: "Error", message: "Scripts ISO not found. Use Tools → Rebuild Scripts ISO first.")
            return
        }

        // Get the XHCI USB controller from the running VM
        guard let usbController = vm.usbControllers.first else {
            showAlert(title: "Error", message: "No USB controller available. VM may need to be restarted.")
            return
        }

        // Create the USB mass storage device configuration
        guard let attachment = try? VZDiskImageStorageDeviceAttachment(url: scriptsISOURL, readOnly: true) else {
            showAlert(title: "Error", message: "Failed to create disk attachment for scripts ISO.")
            return
        }

        let usbConfig = VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        let usbDevice = VZUSBMassStorageDevice(configuration: usbConfig)

        NSLog("[ScriptsUSB] Hot-plugging scripts USB to running VM: \(vmName)")

        // Attach the USB device to the running VM
        usbController.attach(device: usbDevice) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[ScriptsUSB] Failed to hot-plug: \(error)")
                    self?.showAlert(title: "Error", message: "Failed to mount scripts USB: \(error.localizedDescription)")
                } else {
                    NSLog("[ScriptsUSB] Successfully hot-plugged scripts USB!")
                    self?.showAlert(title: "Success", message: "Scripts USB mounted to \(vmName)!\n\nIn Linux: mount /dev/sdb1 /mnt\nIn macOS: Check desktop for SecVF_SCRIPTS")
                }
            }
        }
    }

    private func restartVMWithScripts(_ vm: VMConfiguration, runningVM: VZVirtualMachine) {
        NSLog("[ScriptsUSB] Restarting VM \(vm.name) to attach scripts (fallback for older macOS)")
        runningVM.stop { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[ScriptsUSB] Error stopping VM: \(error)")
            }
            DispatchQueue.main.async {
                self.cleanupVMState(vmId: vm.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startVMWithScripts(vm)
                }
            }
        }
    }

    private func cleanupVMState(vmId: UUID) {
        if let window = vmWindows[vmId] {
            window.close()
        }
        virtualMachines.removeValue(forKey: vmId)
        vmWindows.removeValue(forKey: vmId)
        vmViews.removeValue(forKey: vmId)
        vmConfigs.removeValue(forKey: vmId)
        installerISOPaths.removeValue(forKey: vmId)
        needsInstallFlags.removeValue(forKey: vmId)
    }

    private func startVMWithScripts(_ vm: VMConfiguration) {
        attachScriptsUSBFlags[vm.id] = true
        NSLog("[ScriptsUSB] Starting VM \(vm.name) with scripts USB attached")
        NotificationCenter.default.post(name: .startVM, object: vm)
    }

    @objc private func rebuildScriptsISO() {
        // Try to find scripts directory automatically
        var results: [String] = []
        var errors: [SecVFError] = []

        // Create ISO for macOS VMs (read-only is fine)
        switch ScriptsUSBManager.shared.createScriptsISO() {
        case .success(let isoURL):
            results.append("ISO: \(isoURL.lastPathComponent)")
        case .failure(let error):
            errors.append(error)
        }

        // Create writable disk image for Linux VMs
        switch ScriptsUSBManager.shared.createScriptsDisk() {
        case .success(let diskURL):
            results.append("Disk (writable): \(diskURL.lastPathComponent)")
        case .failure(let error):
            errors.append(error)
        }

        if !results.isEmpty {
            showAlert(title: "Scripts Created", message: "Successfully created:\n\(results.joined(separator: "\n"))")
        } else if !errors.isEmpty {
            // Check if the first error is scriptsSourceNotFound - prompt user
            if case .scriptsSourceNotFound = errors.first {
                ScriptsUSBManager.shared.promptForScriptsDirectory { [weak self] url in
                    guard let url = url else { return }

                    var results2: [String] = []
                    var errors2: [String] = []

                    switch ScriptsUSBManager.shared.createScriptsISO(from: url.path) {
                    case .success(let isoURL):
                        results2.append("ISO: \(isoURL.lastPathComponent)")
                    case .failure(let error):
                        errors2.append(error.localizedDescription)
                    }

                    switch ScriptsUSBManager.shared.createScriptsDisk(from: url.path) {
                    case .success(let diskURL):
                        results2.append("Disk (writable): \(diskURL.lastPathComponent)")
                    case .failure(let error):
                        errors2.append(error.localizedDescription)
                    }

                    if !results2.isEmpty {
                        self?.showAlert(title: "Scripts Created", message: "Successfully created:\n\(results2.joined(separator: "\n"))")
                    } else {
                        self?.showAlert(title: "Error", message: "Failed to create scripts:\n\(errors2.joined(separator: "\n"))")
                    }
                }
            } else {
                // Show the actual errors
                let errorMessages = errors.map { $0.localizedDescription }.joined(separator: "\n")
                showAlert(title: "Error", message: "Failed to create scripts:\n\(errorMessages)")
            }
        }
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showLibraryWindow() {
        if libraryWindowController == nil {
            libraryWindowController = VMLibraryWindowController()
        }

        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Refresh the table view (will trigger async load if needed)
        DispatchQueue.main.async {
            self.libraryWindowController?.refreshTableFromOutside()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't automatically terminate when windows close - we need to manage window lifecycle
        // for switching between library and VM windows
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // When a VM window closes, stop the VM if it's running
        guard let window = notification.object as? NSWindow,
              let identifierString = window.identifier?.rawValue,
              let vmId = UUID(uuidString: identifierString) else {
            return
        }

        guard let vm = virtualMachines[vmId],
              let vmConfig = vmConfigs[vmId] else {
            return
        }

        if vm.state == .running || vm.state == .starting {
            print("VM window closing - stopping VM: \(vmConfig.name)...")
            vm.stop { [weak self] error in
                guard let self = self else { return }

                if let error = error {
                    print("Error stopping VM: \(error)")
                } else {
                    // Update status
                    VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

                    // SECURITY: Stop security monitoring
                    VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)

                    // NETWORK: Disconnect from virtual switch
                    if vmConfig.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
                    }

                    // Clean up references
                    self.virtualMachines.removeValue(forKey: vmId)
                    self.vmWindows.removeValue(forKey: vmId)
                    self.vmViews.removeValue(forKey: vmId)
                    self.vmConfigs.removeValue(forKey: vmId)
                    self.installerISOPaths.removeValue(forKey: vmId)
                    self.needsInstallFlags.removeValue(forKey: vmId)
                }
            }
        } else {
            // VM not running - just clean up references
            virtualMachines.removeValue(forKey: vmId)
            vmWindows.removeValue(forKey: vmId)
            vmViews.removeValue(forKey: vmId)
            vmConfigs.removeValue(forKey: vmId)
            installerISOPaths.removeValue(forKey: vmId)
            needsInstallFlags.removeValue(forKey: vmId)
        }
    }

    // MARK: VZVirtualMachineDelegate methods.

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        // Find which VM this is
        guard let vmId = virtualMachines.first(where: { $0.value === virtualMachine })?.key,
              let vmConfig = vmConfigs[vmId],
              let window = vmWindows[vmId] else {
            NSLog("[DELEGATE] ERROR: Could not identify VM for didStopWithError callback")
            return
        }

        let errorMsg = """
        [DELEGATE] didStopWithError called!
        VM: \(vmConfig.name)
        Error: \(error.localizedDescription)
        Full error: \(String(describing: error))
        """
        NSLog("%@", errorMsg)
        print("Virtual machine did stop with error: \(error.localizedDescription)")

        // NETWORK: Disconnect from virtual switch if in virtual network mode
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
        }

        // Update status and reopen library
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Hide the VM window
            window.orderOut(nil)

            // Show error alert
            let alert = NSAlert()
            alert.messageText = "VM Error"
            alert.informativeText = "Virtual machine \(vmConfig.name) stopped with error: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()

            // Clean up references
            self.virtualMachines.removeValue(forKey: vmId)
            self.vmWindows.removeValue(forKey: vmId)
            self.vmViews.removeValue(forKey: vmId)
            self.vmConfigs.removeValue(forKey: vmId)
            self.installerISOPaths.removeValue(forKey: vmId)
            self.needsInstallFlags.removeValue(forKey: vmId)

            // Reopen library window
            self.showLibraryWindow()
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        // Find which VM this is
        guard let vmId = virtualMachines.first(where: { $0.value === virtualMachine })?.key,
              let vmConfig = vmConfigs[vmId],
              let window = vmWindows[vmId] else {
            NSLog("[DELEGATE] ERROR: Could not identify VM for guestDidStop callback")
            return
        }

        NSLog("[DELEGATE] guestDidStop called - VM stopped normally: \(vmConfig.name)")
        print("Guest did stop virtual machine.")

        // SECURITY: Stop security monitoring
        VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)

        // NETWORK: Disconnect from virtual switch if in virtual network mode
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
        }

        // Update status
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Hide the VM window
            window.orderOut(nil)

            // Clean up references
            self.virtualMachines.removeValue(forKey: vmId)
            self.vmWindows.removeValue(forKey: vmId)
            self.vmViews.removeValue(forKey: vmId)
            self.vmConfigs.removeValue(forKey: vmId)
            self.installerISOPaths.removeValue(forKey: vmId)
            self.needsInstallFlags.removeValue(forKey: vmId)

            // Reopen library window
            self.showLibraryWindow()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        print("Network attachment was disconnected with error: \(error.localizedDescription)")
    }
}
