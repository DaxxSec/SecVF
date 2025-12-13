import Foundation
import Virtualization

/// Headless VM runner using Apple Virtualization framework
class VMRunner: NSObject, VZVirtualMachineDelegate {
    private var virtualMachine: VZVirtualMachine?
    private var runLoop: CFRunLoop?
    private let vmName: String
    private let bundlePath: String

    private var completionHandler: ((Result<Void, Error>) -> Void)?

    init(vmName: String, bundlePath: String) {
        self.vmName = vmName
        self.bundlePath = bundlePath
        super.init()
    }

    // MARK: - Start VM

    @MainActor
    func start() async throws {
        let config = try createVMConfiguration()

        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.virtualMachine = vm

        try await vm.start()
        print("VM '\(vmName)' started successfully")

        // Keep running until VM stops - run on main thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.completionHandler = { _ in
                continuation.resume()
            }
        }

        // Keep main run loop alive
        while virtualMachine?.state == .running || virtualMachine?.state == .starting {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    // MARK: - Stop VM

    func stop(force: Bool = false) async throws {
        guard let vm = virtualMachine else {
            throw VMRunnerError.vmNotRunning
        }

        if force {
            try await vm.stop()
        } else {
            try vm.requestStop()
        }

        print("VM '\(vmName)' stopped")
    }

    // MARK: - VM Configuration

    private func createVMConfiguration() throws -> VZVirtualMachineConfiguration {
        // Load metadata
        let metadataPath = bundlePath + "/metadata.json"
        guard let metadataData = FileManager.default.contents(atPath: metadataPath),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else {
            throw VMRunnerError.metadataNotFound
        }

        let osType = metadata["osType"] as? String ?? "Linux"

        if osType == "macOS" {
            return try createMacOSConfiguration(metadata: metadata)
        } else {
            return try createLinuxConfiguration(metadata: metadata)
        }
    }

    private func createLinuxConfiguration(metadata: [String: Any]) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU
        let cpuCount = metadata["cpuCount"] as? Int ?? 2
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                             min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))

        // Memory
        let memorySize = metadata["memorySize"] as? UInt64 ?? 4 * 1024 * 1024 * 1024
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                               min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        // Boot loader
        let kernelPath = bundlePath + "/vmlinuz"
        let initrdPath = bundlePath + "/initrd"

        if FileManager.default.fileExists(atPath: kernelPath) {
            // Direct kernel boot
            let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
            if FileManager.default.fileExists(atPath: initrdPath) {
                bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
            }
            bootLoader.commandLine = "console=hvc0 root=/dev/vda2"
            config.bootLoader = bootLoader
        } else {
            // EFI boot
            let efiVariableStore: VZEFIVariableStore
            let nvramPath = bundlePath + "/NVRAM"

            if FileManager.default.fileExists(atPath: nvramPath) {
                efiVariableStore = VZEFIVariableStore(url: URL(fileURLWithPath: nvramPath))
            } else {
                efiVariableStore = try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: nvramPath))
            }

            let efiBootLoader = VZEFIBootLoader()
            efiBootLoader.variableStore = efiVariableStore
            config.bootLoader = efiBootLoader
        }

        // Platform
        let platform = VZGenericPlatformConfiguration()
        let machineIdPath = bundlePath + "/MachineIdentifier"

        if FileManager.default.fileExists(atPath: machineIdPath),
           let machineIdData = FileManager.default.contents(atPath: machineIdPath) {
            platform.machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdData)!
        } else {
            let machineId = VZGenericMachineIdentifier()
            try machineId.dataRepresentation.write(to: URL(fileURLWithPath: machineIdPath))
            platform.machineIdentifier = machineId
        }
        config.platform = platform

        // Storage
        let diskPath = bundlePath + "/Disk.img"
        if FileManager.default.fileExists(atPath: diskPath) {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskPath), readOnly: false)
            let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            config.storageDevices = [disk]
        }

        // Network
        let networkConfig = metadata["networkConfig"] as? [String: Any]
        let networkMode = networkConfig?["mode"] as? String ?? "nat"

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        if networkMode == "nat" {
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
        }
        // For "virtual" mode, we'd need the VirtualNetworkSwitch - skip for now
        config.networkDevices = [networkDevice]

        // Serial console (for headless operation)
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        config.serialPorts = [serialPort]

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Keyboard and mouse (for VNC if needed later)
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Graphics (virtual framebuffer for VNC)
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)]
        config.graphicsDevices = [graphicsDevice]

        return config
    }

    private func createMacOSConfiguration(metadata: [String: Any]) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU
        let cpuCount = metadata["cpuCount"] as? Int ?? 4
        config.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                             min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))

        // Memory
        let memorySize = metadata["memorySize"] as? UInt64 ?? 8 * 1024 * 1024 * 1024
        config.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                               min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        // macOS boot loader
        config.bootLoader = VZMacOSBootLoader()

        // macOS platform
        let platform = VZMacPlatformConfiguration()

        // Hardware model
        let hardwareModelPath = bundlePath + "/HardwareModel"
        if let hardwareModelData = FileManager.default.contents(atPath: hardwareModelPath),
           let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) {
            platform.hardwareModel = hardwareModel
        } else {
            throw VMRunnerError.hardwareModelNotFound
        }

        // Machine identifier
        let machineIdPath = bundlePath + "/MachineIdentifier"
        if let machineIdData = FileManager.default.contents(atPath: machineIdPath),
           let machineId = VZMacMachineIdentifier(dataRepresentation: machineIdData) {
            platform.machineIdentifier = machineId
        } else {
            throw VMRunnerError.machineIdNotFound
        }

        // Auxiliary storage
        let auxStoragePath = bundlePath + "/AuxiliaryStorage"
        if FileManager.default.fileExists(atPath: auxStoragePath) {
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: URL(fileURLWithPath: auxStoragePath))
        }

        config.platform = platform

        // Storage
        let diskPath = bundlePath + "/Disk.img"
        if FileManager.default.fileExists(atPath: diskPath) {
            let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: diskPath), readOnly: false)
            let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
            config.storageDevices = [disk]
        }

        // Network
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // Graphics
        let graphicsDevice = VZMacGraphicsDeviceConfiguration()
        graphicsDevice.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)]
        config.graphicsDevices = [graphicsDevice]

        // Keyboard and trackpad
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration()]

        // Audio (optional)
        let audioDevice = VZVirtioSoundDeviceConfiguration()
        let audioInput = VZVirtioSoundDeviceInputStreamConfiguration()
        audioInput.source = VZHostAudioInputStreamSource()
        let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
        audioOutput.sink = VZHostAudioOutputStreamSink()
        audioDevice.streams = [audioInput, audioOutput]
        config.audioDevices = [audioDevice]

        return config
    }

    // MARK: - VZVirtualMachineDelegate

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("VM stopped with error: \(error.localizedDescription)")
        completionHandler?(.failure(error))
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("VM guest stopped")
        completionHandler?(.success(()))
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

