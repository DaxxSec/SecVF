// ─────────────────────────────────────────────────────────────────────────────
// AISandboxMacVMConfiguration.swift
//
// macOS guest VM configuration for the AI Sandbox execution environment.
// Replaces the previous Linux/VZGenericPlatformConfiguration approach.
//
// KEY DIFFERENCES FROM LINUX BUILD:
//   - VZMacPlatformConfiguration instead of VZGenericPlatformConfiguration
//   - VZMacOSBootLoader instead of VZEFIBootLoader
//   - VZMacAuxiliaryStorage (NVRAM equivalent for macOS VMs)
//   - VZMacHardwareModel + VZMacMachineIdentifier must be persisted per bundle
//   - VZMacGraphicsDeviceConfiguration required (even for headless use)
//   - IPSW install via VZMacOSInstaller, not cloud-init
//   - Endpoint Security Framework + DTrace replace auditd/tcpdump
//   - iMessage works natively — no BlueBubbles needed
//
// VM BUNDLE STRUCTURE:
//   ~/.avf/AISandbox/ai-sandbox-base-v1.bundle/
//     ├── disk.img              ← main disk (APFS CoW cloned per session)
//     ├── aux.img               ← auxiliary storage (small, also cloned)
//     ├── hardware-model.bin    ← VZMacHardwareModel data (fixed for bundle)
//     ├── machine-identifier.bin ← VZMacMachineIdentifier (fixed for bundle)
//     └── manifest.json         ← version, ai agent version, dates
//
// INSTALL FLOW (run once to build the base):
//   1. Download IPSW via VZMacOSRestoreImage.latestSupported
//   2. Create install VM → VZMacOSInstaller.install()
//   3. Boot provisioned VM → run provision() to install AI agent + tooling
//   4. Shut down → chmod the bundle → snapshot as base
//
// SESSION FLOW (every agent exec):
//   1. cp -c base disk.img → session disk.img  (APFS CoW, ~0ms)
//   2. cp -c base aux.img  → session aux.img
//   3. Boot session VM with cloned bundle
//   4. Execute via vsock:2222
//   5. Collect ESF/DTrace telemetry
//   6. Stop VM → delete session bundle
// ─────────────────────────────────────────────────────────────────────────────

import Virtualization
import Foundation

// ─── CONSTANTS ────────────────────────────────────────────────────────────────

enum AISandboxDefaults {
    // Hardware — Mac Mini M-series (leave headroom for host)
    static let cpuCount:  Int    = 4
    static let memoryGiB: UInt64 = 8

    // Disk — generous for macOS + dev tools + agent workspace
    static let diskGiB: UInt64 = 64

    // Display — headless but macOS requires a display config
    static let displayWidth:  Int = 1280
    static let displayHeight: Int = 800
    static let displayPPI:    Int = 144

    // vsock port for host↔VM IPC (AI Sandbox exec dispatcher)
    static let vsockPort: UInt32 = 2222

    // Bundle paths — stored under ~/.avf/AISandbox alongside Linux/macOS VMs
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".avf/AISandbox")

    static let baseBundle = baseDir
        .appendingPathComponent("ai-sandbox-base-v1.bundle")

    static let sessionsDir = baseDir
        .appendingPathComponent("sessions")
}

// ─── VM BUNDLE ────────────────────────────────────────────────────────────────
// A "bundle" is just a directory — mirrors how Parallels/UTM organise macOS VMs.

struct AISandboxVMBundle {
    let url: URL

    var diskURL:              URL { url.appendingPathComponent("disk.img") }
    var auxStorageURL:        URL { url.appendingPathComponent("aux.img") }
    var hardwareModelURL:     URL { url.appendingPathComponent("hardware-model.bin") }
    var machineIdentifierURL: URL { url.appendingPathComponent("machine-identifier.bin") }
    var manifestURL:          URL { url.appendingPathComponent("manifest.json") }

    /// Load hardware model from the bundle's persisted data
    var hardwareModel: VZMacHardwareModel? {
        guard let data = try? Data(contentsOf: hardwareModelURL) else { return nil }
        return VZMacHardwareModel(dataRepresentation: data)
    }

