import Foundation

/// Bridge to VM metadata stored in ~/.avf/
class VMManagerBridge {
    private let avfRoot: String
    private let linuxPath: String
    private let macOSPath: String
    private let keysPath: String

    private let aiSandboxPath: String

    init() {
        avfRoot = NSHomeDirectory() + "/.avf"
        linuxPath = avfRoot + "/Linux"
        macOSPath = avfRoot + "/MacOS"
        aiSandboxPath = avfRoot + "/AISandbox"
        keysPath = avfRoot + "/keys"
    }

    // MARK: - List VMs

    func listVMs() -> [[String: Any]] {
        var vms: [[String: Any]] = []

        // List Linux VMs
        if let linuxVMs = try? FileManager.default.contentsOfDirectory(atPath: linuxPath) {
            for vmDir in linuxVMs where vmDir.hasSuffix(".bundle") {
                if let vm = loadVMMetadata(path: linuxPath + "/" + vmDir, osType: "Linux") {
                    vms.append(vm)
                }
            }
        }

        // List macOS VMs
        if let macVMs = try? FileManager.default.contentsOfDirectory(atPath: macOSPath) {
            for vmDir in macVMs where vmDir.hasSuffix(".bundle") {
                if let vm = loadVMMetadata(path: macOSPath + "/" + vmDir, osType: "macOS") {
                    vms.append(vm)
                }
            }
        }

        // List AI Sandbox VMs (base + sessions)
        if let sandboxVMs = try? FileManager.default.contentsOfDirectory(atPath: aiSandboxPath) {
            for vmDir in sandboxVMs where vmDir.hasSuffix(".bundle") {
                if let vm = loadVMMetadata(path: aiSandboxPath + "/" + vmDir, osType: "AISandbox") {
                    vms.append(vm)
                }
            }
        }
        // Also check sessions subdirectory
        let sessionsPath = aiSandboxPath + "/sessions"
        if let sessionVMs = try? FileManager.default.contentsOfDirectory(atPath: sessionsPath) {
            for vmDir in sessionVMs where vmDir.hasSuffix(".bundle") {
                if let vm = loadVMMetadata(path: sessionsPath + "/" + vmDir, osType: "AISandbox") {
                    vms.append(vm)
                }
            }
        }

        return vms
    }

    private func loadVMMetadata(path: String, osType: String) -> [String: Any]? {
        let metadataPath = path + "/metadata.json"
        let manifestPath = path + "/manifest.json"
        let bundleName = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: ".bundle", with: "")

        // Try metadata.json first (standard VMs), then manifest.json (AI Sandbox)
        var vm: [String: Any]
        if let data = FileManager.default.contents(atPath: metadataPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            vm = json
        } else if let data = FileManager.default.contents(atPath: manifestPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Normalize manifest.json fields to match metadata.json shape
            vm = [
                "name": json["name"] as? String ?? bundleName,
                "id": json["id"] as? String ?? "",
                "vm_type": json["vm_type"] ?? "ai-sandbox",
                "macos_version": json["macos_version"] ?? "",
                "cpu_count": json["cpu_count"] ?? 0,
                "memory_gib": json["memory_gib"] ?? 0,
                "disk_size_gib": json["disk_size_gib"] ?? 0,
                "sealed_at": json["sealed_at"] ?? "",
                "version": json["version"] ?? ""
            ]
        } else {
            // Return basic info even without metadata
            vm = [
                "name": bundleName
            ]
        }

        vm["osType"] = osType
        vm["path"] = path

        // Ensure name is set
        if vm["name"] as? String == nil || (vm["name"] as? String)?.isEmpty == true {
            vm["name"] = bundleName
        }

        // Check running status
        let name = vm["name"] as? String ?? bundleName
        vm["status"] = getVMRunningStatus(name: name)

        // Get IP if running
        if vm["status"] as? String == "running" {
            vm["ipAddress"] = getVMIP(name: name)
        }

