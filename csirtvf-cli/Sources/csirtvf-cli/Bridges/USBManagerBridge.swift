import Foundation

/// Bridge to USB device management via IOKit
class USBManagerBridge {

    // MARK: - List Physical USB Devices

    func listDevices() -> [[String: Any]] {
        var devices: [[String: Any]] = []

        // Use system_profiler to get USB info
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPUSBDataType", "-json"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let usbData = json["SPUSBDataType"] as? [[String: Any]] {
                devices = parseUSBDevices(usbData)
            }
        } catch {
            // Return empty list on error
        }

        return devices
    }

    private func parseUSBDevices(_ usbData: [[String: Any]]) -> [[String: Any]] {
        var devices: [[String: Any]] = []

        for controller in usbData {
            if let items = controller["_items"] as? [[String: Any]] {
                for item in items {
                    // Skip internal devices (hubs, etc.)
                    if let name = item["_name"] as? String,
                       !name.lowercased().contains("hub"),
                       !name.lowercased().contains("internal") {

                        var device: [String: Any] = [
                            "name": name,
                            "vendor": item["manufacturer"] as? String ?? "Unknown",
                            "type": "Physical",
                            "status": "Available"
                        ]

                        if let vendorId = item["vendor_id"] as? String {
                            device["vendorId"] = vendorId
                        }
                        if let productId = item["product_id"] as? String {
                            device["productId"] = productId
                        }
                        if let serialNumber = item["serial_num"] as? String {
                            device["serialNumber"] = serialNumber
                        }

                        devices.append(device)
                    }

                    // Check for nested devices
                    if let nested = item["_items"] as? [[String: Any]] {
                        devices += parseUSBDevices([["_items": nested]])
                    }
                }
            }
        }

        return devices
    }

    // MARK: - List Virtual USB Disks

    func listVirtualDisks() -> [[String: Any]] {
        var disks: [[String: Any]] = []

        let virtualDiskPath = NSHomeDirectory() + "/.avf/usb"

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: virtualDiskPath) else {
            return disks
        }

        for file in files where file.hasSuffix(".dmg") || file.hasSuffix(".iso") {
            let filePath = virtualDiskPath + "/" + file
            let name = file.replacingOccurrences(of: ".dmg", with: "").replacingOccurrences(of: ".iso", with: "")

            var disk: [String: Any] = [
                "name": name,
                "vendor": "SecVF",
                "type": "Virtual",
                "path": filePath,
                "status": "Available"
            ]

            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                disk["size"] = size
                disk["sizeFormatted"] = formatBytes(size)
            }

            // Check if mounted to any VM
            if let mountedVM = getVMMountedTo(diskPath: filePath) {
                disk["mountedTo"] = mountedVM
                disk["status"] = "Mounted"
            }

            disks.append(disk)
        }

        return disks
    }

    private func getVMMountedTo(diskPath: String) -> String? {
        // Check VM metadata for mounted USB devices
        let avfRoot = NSHomeDirectory() + "/.avf"
        let linuxPath = avfRoot + "/Linux"

        guard let vms = try? FileManager.default.contentsOfDirectory(atPath: linuxPath) else {
            return nil
        }

        for vmDir in vms where vmDir.hasSuffix(".bundle") {
            let metadataPath = linuxPath + "/" + vmDir + "/metadata.json"
            if let data = FileManager.default.contents(atPath: metadataPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mountedUSB = json["mountedUSB"] as? String,
               mountedUSB == diskPath {
                return json["name"] as? String
            }
        }

        return nil
    }

    // MARK: - Mount Device to VM

    func mountDevice(device: String, toVM vmName: String) -> [String: Any] {
        // Send notification to main app to mount USB
        let notification = DistributedNotificationCenter.default()
        notification.postNotificationName(
            NSNotification.Name("com.secvf.cli.mount-usb"),
            object: nil,
            userInfo: ["device": device, "vmName": vmName],
            deliverImmediately: true
        )

        return ["success": true]
    }

    // MARK: - Eject Device

    func ejectDevice(device: String) -> [String: Any] {
        // Send notification to main app to eject USB
        let notification = DistributedNotificationCenter.default()
        notification.postNotificationName(
            NSNotification.Name("com.secvf.cli.eject-usb"),
            object: nil,
            userInfo: ["device": device],
            deliverImmediately: true
        )

        return ["success": true]
    }

    // MARK: - Create Virtual Disk

    func createVirtualDisk(name: String, sizeMB: Int, format: String, source: String?) -> [String: Any] {
        let virtualDiskPath = NSHomeDirectory() + "/.avf/usb"

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(atPath: virtualDiskPath, withIntermediateDirectories: true)
        } catch {
            return ["error": "Failed to create USB directory: \(error.localizedDescription)"]
        }

        let ext = format.lowercased() == "iso" ? "iso" : "dmg"
        let outputPath = virtualDiskPath + "/\(name).\(ext)"

        // Check if already exists
        if FileManager.default.fileExists(atPath: outputPath) {
            return ["error": "Virtual disk '\(name)' already exists"]
        }

        if ext == "iso" {
            return createISODisk(name: name, outputPath: outputPath, source: source)
        } else {
            return createDMGDisk(name: name, outputPath: outputPath, sizeMB: sizeMB, source: source)
        }
    }

    private func createDMGDisk(name: String, outputPath: String, sizeMB: Int, source: String?) -> [String: Any] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")

        if let sourcePath = source {
            // Create from source directory
            task.arguments = ["create", "-volname", name, "-srcfolder", sourcePath, "-ov", "-format", "UDRW", outputPath]
        } else {
            // Create empty disk
            task.arguments = ["create", "-volname", name, "-size", "\(sizeMB)m", "-fs", "HFS+", "-format", "UDRW", outputPath]
        }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return ["success": true, "path": outputPath]
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return ["error": "hdiutil failed: \(output)"]
            }
        } catch {
            return ["error": "Failed to run hdiutil: \(error.localizedDescription)"]
        }
    }

    private func createISODisk(name: String, outputPath: String, source: String?) -> [String: Any] {
        guard let sourcePath = source else {
            return ["error": "Source directory required for ISO creation"]
        }

        // Use hdiutil to create ISO
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["makehybrid", "-o", outputPath, "-iso", "-joliet", sourcePath]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return ["success": true, "path": outputPath]
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return ["error": "hdiutil failed: \(output)"]
            }
        } catch {
            return ["error": "Failed to create ISO: \(error.localizedDescription)"]
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        let mb = Double(bytes) / (1024 * 1024)

        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(bytes) B"
    }
}