    /// Load machine identifier from the bundle's persisted data
    var machineIdentifier: VZMacMachineIdentifier? {
        guard let data = try? Data(contentsOf: machineIdentifierURL) else { return nil }
        return VZMacMachineIdentifier(dataRepresentation: data)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Create the bundle directory
    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// APFS CoW clone this bundle to a new session bundle.
    /// On APFS, cp -c (clonefile) makes this nearly instantaneous.
    func clone(to destination: URL) throws {
        // Clone disk image (CoW — zero copy time, zero extra space until written)
        try FileManager.default.copyItem(at: diskURL, to: destination.appendingPathComponent("disk.img"))
        // Clone aux storage (small, but needs its own writable copy)
        try FileManager.default.copyItem(at: auxStorageURL, to: destination.appendingPathComponent("aux.img"))
        // Share hardware model + machine identifier (read-only, no need to copy)
        // Session VMs reuse the base's hardware identity — fine for sandbox use
        try FileManager.default.copyItem(at: hardwareModelURL, to: destination.appendingPathComponent("hardware-model.bin"))
        try FileManager.default.copyItem(at: machineIdentifierURL, to: destination.appendingPathComponent("machine-identifier.bin"))
    }
}

// ─── MAIN CONFIGURATION ───────────────────────────────────────────────────────

struct AISandboxMacVMConfiguration {

    let configuration:  VZVirtualMachineConfiguration
    let socketDevice:   VZVirtioSocketDeviceConfiguration

    /// Build a configuration from an existing provisioned VM bundle.
    /// Use this for session VMs (cloned from base).
    init(bundle: AISandboxVMBundle,
         workspaceURL: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent("ai-sandbox-workspace"),
         sessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent(".avf/AISandbox/sessions"),
         anchorURL: URL = FileManager.default.homeDirectoryForCurrentUser
             .appendingPathComponent("ai-sandbox-workspace/anchor")
    ) throws {

        guard let hardwareModel     = bundle.hardwareModel     else { throw AISandboxVMError.missingHardwareModel }
        guard let machineIdentifier = bundle.machineIdentifier else { throw AISandboxVMError.missingMachineIdentifier }

        let config = VZVirtualMachineConfiguration()

        // ── 1. CPU + Memory ───────────────────────────────────────────────────
        config.cpuCount   = Self.clampCPU(AISandboxDefaults.cpuCount)
        config.memorySize = Self.clampMem(AISandboxDefaults.memoryGiB * 1_073_741_824)

        // ── 2. macOS Platform ─────────────────────────────────────────────────
        // This is the key difference from Linux: VZMacPlatformConfiguration
        // binds the VM to a specific macOS hardware model and serial identity.
        let platform             = VZMacPlatformConfiguration()
        platform.hardwareModel   = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: bundle.auxStorageURL)
        config.platform          = platform

        // ── 3. macOS Boot Loader ──────────────────────────────────────────────
        // VZMacOSBootLoader — no EFI needed, macOS handles its own boot chain
        config.bootLoader = VZMacOSBootLoader()

        // ── 4. Storage ────────────────────────────────────────────────────────
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL, readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // ── 5. Networking ─────────────────────────────────────────────────────
        // NAT — VM reaches internet (through Kali router VM in CSIRT-VF stack).
        // Host→VM comms use vsock only; no TCP ports exposed.
        let netDevice = VZVirtioNetworkDeviceConfiguration()
        netDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [netDevice]

        // ── 6. vsock (host ↔ VM IPC) ──────────────────────────────────────────
        let socketDev = VZVirtioSocketDeviceConfiguration()
        self.socketDevice = socketDev
        config.socketDevices = [socketDev]

        // ── 7. VirtioFS Shared Directories ────────────────────────────────────
        var sharingDevices: [VZDirectorySharingDeviceConfiguration] = []

        // /workspace — agent read/write (only this dir)
        let wsShare  = VZSharedDirectory(url: workspaceURL, readOnly: false)
        let wsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        wsConfig.share = VZSingleDirectoryShare(directory: wsShare)
        sharingDevices.append(wsConfig)