        return vm
    }

    private func getVMRunningStatus(name: String) -> String {
        // Check if VM process is running by looking for SecVF with this VM
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "SecVF.*\(name)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0 ? "running" : "stopped"
        } catch {
            return "unknown"
        }
    }

    // MARK: - Create VM

    func createVM(config: [String: Any]) -> [String: Any] {
        guard let name = config["name"] as? String else {
            return ["error": "VM name is required"]
        }

        // Validate name
        if name.contains("/") || name.contains("..") {
            return ["error": "Invalid VM name"]
        }

        let osType = config["osType"] as? String ?? "Linux"
        let basePath = osType == "macOS" ? macOSPath : linuxPath
        let bundlePath = basePath + "/\(name).bundle"

        // Check if already exists
        if FileManager.default.fileExists(atPath: bundlePath) {
            return ["error": "VM '\(name)' already exists"]
        }

        do {
            // Create bundle directory
            try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)

            // Create metadata.json
            var metadata = config
            metadata["createdAt"] = ISO8601DateFormatter().string(from: Date())
            metadata["id"] = UUID().uuidString

            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            try metadataData.write(to: URL(fileURLWithPath: bundlePath + "/metadata.json"))

            // Generate SSH keys
            generateSSHKeys(vmName: name)

            return metadata
        } catch {
            return ["error": "Failed to create VM: \(error.localizedDescription)"]
        }
    }

    // MARK: - Start VM

    func startVM(name: String) -> [String: Any] {
        // Find VM
        guard let vm = findVM(name: name) else {
            return ["error": "VM '\(name)' not found"]
        }

        // Check if already running
        if vm["status"] as? String == "running" {
            return ["error": "VM '\(name)' is already running"]
        }

        // Send notification to SecVF app to start the VM
        // This requires the main app to be running
        let notificationResult = sendNotificationToApp(action: "start", vmName: name)

        if !notificationResult {
            return ["error": "Failed to start VM. Is SecVF running?"]
        }

        return ["success": true, "name": name]
    }

    // MARK: - Stop VM

    func stopVM(name: String, force: Bool = false) -> [String: Any] {
        guard let vm = findVM(name: name) else {
            return ["error": "VM '\(name)' not found"]
        }

        if vm["status"] as? String != "running" {
            return ["error": "VM '\(name)' is not running"]
        }

        let action = force ? "force-stop" : "stop"
        let notificationResult = sendNotificationToApp(action: action, vmName: name)

        if !notificationResult {
            return ["error": "Failed to stop VM. Is SecVF running?"]
        }

        return ["success": true, "name": name]
    }

    // MARK: - Delete VM

    func deleteVM(name: String) -> [String: Any] {
        guard let vm = findVM(name: name) else {
            return ["error": "VM '\(name)' not found"]
        }

        // Don't delete running VMs
        if vm["status"] as? String == "running" {
            return ["error": "Cannot delete running VM. Stop it first."]
        }

        guard let path = vm["path"] as? String else {
            return ["error": "VM path not found"]
        }

        do {
            try FileManager.default.removeItem(atPath: path)

            // Also remove SSH keys
            let keyPath = keysPath + "/\(name)"
            if FileManager.default.fileExists(atPath: keyPath) {
                try FileManager.default.removeItem(atPath: keyPath)
            }

            return ["success": true, "name": name]
        } catch {
            return ["error": "Failed to delete VM: \(error.localizedDescription)"]
        }
    }

    // MARK: - Get VM Status

    func getVMStatus(name: String) -> [String: Any] {
        guard let vm = findVM(name: name) else {
            return ["error": "VM '\(name)' not found"]
        }
        return vm
    }

    // MARK: - Get VM IP

    func getVMIP(name: String) -> String? {
        // Try to get IP from ARP table or VM metadata
        // For virtual network VMs, we assign IPs in 10.0.100.x range

        // First check metadata for static IP
        if let vm = findVM(name: name),
           let ip = vm["ipAddress"] as? String {
            return ip
        }

        // Try ARP lookup for the VM's MAC address
        // This is a simplified approach - in practice we'd need the MAC from VM config

        return nil
    }

    // MARK: - Exec Bridge Available Check (AI Sandbox)

    func isExecBridgeAvailable(name: String) -> Bool {
        guard let vm = findVM(name: name),
              let idString = vm["id"] as? String, !idString.isEmpty else {
            return false
        }
        let socketPath = "/tmp/secvf-exec-\(idString).sock"
        return FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - SSH Available Check

    func isSSHAvailable(name: String) -> Bool {
        guard let ip = getVMIP(name: name) else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        task.arguments = ["-z", "-w", "2", ip, "22"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Snapshots

    func createSnapshot(vmName: String, snapshotName: String, description: String?) -> [String: Any] {
        guard let vm = findVM(name: vmName) else {
            return ["error": "VM '\(vmName)' not found"]
        }

        guard let path = vm["path"] as? String else {
            return ["error": "VM path not found"]
        }

        let snapshotsDir = path + "/Snapshots"
        let snapshotPath = snapshotsDir + "/\(snapshotName)"

        do {
            try FileManager.default.createDirectory(atPath: snapshotPath, withIntermediateDirectories: true)

            // Copy current disk state
            let diskPath = path + "/Disk.img"
            if FileManager.default.fileExists(atPath: diskPath) {
                try FileManager.default.copyItem(atPath: diskPath, toPath: snapshotPath + "/Disk.img")
            }

            // Save NVRAM
            let nvramPath = path + "/NVRAM"
            if FileManager.default.fileExists(atPath: nvramPath) {
                try FileManager.default.copyItem(atPath: nvramPath, toPath: snapshotPath + "/NVRAM")
            }

            // Save snapshot metadata
            let snapshotMeta: [String: Any] = [
                "name": snapshotName,
                "description": description ?? "",
                "created": ISO8601DateFormatter().string(from: Date()),
                "vmName": vmName
            ]
            let metaData = try JSONSerialization.data(withJSONObject: snapshotMeta, options: .prettyPrinted)
            try metaData.write(to: URL(fileURLWithPath: snapshotPath + "/snapshot.json"))

            return snapshotMeta
        } catch {
            return ["error": "Failed to create snapshot: \(error.localizedDescription)"]
        }
    }

    func listSnapshots(vmName: String) -> [[String: Any]] {
        guard let vm = findVM(name: vmName),
              let path = vm["path"] as? String else {
            return []
        }

        let snapshotsDir = path + "/Snapshots"
        var snapshots: [[String: Any]] = []

        if let snapshotDirs = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir) {
            for dir in snapshotDirs {
                let metaPath = snapshotsDir + "/\(dir)/snapshot.json"
                if let data = FileManager.default.contents(atPath: metaPath),
                   var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Calculate size
                    let snapshotPath = snapshotsDir + "/\(dir)"
                    if let size = getDirectorySize(snapshotPath) {
                        meta["size"] = formatBytes(size)
                    }
                    snapshots.append(meta)
                }
            }
        }

        return snapshots.sorted { ($0["created"] as? String ?? "") > ($1["created"] as? String ?? "") }
    }

    func restoreSnapshot(vmName: String, snapshotName: String) -> [String: Any] {
        guard let vm = findVM(name: vmName),
              let path = vm["path"] as? String else {
            return ["error": "VM '\(vmName)' not found"]
        }

        if vm["status"] as? String == "running" {
            return ["error": "Cannot restore snapshot while VM is running"]
        }

        let snapshotPath = path + "/Snapshots/\(snapshotName)"

        guard FileManager.default.fileExists(atPath: snapshotPath) else {
            return ["error": "Snapshot '\(snapshotName)' not found"]
        }

        do {
            // Restore disk
            let diskPath = path + "/Disk.img"
            let snapshotDisk = snapshotPath + "/Disk.img"
            if FileManager.default.fileExists(atPath: snapshotDisk) {
                try? FileManager.default.removeItem(atPath: diskPath)
                try FileManager.default.copyItem(atPath: snapshotDisk, toPath: diskPath)
            }

            // Restore NVRAM
            let nvramPath = path + "/NVRAM"
            let snapshotNVRAM = snapshotPath + "/NVRAM"
            if FileManager.default.fileExists(atPath: snapshotNVRAM) {
                try? FileManager.default.removeItem(atPath: nvramPath)
                try FileManager.default.copyItem(atPath: snapshotNVRAM, toPath: nvramPath)
            }

            return ["success": true]
        } catch {
            return ["error": "Failed to restore snapshot: \(error.localizedDescription)"]
        }
    }

    func deleteSnapshot(vmName: String, snapshotName: String) -> [String: Any] {
        guard let vm = findVM(name: vmName),
              let path = vm["path"] as? String else {
            return ["error": "VM '\(vmName)' not found"]
        }

        let snapshotPath = path + "/Snapshots/\(snapshotName)"

        guard FileManager.default.fileExists(atPath: snapshotPath) else {
            return ["error": "Snapshot '\(snapshotName)' not found"]
        }

        do {
            try FileManager.default.removeItem(atPath: snapshotPath)
            return ["success": true]
        } catch {
            return ["error": "Failed to delete snapshot: \(error.localizedDescription)"]
        }
    }

    // MARK: - Helpers

    func findVMByName(name: String) -> [String: Any]? {
        let vms = listVMs()
        return vms.first { ($0["name"] as? String) == name }
    }

    private func findVM(name: String) -> [String: Any]? {
        return findVMByName(name: name)
    }

    private func generateSSHKeys(vmName: String) {
        let keyDir = keysPath + "/\(vmName)"
        let privateKey = keyDir + "/id_ed25519"

        // Skip if keys already exist
        if FileManager.default.fileExists(atPath: privateKey) {
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: keyDir, withIntermediateDirectories: true)

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            task.arguments = ["-t", "ed25519", "-f", privateKey, "-N", "", "-C", "secvf-\(vmName)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            try task.run()
            task.waitUntilExit()
        } catch {
            // Non-fatal - SSH keys are optional
        }
    }

    private func sendNotificationToApp(action: String, vmName: String) -> Bool {
        // Use distributed notification to communicate with main app
        let notification = DistributedNotificationCenter.default()
        notification.postNotificationName(
            NSNotification.Name("com.secvf.cli.\(action)"),
            object: nil,
            userInfo: ["vmName": vmName],
            deliverImmediately: true
        )
        return true
    }

    private func getDirectorySize(_ path: String) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return nil
        }

        var size: Int64 = 0
        for case let file as String in enumerator {
            let filePath = path + "/" + file
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attrs[.size] as? Int64 {
                size += fileSize
            }
        }
        return size
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        let mb = Double(bytes) / (1024 * 1024)

        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(bytes) B"
    }
}
