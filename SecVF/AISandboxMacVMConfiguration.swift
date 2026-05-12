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
import Darwin   // flock(2), open(2), close(2)

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

    // MARK: - One-shot Recovery boot flag (manifest-backed)
    //
    // Persisted on the base bundle's manifest.json. Scope: "the next
    // session spawned from this base should boot into macOS Recovery."
    // The Disk.img + HardwareModel are sealed read-only via 0o444 but
    // the manifest is writable — exactly where this kind of one-shot
    // toggle should live.
    //
    // Sessions are ephemeral CoW clones, so Recovery operations run on
    // the clone's disk and never risk the base. Once a session is
    // spawned with the flag, the base manifest clears it so future
    // sessions are normal.

    /// Read `bootIntoRecoveryNext` from the manifest. Returns false if
    /// the field is missing or the manifest can't be read — fail-safe
    /// default for a security-relevant boot choice.
    func loadBootIntoRecoveryNext() -> Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return (manifest["bootIntoRecoveryNext"] as? Bool) ?? false
    }

    /// Set (or clear) the one-shot Recovery flag on the manifest.
    /// throws on disk errors so callers can surface the failure rather
    /// than silently dropping a security-relevant boot choice.
    func setBootIntoRecoveryNext(_ value: Bool) throws {
        var manifest: [String: Any] = [:]
        if let existing = try? Data(contentsOf: manifestURL),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            manifest = parsed
        }
        if value {
            manifest["bootIntoRecoveryNext"] = true
        } else {
            manifest.removeValue(forKey: "bootIntoRecoveryNext")
        }
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: .prettyPrinted
        )
        try data.write(to: manifestURL, options: .atomic)
    }

    /// APFS CoW clone this bundle to a new session bundle.
    /// On APFS, cp -c (clonefile) makes this nearly instantaneous.
    func clone(to destination: URL) throws {
        let fm = FileManager.default

        // Clone disk image (CoW — zero copy time, zero extra space until written)
        let clonedDisk = destination.appendingPathComponent("disk.img")
        try fm.copyItem(at: diskURL, to: clonedDisk)
        // Clone aux storage (small, but needs its own writable copy)
        let clonedAux = destination.appendingPathComponent("aux.img")
        try fm.copyItem(at: auxStorageURL, to: clonedAux)

        // The sealed base has 0o444 on disk.img/aux.img — make the session
        // copies writable so VZ can attach them with readOnly: false.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: clonedDisk.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: clonedAux.path)

        // Share hardware model + machine identifier (read-only, no need to copy)
        // Session VMs reuse the base's hardware identity — fine for sandbox use
        try fm.copyItem(at: hardwareModelURL, to: destination.appendingPathComponent("hardware-model.bin"))
        try fm.copyItem(at: machineIdentifierURL, to: destination.appendingPathComponent("machine-identifier.bin"))
    }
}

// ─── MAIN CONFIGURATION ───────────────────────────────────────────────────────

struct AISandboxMacVMConfiguration {

    let configuration:  VZVirtualMachineConfiguration
    let socketDevice:   VZVirtioSocketDeviceConfiguration