        // /sessions-ro — session history read-only
        let sessShare  = VZSharedDirectory(url: sessionsURL, readOnly: true)
        let sessConfig = VZVirtioFileSystemDeviceConfiguration(tag: "sessions-ro")
        sessConfig.share = VZSingleDirectoryShare(directory: sessShare)
        sharingDevices.append(sessConfig)

        // /anchor-ro — identity anchor (read-only, immutable)
        let anchorShare  = VZSharedDirectory(url: anchorURL, readOnly: true)
        let anchorConfig = VZVirtioFileSystemDeviceConfiguration(tag: "anchor-ro")
        anchorConfig.share = VZSingleDirectoryShare(directory: anchorShare)
        sharingDevices.append(anchorConfig)

        config.directorySharingDevices = sharingDevices

        // ── 8. Graphics ───────────────────────────────────────────────────────
        // macOS guest REQUIRES a graphics configuration even when headless.
        // Set a reasonable resolution; the window can be hidden in your app.
        let display = VZMacGraphicsDisplayConfiguration(
            widthInPixels:  AISandboxDefaults.displayWidth,
            heightInPixels: AISandboxDefaults.displayHeight,
            pixelsPerInch:  AISandboxDefaults.displayPPI
        )
        let graphicsConfig = VZMacGraphicsDeviceConfiguration()
        graphicsConfig.displays = [display]
        config.graphicsDevices = [graphicsConfig]

        // ── 9. Input Devices ──────────────────────────────────────────────────
        // macOS guest requires keyboard + pointer even for headless operation.
        config.keyboards       = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // ── 10. Audio ─────────────────────────────────────────────────────────
        // Minimal audio config — required by some macOS subsystems
        let audioInput         = VZVirtioSoundDeviceInputStreamConfiguration()
        audioInput.source      = VZHostAudioInputStreamSource()
        let audioOutput        = VZVirtioSoundDeviceOutputStreamConfiguration()
        audioOutput.sink       = VZHostAudioOutputStreamSink()
        let audioDevice        = VZVirtioSoundDeviceConfiguration()
        audioDevice.streams    = [audioInput, audioOutput]
        config.audioDevices    = [audioDevice]

        // ── 11. Entropy ───────────────────────────────────────────────────────
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // ── 12. Memory Balloon ────────────────────────────────────────────────
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // ── 13. Validate ──────────────────────────────────────────────────────
        try config.validate()
        self.configuration = config
    }

    private static func clampCPU(_ n: Int) -> Int {
        (VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount).clamped(to: 1...64).contains(n) ? n : max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, n))
    }
    private static func clampMem(_ n: UInt64) -> UInt64 {
        max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, n))
    }
}


// ─── INSTALLER — BUILD THE BASE BUNDLE ───────────────────────────────────────
// Run this ONCE to create ai-sandbox-base-v1.bundle.
// This is your "build IPSW → install → provision → snapshot" pipeline.

class AISandboxMacVMInstaller {

    static let bundleURL = AISandboxDefaults.baseBundle

    // ── Step 1: Download IPSW + create VM bundle ──────────────────────────────
    static func downloadAndInstall(
        progress: @escaping (Double) -> Void
    ) async throws -> AISandboxVMBundle {

        let bundle = AISandboxVMBundle(url: bundleURL)
        guard !bundle.exists else {
            throw AISandboxVMError.bundleAlreadyExists(bundleURL)
        }
        try bundle.create()

        // ── Get latest supported restore image (IPSW URL from Apple CDN) ──────
        // VZMacOSRestoreImage.latestSupported queries Apple's servers for the
        // most recent macOS version compatible with this host's hardware.
        let restoreImage = try await VZMacOSRestoreImage.latestSupported

        // Get the hardware requirements for this restore image
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw AISandboxVMError.noSupportedConfiguration
        }

        // ── Create + persist hardware identity ────────────────────────────────
        // These two values MUST be saved — they define the VM's hardware identity.
        // If lost, the VM may fail to boot or show activation issues.
        let hardwareModel     = requirements.hardwareModel
        let machineIdentifier = VZMacMachineIdentifier()  // fresh unique identity

        try hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
        try machineIdentifier.dataRepresentation.write(to: bundle.machineIdentifierURL)

