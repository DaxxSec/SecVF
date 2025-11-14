/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app delegate that sets up and starts the virtual machine.
*/

import Virtualization

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    @IBOutlet var window: NSWindow!

    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    private var virtualMachine: VZVirtualMachine!

    private var installerISOPath: URL?

    private var needsInstall = true

    private var vmConfig: VMConfiguration!

    private var libraryWindowController: VMLibraryWindowController?

    // Log viewer windows (retained to prevent deallocation)
    private var securityLogViewer: LogViewerWindowController?
    private var networkLogViewer: LogViewerWindowController?

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
    }

    // MARK: - Notification Handlers

    @objc private func handleStartVM(_ notification: Notification) {
        guard let vm = notification.object as? VMConfiguration else { return }
        vmConfig = vm
        needsInstall = false
        installerISOPath = nil
        showMainWindowAndStartVM()
    }

    @objc private func handleStartVMWithISO(_ notification: Notification) {
        guard let info = notification.object as? [String: Any],
              let vm = info["vm"] as? VMConfiguration,
              let iso = info["iso"] as? URL else { return }
        vmConfig = vm
        needsInstall = true
        installerISOPath = iso
        showMainWindowAndStartVM()
    }

    private func showMainWindowAndStartVM() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        configureAndStartVirtualMachine()
    }

    // MARK: Create device configuration objects for the virtual machine.

    private func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
        guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: vmConfig.diskImagePath), readOnly: false) else {
            fatalError("Failed to create main disk attachment.")
        }

        let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
        return mainDisk
    }

    private func computeCPUCount() -> Int {
        var virtualCPUCount = vmConfig.cpuCount
        virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

        return virtualCPUCount
    }

    private func computeMemorySize() -> UInt64 {
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

    private func createAndSaveMachineIdentifier() -> VZGenericMachineIdentifier {
        let machineIdentifier = VZGenericMachineIdentifier()

        // Store the machine identifier to disk so you can retrieve it for subsequent boots.
        try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmConfig.machineIdentifierPath))
        return machineIdentifier
    }

    private func retrieveMachineIdentifier() -> VZGenericMachineIdentifier {
        // Retrieve the machine identifier.
        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: vmConfig.machineIdentifierPath)) else {
            fatalError("Failed to retrieve the machine identifier data.")
        }

        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Failed to create the machine identifier.")
        }

        return machineIdentifier
    }

    private func createEFIVariableStore() -> VZEFIVariableStore {
        let nvramURL = URL(fileURLWithPath: vmConfig.nvramPath)

        // Remove existing NVRAM file if it exists
        if FileManager.default.fileExists(atPath: vmConfig.nvramPath) {
            try? FileManager.default.removeItem(at: nvramURL)
        }

        guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: nvramURL) else {
            fatalError("Failed to create the EFI variable store at: \(vmConfig.nvramPath)")
        }

        return efiVariableStore
    }

    private func retrieveEFIVariableStore() -> VZEFIVariableStore {
        if !FileManager.default.fileExists(atPath: vmConfig.nvramPath) {
            fatalError("EFI variable store does not exist.")
        }

        return VZEFIVariableStore(url: URL(fileURLWithPath: vmConfig.nvramPath))
    }

    private func createUSBMassStorageDeviceConfiguration() -> VZUSBMassStorageDeviceConfiguration {
        guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: installerISOPath!, readOnly: true) else {
            fatalError("Failed to create installer's disk attachment.")
        }

        return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
    }

    private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()

        // Configure network attachment based on VM's network mode
        switch vmConfig.networkConfig.mode {
        case .nat:
            // Standard NAT networking - VM has internet access
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            print("[Network] Configuring NAT networking for \(vmConfig.name)")

        case .virtual:
            // Virtual switch networking - VM-to-VM communication only
            if let (readHandle, writeHandle) = VirtualNetworkSwitch.shared.connectVM(
                vmId: vmConfig.id,
                vmName: vmConfig.name
            ) {
                networkDevice.attachment = VZFileHandleNetworkDeviceAttachment(
                    fileHandleForReading: readHandle,
                    fileHandleForWriting: writeHandle
                )
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

    private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
        ]

        return graphicsDevice
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

    private func createAndSaveMacMachineIdentifier() -> VZMacMachineIdentifier {
        let machineIdentifier = VZMacMachineIdentifier()
        try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: vmConfig.machineIdentifierPath))
        return machineIdentifier
    }

    private func retrieveMacMachineIdentifier() -> VZMacMachineIdentifier {
        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: vmConfig.machineIdentifierPath)) else {
            fatalError("Failed to retrieve Mac machine identifier data.")
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Failed to create Mac machine identifier.")
        }
        return machineIdentifier
    }

    private func createMacAuxiliaryStorage(hardwareModel: VZMacHardwareModel) -> VZMacAuxiliaryStorage {
        let auxiliaryStoragePath = vmConfig.bundlePath + "AuxiliaryStorage"
        guard let auxiliaryStorage = try? VZMacAuxiliaryStorage(creatingStorageAt: URL(fileURLWithPath: auxiliaryStoragePath), hardwareModel: hardwareModel) else {
            fatalError("Failed to create Mac auxiliary storage.")
        }
        return auxiliaryStorage
    }

    private func retrieveMacAuxiliaryStorage() -> VZMacAuxiliaryStorage {
        let auxiliaryStoragePath = vmConfig.bundlePath + "AuxiliaryStorage"
        return VZMacAuxiliaryStorage(contentsOf: URL(fileURLWithPath: auxiliaryStoragePath))
    }

    private func createMacHardwareModel() -> VZMacHardwareModel {
        // Get hardware model from the IPSW restore image
        guard let restoreImageURL = installerISOPath else {
            fatalError("No restore image path provided for macOS install")
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
            fatalError("Failed to get hardware model from restore image")
        }

        // Save hardware model to disk
        let hardwareModelPath = vmConfig.bundlePath + "HardwareModel"
        try! model.dataRepresentation.write(to: URL(fileURLWithPath: hardwareModelPath))

        return model
    }

    private func retrieveMacHardwareModel() -> VZMacHardwareModel {
        let hardwareModelPath = vmConfig.bundlePath + "HardwareModel"
        guard let hardwareModelData = try? Data(contentsOf: URL(fileURLWithPath: hardwareModelPath)) else {
            fatalError("Failed to retrieve Mac hardware model data.")
        }
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            fatalError("Failed to create Mac hardware model.")
        }
        return hardwareModel
    }



    // MARK: Create the virtual machine configuration and instantiate the virtual machine.

    func createVirtualMachine() {
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()

        virtualMachineConfiguration.cpuCount = computeCPUCount()
        virtualMachineConfiguration.memorySize = computeMemorySize()

        let isMacOS = vmConfig.osType == "macOS"
        let disksArray = NSMutableArray()

        if isMacOS {
            // macOS VM configuration
            let platform = VZMacPlatformConfiguration()
            let bootloader = VZMacOSBootLoader()

            if needsInstall {
                // Fresh macOS install from IPSW
                // Create hardware model first, as it's needed for auxiliary storage
                let hardwareModel = createMacHardwareModel()
                platform.machineIdentifier = createAndSaveMacMachineIdentifier()
                platform.auxiliaryStorage = createMacAuxiliaryStorage(hardwareModel: hardwareModel)
                platform.hardwareModel = hardwareModel
                disksArray.add(createUSBMassStorageDeviceConfiguration())
            } else {
                // Boot existing macOS install
                platform.machineIdentifier = retrieveMacMachineIdentifier()
                platform.hardwareModel = retrieveMacHardwareModel()
                platform.auxiliaryStorage = retrieveMacAuxiliaryStorage()
            }

            virtualMachineConfiguration.platform = platform
            virtualMachineConfiguration.bootLoader = bootloader
        } else {
            // Linux VM configuration
            let platform = VZGenericPlatformConfiguration()
            let bootloader = VZEFIBootLoader()

            if needsInstall {
                // Fresh Linux install from ISO
                platform.machineIdentifier = createAndSaveMachineIdentifier()
                bootloader.variableStore = createEFIVariableStore()
                disksArray.add(createUSBMassStorageDeviceConfiguration())
            } else {
                // Boot existing Linux install
                platform.machineIdentifier = retrieveMachineIdentifier()
                bootloader.variableStore = retrieveEFIVariableStore()
            }

            virtualMachineConfiguration.platform = platform
            virtualMachineConfiguration.bootLoader = bootloader
        }

        disksArray.add(createBlockDeviceConfiguration())
        guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
            fatalError("Invalid disksArray.")
        }
        virtualMachineConfiguration.storageDevices = disks

        virtualMachineConfiguration.networkDevices = [createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]

        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        if !isMacOS {
            // SPICE agent is only for Linux VMs
            virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]
        }

        try! virtualMachineConfiguration.validate()
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
    }

    // MARK: Start the virtual machine.

    func configureAndStartVirtualMachine() {

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

        DispatchQueue.main.async {
            self.createVirtualMachine()
            self.virtualMachineView.virtualMachine = self.virtualMachine

            if #available(macOS 14.0, *) {
                // Configure the app to automatically respond changes in the display size.
                self.virtualMachineView.automaticallyReconfiguresDisplay = true
            }

            self.virtualMachine.delegate = self

            // SECURITY: Start security monitoring for this VM
            VMSecurityMonitor.shared.startMonitoring(vm: self.vmConfig, virtualMachine: self.virtualMachine)

            self.virtualMachine.start(completionHandler: { (result) in
                switch result {
                case let .failure(error):
                    VMManager.shared.updateVMStatus(self.vmConfig, status: .stopped)
                    // Stop security monitoring on failure
                    VMSecurityMonitor.shared.stopMonitoring(vmID: self.vmConfig.id)
                    // Disconnect from virtual switch on failure
                    if self.vmConfig.networkConfig.mode == .virtual {
                        VirtualNetworkSwitch.shared.disconnectPort(vmId: self.vmConfig.id)
                    }
                    fatalError("Virtual machine failed to start with error: \(error)")

                default:
                    print("Virtual machine successfully started.")
                    VMManager.shared.updateVMStatus(self.vmConfig, status: .running)

                    // Log security recommendations
                    let recommendations = VMSecurityMonitor.shared.getSecurityRecommendations(for: self.vmConfig)
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
        // Hide the main VM window initially
        window.orderOut(nil)

        // Setup Monitoring menu
        setupMonitoringMenu()

        // Show the VM library window
        showLibraryWindow()
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

        // Virtual Switch Statistics
        let switchStatsItem = NSMenuItem(
            title: "Virtual Switch Statistics",
            action: #selector(showSwitchStatistics),
            keyEquivalent: "3"
        )
        switchStatsItem.keyEquivalentModifierMask = [.command, .shift]
        switchStatsItem.target = self
        monitoringMenu.addItem(switchStatsItem)

        // Create top-level menu item
        let monitoringMenuItem = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: "")
        monitoringMenuItem.submenu = monitoringMenu

        // Insert after the application menu (index 0) and before Window menu
        // Typical order: App, File, Edit, View, Window, Help
        // We'll insert at index 1 (after App menu)
        mainMenu.insertItem(monitoringMenuItem, at: 1)
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

    @objc private func showSwitchStatistics() {
        // Print switch statistics to console and show in alert
        VirtualNetworkSwitch.shared.printStatistics()

        let stats = VirtualNetworkSwitch.shared.getStatistics()

        var message = "Virtual Network Switch Status\n\n"
        message += "Running: \(stats["running"] as? Bool ?? false ? "Yes" : "No")\n"
        message += "Connected Ports: \(stats["connectedPorts"] ?? 0)\n"
        message += "Learned MACs: \(stats["learnedMACs"] ?? 0)\n"
        message += "Packets Forwarded: \(stats["packetsForwarded"] ?? 0)\n"
        message += "Packets Broadcast: \(stats["packetsBroadcast"] ?? 0)\n"

        if let portStats = stats["ports"] as? [[String: Any]], !portStats.isEmpty {
            message += "\nConnected VMs:\n"
            for port in portStats {
                message += "  • \(port["vmName"] as? String ?? "unknown")\n"
                message += "    MAC: \(port["macAddress"] as? String ?? "unknown")\n"
                message += "    RX: \(port["packetsRx"] ?? 0) packets\n"
                message += "    TX: \(port["packetsTx"] ?? 0) packets\n"
            }
        } else {
            message += "\nNo VMs currently connected to virtual switch."
        }

        let alert = NSAlert()
        alert.messageText = "Virtual Switch Statistics"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showLibraryWindow() {
        if libraryWindowController == nil {
            libraryWindowController = VMLibraryWindowController()
        }

        // Reload VM list to show current status
        VMManager.shared.loadVirtualMachines()

        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Refresh the table view
        DispatchQueue.main.async {
            self.libraryWindowController?.refreshTableFromOutside()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't automatically terminate when windows close - we need to manage window lifecycle
        // for switching between library and VM windows
        return false
    }

    // MARK: VZVirtualMachineDelegate methods.

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("Virtual machine did stop with error: \(error.localizedDescription)")

        // NETWORK: Disconnect from virtual switch if in virtual network mode
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
        }

        // Update status and reopen library
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

        DispatchQueue.main.async {
            // Hide the VM window
            self.window.orderOut(nil)

            // Show error alert
            let alert = NSAlert()
            alert.messageText = "VM Error"
            alert.informativeText = "Virtual machine stopped with error: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()

            // Reopen library window
            self.showLibraryWindow()
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Guest did stop virtual machine.")

        // SECURITY: Stop security monitoring
        VMSecurityMonitor.shared.stopMonitoring(vmID: vmConfig.id)

        // NETWORK: Disconnect from virtual switch if in virtual network mode
        if vmConfig.networkConfig.mode == .virtual {
            VirtualNetworkSwitch.shared.disconnectPort(vmId: vmConfig.id)
        }

        // Update status
        VMManager.shared.updateVMStatus(vmConfig, status: .stopped)

        DispatchQueue.main.async {
            // Hide the VM window
            self.window.orderOut(nil)

            // Reopen library window
            self.showLibraryWindow()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        print("Netowrk attachment was disconnected with error: \(error.localizedDescription)")
    }
}