    /// Build a configuration from an existing provisioned VM bundle.
    /// Use this for session VMs (cloned from base).
    init(bundle: AISandboxVMBundle,
         workspaceURL: URL = AISandboxDefaults.baseDir
             .appendingPathComponent("workspace"),
         sessionsURL: URL = AISandboxDefaults.sessionsDir,
         anchorURL: URL = AISandboxDefaults.baseDir
             .appendingPathComponent("workspace/anchor")
    ) throws {

        guard let hardwareModel     = bundle.hardwareModel     else { throw AISandboxVMError.missingHardwareModel }
        guard let machineIdentifier = bundle.machineIdentifier else { throw AISandboxVMError.missingMachineIdentifier }

        // Ensure shared directories exist before VZSharedDirectory touches them
        let fm = FileManager.default
        for dir in [workspaceURL, sessionsURL, anchorURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

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
        // Pin VirtioBlock unconditionally — NVMe (VZNVMExpressController) is
        // only valid with VZGenericPlatformConfiguration (Linux guests). The
        // disk image was installed via VZVirtioBlockDeviceConfiguration, so
        // switching controller types would also lose the boot volume.
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL, readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        ]

        // ── 5. Networking ─────────────────────────────────────────────────────
        // NAT — VM reaches internet (through Kali router VM in SecVF stack).
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


// ─── VSOCK CHANNEL — HOST↔GUEST IPC ───────────────────────────────────────────
// Thin wrapper around VZVirtioSocketDevice for the AI Sandbox vsock surface.
// The guest's vsock-agent (installed by provision-macos-vm.sh) listens on
// :2222 with `socat VSOCK-LISTEN:2222,reuseaddr,fork EXEC:.../exec-handler.sh`,
// which reads ONE command line per connection, runs it, and closes the socket.
//
// `runOneShot` matches that lifecycle: write a command, drain stdout until
// the guest closes, return the accumulated string. Future streaming probes
// (e.g. dtrace) can be added as additional methods on this enum.

enum VsockChannel {
    /// Send `command` over vsock to the guest and accumulate stdout until the
    /// guest closes the socket. Suitable for the one-shot exec agent.
    static func runOneShot(
        on vm: VZVirtualMachine,
        port: UInt32 = AISandboxDefaults.vsockPort,
        command: String
    ) async throws -> String {
        guard let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw AISandboxVMError.socketDeviceNotFound
        }
        return try await connect(socketDevice: socketDev, port: port, command: command)
    }

    /// Same as `runOneShot` but takes a pre-resolved socket device — used when
    /// the caller already holds a reference (e.g. installer flows).
    static func runOneShot(
        socketDevice: VZVirtioSocketDevice,
        port: UInt32 = AISandboxDefaults.vsockPort,
        command: String
    ) async throws -> String {
        return try await connect(socketDevice: socketDevice, port: port, command: command)
    }

    private static func connect(
        socketDevice: VZVirtioSocketDevice,
        port: UInt32,
        command: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            socketDevice.connect(toPort: port) { result in
                switch result {
                case .failure(let err):
                    cont.resume(throwing: err)
                case .success(let conn):
                    // VZVirtioSocketConnection exposes a raw fileDescriptor; wrap
                    // it in a FileHandle to use the readabilityHandler API. The
                    // socket is bidirectional, so the same handle reads and writes.
                    let handle = FileHandle(fileDescriptor: conn.fileDescriptor, closeOnDealloc: false)
                    if let payload = (command + "\n").data(using: .utf8) {
                        do { try handle.write(contentsOf: payload) } catch {
                            cont.resume(throwing: error)
                            return
                        }
                    }
                    let state = VsockReadState()
                    handle.readabilityHandler = { fh in
                        let d = fh.availableData
                        if d.isEmpty {
                            fh.readabilityHandler = nil
                            guard !state.hasResumed else { return }
                            state.hasResumed = true
                            // Hold onto `conn` until we're done so the fd stays open.
                            _ = conn
                            cont.resume(returning: state.output)
                        } else {
                            state.output += String(data: d, encoding: .utf8) ?? ""
                        }
                    }
                }
            }
        }
    }
}

/// Reference-typed state for the vsock read continuation. Avoids Swift 6
/// sendable-closure-capture warnings by holding mutable fields on an object
/// rather than as captured `var`s.
private final class VsockReadState {
    var output: String = ""
    var hasResumed: Bool = false
}


// ─── INSTALLER — BUILD THE BASE BUNDLE ───────────────────────────────────────
// Run this ONCE to create ai-sandbox-base-v1.bundle.
// This is your "build IPSW → install → provision → snapshot" pipeline.

class AISandboxMacVMInstaller {

    static let bundleURL = AISandboxDefaults.baseBundle

