//
//  VsockExecBridge.swift
//  SecVF
//
//  Bridges a per-VM Unix domain socket to the guest's vsock exec channel
//  (port 2222 by default). Lets cross-process — and cross-user — clients
//  drive the AI sandbox guest without owning a VZVirtioSocketDevice
//  themselves.
//
//  Wire shape:
//
//      client (any user)                    SecVF.app                  guest
//      ─────────────────                    ─────────                  ─────
//      connect /tmp/secvf-exec-<UUID>.sock  ─── UDS accept ──────────►
//                                           ─── VZVirtioSocketDevice
//                                               .connect(2222) ──────► socat
//                                                                       │
//      send command + read stdout  ◄────── byte-pipe both directions ─► EXEC
//      EOF on either side          ◄────── tears down both legs ──────►
//
//  Designed for use with `secvf-cli vm exec`. Cross-user access via
//  mode 0666 on the UDS — the multi-user mac mini setup needs this.
//

import Darwin
import Foundation
import Virtualization

/// Per-VM bridge that exposes the AI Sandbox vsock exec channel as a Unix
/// domain socket so non-SecVF processes can drive the guest.
final class VsockExecBridge {

    let vmId: UUID
    let vmName: String
    let socketPath: String

    private weak var vm: VZVirtualMachine?
    private let vsockPort: UInt32

    private var listenerFd: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private let queue = DispatchQueue(
        label: "com.secvf.vsock-exec-bridge",
        qos: .userInitiated
    )
    private(set) var isRunning = false

    init(
        vmId: UUID,
        vmName: String,
        vm: VZVirtualMachine,
        vsockPort: UInt32 = AISandboxDefaults.vsockPort
    ) {
        self.vmId = vmId
        self.vmName = vmName
        self.vm = vm
        self.vsockPort = vsockPort
        // Use the VM ID rather than name in the path — names can collide /
        // change, IDs are stable.
        self.socketPath = "/tmp/secvf-exec-\(vmId.uuidString).sock"
    }

    deinit { stopInternal() }

    // MARK: - Lifecycle

    func start() throws {
        // Clear any stale socket file from a prior crash.
        unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VsockExecBridgeError.socketCreate(errno: errno)
        }
        // Don't leak this fd into child processes.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= pathCapacity else {
            close(fd)
            throw VsockExecBridgeError.pathTooLong(socketPath)
        }

        let bindOK: Bool = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        memcpy(dst, base, pathBytes.count)
                    }
                }
                let rc = withUnsafePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                        Darwin.bind(fd, saptr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                return rc == 0
            }
        }

        guard bindOK else {
            let e = errno
            close(fd)
            throw VsockExecBridgeError.bind(errno: e, path: socketPath)
        }

        // Cross-user access on the multi-user mac mini.
        chmod(socketPath, 0o666)

        guard Darwin.listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw VsockExecBridgeError.listen(errno: e)
        }

        listenerFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { [weak self] in
            guard let self = self, self.listenerFd >= 0 else { return }
            close(self.listenerFd)
            self.listenerFd = -1
        }
        src.resume()
        listenerSource = src
        isRunning = true

        NSLog("[VsockExecBridge] %@ listening at %@", vmName, socketPath)
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        isRunning = false
        listenerSource?.cancel()
        listenerSource = nil
        // listenerFd is closed inside the source's cancel handler.
        unlink(socketPath)
    }

    // MARK: - Accept

    private func acceptOne() {
        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(listenerFd, &clientAddr, &clientLen)
        guard clientFd >= 0 else { return }
        _ = fcntl(clientFd, F_SETFD, FD_CLOEXEC)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.bridgeOneConnection(clientFd: clientFd)
        }
    }

    // MARK: - Bridging

    private func bridgeOneConnection(clientFd: Int32) {
        let clientHandle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: true)

        guard let vm = vm else {
            try? clientHandle.write(
                contentsOf: Data("secvf-exec-bridge: VM no longer running\n".utf8)
            )
            try? clientHandle.close()
            return
        }
        guard let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice else {
            try? clientHandle.write(
                contentsOf: Data("secvf-exec-bridge: no vsock device on VM\n".utf8)
            )
            try? clientHandle.close()
            return
        }

        // Open the vsock connection. The completion fires on an internal queue,
        // so the semaphore wait below doesn't deadlock.
        let sem = DispatchSemaphore(value: 0)
        var connOpt: VZVirtioSocketConnection?
        var connErr: Error?
        socketDev.connect(toPort: vsockPort) { result in
            switch result {
            case .success(let c): connOpt = c
            case .failure(let e): connErr = e
            }
            sem.signal()
        }
        sem.wait()

        guard let vsockConn = connOpt else {
            let msg: String
            if let e = connErr {
                msg = "secvf-exec-bridge: vsock connect to :\(vsockPort) failed: \(e.localizedDescription)\n"
            } else {
                msg = "secvf-exec-bridge: vsock connect to :\(vsockPort) returned nil (is the exec agent running in the guest?)\n"
            }
            try? clientHandle.write(contentsOf: Data(msg.utf8))
            try? clientHandle.close()
            return
        }

        let vsockHandle = FileHandle(
            fileDescriptor: vsockConn.fileDescriptor,
            closeOnDealloc: false
        )

        // Two-leg pipe — exit when either side EOFs.
        let state = BridgeState()
        let group = DispatchGroup()
        group.enter()
        group.enter()

        clientHandle.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                state.tearDown(other: vsockHandle, group: group)
            } else {
                do { try vsockHandle.write(contentsOf: d) } catch {
                    fh.readabilityHandler = nil
                    state.tearDown(other: vsockHandle, group: group)
                }
            }
        }

        vsockHandle.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                state.tearDown(other: clientHandle, group: group)
            } else {
                do { try clientHandle.write(contentsOf: d) } catch {
                    fh.readabilityHandler = nil
                    state.tearDown(other: clientHandle, group: group)
                }
            }
        }

        group.wait()

        // Keep the vsock connection alive until both legs are done.
        _ = vsockConn
        try? clientHandle.close()
    }
}

