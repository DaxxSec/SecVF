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

#if canImport(Glibc)
import Glibc
#endif

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

    /// Canonical port is `AISandboxDefaults.vsockPort` (2222). Hardcoded here
    /// as the default arg so the bridge file has no cross-file compile-time
    /// dependency on the AI sandbox config — it works for any VM with any
    /// vsock listener on 2222, AI sandbox or otherwise.
    init(
        vmId: UUID,
        vmName: String,
        vm: VZVirtualMachine,
        vsockPort: UInt32 = 2222
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

        // Phase 1: copy path bytes into addr.sun_path. This needs exclusive
        // access to the sun_path field, so we keep this scope tight and
        // exit it before taking a pointer to the whole `addr` for bind().
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        memcpy(dst, base, pathBytes.count)
                    }
                }
            }
        }

        // Phase 2: bind, with a fresh exclusive access to `addr` as a whole.
        let bindResult: Int32 = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                Darwin.bind(fd, saptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
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

        // SECURITY: peer-credential gate.
        //
        // The UDS lives at /tmp/secvf-exec-<UUID>.sock with mode 0666 so
        // cross-user setups (multi-user mac mini) can connect. That alone
        // would let any local account on the host get a root shell *inside*
        // the guest via STREAM mode — which then has rw access to the
        // host's ~/ai-sandbox-workspace. Mitigate by checking the connecting
        // peer's uid against an allowlist.
        //
        // Default: only the user running SecVF.app may connect. Other users
        // opt in by adding their username (or numeric uid) to
        //   ~/.avf/config/exec-bridge-allowlist
        // one entry per line, comments with #.
        if let denyMessage = denyReasonForPeer(clientFd: clientFd) {
            let line = "secvf-exec-bridge: \(denyMessage)\n"
            _ = line.withCString { write(clientFd, $0, strlen($0)) }
            close(clientFd)
            NSLog("[VsockExecBridge] %@ refused connection: %@", vmName, denyMessage)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.bridgeOneConnection(clientFd: clientFd)
        }
    }

    /// Returns a deny reason string if the peer should be refused, or nil if
    /// the connection is authorized to proceed.
    private func denyReasonForPeer(clientFd: Int32) -> String? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(clientFd, &euid, &egid) == 0 else {
            return "could not resolve peer credentials"
        }
        let allowed = VsockExecBridge.loadAllowlist()
        if allowed.contains(euid) {
            return nil
        }
        return "uid \(euid) not in exec-bridge allowlist (add to ~/.avf/config/exec-bridge-allowlist to authorize)"
    }

    /// Always-allowed UID is the one running SecVF.app. Plus any users
    /// listed (numeric or by name) in the optional allowlist file.
    /// Loaded on every connection so config edits take effect immediately —
    /// the file is small, so re-reading is cheap.
    private static func loadAllowlist() -> Set<uid_t> {
        var allowed: Set<uid_t> = [getuid()]
        let configPath = NSHomeDirectory() + "/.avf/config/exec-bridge-allowlist"
        guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return allowed
        }
        for rawLine in raw.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let numeric = uid_t(line) {
                allowed.insert(numeric)
                continue
            }
            // Resolve username → uid.
            if let pw = getpwnam(line) {
                allowed.insert(pw.pointee.pw_uid)
            }
        }
        return allowed
    }

    // MARK: - Bridging

    /// Wires up bidirectional byte-piping between the UDS client and a fresh
    /// vsock connection to the guest, then returns. Tear-down runs
    /// asynchronously when either side EOFs — we do NOT block this worker
    /// thread for the bridged session's lifetime.
    private func bridgeOneConnection(clientFd: Int32) {
        let clientHandle = FileHandle(fileDescriptor: clientFd, closeOnDealloc: true)

        guard let vm = vm else {
            errorOut(clientHandle, "VM no longer running")
            return
        }
        guard let socketDev = vm.socketDevices.first as? VZVirtioSocketDevice else {
            errorOut(clientHandle, "no vsock device on VM")
            return
        }

        // Bounded wait — if the guest's vsock stack never accepts (e.g. the
        // exec agent isn't listening), we surface a clean error instead of
        // wedging the thread forever.
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
        let connectTimeout: DispatchTime = .now() + .seconds(5)
        if sem.wait(timeout: connectTimeout) == .timedOut {
            errorOut(clientHandle, "vsock connect to :\(vsockPort) timed out after 5s")
            return
        }

        guard let vsockConn = connOpt else {
            let detail = connErr.map { $0.localizedDescription }
                ?? "returned nil (is the exec agent running in the guest?)"
            errorOut(clientHandle, "vsock connect to :\(vsockPort) failed: \(detail)")
            return
        }

        let vsockHandle = FileHandle(
            fileDescriptor: vsockConn.fileDescriptor,
            closeOnDealloc: false
        )

        // Two-leg pipe — when either side EOFs we close BOTH and clean up.
        // BridgeState ensures the close runs exactly once even though both
        // readabilityHandlers will end up firing with empty data (one
        // because of the real EOF, the other because we closed the handle).
        let state = BridgeState(client: clientHandle, vsock: vsockHandle, vsockConn: vsockConn)

        clientHandle.readabilityHandler = { [weak state] fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                state?.finish()
                return
            }
            if state?.writeToVsock(d) != true {
                fh.readabilityHandler = nil
            }
        }

        vsockHandle.readabilityHandler = { [weak state] fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                state?.finish()
                return
            }
            if state?.writeToClient(d) != true {
                fh.readabilityHandler = nil
            }
        }
    }

    private func errorOut(_ handle: FileHandle, _ msg: String) {
        let line = "secvf-exec-bridge: \(msg)\n"
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    }
}

/// Holds both legs of an active bridged connection and runs cleanup exactly
/// once. The two readabilityHandler closures hold weak refs to this object;
/// when both are detached and `state` is the only thing keeping the handles
/// alive, ARC frees everything cleanly.
private final class BridgeState {
    private let lock = NSLock()
    private var finished = false
    private let client: FileHandle
    private let vsock: FileHandle
    // Strong ref to the connection to keep its underlying fd alive.
    private let vsockConn: VZVirtioSocketConnection

    init(client: FileHandle, vsock: FileHandle, vsockConn: VZVirtioSocketConnection) {
        self.client = client
        self.vsock = vsock
        self.vsockConn = vsockConn
    }

    /// Idempotent. Closes both handles + clears their readability handlers.
    func finish() {
        lock.lock()
        let firstCall = !finished
        finished = true
        lock.unlock()
        guard firstCall else { return }
        client.readabilityHandler = nil
        vsock.readabilityHandler = nil
        try? client.close()
        try? vsock.close()
        // vsockConn drops with self.
    }

    /// Returns true if the write succeeded (caller can keep reading).
    func writeToVsock(_ data: Data) -> Bool {
        lock.lock()
        let alive = !finished
        lock.unlock()
        guard alive else { return false }
        do { try vsock.write(contentsOf: data); return true }
        catch { finish(); return false }
    }

    func writeToClient(_ data: Data) -> Bool {
        lock.lock()
        let alive = !finished
        lock.unlock()
        guard alive else { return false }
        do { try client.write(contentsOf: data); return true }
        catch { finish(); return false }
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