        // ── Create auxiliary storage ───────────────────────────────────────────
        // Equivalent to NVRAM on a physical Mac — macOS stores boot state here.
        let auxStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: bundle.auxStorageURL,
            hardwareModel: hardwareModel,
            options: [.allowOverwrite]
        )
        _ = auxStorage // will be loaded by configuration

        // ── Create disk image ─────────────────────────────────────────────────
        try createDisk(at: bundle.diskURL, sizeGiB: AISandboxDefaults.diskGiB)

        // ── Build install configuration ───────────────────────────────────────
        let installConfig = VZVirtualMachineConfiguration()
        installConfig.cpuCount   = max(requirements.minimumSupportedCPUCount, AISandboxDefaults.cpuCount)
        installConfig.memorySize = max(requirements.minimumSupportedMemorySize, AISandboxDefaults.memoryGiB * 1_073_741_824)

        let platform             = VZMacPlatformConfiguration()
        platform.hardwareModel   = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage  = VZMacAuxiliaryStorage(contentsOf: bundle.auxStorageURL)
        installConfig.platform   = platform
        installConfig.bootLoader = VZMacOSBootLoader()

        let diskAtt = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        installConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAtt)]

        let netDev = VZVirtioNetworkDeviceConfiguration()
        netDev.attachment = VZNATNetworkDeviceAttachment()
        installConfig.networkDevices = [netDev]

        let display = VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 144)
        let gfx = VZMacGraphicsDeviceConfiguration()
        gfx.displays = [display]
        installConfig.graphicsDevices = [gfx]
        installConfig.keyboards       = [VZUSBKeyboardConfiguration()]
        installConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        installConfig.entropyDevices  = [VZVirtioEntropyDeviceConfiguration()]

        try installConfig.validate()

        // ── Install macOS from IPSW ───────────────────────────────────────────
        let vm        = VZVirtualMachine(configuration: installConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage.url)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Observe install progress
            var obs: NSKeyValueObservation?
            obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                progress(change.newValue ?? 0)
            }

            installer.install { result in
                obs?.invalidate()
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
        }

        return bundle
    }

    // ── Step 2: Provision the installed VM ────────────────────────────────────
    // After install, boot the VM and run the setup script.
    // The setup script installs the AI agent and configures monitoring.
    static func provisionBundle(_ bundle: AISandboxVMBundle) async throws {
        let vmConfig = try AISandboxMacVMConfiguration(bundle: bundle)
        let vm       = VZVirtualMachine(configuration: vmConfig.configuration)

        try await vm.start()

        // Wait for the vsock agent to come up (provision script starts it)
        try await Task.sleep(nanoseconds: 30_000_000_000) // 30s for first boot + login

        // Send the provision script via vsock
        guard let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw AISandboxVMError.socketDeviceNotFound
        }

        let provisionScript = try String(
            contentsOf: Bundle.main.url(forResource: "provision-macos-vm", withExtension: "sh")!
        )

        _ = try await sendVsockCommand(provisionScript, socketDevice: socketDev)

        // Graceful shutdown
        try await vm.stop()
    }

    // ── Seal the base bundle ──────────────────────────────────────────────────
    static func sealBundle(_ bundle: AISandboxVMBundle) throws {
        // Write manifest
        let manifest: [String: Any] = [
            "vm_type":   "ai-sandbox-macos-base",
            "version":   "1.0",
            "sealed_at": ISO8601DateFormatter().string(from: Date()),
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "disk_size_gib": AISandboxDefaults.diskGiB,
            "cpu_count":     AISandboxDefaults.cpuCount,
            "memory_gib":    AISandboxDefaults.memoryGiB
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
        try data.write(to: bundle.manifestURL)

        // Make disk + hardware model read-only (seal them)
        // Session VMs get their own CoW copy of disk.img and aux.img
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: bundle.diskURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: bundle.hardwareModelURL.path
        )
    }

    // ── Disk creation helper ──────────────────────────────────────────────────
    private static func createDisk(at url: URL, sizeGiB: UInt64) throws {
        let sizeBytes = Int64(sizeGiB * 1_073_741_824)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AISandboxVMError.diskCreationFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeBytes))
    }

    // ── vsock command helper ──────────────────────────────────────────────────
    private static func sendVsockCommand(
        _ command: String,
        socketDevice: VZVirtioSocketDevice
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            socketDevice.connect(toPort: AISandboxDefaults.vsockPort) { result in
                switch result {
                case .failure(let e): cont.resume(throwing: e)
                case .success(let conn):
                    conn.fileHandleForWriting.write((command + "\n").data(using: .utf8)!)
                    var output = ""
                    var hasResumed = false
                    conn.fileHandleForReading.readabilityHandler = { fh in
                        let d = fh.availableData
                        if d.isEmpty {
                            fh.readabilityHandler = nil
                            guard !hasResumed else { return }
                            hasResumed = true
                            cont.resume(returning: output)
                        } else {
                            output += String(data: d, encoding: .utf8) ?? ""
                        }
                    }
                }
            }
        }
    }
}