/// Reference type for tear-down state — shared between the two leg handlers.
private final class BridgeState {
    private let lock = NSLock()
    private var torn = false

    func tearDown(other: FileHandle, group: DispatchGroup) {
        lock.lock()
        let firstLegFinishing = !torn
        torn = true
        lock.unlock()
        group.leave()
        if firstLegFinishing {
            other.readabilityHandler = nil
            try? other.close()
            group.leave()
        }
    }
}

// MARK: - Manager singleton

/// Process-wide registry of active vsock exec bridges, one per running VM.
/// Mirrors `VMSecurityMonitor.shared` so AppDelegate hooks the lifecycle in
/// the same place — start when a VM starts, stop when it stops.
final class VsockExecBridgeManager {
    static let shared = VsockExecBridgeManager()

    private let lock = NSLock()
    private var bridges: [UUID: VsockExecBridge] = [:]

    private init() {}

    /// Start a bridge for `vm`. No-op if the VM has no vsock device (the
    /// regular Linux VMs and non-AI-sandbox macOS VMs don't carry one).
    func startBridge(vmId: UUID, vmName: String, vm: VZVirtualMachine) {
        guard vm.socketDevices.first is VZVirtioSocketDevice else { return }
        let bridge = VsockExecBridge(vmId: vmId, vmName: vmName, vm: vm)
        do {
            try bridge.start()
            lock.lock()
            bridges[vmId]?.stop()
            bridges[vmId] = bridge
            lock.unlock()
        } catch {
            NSLog("[VsockExecBridgeManager] %@ start failed: %@",
                  vmName, error.localizedDescription)
        }
    }

    func stopBridge(vmId: UUID) {
        lock.lock()
        let bridge = bridges.removeValue(forKey: vmId)
        lock.unlock()
        bridge?.stop()
    }

    func socketPath(forVmId vmId: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return bridges[vmId]?.socketPath
    }

    func socketPath(forVmName vmName: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return bridges.values.first(where: { $0.vmName == vmName })?.socketPath
    }
}


enum VsockExecBridgeError: LocalizedError {
    case socketCreate(errno: Int32)
    case bind(errno: Int32, path: String)
    case listen(errno: Int32)
    case pathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .socketCreate(let e):
            return "socket() failed: \(String(cString: strerror(e)))"
        case .bind(let e, let p):
            return "bind(\(p)) failed: \(String(cString: strerror(e)))"
        case .listen(let e):
            return "listen() failed: \(String(cString: strerror(e)))"
        case .pathTooLong(let p):
            return "Unix domain socket path too long for sun_path: \(p)"
        }
    }
}
