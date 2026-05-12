/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app delegate that sets up and starts the virtual machine.
*/

@preconcurrency import Virtualization

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @MainActor VZVirtualMachineDelegate, NSWindowDelegate {

    // Multi-VM architecture - manage separate windows for each running VM
    private var vmWindows: [UUID: NSWindow] = [:]

    // The currently-running AI Sandbox install task, if any. A second click
    // on Tools → Create AI Sandbox VM… cancels this one before starting a
    // new attempt — prevents two installer pipelines fighting over the
    // same aux storage flock when the first one errored out partway.
    private var activeAISandboxInstallTask: Task<Void, Never>?
    /// Identity tag for `activeAISandboxInstallTask`. `Task` is a value
    /// type so `===` doesn't apply; a per-task UUID lets the self-clear
    /// avoid stomping a newer click's task. (S7 of PR #4 review.)
    private var activeAISandboxInstallTaskId: UUID?
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

        // Open packet analysis — single owner is AppDelegate. Other UIs post
        // .openPacketAnalysis rather than instantiate a second controller.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenPacketAnalysis(_:)),
            name: .openPacketAnalysis,
            object: nil
        )

        // Register for CLI distributed notifications (cross-process).
        //
        // Scope note (B7): DistributedNotificationCenter.default() is a
        // PER-USER-SESSION center on macOS — it lives on the user's launchd
        // bootstrap, so other users on the same Mac (fast user switching,
        // separate accounts) cannot post into our handlers. Same-user
        // processes CAN post these notifications, but a same-user attacker
        // has already compromised SecVF's UI affordances; DNC adds no new
        // attack surface beyond what GUI scripting would offer. For SecVF
        // 1.0 we accept the same-user threat model and do not add a
        // sender-PID validation step. If we later support a multi-tenant
        // host model, gate these on a shared-secret userInfo token.
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

        // Capture lifecycle from MCP / CLI. The handlers drive the same
        // PacketCaptureManager singleton the GUI uses — keeping one
        // source of truth for the tshark pipeline.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIStartCapture(_:)),
            name: NSNotification.Name("com.secvf.cli.capture-start"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIStopCapture(_:)),
            name: NSNotification.Name("com.secvf.cli.capture-stop"),
            object: nil
        )
    }

    // MARK: - Notification Handlers

    @objc private func handleStartVM(_ notification: Notification) {
        guard let vm = notification.object as? VMConfiguration else { return }

        // Prevent duplicate VM instances — skip if this VM already has a window open
        if virtualMachines[vm.id] != nil || vmWindows[vm.id] != nil {
            NSLog("[AppDelegate] VM '%@' is already running or starting — ignoring duplicate start", vm.name)
            return
        }

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

        // Check if this is an AI Sandbox VM by scanning ~/.avf/AISandbox/
        let aiSandboxRoot = NSHomeDirectory() + "/.avf/AISandbox"
        let candidatePaths = [
            aiSandboxRoot + "/\(vmName).bundle",
            aiSandboxRoot + "/sessions/\(vmName).bundle"
        ]
        let isAISandbox = candidatePaths.contains { FileManager.default.fileExists(atPath: $0) }

        if isAISandbox {
            NSLog("[CLI] Routing AI Sandbox VM through bootAISandboxSession()")
            DispatchQueue.main.async { [weak self] in
                self?.bootAISandboxSession()
            }
            return
        }

        // Standard VM path — find in VMManager
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

    // MARK: - CLI / MCP capture lifecycle
    //
    // PacketCaptureManager is the single source of truth for the tshark
    // pipeline — the GUI capture toggle and these notification-driven
    // handlers both route through it. Idempotent: starting an already-
    // running capture or stopping a stopped one just logs and returns.

    @objc private func handleCLIStartCapture(_ notification: Notification) {
        let bpf = notification.userInfo?["bpfFilter"] as? String
        let pcapPath = notification.userInfo?["pcapPath"] as? String
        NSLog("[CLI] Start capture requested (bpf: %@, pcap: %@)",
              bpf ?? "(none)", pcapPath ?? "(default)")

        DispatchQueue.main.async {
            let mgr = PacketCaptureManager.shared
            if mgr.isCapturing {
                NSLog("[CLI] Capture already running — ignoring duplicate start")
                return
            }
            let ok = mgr.startCapture()
            NSLog("[CLI] startCapture returned: %@", ok ? "true" : "false")
            NotificationCenter.default.post(name: .captureStarted, object: nil)
        }
    }

    @objc private func handleCLIStopCapture(_ notification: Notification) {
        NSLog("[CLI] Stop capture requested")
        DispatchQueue.main.async {
            let mgr = PacketCaptureManager.shared
            guard mgr.isCapturing else {
                NSLog("[CLI] Capture not running — ignoring stop")
                return
            }
            mgr.stopCapture()
            NotificationCenter.default.post(name: .captureStopped, object: nil)
        }
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

    private func createNetworkDeviceConfigurations(for vmId: UUID) throws -> [VZVirtioNetworkDeviceConfiguration] {
        guard let vmConfig = vmConfigs[vmId] else {
            throw SecVFError.vmConfigNotFound(vmId: vmId)
        }

        // Configure network attachment based on VM's network mode
        switch vmConfig.networkConfig.mode {
        case .nat:
            // Standard NAT networking - VM has internet access (single NIC)
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            print("[Network] Configuring NAT networking for \(vmConfig.name)")
            return [networkDevice]

        case .virtual:
            // Virtual switch networking
            if let fileHandle = VirtualNetworkSwitch.shared.connectVM(
                vmId: vmConfig.id,
                vmName: vmConfig.name
            ) {
                let vswitchDevice = VZVirtioNetworkDeviceConfiguration()
                vswitchDevice.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
                print("[Network] Configuring virtual switch networking for \(vmConfig.name)")

                if vmConfig.networkConfig.isRouter {
                    // Dual-NIC router: virtual switch (enp0s1) + NAT (enp0s2)
                    // Kali routes client VM traffic from vswitch to internet via NAT
                    let natDevice = VZVirtioNetworkDeviceConfiguration()
                    natDevice.attachment = VZNATNetworkDeviceAttachment()
                    print("[Network] \(vmConfig.name) configured as dual-NIC router (Virtual Switch + NAT)")
                    return [vswitchDevice, natDevice]
                } else if let routerVMId = vmConfig.networkConfig.routerVMId {
                    print("[Network] \(vmConfig.name) will route through VM: \(routerVMId)")
                }

                return [vswitchDevice]
            } else {
                if vmConfig.networkConfig.isRouter {
                    // Router VM must have virtual switch - no fallback
                    throw SecVFError.networkConfigurationFailed(reason: "Router VM '\(vmConfig.name)' failed to connect to virtual switch. A router without the virtual switch cannot monitor traffic.")
                }
                // Fallback to NAT if virtual switch connection fails for non-router VMs
                print("[Network] WARNING: Failed to connect to virtual switch, falling back to NAT")
                let networkDevice = VZVirtioNetworkDeviceConfiguration()
                networkDevice.attachment = VZNATNetworkDeviceAttachment()
                return [networkDevice]
            }
        }
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
                    Task { @MainActor [weak self] in
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

        virtualMachineConfiguration.networkDevices = try createNetworkDeviceConfigurations(for: vmId)
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

        // Add a virtio socket device (vsock) only for macOS guests — that's
        // where the AI sandbox exec agent listens on port 2222. Linux VMs in
        // SecVF (kali router etc.) don't currently use vsock, and adding the
        // device unconditionally caused VM-startup hangs in testing. Limit to
        // macOS for now; revisit if a Linux-side use case appears.
        if isMacOS {
            virtualMachineConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            NSLog("[VM] Added virtio socket device (vsock) for host-guest IPC")
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

            // Expose the AI Sandbox vsock exec channel as a UDS at
            // /tmp/secvf-exec-<vmid>.sock so cross-process / cross-user
            // clients (e.g. ai-mon's SecVFTracer, secvf-cli vm exec) can
            // drive the guest. No-op for VMs without a vsock device.
            VsockExecBridgeManager.shared.startBridge(
                vmId: vmConfig.id, vmName: vmConfig.name, vm: virtualMachine
            )

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

            // One-shot Recovery boot for macOS guests. If the user flipped
            // `bootIntoRecoveryNext` on (via the "Boot Into Recovery Next"
            // menu item), pass startUpFromMacOSRecovery=true to this start
            // call. The flag is cleared + metadata.json re-written BEFORE
            // the VM starts so a mid-start crash doesn't trap the user in
            // a recovery boot loop on every subsequent launch.
            //
            // We clear-first-start-second because:
            //   1. Persisting after the start callback fires is racy — the
            //      callback runs async; meanwhile the user might quit
            //      SecVF.app and the flag would never get cleared.
            //   2. Even on a Force-Quit + relaunch, the saved metadata
            //      already reflects "next boot is normal".
            //   3. If the start itself fails (e.g. unsupported macOS), the
            //      user just re-toggles to retry — strictly better than
            //      the alternative (silently looping into recovery).
            let bootIntoRecovery = (vmConfig.osType == "macOS")
                && (vmConfig.bootIntoRecoveryNext == true)
            if bootIntoRecovery {
                NSLog("[VM] One-shot Recovery boot requested for %@; clearing flag before start", vmConfig.name)
                var cleared = vmConfig
                cleared.bootIntoRecoveryNext = false
                self.vmConfigs[vmId] = cleared
                do {
                    try VMManager.shared.setRecoveryBootFlag(cleared, on: false)
                } catch {
                    NSLog("[VM] Warning: could not persist cleared recovery flag for %@: %@",
                          cleared.name, error.localizedDescription)
                }
            }

            // Branch on Recovery so the no-options call path is unchanged
            // for the 99% case.
            if bootIntoRecovery {
                #if arch(arm64)
                if #available(macOS 13.0, *) {
                    let opts = VZMacOSVirtualMachineStartOptions()
                    opts.startUpFromMacOSRecovery = true
                    Task { @MainActor in
                        do {
                            try await virtualMachine.start(options: opts)
                            self.handleVMStartSuccess(vmId: vmId)
                        } catch {
                            self.handleVMStartFailure(vmId: vmId, error: error,
                                                       needsInstall: needsInstall)
                        }
                    }
                    return
                }
                #endif
                // Older macOS / non-ARM can't request Recovery; fall through
                // to a normal boot with a warning. The flag has already been
                // cleared above so we don't loop.
                NSLog("[VM] Recovery boot not supported on this host; doing normal boot")
            }

            virtualMachine.start(completionHandler: { [weak self] (result) in
                guard let self = self else { return }
                guard let vmConfig = self.vmConfigs[vmId] else { return }

                switch result {
                case let .failure(error):
                    self.handleVMStartFailure(
                        vmId: vmId,
                        error: error,
                        needsInstall: needsInstall
                    )
                default:
                    self.handleVMStartSuccess(vmId: vmId)
                    _ = vmConfig  // silence unused-var if compiler picks it up later
                }
            })
        }
    }

    // MARK: - VM start outcome handlers
    //
    // Extracted so both the standard `virtualMachine.start(completionHandler:)`
    // path and the Recovery-boot `try await virtualMachine.start(options:)`
    // path land in one place. Keeps security-monitor teardown + virtual-switch
    // cleanup + error reporting consistent.

    private func handleVMStartSuccess(vmId: UUID) {
        guard let vmConfig = self.vmConfigs[vmId] else { return }
        print("Virtual machine successfully started.")
        VMManager.shared.updateVMStatus(vmConfig, status: .running)

        let recommendations = VMSecurityMonitor.shared.getSecurityRecommendations(for: vmConfig)
        print("\n⚠️ SECURITY RECOMMENDATIONS:")
        for rec in recommendations {
            print("  \(rec)")
        }
        print("")
    }

    private func handleVMStartFailure(vmId: UUID, error: Error, needsInstall: Bool) {
        guard let vmConfig = self.vmConfigs[vmId] else { return }
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)
        VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)
        VsockExecBridgeManager.shared.stopBridge(vmId: vmConfig.id)
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
        }

        let errorMsg = """
        [CRITICAL] VM failed to start!
        VM: \(vmConfig.name)
        Error: \(error.localizedDescription)
        Full error: \(String(describing: error))
        OS Type: \(vmConfig.osType)
        Needs Install: \(needsInstall)
        """
        NSLog("%@", errorMsg)

        let logsDir = NSHomeDirectory() + "/.avf/logs/"
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let debugPath = logsDir + "secvf-crash-debug.txt"
        try? errorMsg.write(toFile: debugPath, atomically: true, encoding: .utf8)

        let vmError = SecVFError.vmStartFailed(underlying: error)
        AlertPresenter.showVMErrorWithLogOption(vmError, vmName: vmConfig.name)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Clean up any stray windows from previous sessions (macOS window restoration)
        closeAllVMWindows()

        // Prune old logs and rotate the audit log on launch — bounded retention
        // for accumulated network/security/error files in ~/.avf/logs/.
        LogRotation.runAtLaunch()

        // Backfill missing id/name into pre-existing AI Sandbox bundle
        // manifests. Bundles sealed before the sealBundle() id/name fix
        // (PR #4) have no `id` field, which leaves `secvf-cli vm exec`
        // unable to compute the UDS path and forces `--wait` to fall
        // through to SSH polling. Idempotent — only mutates manifests
        // that are missing the field. (Issue B of PR #4 followup.)
        backfillAISandboxManifestIds()
        checkForUnfinishedAISandboxBake()

        // Setup Monitoring menu
        setupMonitoringMenu()

        // Show splash screen and refresh distro versions
        showSplashScreen()
        refreshDistroVersionsOnStartup()
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
        // Don't auto-close — refreshDistroVersionsOnStartup will dismiss it.
    }

    private func refreshDistroVersionsOnStartup() {
        splashScreen?.setStatusMessage("[ CHECKING DISTRO VERSIONS ]")

        // Safety timeout — show the library even if version checks hang
        var dismissed = false
        let dismissSplash = { [weak self] in
            guard !dismissed else { return }
            dismissed = true
            self?.splashScreen?.fadeOut()
            // Keep splashScreen reference alive — orderOut hides it but
            // deallocating triggers deferred AppKit teardown that crashes.
            self?.showLibraryWindow()
        }

        // Splash safety timeout. Lowered from 10s to 4s (S9 of PR #4 review)
        // because refreshDistroVersions is now TTL-rate-limited — if the call
        // would actually hit the network, it's an attempt-once-per-6h thing
        // and we'd rather show the library quickly with stale distro data
        // than block launch waiting for a slow mirror.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if !dismissed {
                NSLog("[DistroRefresh] Timed out — dismissing splash")
                dismissSplash()
            }
        }

        DistroConfigurationManager.shared.refreshDistroVersions(
            progress: { [weak self] distroName, status in
                // progress callbacks arrive on background threads — bounce to main
                DispatchQueue.main.async {
                    self?.splashScreen?.setStatusMessage("[ \(distroName): \(status) ]")
                }
            },
            completion: { [weak self] updated, errors in
                // completion is already on main (group.notify .main) but be safe
                DispatchQueue.main.async {
                    if updated.isEmpty {
                        self?.splashScreen?.setStatusMessage("[ ALL DISTROS CURRENT ]")
                    } else {
                        self?.splashScreen?.setStatusMessage("[ UPDATED \(updated.count) DISTRO\(updated.count == 1 ? "" : "S") ]")
                        for u in updated { NSLog("[DistroRefresh] Updated: %@", u) }
                    }
                    for e in errors { NSLog("[DistroRefresh] Error: %@", e) }

                    // Brief pause so user can read the final status, then dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismissSplash()
                    }
                }
            }
        )
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

        toolsMenu.addItem(NSMenuItem.separator())

        // Download macOS IPSW (one-time cache for any macOS VM creation flow)
        let downloadIPSWItem = NSMenuItem(
            title: "Download macOS IPSW…",
            action: #selector(downloadMacOSIPSW),
            keyEquivalent: ""
        )
        downloadIPSWItem.target = self
        toolsMenu.addItem(downloadIPSWItem)

        // Create AI Sandbox VM (programmatic AISandboxMacVMInstaller path)
        let createSandboxItem = NSMenuItem(
            title: "Create AI Sandbox VM…",
            action: #selector(createAISandboxVM),
            keyEquivalent: ""
        )
        createSandboxItem.target = self
        toolsMenu.addItem(createSandboxItem)

        // Boot AI Sandbox (clone base → session, boot, show window)
        let bootSandboxItem = NSMenuItem(
            title: "Boot AI Sandbox",
            action: #selector(bootAISandboxSession),
            keyEquivalent: ""
        )
        bootSandboxItem.target = self
        toolsMenu.addItem(bootSandboxItem)

        toolsMenu.addItem(NSMenuItem.separator())

        // One-shot Recovery boot. Operates on the VM currently selected in
        // the library window. validateMenuItem enables/disables based on
        // whether that VM is a macOS guest. The action shows a confirmation
        // alert; on approval, sets bootIntoRecoveryNext=true and persists.
        // AppDelegate's start path clears the flag right before booting.
        let recoveryBootItem = NSMenuItem(
            title: "Boot Into Recovery Next (macOS VM)",
            action: #selector(toggleRecoveryBootForSelectedVM),
            keyEquivalent: ""
        )
        recoveryBootItem.target = self
        toolsMenu.addItem(recoveryBootItem)

        // Create top-level menu item
        let toolsMenuItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        toolsMenuItem.submenu = toolsMenu

        // Insert after Monitoring menu (index 2)
        mainMenu.insertItem(toolsMenuItem, at: 2)
    }

    /// Find the macOS VM currently selected in the library window, or
    /// nil if no selection / selection is a Linux VM. Used by the
    /// Recovery-boot menu item.
    private func selectedMacOSVMConfig() -> VMConfiguration? {
        guard let libraryController = libraryWindowController,
              let selected = libraryController.selectedVM,
              selected.osType == "macOS" else {
            return nil
        }
        return selected
    }

    @objc private func toggleRecoveryBootForSelectedVM(_ sender: Any?) {
        guard let vmConfig = selectedMacOSVMConfig() else {
            let alert = NSAlert()
            alert.messageText = "No macOS VM selected"
            alert.informativeText = "Select a macOS VM in the library, then choose this menu item to schedule its next boot into Recovery mode."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alreadyArmed = vmConfig.bootIntoRecoveryNext == true
        let alert = NSAlert()
        if alreadyArmed {
            alert.messageText = "Cancel Recovery boot for '\(vmConfig.name)'?"
            alert.informativeText = "The next boot is currently scheduled to enter macOS Recovery. Cancel that and resume normal boots?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Cancel Recovery")
            alert.addButton(withTitle: "Keep Armed")
        } else {
            alert.messageText = "Boot '\(vmConfig.name)' into Recovery on next start?"
            alert.informativeText = """
                The next time you start this VM, it will boot into macOS Recovery instead of the normal OS. The toggle is one-shot — it clears itself right before boot, so subsequent starts are normal.

                Use this for: disk repair, FileVault unlock, reinstalling macOS, resetting firmware password, or any task that requires Recovery.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Arm Recovery Boot")
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()
        let proceed = (response == .alertFirstButtonReturn)
        guard proceed else { return }

        let newValue = !alreadyArmed
        do {
            try VMManager.shared.setRecoveryBootFlag(vmConfig, on: newValue)
            NSLog("[VM] bootIntoRecoveryNext for %@ → %@",
                  vmConfig.name, newValue ? "true" : "false")
            libraryWindowController?.refreshTableFromOutside()

            if newValue {
                let confirm = NSAlert()
                confirm.messageText = "Recovery boot armed"
                confirm.informativeText = "'\(vmConfig.name)' will boot into macOS Recovery on its next start. The flag clears automatically after the boot is triggered."
                confirm.alertStyle = .informational
                confirm.addButton(withTitle: "OK")
                confirm.runModal()
            }
        } catch {
            let err = NSAlert()
            err.messageText = "Couldn't update Recovery flag"
            err.informativeText = "Failed to persist the Recovery boot flag for '\(vmConfig.name)': \(error.localizedDescription)"
            err.alertStyle = .critical
            err.addButton(withTitle: "OK")
            err.runModal()
        }
    }

    /// Per-VM action: validate Recovery menu item visibility.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleRecoveryBootForSelectedVM) {
            // Title updates dynamically based on current state.
            if let vm = selectedMacOSVMConfig() {
                let armed = vm.bootIntoRecoveryNext == true
                menuItem.title = armed
                    ? "Cancel Recovery Boot (\(vm.name))"
                    : "Boot Into Recovery Next (\(vm.name))"
                return true
            } else {
                menuItem.title = "Boot Into Recovery Next (macOS VM)"
                // Still selectable so the user gets the "select a macOS VM"
                // alert; otherwise the menu item is just gray with no
                // explanation, which is less helpful.
                return true
            }
        }
        return true
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

    @objc private func handleOpenPacketAnalysis(_ notification: Notification) {
        // Funnels library-window and any future caller through the same
        // singleton-owned analysis window.
        showPacketAnalysis()
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
        // ISOCacheManagerWindow.swift exists in the repo but is not yet
        // added to the Xcode project target. The menu item was previously
        // a silent NSLog — surface an honest alert instead so the user
        // isn't left wondering why nothing happened.
        // TODO(pre-launch): wire ISOCacheManagerWindow into the Xcode
        // project target and replace this alert with the real call site.
        let alert = NSAlert()
        alert.messageText = "ISO Cache Manager — coming soon"
        alert.informativeText = "This feature is in development and not yet enabled in this build. For now, manage cached ISOs directly under ~/.avf/ISOCache/."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showSwitchStatistics() {
        // SwitchStatisticsWindowController.swift exists in the repo but
        // is not yet added to the Xcode project target. Previously this
        // dumped to stdout (invisible). Surface an honest alert + offer
        // to print to Console as a fallback.
        // TODO(pre-launch): wire SwitchStatisticsWindowController and
        // replace this alert with the real call site.
        let alert = NSAlert()
        alert.messageText = "Switch Statistics window — coming soon"
        alert.informativeText = "The in-app statistics window is in development. For now, current stats have been printed to the system log (Console.app, subsystem com.DaxxSec.SecVF)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Still emit to OSLog for users who know to look for it.
        VirtualNetworkSwitch.shared.printStatistics()
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
        // Disconnect from virtual switch BEFORE clearing VM references
        // to prevent the readability handler from firing on stale state
        if let vmConfig = vmConfigs[vmId], vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
        }

        // Clear delegate to prevent stale callbacks (guestDidStop/didStopWithError)
        virtualMachines[vmId]?.delegate = nil

        // Detach view before closing window to prevent framebuffer crash
        if let view = vmViews[vmId] {
            view.removeFromSuperview()
        }

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

    // MARK: - AI Sandbox VM creation

    /// Build a new AI Sandbox base bundle programmatically. Reuses any
    /// IPSW already in `~/.avf/MacOS/` (avoids 13 GB redownload). Runs
    /// install + provision + seal in the background and surfaces progress
    /// + completion alerts to the user.
    @objc private func createAISandboxVM() {
        // If a previous install is still running (or wedged), cancel it
        // first so its VZ refs can drop and any flock it holds releases
        // before we kick off a fresh attempt on the same paths.
        if let prior = activeAISandboxInstallTask {
            NSLog("[AISandbox] Cancelling prior install task before starting new attempt")
            prior.cancel()
            activeAISandboxInstallTask = nil
            activeAISandboxInstallTaskId = nil
        }

        // Confirm with the user — this takes 30-60 min and is destructive
        // if a base bundle already exists.
        let baseBundleURL = AISandboxDefaults.baseBundle
        let bundleExists = FileManager.default.fileExists(atPath: baseBundleURL.path)

        let confirm = NSAlert()
        if bundleExists {
            confirm.messageText = "Replace existing AI Sandbox VM?"
            confirm.informativeText = """
            A base bundle already exists at:
                \(baseBundleURL.path)

            "Delete & Recreate" will remove it (including ~70 GB of disk.img)
            and start a fresh install.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Delete & Recreate")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            // Remove the stale bundle. We do this synchronously here on main
            // — files are local, fast even at 70 GB sparse since most of
            // disk.img is unused.
            do {
                try FileManager.default.removeItem(at: baseBundleURL)
                NSLog("[AISandbox] Removed stale bundle at %@", baseBundleURL.path)
            } catch {
                showAlert(
                    title: "Could not remove existing bundle",
                    message: "\(error.localizedDescription)\n\nManually run:\n  rm -rf \(baseBundleURL.path)\n\nthen try again."
                )
                return
            }
        } else {
            confirm.messageText = "Create AI Sandbox VM?"
            confirm.informativeText = """
            Builds a new AI Sandbox base bundle at:
                \(baseBundleURL.path)

            This will:
              1. Install macOS via VZMacOSInstaller (uses cached IPSW if present)
              2. Boot the guest and run provision-macos-vm.sh via vsock
              3. Seal the bundle as the immutable base for session VMs

            Total time: ~30-60 minutes. The host stays usable.
            """
            confirm.alertStyle = .informational
            confirm.addButton(withTitle: "Create")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        // Require a cached IPSW — VZMacOSInstaller only accepts local file URLs.
        // Use Tools → Download macOS IPSW to cache one, then try again.
        guard let cachedIPSW = locateCachedIPSW() else {
            showAlert(
                title: "No macOS IPSW Found",
                message: """
                A macOS restore image (.ipsw) is required to build the AI Sandbox VM.

                Use Tools → Download macOS IPSW to download one first, then try again.
                """
            )
            return
        }
        NSLog("[AISandbox] Reusing cached IPSW: %@", cachedIPSW.path)

        // Drive the tracker singleton — VMLibraryWindowController watches it
        // and renders an "installing" entry in the Tasks tab.
        // begin() returns a fresh runId; pass it to every run-scoped
        // mutation so a superseded run's late callbacks can't clobber the
        // run that replaced it. See PR #4 review C2.
        let runId = AISandboxInstallTracker.shared.begin()
        AISandboxInstallTracker.shared.log("Starting AI Sandbox build", runId: runId)
        AISandboxInstallTracker.shared.log("IPSW: \(cachedIPSW.lastPathComponent)", runId: runId)
        AISandboxInstallTracker.shared.log("Bundle: \(AISandboxDefaults.baseBundle.path)", runId: runId)

        let task = Task { [weak self] in
            // self-clear hook so a future click doesn't try to cancel a
            // task that already finished. The strong-id comparison lives in
            // clearActiveInstallTaskIfMatches; we capture the task ref
            // *after* the Task literal so we can pass it.
            do {
                // Phase 1: install
                var lastLoggedPct = -1
                let bundle = try await AISandboxMacVMInstaller.downloadAndInstall(
                    localIPSW: cachedIPSW,
                    progress: { fraction in
                        Task { @MainActor in
                            AISandboxInstallTracker.shared.updateInstallFraction(fraction, runId: runId)
                            // Log every 5% milestone to Tasks tab
                            let pct = Int(fraction * 100)
                            let bucket = (pct / 5) * 5
                            if bucket != lastLoggedPct {
                                lastLoggedPct = bucket
                                AISandboxInstallTracker.shared.log("VZMacOSInstaller: \(pct)%", runId: runId)
                            }
                        }
                    }
                )
                await MainActor.run {
                    AISandboxInstallTracker.shared.log("macOS install complete", runId: runId)
                }

                try Task.checkCancellation()

                // Phase 2: provision — boot the VM so the user can complete
                // Setup Assistant, then run the provision script. A fresh
                // macOS install has no vsock agent, so we expose the script
                // via VirtioFS and guide the user through Terminal.
                await MainActor.run {
                    AISandboxInstallTracker.shared.setPhase(.provisioning, runId: runId)
                    AISandboxInstallTracker.shared.log("Booting VM for first-boot provisioning…", runId: runId)
                }

                try await self?.runProvisioningPhase(bundle: bundle, runId: runId)

                try Task.checkCancellation()

                // Phase 3: seal
                await MainActor.run {
                    AISandboxInstallTracker.shared.setPhase(.sealing, runId: runId)
                    AISandboxInstallTracker.shared.log("Sealing base bundle…", runId: runId)
                }
                try AISandboxMacVMInstaller.sealBundle(bundle)

                await MainActor.run {
                    AISandboxInstallTracker.shared.log("Bundle sealed at \(bundle.url.path)", runId: runId)
                    AISandboxInstallTracker.shared.setPhase(.finished, runId: runId)
                    self?.showAlert(
                        title: "AI Sandbox VM Ready",
                        message: """
                        Base bundle sealed at:
                            \(bundle.url.path)

                        Use Tools → Boot AI Sandbox to launch a session VM.
                        Each session is an APFS clone of the base — fast and disposable.
                        """
                    )
                    AISandboxInstallTracker.shared.reset(runId: runId)
                }
            } catch is CancellationError {
                NSLog("[AISandbox] Install cancelled (likely superseded by a later click)")
                // Run-scoped — silently no-ops if a newer run owns the
                // tracker. This is the C2 fix: prior PRs unconditionally
                // called fail()/reset() and clobbered the replacement run.
                await MainActor.run {
                    AISandboxInstallTracker.shared.log("Cancelled.", runId: runId)
                    AISandboxInstallTracker.shared.fail(with: "cancelled", runId: runId)
                    AISandboxInstallTracker.shared.reset(runId: runId)
                }
            } catch {
                await MainActor.run {
                    AISandboxInstallTracker.shared.log("Error: \(error.localizedDescription)", runId: runId)
                    AISandboxInstallTracker.shared.fail(with: error.localizedDescription, runId: runId)
                    self?.showAlert(
                        title: "AI Sandbox VM creation failed",
                        message: "\(error.localizedDescription)\n\nFull: \(String(describing: error))"
                    )
                    AISandboxInstallTracker.shared.reset(runId: runId)
                }
            }
        }
        let taskId = UUID()
        activeAISandboxInstallTask = task
        activeAISandboxInstallTaskId = taskId

        // Self-clear on completion. Compare via a per-task UUID — `Task` is
        // a value type so identity comparison via `===` doesn't apply.
        // If a newer click already replaced us by the time this runs,
        // our taskId won't match and we leave the newer state alone.
        Task { @MainActor [weak self] in
            await task.value   // Task<Void, Never> — never throws
            self?.clearActiveInstallTaskIfMatches(taskId)
        }
    }

    /// Clears `activeAISandboxInstallTask` only if it still belongs to the
    /// run identified by `taskId`. A newer click that replaced us must not
    /// have its reference stomped. (S7 of PR #4 review.)
    private func clearActiveInstallTaskIfMatches(_ taskId: UUID) {
        if activeAISandboxInstallTaskId == taskId {
            activeAISandboxInstallTask = nil
            activeAISandboxInstallTaskId = nil
        }
    }

    // MARK: - AI Sandbox Provisioning Phase

    /// Host-side path where the provision script writes its completion marker
    /// via the VirtioFS workspace share.
    private var provisionMarkerURL: URL {
        AISandboxDefaults.baseDir
            .appendingPathComponent("workspace/provision-complete.json")
    }

    /// Provisioning window shown during first-boot bake. Retained here so
    /// we can close it programmatically when provisioning completes.
    private var provisioningWindow: NSWindow?

    /// Boot the freshly-installed VM, show a window for the user to complete
    /// Setup Assistant + run the provision script, and wait for the completion
    /// marker before returning. Called between install and seal.
    @MainActor
    private func runProvisioningPhase(
        bundle: AISandboxVMBundle,
        runId: UUID
    ) async throws {
        let tracker = AISandboxInstallTracker.shared
        let fm = FileManager.default
        let workspaceDir = AISandboxDefaults.baseDir.appendingPathComponent("workspace")

        // ── 1. Ensure workspace dir exists and copy provision script there ──
        try fm.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let scriptDst = workspaceDir.appendingPathComponent("provision-macos-vm.sh")
        // Prefer the bundled resource; fall back to the repo copy
        let scriptSrc = Bundle.main.url(forResource: "provision-macos-vm", withExtension: "sh")
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Code/SecVF/scripts/provision-macos-vm.sh")
        if fm.fileExists(atPath: scriptSrc.path) {
            try? fm.removeItem(at: scriptDst) // overwrite stale copy
            try fm.copyItem(at: scriptSrc, to: scriptDst)
            // Ensure it's executable
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptDst.path)
        }
        tracker.log("Provision script staged at \(scriptDst.path)", runId: runId)

        // Remove stale marker from a prior failed bake
        try? fm.removeItem(at: provisionMarkerURL)

        // ── 2. Boot the VM with a visible window ────────────────────────────
        let vmConfig = try AISandboxMacVMConfiguration(bundle: bundle)
        let machine = VZVirtualMachine(configuration: vmConfig.configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SecVF - AI Sandbox Provisioning"

        let vmView = VZVirtualMachineView()
        vmView.frame = window.contentView!.bounds
        vmView.autoresizingMask = [.width, .height]
        vmView.virtualMachine = machine
        if #available(macOS 14.0, *) {
            vmView.automaticallyReconfiguresDisplay = true
        }
        window.contentView?.addSubview(vmView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.provisioningWindow = window

        tracker.log("Starting VM for first boot…", runId: runId)
        try await machine.start()
        tracker.log("VM running — complete Setup Assistant in the VM window", runId: runId)

        // ── 3. Show instruction panel ───────────────────────────────────────
        showProvisioningInstructions()

        // ── 4. Poll for the marker file ─────────────────────────────────────
        // The provision script writes provision-complete.json to /workspace/
        // (VirtioFS). We poll on the host side. No hard timeout — the user
        // controls pace. Task cancellation breaks the loop.
        tracker.log("Waiting for provision-complete.json in workspace…", runId: runId)
        while !fm.fileExists(atPath: provisionMarkerURL.path) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
        }
        tracker.log("Provision marker detected — provisioning complete", runId: runId)

        // ── 5. Shut down the VM ─────────────────────────────────────────────
        tracker.log("Shutting down provisioned VM…", runId: runId)
        if machine.canRequestStop {
            try machine.requestStop()
            // Wait for graceful shutdown (up to 60s)
            for _ in 0..<20 {
                if machine.state == .stopped { break }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if machine.state != .stopped {
            try await machine.stop()
        }
        tracker.log("VM shut down", runId: runId)

        // Clean up the provisioning window
        self.provisioningWindow?.close()
        self.provisioningWindow = nil
    }

    /// On launch, detect an unfinished bake: base bundle exists, disk.img is
    /// writable (not sealed), and no provision marker. Offer to resume.
    private func checkForUnfinishedAISandboxBake() {
        let fm = FileManager.default
        let baseBundle = AISandboxVMBundle(url: AISandboxDefaults.baseBundle)
        guard baseBundle.exists else { return }

        // Sealed bundles have disk.img at 0o444. If it's writable, the bake
        // was interrupted before seal.
        let diskPath = baseBundle.diskURL.path
        guard fm.isWritableFile(atPath: diskPath) else { return }

        // If the marker already exists, provisioning finished but sealing
        // didn't. We can go straight to seal.
        if fm.fileExists(atPath: provisionMarkerURL.path) {
            let alert = NSAlert()
            alert.messageText = "Finish Sealing AI Sandbox?"
            alert.informativeText = """
            The AI Sandbox base bundle at:
                \(baseBundle.url.path)

            was provisioned but never sealed. Seal it now?
            """
            alert.addButton(withTitle: "Seal Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                do {
                    try AISandboxMacVMInstaller.sealBundle(baseBundle)
                    showAlert(title: "AI Sandbox Sealed", message: "Base bundle sealed. Use Tools → Boot AI Sandbox to launch a session.")
                } catch {
                    showAlert(title: "Seal Failed", message: error.localizedDescription)
                }
            }
            return
        }

        // No marker, unsealed bundle → bake was interrupted before or during provisioning.
        let alert = NSAlert()
        alert.messageText = "Resume AI Sandbox Provisioning?"
        alert.informativeText = """
        An unfinished AI Sandbox base bundle was found at:
            \(baseBundle.url.path)

        macOS is installed but provisioning didn't complete.
        "Resume" will boot the VM so you can finish Setup Assistant \
        and run the provision script.

        "Discard" will delete the bundle so you can start fresh.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Resume provisioning
            let runId = AISandboxInstallTracker.shared.begin()
            AISandboxInstallTracker.shared.setPhase(.provisioning, runId: runId)
            AISandboxInstallTracker.shared.log("Resuming interrupted provisioning", runId: runId)

            let task = Task { [weak self] in
                do {
                    try await self?.runProvisioningPhase(bundle: baseBundle, runId: runId)
                    try Task.checkCancellation()

                    await MainActor.run {
                        AISandboxInstallTracker.shared.setPhase(.sealing, runId: runId)
                        AISandboxInstallTracker.shared.log("Sealing base bundle…", runId: runId)
                    }
                    try AISandboxMacVMInstaller.sealBundle(baseBundle)
                    await MainActor.run {
                        AISandboxInstallTracker.shared.log("Bundle sealed", runId: runId)
                        AISandboxInstallTracker.shared.setPhase(.finished, runId: runId)
                        self?.showAlert(
                            title: "AI Sandbox VM Ready",
                            message: "Base bundle sealed. Use Tools → Boot AI Sandbox to launch a session VM."
                        )
                        AISandboxInstallTracker.shared.reset(runId: runId)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        AISandboxInstallTracker.shared.fail(with: "cancelled", runId: runId)
                        AISandboxInstallTracker.shared.reset(runId: runId)
                    }
                } catch {
                    await MainActor.run {
                        AISandboxInstallTracker.shared.fail(with: error.localizedDescription, runId: runId)
                        self?.showAlert(title: "Provisioning Failed", message: error.localizedDescription)
                        AISandboxInstallTracker.shared.reset(runId: runId)
                    }
                }
            }
            activeAISandboxInstallTask = task
            let taskId = UUID()
            activeAISandboxInstallTaskId = taskId
            Task { @MainActor [weak self] in
                await task.value
                self?.clearActiveInstallTaskIfMatches(taskId)
            }
        } else if response == .alertSecondButtonReturn {
            // Discard
            try? fm.removeItem(at: baseBundle.url)
            NSLog("[AISandbox] Discarded unfinished bundle at %@", baseBundle.url.path)
        }
        // "Later" → do nothing
    }

    /// Shows a floating instruction panel guiding the user through first-boot
    /// provisioning. The panel is non-modal so the VM window stays interactive.
    private func showProvisioningInstructions() {
        let alert = NSAlert()
        alert.messageText = "AI Sandbox First-Boot Provisioning"
        alert.informativeText = """
        The VM is booting for the first time. Complete these steps \
        in the VM window:

        1. Walk through macOS Setup Assistant (create any admin user)
        2. Once at the desktop, open Terminal.app and run:

           sudo mkdir -p /workspace
           sudo mount -t virtiofs workspace /workspace
           /workspace/provision-macos-vm.sh

        3. Wait for the script to finish (~10-30 min).
           It will install Homebrew, Node.js, the AI agent,
           security monitoring, and the vsock exec dispatcher.

        SecVF will automatically detect completion and seal the bundle.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Walks `~/.avf/AISandbox/` (base bundle + sessions) and backfills the
    /// `id`/`name` fields into any manifest.json that's missing them.
    /// Idempotent — leaves manifests with existing ids alone. Runs once at
    /// app launch so the CLI's exec-bridge path can compute the UDS path
    /// for bundles that were sealed before the id/name fields were added
    /// in PR #4. (Issue B of PR #4 followup.)
    private func backfillAISandboxManifestIds() {
        let aiSandboxRoot = NSHomeDirectory() + "/.avf/AISandbox"
        let fm = FileManager.default

        var bundlesToCheck: [URL] = []
        // Base bundles directly under ~/.avf/AISandbox/
        if let entries = try? fm.contentsOfDirectory(atPath: aiSandboxRoot) {
            for entry in entries where entry.hasSuffix(".bundle") {
                bundlesToCheck.append(URL(fileURLWithPath: aiSandboxRoot + "/" + entry))
            }
        }
        // Session bundles under ~/.avf/AISandbox/sessions/
        let sessionsRoot = aiSandboxRoot + "/sessions"
        if let entries = try? fm.contentsOfDirectory(atPath: sessionsRoot) {
            for entry in entries where entry.hasSuffix(".bundle") {
                bundlesToCheck.append(URL(fileURLWithPath: sessionsRoot + "/" + entry))
            }
        }

        for bundleURL in bundlesToCheck {
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            var changed = false
            let idStr = manifest["id"] as? String
            if idStr == nil || idStr?.isEmpty == true || UUID(uuidString: idStr ?? "") == nil {
                manifest["id"] = UUID().uuidString
                changed = true
            }
            if (manifest["name"] as? String)?.isEmpty ?? true {
                let bundleName = bundleURL.deletingPathExtension().lastPathComponent
                manifest["name"] = bundleName
                changed = true
            }

            if changed,
               let updated = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
                try? updated.write(to: manifestURL)
                NSLog("[AISandbox] Backfilled manifest id/name for %@", bundleURL.lastPathComponent)
            }
        }
    }

    // MARK: - Boot AI Sandbox Session

    /// Active sandbox session — retained so the VM stays alive.
    private var activeSandboxSession: AISandboxVMSession?
    /// Stable UUID assigned to the active sandbox session for exec bridge addressing.
    private var activeSandboxVMId: UUID?
    /// Synchronous gate: set to true *before* the boot Task starts so a
    /// second click within the clone+start window can't race a duplicate
    /// session into existence (S3 of PR #4 review).
    private var activeSandboxBootInFlight = false

    /// Tools → Boot AI Sandbox. Clones the base bundle (APFS CoW), boots
    /// the session VM, and shows it in a new window.
    @objc private func bootAISandboxSession() {
        let baseBundle = AISandboxVMBundle(url: AISandboxDefaults.baseBundle)
        guard baseBundle.exists else {
            showAlert(
                title: "AI Sandbox Base Not Found",
                message: "No base bundle at:\n    \(AISandboxDefaults.baseBundle.path)\n\nUse Tools → Create AI Sandbox VM to build one first."
            )
            return
        }

        // If a session is already running, bring its window forward
        if let existing = activeSandboxSession, existing.vm?.state == .running || existing.vm?.state == .starting {
            for window in NSApp.windows where window.title.contains("AI Sandbox") {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        // Synchronous race gate. The boot Task takes seconds (clone + VZ
        // config + machine.start) before assigning `activeSandboxSession`.
        // Without this, a second click during that window would clone a
        // second bundle, start a second VZ machine, and silently leak the
        // loser when the second writer overwrites `activeSandboxSession`.
        if activeSandboxBootInFlight {
            NSLog("[AISandbox] Boot already in flight; ignoring duplicate click")
            return
        }
        activeSandboxBootInFlight = true

        Task { @MainActor in
            defer { self.activeSandboxBootInFlight = false }

            let session = AISandboxVMSession()
            NSLog("[AISandbox] Cloning base → session %@", session.sessionID)

            do {
                try session.cloneBase()
                NSLog("[AISandbox] Clone complete: %@", session.bundleURL.path)

                // Build VZ config from the cloned session bundle
                let bundle = AISandboxVMBundle(url: session.bundleURL)
                let sandboxConfig = try AISandboxMacVMConfiguration(bundle: bundle)
                let machine = VZVirtualMachine(configuration: sandboxConfig.configuration)
                session.vm = machine

                // Create window
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "SecVF - AI Sandbox [\(session.sessionID)]"
                window.delegate = self

                let vmView = VZVirtualMachineView()
                vmView.frame = window.contentView!.bounds
                vmView.autoresizingMask = [.width, .height]
                vmView.virtualMachine = machine
                if #available(macOS 14.0, *) {
                    vmView.automaticallyReconfiguresDisplay = true
                }
                window.contentView?.addSubview(vmView)

                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)

                self.activeSandboxSession = session

                // S4: persist the sandbox UUID on first boot only. Re-booting
                // the same session bundle MUST keep the same id so existing
                // `secvf-cli vm exec` clients addressing /tmp/secvf-exec-<id>.sock
                // don't get stranded by a fresh UUID rewrite.
                let manifestURL = session.bundleURL.appendingPathComponent("manifest.json")
                var manifest = (try? JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifestURL)) as? [String: Any]) ?? [:]

                let sandboxVMId: UUID
                if let existing = manifest["id"] as? String,
                   let parsed = UUID(uuidString: existing), !existing.isEmpty {
                    sandboxVMId = parsed
                } else {
                    sandboxVMId = UUID()
                    manifest["id"] = sandboxVMId.uuidString
                }
                if (manifest["name"] as? String)?.isEmpty ?? true {
                    manifest["name"] = "ai-sandbox-exec-\(session.sessionID)"
                }
                self.activeSandboxVMId = sandboxVMId

                if let updated = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
                    try? updated.write(to: manifestURL)
                }

                NSLog("[AISandbox] Starting session VM (id=%@)…", sandboxVMId.uuidString)
                try await machine.start()
                NSLog("[AISandbox] Session VM running")

                // Start the vsock exec bridge so `secvf-cli vm exec` can reach this VM
                VsockExecBridgeManager.shared.startBridge(
                    vmId: sandboxVMId,
                    vmName: "ai-sandbox-exec-\(session.sessionID)",
                    vm: machine
                )
            } catch {
                NSLog("[AISandbox] Boot failed: %@", error.localizedDescription)
                // Clean up failed session
                if let vmId = self.activeSandboxVMId {
                    VsockExecBridgeManager.shared.stopBridge(vmId: vmId)
                }
                self.activeSandboxVMId = nil
                try? await session.destroy()
                showAlert(
                    title: "AI Sandbox Boot Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Tools → Download macOS IPSW. One-time pull of the latest Apple-supported
    /// IPSW into `~/.avf/MacOS/`. Subsequent macOS VM creation flows
    /// (regular + AI Sandbox) reuse the cached file and skip the multi-GB
    /// re-download.
    @objc private func downloadMacOSIPSW() {
        Task { @MainActor in
            let restoreImage: VZMacOSRestoreImage
            do {
                restoreImage = try await VZMacOSRestoreImage.latestSupported
            } catch {
                showAlert(
                    title: "Could not query Apple for the latest IPSW",
                    message: error.localizedDescription
                )
                return
            }

            let osv = restoreImage.operatingSystemVersion
            let versionStr = "\(osv.majorVersion).\(osv.minorVersion)\(osv.patchVersion > 0 ? ".\(osv.patchVersion)" : "")"
            let buildStr = restoreImage.buildVersion
            let filename = "UniversalMac_\(versionStr)_\(buildStr)_Restore.ipsw"

            let macOSDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".avf/MacOS", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: macOSDir, withIntermediateDirectories: true
            )
            let destURL = macOSDir.appendingPathComponent(filename)

            // Confirm + handle existing cache.
            if FileManager.default.fileExists(atPath: destURL.path) {
                let alert = NSAlert()
                alert.messageText = "IPSW already cached"
                alert.informativeText = """
                \(filename) is already at:
                    \(destURL.path)

                Replace it with a fresh download?
                """
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try? FileManager.default.removeItem(at: destURL)
            } else {
                let alert = NSAlert()
                alert.messageText = "Download \(filename)?"
                alert.informativeText = """
                Source: Apple (\(restoreImage.url.absoluteString))
                Destination: \(destURL.path)

                Size: ~13-16 GB. Time depends on your connection.
                """
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            // Track progress in the Tasks tab instead of a blocking alert sheet.
            let tracker = IPSWDownloadTracker.shared
            tracker.begin(filename: filename, expectedBytes: 0)
            tracker.log("Starting IPSW download")
            tracker.log("Source: \(restoreImage.url.absoluteString)")
            tracker.log("Destination: \(destURL.path)")

            do {
                try await downloadFile(
                    from: restoreImage.url,
                    to: destURL,
                    progress: { received, total in
                        tracker.updateProgress(received: received, total: total)
                    }
                )
                tracker.log("Download complete — \(destURL.lastPathComponent)")
                tracker.complete()
                showAlert(
                    title: "IPSW Downloaded",
                    message: "Saved to:\n    \(destURL.path)\n\nNew macOS VMs will reuse this without re-downloading."
                )
            } catch {
                tracker.log("Download failed: \(error.localizedDescription)")
                tracker.fail(with: error.localizedDescription)
                showAlert(
                    title: "Download failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// URLSession download with delegate-based progress. The KVO approach
    /// was broken: the observation was deallocated immediately, and Apple's
    /// CDN may omit Content-Length which leaves fractionCompleted at 0.
    /// This delegate gets `didWriteData` callbacks that always fire.
    @MainActor
    private func downloadFile(
        from source: URL,
        to destination: URL,
        progress: @escaping (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil  // use system serial queue
        )
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: source)
        task.resume()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.continuation = cont
        }
    }
}

// MARK: - DownloadDelegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let progress: (_ received: Int64, _ total: Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    /// Milestone bookkeeping. INVARIANT: read/write only on main. The
    /// URLSession delegate methods fire on a serial OperationQueue, but
    /// every site that touches `lastLoggedPct` must hop to main first
    /// (see urlSession(_:didWriteData:...) for the pattern). Splitting
    /// the read or write outside the main hop would race the tracker
    /// log call and miss/duplicate milestones (S10 of PR #4 review).
    private var lastLoggedPct = -1

    init(destination: URL, progress: @escaping (_ received: Int64, _ total: Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        DispatchQueue.main.async {
            self.progress(totalBytesWritten, total)

            // Log every 1% milestone to the tracker
            if total > 0 {
                let pct = Int(Double(totalBytesWritten) / Double(total) * 100)
                if pct != self.lastLoggedPct {
                    self.lastLoggedPct = pct
                    let mbWritten = totalBytesWritten / (1024 * 1024)
                    let mbTotal = total / (1024 * 1024)
                    IPSWDownloadTracker.shared.log("Downloading: \(pct)% (\(mbWritten)/\(mbTotal) MB)")
                }
            } else {
                // No Content-Length — log every 50 MB
                let mb = totalBytesWritten / (1024 * 1024)
                let lastMB = (totalBytesWritten - bytesWritten) / (1024 * 1024)
                let bucket = (mb / 50) * 50
                let lastBucket = (lastMB / 50) * 50
                if bucket != lastBucket {
                    IPSWDownloadTracker.shared.log("Downloaded: \(mb) MB (size unknown)")
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - AppDelegate helpers (continued)

extension AppDelegate {
    /// Looks for a cached macOS IPSW under `~/.avf/MacOS/` — if found,
    /// `AISandboxMacVMInstaller.downloadAndInstall` will use it and skip
    /// the Apple CDN download.
    private func locateCachedIPSW() -> URL? {
        let macOSDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".avf/MacOS", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: macOSDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first(where: { $0.pathExtension.lowercased() == "ipsw" })
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Only intercept VM windows (identified by UUID)
        guard let identifierString = sender.identifier?.rawValue,
              let vmId = UUID(uuidString: identifierString),
              let vm = virtualMachines[vmId],
              let vmConfig = vmConfigs[vmId],
              vm.state == .running || vm.state == .starting else {
            return true  // Not a running VM window — allow close
        }

        // Count other running VMs (excluding this one)
        let otherRunningVMs = virtualMachines.filter { $0.key != vmId && ($0.value.state == .running || $0.value.state == .starting) }

        let alert = NSAlert()
        alert.alertStyle = .warning

        if otherRunningVMs.isEmpty {
            // Only this VM is running — simpler dialog
            alert.messageText = "Stop \"\(vmConfig.name)\"?"
            alert.informativeText = "This VM is still running. Closing the window will stop it."
            alert.addButton(withTitle: "Stop VM")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // "Stop VM" — proceed with close, windowWillClose handles teardown
                return true
            }
            return false  // Cancel
        } else {
            // Multiple VMs running — full 3-button dialog
            let otherNames = otherRunningVMs.compactMap { vmConfigs[$0.key]?.name }.joined(separator: ", ")
            alert.messageText = "VM \"\(vmConfig.name)\" is running"
            alert.informativeText = "Other running VMs: \(otherNames)\n\nChoose an action:"
            alert.addButton(withTitle: "Restart \"\(vmConfig.name)\"")
            alert.addButton(withTitle: "Stop All VMs")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // "Restart this VM" — restart without closing the window normally
                restartVM(vmId: vmId)
                return false  // Don't close the window — restart will reopen it

            case .alertSecondButtonReturn:
                // "Stop All VMs" — stop everything gracefully
                stopAllVMs()
                return false  // Don't close this window — stopAllVMs handles all cleanup

            default:
                return false  // Cancel
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // When a VM window closes, stop the VM if it's running.
        // At this point windowShouldClose already approved the close.
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
            NSLog("[AppDelegate] VM window closing - stopping VM: %@", vmConfig.name)

            // 1. Clear delegate to prevent stale guestDidStop/didStopWithError callbacks
            vm.delegate = nil

            // 2. Detach VZVirtualMachineView from window BEFORE stopping VM
            if let view = vmViews[vmId] {
                view.removeFromSuperview()
            }

            // 3. Stop security monitoring
            VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)
            VsockExecBridgeManager.shared.stopBridge(vmId: vmConfig.id)

            // 4. Update status
            VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

            // 5. Stop the VM — do NOT disconnect the vswitch socket beforehand.
            //    The Virtualization framework needs the socket fd alive during its
            //    internal teardown. Closing it early causes EXC_BAD_ACCESS in objc_release
            //    as the framework accesses the invalidated socket state.
            //    Disconnect and release all references AFTER vm.stop() completes.
            vm.stop { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        NSLog("[AppDelegate] Error stopping VM: %@", error.localizedDescription)
                    }
                    // Framework teardown complete — NOW safe to disconnect and release
                    if vmConfig.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
                    }
                    self.virtualMachines.removeValue(forKey: vmId)
                    self.vmWindows.removeValue(forKey: vmId)
                    self.vmViews.removeValue(forKey: vmId)
                    self.vmConfigs.removeValue(forKey: vmId)
                    self.installerISOPaths.removeValue(forKey: vmId)
                    self.needsInstallFlags.removeValue(forKey: vmId)
                }
            }

            // 6. Safety timeout — if vm.stop() never completes (hung VM), force cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                if self.virtualMachines[vmId] != nil {
                    NSLog("[AppDelegate] VM stop timed out for %@ — forcing cleanup", vmConfig.name)
                    if vmConfig.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
                    }
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
            vm.delegate = nil
            virtualMachines.removeValue(forKey: vmId)
            vmWindows.removeValue(forKey: vmId)
            vmViews.removeValue(forKey: vmId)
            vmConfigs.removeValue(forKey: vmId)
            installerISOPaths.removeValue(forKey: vmId)
            needsInstallFlags.removeValue(forKey: vmId)
        }
    }

    // MARK: - VM Lifecycle Helpers

    /// Restarts a single VM: stops it, cleans up, then relaunches via .startVM notification.
    private func restartVM(vmId: UUID) {
        guard let vm = virtualMachines[vmId],
              let vmConfig = vmConfigs[vmId] else { return }

        NSLog("[AppDelegate] Restarting VM: %@", vmConfig.name)

        // Keep a copy of the config for relaunch
        let configCopy = vmConfig

        // 1. Clear delegate
        vm.delegate = nil

        // 2. Detach view before stopping
        if let view = vmViews[vmId] {
            view.removeFromSuperview()
        }

        // 3. Stop security monitoring
        VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)
        VsockExecBridgeManager.shared.stopBridge(vmId: vmConfig.id)

        // 4. Update status
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

        // 5. Stop the VM — disconnect vswitch AFTER stop completes, then relaunch
        vm.stop { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let error = error {
                    NSLog("[AppDelegate] Error stopping VM for restart: %@", error.localizedDescription)
                }

                // Clean up all state for this VM
                self.cleanupVMState(vmId: vmId)

                // Relaunch after a brief delay to let cleanup complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSLog("[AppDelegate] Relaunching VM: %@", configCopy.name)
                    NotificationCenter.default.post(name: .startVM, object: configCopy)
                }
            }
        }
    }

    /// Gracefully stops all running VMs, cleans up state, and reopens the library window.
    private func stopAllVMs() {
        let runningVMs = virtualMachines.filter { $0.value.state == .running || $0.value.state == .starting }
        guard !runningVMs.isEmpty else { return }

        NSLog("[AppDelegate] Stopping all VMs (%d running)", runningVMs.count)

        let vmIds = Array(runningVMs.keys)

        for (vmId, vm) in runningVMs {
            let vmConfig = vmConfigs[vmId]

            // 1. Clear delegate
            vm.delegate = nil

            // 2. Detach view before stopping
            if let view = vmViews[vmId] {
                view.removeFromSuperview()
            }

            // 3. Stop security monitoring
            if let config = vmConfig {
                VMSecurityMonitor.shared.stopMonitoring(vmID: config.id)
                VsockExecBridgeManager.shared.stopBridge(vmId: config.id)
                VMManager.shared.updateVMStatus(config, status: .stopped)
            }

            // 4. Hide window immediately (without triggering windowShouldClose)
            if let window = vmWindows[vmId] {
                window.orderOut(nil)
            }

            // 5. Stop VM — disconnect vswitch and release refs AFTER framework teardown
            vm.stop { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let error = error {
                        NSLog("[AppDelegate] Error stopping VM %@: %@",
                              vmConfig?.name ?? vmId.uuidString, error.localizedDescription)
                    }
                    if let config = vmConfig, config.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPortSync(vmId: config.id)
                    }
                    self.virtualMachines.removeValue(forKey: vmId)
                    self.vmWindows.removeValue(forKey: vmId)
                    self.vmViews.removeValue(forKey: vmId)
                    self.vmConfigs.removeValue(forKey: vmId)
                    self.installerISOPaths.removeValue(forKey: vmId)
                    self.needsInstallFlags.removeValue(forKey: vmId)
                }
            }
        }

        // Safety timeout — force cleanup for any VMs whose stop() never completed
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            for vmId in vmIds where self.virtualMachines[vmId] != nil {
                NSLog("[AppDelegate] VM stop timed out for %@ — forcing cleanup", vmId.uuidString)
                if let config = self.vmConfigs[vmId], config.networkConfig.mode == .virtual {
                    VirtualNetworkSwitch.shared.disconnectPortSync(vmId: config.id)
                }
                self.virtualMachines.removeValue(forKey: vmId)
                self.vmWindows.removeValue(forKey: vmId)
                self.vmViews.removeValue(forKey: vmId)
                self.vmConfigs.removeValue(forKey: vmId)
                self.installerISOPaths.removeValue(forKey: vmId)
                self.needsInstallFlags.removeValue(forKey: vmId)
            }
        }

        // Reopen library window
        showLibraryWindow()
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
            VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
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
        VsockExecBridgeManager.shared.stopBridge(vmId: vmConfig.id)

        // NETWORK: Disconnect from virtual switch if in virtual network mode
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPortSync(vmId: vmConfig.id)
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
