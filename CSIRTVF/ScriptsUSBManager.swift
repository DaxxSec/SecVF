import Foundation
import Cocoa

/// Manages creation and mounting of the SecVF scripts virtual USB/ISO
class ScriptsUSBManager {

    static let shared = ScriptsUSBManager()

    private let scriptsISOPath: String
    private let scriptsStagingPath: String
    private let scriptsSourcePath: String

    private init() {
        let avfDir = NSHomeDirectory() + "/.avf"
        scriptsISOPath = avfDir + "/secvf-scripts.iso"
        scriptsStagingPath = avfDir + "/scripts-staging"

        // Get the scripts directory from the app bundle
        if let bundlePath = Bundle.main.resourcePath {
            scriptsSourcePath = bundlePath + "/scripts"
        } else {
            // Fallback to development path
            scriptsSourcePath = ""
        }
    }

    /// Check if the scripts ISO exists and is up to date
    var scriptsISOExists: Bool {
        return FileManager.default.fileExists(atPath: scriptsISOPath)
    }

    /// Get the URL of the scripts ISO
    var scriptsISOURL: URL? {
        guard scriptsISOExists else { return nil }
        return URL(fileURLWithPath: scriptsISOPath)
    }

    /// Create or update the scripts ISO
    /// Returns the URL of the created ISO, or nil on failure
    func createScriptsISO(from scriptsDirectory: String? = nil) -> URL? {
        let sourceDir = scriptsDirectory ?? getScriptsSourceDirectory()

        guard let sourceDir = sourceDir else {
            NSLog("[ScriptsUSB] ERROR: Could not find scripts source directory")
            return nil
        }

        NSLog("[ScriptsUSB] Creating scripts ISO from: \(sourceDir)")

        // Create staging directory
        do {
            if FileManager.default.fileExists(atPath: scriptsStagingPath) {
                try FileManager.default.removeItem(atPath: scriptsStagingPath)
            }
            try FileManager.default.createDirectory(atPath: scriptsStagingPath, withIntermediateDirectories: true)

            // Copy scripts to staging
            let scriptsDestPath = scriptsStagingPath + "/scripts"
            try FileManager.default.createDirectory(atPath: scriptsDestPath, withIntermediateDirectories: true)

            // Copy all .sh files
            let contents = try FileManager.default.contentsOfDirectory(atPath: sourceDir)
            for file in contents {
                if file.hasSuffix(".sh") || file == "README.md" {
                    let sourcePath = sourceDir + "/" + file
                    let destPath = scriptsDestPath + "/" + file
                    try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)
                    NSLog("[ScriptsUSB] Copied: \(file)")
                }
            }

            // Create a README for the USB
            let readmeContent = """
            SecVF Setup Scripts
            =====================

            This virtual USB contains setup scripts for SecVF virtual machines.

            For Kali Router VM:
            -------------------
            1. Mount this drive (if not auto-mounted):
               sudo mkdir -p /mnt/scripts
               sudo mount /dev/sr0 /mnt/scripts   # or /dev/sdb1

            2. Run the router setup:
               cd /mnt/scripts/scripts
               sudo ./kali-router-setup.sh

            3. Run FakeNet for malware analysis:
               sudo ./kali-fakenet-setup.sh start

            For macOS VMs:
            --------------
            The drive should auto-mount on the desktop.
            Open Terminal and run:
               cd /Volumes/SecVF_SCRIPTS/scripts
               sudo ./macos-network-setup.sh

            Available Scripts:
            ------------------
            - kali-router-setup.sh      - Configure Kali as network router
            - kali-router-quick-setup.sh - Quick network config only
            - kali-fakenet-setup.sh     - Fake internet for malware analysis
            - macos-network-setup.sh    - Configure macOS VM networking
            - test_virtual_switch.sh    - Test virtual network switch

            For more information, see README.md
            """
            try readmeContent.write(toFile: scriptsStagingPath + "/README.txt", atomically: true, encoding: .utf8)

        } catch {
            NSLog("[ScriptsUSB] ERROR creating staging directory: \(error)")
            return nil
        }

        // Remove old ISO if exists
        if FileManager.default.fileExists(atPath: scriptsISOPath) {
            try? FileManager.default.removeItem(atPath: scriptsISOPath)
        }

        // Create ISO using hdiutil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid",
            "-o", scriptsISOPath,
            "-iso",
            "-joliet",
            "-default-volume-name", "SecVF_SCRIPTS",
            scriptsStagingPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                NSLog("[ScriptsUSB] Successfully created ISO: \(scriptsISOPath)")

                // Clean up staging directory
                try? FileManager.default.removeItem(atPath: scriptsStagingPath)

                return URL(fileURLWithPath: scriptsISOPath)
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ScriptsUSB] ERROR creating ISO: \(output)")
                return nil
            }
        } catch {
            NSLog("[ScriptsUSB] ERROR running hdiutil: \(error)")
            return nil
        }
    }

    /// Find the scripts source directory
    private func getScriptsSourceDirectory() -> String? {
        // First, check the app bundle
        if let bundleScripts = Bundle.main.path(forResource: "scripts", ofType: nil) {
            if FileManager.default.fileExists(atPath: bundleScripts) {
                return bundleScripts
            }
        }

        // Check relative to the executable (for development)
        if let execPath = Bundle.main.executablePath {
            let devPath = (execPath as NSString).deletingLastPathComponent + "/../../../scripts"
            let resolvedPath = (devPath as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolvedPath) {
                return resolvedPath
            }
        }

        // Check current working directory
        let cwdPath = FileManager.default.currentDirectoryPath + "/scripts"
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }

        // Check home directory for development
        let homePath = NSHomeDirectory() + "/Code/Sandboxes/SecVF/scripts"
        if FileManager.default.fileExists(atPath: homePath) {
            return homePath
        }

        return nil
    }

    /// Show dialog to select scripts directory (for first-time setup or if scripts not found)
    func promptForScriptsDirectory(completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = "Select SecVF Scripts Directory"
            panel.message = "Choose the folder containing SecVF setup scripts (kali-router-setup.sh, etc.)"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false

            if panel.runModal() == .OK {
                completion(panel.url)
            } else {
                completion(nil)
            }
        }
    }
}