// MARK: - Errors

enum VMRunnerError: LocalizedError {
    case vmNotFound
    case vmNotRunning
    case metadataNotFound
    case hardwareModelNotFound
    case machineIdNotFound
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .vmNotFound: return "VM not found"
        case .vmNotRunning: return "VM is not running"
        case .metadataNotFound: return "VM metadata not found"
        case .hardwareModelNotFound: return "macOS hardware model not found"
        case .machineIdNotFound: return "Machine identifier not found"
        case .alreadyRunning: return "VM is already running"
        }
    }
}

// MARK: - VM Process Manager

/// Manages running VM processes
class VMProcessManager {
    static let shared = VMProcessManager()

    private let pidDirectory: String
    private let avfRoot: String

    private init() {
        avfRoot = NSHomeDirectory() + "/.avf"
        pidDirectory = avfRoot + "/run"

        // Create PID directory
        try? FileManager.default.createDirectory(atPath: pidDirectory, withIntermediateDirectories: true)
    }

    func getPidFile(for vmName: String) -> String {
        return pidDirectory + "/\(vmName).pid"
    }

    func isVMRunning(name: String) -> Bool {
        let pidFile = getPidFile(for: name)
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        // Check if process is still running
        return kill(pid, 0) == 0
    }

    func writePidFile(for vmName: String) {
        let pidFile = getPidFile(for: vmName)
        let pid = ProcessInfo.processInfo.processIdentifier
        try? "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    func removePidFile(for vmName: String) {
        let pidFile = getPidFile(for: vmName)
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    func getRunningPid(for vmName: String) -> Int32? {
        let pidFile = getPidFile(for: vmName)
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    func stopVM(name: String, force: Bool = false) -> Bool {
        guard let pid = getRunningPid(for: name) else {
            return false
        }

        let signal: Int32 = force ? SIGKILL : SIGTERM
        let result = kill(pid, signal)

        if result == 0 {
            removePidFile(for: name)
            return true
        }
        return false
    }
}