// ─── SESSION VM ───────────────────────────────────────────────────────────────

@MainActor
class AISandboxVMSession {

    let sessionID:  String
    let bundleURL:  URL
    var vm:         VZVirtualMachine?

    init(sessionID: String = UUID().uuidString.prefix(8).lowercased() + "") {
        self.sessionID = String(sessionID)
        self.bundleURL = AISandboxDefaults.sessionsDir
            .appendingPathComponent("ai-sandbox-exec-\(sessionID).bundle")
    }

    // Clone base → session (APFS CoW, ~0ms on APFS)
    func cloneBase() throws {
        let base = AISandboxVMBundle(url: AISandboxDefaults.baseBundle)
        guard base.exists else { throw AISandboxVMError.baseBundleNotFound }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try base.clone(to: bundleURL)
    }

    func boot() async throws {
        let bundle = AISandboxVMBundle(url: bundleURL)
        let config = try AISandboxMacVMConfiguration(bundle: bundle)
        let machine = VZVirtualMachine(configuration: config.configuration)
        self.vm = machine
        try await machine.start()
    }

    func run(command: String) async throws -> String {
        guard let machine = vm,
              let socketDev = machine.socketDevices.first as? VZVirtioSocketDevice
        else { throw AISandboxVMError.socketDeviceNotFound }

        return try await withCheckedThrowingContinuation { cont in
            socketDev.connect(toPort: AISandboxDefaults.vsockPort) { result in
                switch result {
                case .failure(let e): cont.resume(throwing: e)
                case .success(let conn):
                    conn.fileHandleForWriting.write((command + "\n").data(using: .utf8)!)
                    var out = ""
                    var hasResumed = false
                    conn.fileHandleForReading.readabilityHandler = { fh in
                        let d = fh.availableData
                        if d.isEmpty {
                            fh.readabilityHandler = nil
                            guard !hasResumed else { return }
                            hasResumed = true
                            cont.resume(returning: out)
                        } else { out += String(data: d, encoding: .utf8) ?? "" }
                    }
                }
            }
        }
    }

    func destroy() async throws {
        if let machine = vm, machine.state == .running {
            try await machine.stop()
        }
        vm = nil
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
    }
}

// ─── ERRORS ───────────────────────────────────────────────────────────────────

enum AISandboxVMError: LocalizedError {
    case missingHardwareModel
    case missingMachineIdentifier
    case noSupportedConfiguration
    case bundleAlreadyExists(URL)
    case baseBundleNotFound
    case diskCreationFailed
    case socketDeviceNotFound

    var errorDescription: String? {
        switch self {
        case .missingHardwareModel:        return "VM bundle missing hardware-model.bin"
        case .missingMachineIdentifier:    return "VM bundle missing machine-identifier.bin"
        case .noSupportedConfiguration:    return "Restore image has no supported configuration for this host"
        case .bundleAlreadyExists(let u):  return "Base bundle already exists at: \(u.path)"
        case .baseBundleNotFound:          return "Base bundle not found — run installer first"
        case .diskCreationFailed:          return "Could not create disk image file"
        case .socketDeviceNotFound:        return "vsock device not found or VM not running"
        }
    }
}