    // ── Step 1: Download IPSW + create VM bundle ──────────────────────────────
    /// Build a fresh AI Sandbox base bundle. If `localIPSW` is provided and
    /// readable, that IPSW is used (skipping the multi-GB download); otherwise
    /// the latest supported macOS image is fetched from Apple's CDN.
    ///
    /// `@MainActor` because `VZVirtualMachine.init`, `VZMacOSInstaller.init`,
    /// and `installer.install` all assert they're called on the main queue.
    @MainActor
    static func downloadAndInstall(
        localIPSW: URL? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> AISandboxVMBundle {

        let bundle = AISandboxVMBundle(url: bundleURL)
        guard !bundle.exists else {
            throw AISandboxVMError.bundleAlreadyExists(bundleURL)
        }
        try bundle.create()

        // Clean up the bundle directory on any FATAL failure so the next
        // attempt starts fresh without prompting "Replace existing bundle?".
        //
        // Critical: skip the cleanup on `CancellationError`. A superseded
        // run reaches its catch arm AFTER the replacement run has already
        // started its own `bundle.create()` against the same path; if we
        // delete on cancellation, we silently corrupt the in-flight run.
        // See PR #4 review C1 (docs/PR4_REVIEW_FIXES_2026-05-03.md).
        var installSucceeded = false
        var wasCancelled = false
        defer {
            if !installSucceeded && !wasCancelled {
                try? FileManager.default.removeItem(at: bundle.url)
            }
        }

        do {
            return try await Self.installAfterBundleCreated(
                bundle: bundle,
                localIPSW: localIPSW,
                progress: progress,
                installSucceeded: &installSucceeded
            )
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    /// Inner install body. Split out from `downloadAndInstall` so the
    /// outer function can wrap it in a single do/catch that distinguishes
    /// CancellationError from other failures (controls whether the
    /// cleanup defer runs). `installSucceeded` is an inout flag so the
    /// outer defer sees the final value.
    @MainActor
    private static func installAfterBundleCreated(
        bundle: AISandboxVMBundle,
        localIPSW: URL?,
        progress: @escaping (Double) -> Void,
        installSucceeded: inout Bool
    ) async throws -> AISandboxVMBundle {

        // ── Preflight: aux storage flock ──────────────────────────────────────
        // VZ's `installConfig.validate()` will surface a generic "Invalid
        // virtual machine configuration / Failed to lock auxiliary storage"
        // (VZErrorDomain 2 / NSPOSIXErrorDomain 35 EAGAIN) if anything else
        // has an exclusive lock on aux.img. Detect that here so the user
        // gets actionable guidance ("kill these processes") instead of VZ's
        // opaque wrapper. We probe via a non-blocking flock on a freshly-
        // opened FD; success → close immediately so creatingStorageAt: can
        // take the real lock. Tiny TOCTOU window we accept (an attacker who
        // could exploit it already had the lock).
        try Self.assertAuxStorageNotExternallyLocked(at: bundle.auxStorageURL)

        try Task.checkCancellation()  // honor task cancellation

        // ── Resolve restore image ─────────────────────────────────────────────
        // VZMacOSInstaller only accepts local file URLs — passing a network URL
        // causes an immediate failure. Always require a pre-downloaded IPSW;
        // the caller (createAISandboxVM) guards this before starting the task.
        guard let localIPSW = localIPSW, FileManager.default.fileExists(atPath: localIPSW.path) else {
            throw AISandboxVMError.noLocalIPSW
        }
        let restoreImage = try await VZMacOSRestoreImage.image(from: localIPSW)

        try Task.checkCancellation()

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

        // Translate VZ's generic wrap of EAGAIN into our specific error so
        // the recovery suggestion fires. Any other validation failure
        // bubbles up unchanged.
        do {
            try installConfig.validate()
        } catch {
            if Self.isAuxStorageLockError(error) {
                throw SecVFError.auxiliaryStorageLocked(path: bundle.auxStorageURL.path)
            }
            throw error
        }

        // ── Install macOS from IPSW ───────────────────────────────────────────
        // We're already on @MainActor (function annotation), so the framework
        // queue assertions are satisfied. Suspending on Task.sleep / network
        // calls / completion handlers all hop off main while suspended; we
        // come back to main when resumed, which is what VZ wants.
        let vm = VZVirtualMachine(configuration: installConfig)
        // Use localIPSW directly — VZMacOSInstaller requires a local file URL.
        let installer = VZMacOSInstaller(
            virtualMachine: vm,
            restoringFromImageAt: localIPSW
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var obs: NSKeyValueObservation?
            obs = installer.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                progress(change.newValue ?? 0)
            }
            installer.install { result in
                obs?.invalidate()
                switch result {
                case .success: cont.resume()
                case .failure(let err):
                    // Translate AMRestore errors (buried under VZErrorDomain 10007)
                    // into an actionable message instead of the raw error chain.
                    if Self.isAMRestoreError(err) {
                        cont.resume(throwing: AISandboxVMError.ipswIncompatibleOrCorrupt)
                    } else {
                        cont.resume(throwing: err)
                    }
                }
            }
        }

        installSucceeded = true
        return bundle
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// Non-blocking flock check on aux.img. If the file doesn't exist yet
    /// (clean-slate install), we no-op and let `creatingStorageAt:` create it.
    /// If it exists and an exclusive flock is unavailable, we throw with the
    /// path so SecVFError can render the user-facing diagnostic.
    private static func assertAuxStorageNotExternallyLocked(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else {
            // Can't open at all — distinct error class; let creatingStorageAt:
            // surface the underlying reason with its own error.
            return
        }
        defer { close(fd) }
        // LOCK_EX | LOCK_NB: exclusive, non-blocking. Returns -1/EAGAIN if held.
        let r = flock(fd, LOCK_EX | LOCK_NB)
        if r != 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                throw SecVFError.auxiliaryStorageLocked(path: url.path)
            }
            // Other flock failures (EBADF, ENOLCK, …) are not the lock-held
            // case; let downstream surface them with their own specifics.
            return
        }
        // Release the lock so the real `creatingStorageAt:` can take it.
        // The fd close in `defer` already does this; flock(LOCK_UN) is
        // belt-and-suspenders for clarity.
        _ = flock(fd, LOCK_UN)
    }

    /// Returns true if the given Error is a VZMacOSInstaller failure caused by
    /// the underlying AMRestore engine (com.apple.MobileDevice.MobileRestore).
    /// This typically means the IPSW is stale, corrupted, or incompatible with
    /// the current host. The fix is to re-download via Tools → Download macOS IPSW.
    private static func isAMRestoreError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == VZErrorDomain, ns.code == 10007 else { return false }
        var current: NSError? = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let e = current {
            if e.domain == "com.apple.MobileDevice.MobileRestore" { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Returns true if the given Error is VZ's wrap of POSIX EAGAIN on aux
    /// storage. We check by walking the underlying-error chain rather than
    /// matching error message strings (which Apple may localize/reword).
    private static func isAuxStorageLockError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == VZErrorDomain else { return false }
        var current: NSError? = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain, e.code == Int(EAGAIN) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // ── Step 2: Provision the installed VM ────────────────────────────────────
    // After install, boot the VM and run the setup script.
    // The setup script installs the AI agent and configures monitoring.
    ///
    /// `@MainActor` for the same reason as `downloadAndInstall`: VZ lifecycle
    /// APIs require the main queue.
    @MainActor
    static func provisionBundle(_ bundle: AISandboxVMBundle) async throws {
        let vmConfig = try AISandboxMacVMConfiguration(bundle: bundle)
        let vm = VZVirtualMachine(configuration: vmConfig.configuration)

        try await vm.start()

        // Wait for the vsock agent to come up (provision script starts it)
        try await Task.sleep(nanoseconds: 30_000_000_000) // 30s for first boot + login

        // Send the provision script via vsock
        guard let scriptURL = Bundle.main.url(
            forResource: "provision-macos-vm", withExtension: "sh"
        ) else {
            throw AISandboxVMError.provisionScriptMissing
        }
        let provisionScript = try String(contentsOf: scriptURL, encoding: .utf8)

        _ = try await VsockChannel.runOneShot(on: vm, command: provisionScript)

        // Graceful shutdown
        try await vm.stop()
    }

    // ── Seal the base bundle ──────────────────────────────────────────────────
    static func sealBundle(_ bundle: AISandboxVMBundle) throws {
        // Write manifest — include a stable id + name so the CLI can address this bundle
        let manifest: [String: Any] = [
            "id":        UUID().uuidString,
            "name":      "ai-sandbox-base-v1",
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
        guard let machine = vm else { throw AISandboxVMError.socketDeviceNotFound }
        return try await VsockChannel.runOneShot(on: machine, command: command)
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
    case provisionScriptMissing
    case noLocalIPSW
    case ipswIncompatibleOrCorrupt

    var errorDescription: String? {
        switch self {
        case .missingHardwareModel:        return "VM bundle missing hardware-model.bin"
        case .missingMachineIdentifier:    return "VM bundle missing machine-identifier.bin"
        case .noSupportedConfiguration:    return "Restore image has no supported configuration for this host"
        case .bundleAlreadyExists(let u):  return "Base bundle already exists at: \(u.path)"
        case .baseBundleNotFound:          return "Base bundle not found — run installer first"
        case .diskCreationFailed:          return "Could not create disk image file"
        case .socketDeviceNotFound:        return "vsock device not found or VM not running"
        case .provisionScriptMissing:      return "provision-macos-vm.sh not found in app bundle resources"
        case .noLocalIPSW:                 return "No local IPSW found — use Tools → Download macOS IPSW first"
        case .ipswIncompatibleOrCorrupt:   return "The cached IPSW is incompatible or corrupted. Use Tools → Download macOS IPSW to download a fresh copy, then try again."
        }
    }
}
