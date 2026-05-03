import Foundation
import Cocoa

/// Manages creation and mounting of the SecVF scripts virtual USB/disk image
class ScriptsUSBManager {

    static let shared = ScriptsUSBManager()

    // MARK: - Security: Path Sanitization

    /// SECURITY: Validate and sanitize a file path before passing to external processes
    /// Prevents path injection attacks via special characters or path traversal
    /// Internal (not private) so unit tests can exercise it directly via @testable.
    func sanitizePath(_ path: String) -> String? {
        // Normalize the path first
        let normalized = (path as NSString).standardizingPath

        // Check for path traversal attempts
        if normalized.contains("..") {
            NSLog("[ScriptsUSB] SECURITY: Path traversal attempt detected in: %@", path)
            return nil
        }

        // Only allow safe characters: alphanumeric, slash, dash, underscore, dot, space
        // This prevents shell injection via backticks, $(), semicolons, etc.
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/_-. "))
        for scalar in normalized.unicodeScalars {
            if !allowedCharacters.contains(scalar) {
                NSLog("[ScriptsUSB] SECURITY: Disallowed character '%@' (U+%04X) in path: %@",
                      String(scalar), scalar.value, path)
                return nil
            }
        }

        // Ensure path doesn't start with a dash (could be interpreted as option)
        if normalized.hasPrefix("-") {
            NSLog("[ScriptsUSB] SECURITY: Path starts with dash (option injection): %@", path)
            return nil
        }

        // Verify the path exists and is a directory (for source directories)
        // Note: This is optional - caller may want to validate this themselves

        return normalized
    }

    /// SECURITY: Validate a path is within expected boundaries.
    ///
    /// Critical invariant: every prefix must end with `/`. Otherwise the
    /// hasPrefix check matches sibling directories — `/Users/openclaw`
    /// matches `/Users/openclaw_evil/...` — and the allowlist is bypassed.
    /// `/tmp/` and `/private/tmp/` already end in `/`; the home and bundle
    /// paths don't, so we append it here.
    /// Internal (not private) so unit tests can exercise it directly.
    func isPathWithinAllowedDirectories(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let homeDir = NSHomeDirectory()
        let bundlePath = Bundle.main.bundlePath

        let allowedPrefixes: [String] = [
            homeDir.hasSuffix("/") ? homeDir : homeDir + "/",
            bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/",
            "/tmp/",
            "/private/tmp/"
        ]

        // Equality with the bare directory is also allowed (e.g. the home
        // dir itself, with no trailing slash on the input). hasPrefix on the
        // slash-suffixed version handles every other case, including a path
        // identical to the prefix when written as `<prefix>/`.
        let bareAllowed: [String] = [homeDir, bundlePath]
        if bareAllowed.contains(normalized) {
            return true
        }

        for prefix in allowedPrefixes {
            if normalized.hasPrefix(prefix) {
                return true
            }
        }

        NSLog("[ScriptsUSB] SECURITY: Path outside allowed directories: %@", path)
        return false
    }

    /// SECURITY: Resolve a candidate file's real path (following symlinks)
    /// and ensure it is still inside the allowlist before we copy it onto a
    /// disk that gets handed to a (potentially hostile) guest. Without this,
    /// a symlink in the source tree pointing to /etc/passwd, /private/etc/...,
    /// or a private key under ~/Library would be silently shipped to the VM.
    private func resolveAndValidateSourceFile(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else {
            NSLog("[ScriptsUSB] SECURITY: realpath failed for: %@", path)
            return nil
        }
        defer { free(resolved) }
        let realPath = String(cString: resolved)

        // The resolved path must itself be inside the allowed directories.
        // Without this, a symlink whose name passes sanitization can still
        // dereference to anywhere on disk.
        guard isPathWithinAllowedDirectories(realPath) else {
            NSLog("[ScriptsUSB] SECURITY: Symlink target outside allowed directories — refusing to copy: %@ -> %@", path, realPath)
            return nil
        }

        return realPath
    }

    // SECURITY: Single lock around create-disk operations. scriptsMountPath
    // and scriptsStagingPath are shared singletons; concurrent callers would
    // collide on the mount point and silently corrupt the produced image.
    private let createDiskLock = NSLock()

    private let scriptsDiskPath: String      // Writable disk image for Linux
    private let scriptsISOPath: String       // Read-only ISO for macOS
    private let scriptsStagingPath: String
    private let scriptsSourcePath: String
    private let scriptsMountPath: String

    private init() {
        let avfDir = NSHomeDirectory() + "/.avf"
        scriptsDiskPath = avfDir + "/secvf-scripts.dmg"  // Writable FAT32 disk image
        scriptsISOPath = avfDir + "/secvf-scripts.iso"   // Keep ISO for macOS compatibility
        scriptsStagingPath = avfDir + "/scripts-staging"
        scriptsMountPath = avfDir + "/scripts-mount"

        // Get the scripts directory from the app bundle
        if let bundlePath = Bundle.main.resourcePath {
            scriptsSourcePath = bundlePath + "/scripts"
        } else {
            // Fallback to development path
            scriptsSourcePath = ""
        }
    }

    /// Check if the scripts disk image exists
    var scriptsDiskExists: Bool {
        return FileManager.default.fileExists(atPath: scriptsDiskPath)
    }

    /// Check if the scripts ISO exists (for macOS VMs)
    var scriptsISOExists: Bool {
        return FileManager.default.fileExists(atPath: scriptsISOPath)
    }

    /// Get the URL of the scripts disk image (writable, for Linux)
    var scriptsDiskURL: URL? {
        guard scriptsDiskExists else { return nil }
        return URL(fileURLWithPath: scriptsDiskPath)
    }

    /// Get the URL of the scripts ISO (read-only, for macOS)
    var scriptsISOURL: URL? {
        guard scriptsISOExists else { return nil }
        return URL(fileURLWithPath: scriptsISOPath)
    }

    /// Create or update the writable scripts disk image (for Linux VMs)
    /// Returns Result with the URL of the created disk image, or typed error on failure
    func createScriptsDisk(from scriptsDirectory: String? = nil) -> Result<URL, SecVFError> {
        createDiskLock.lock()
        defer { createDiskLock.unlock() }
        let rawSourceDir = scriptsDirectory ?? getScriptsSourceDirectory()

        guard let rawSourceDir = rawSourceDir else {
            NSLog("[ScriptsUSB] ERROR: Could not find scripts source directory")
            return .failure(.scriptsSourceNotFound)
        }

        // SECURITY: Sanitize and validate the source directory path
        guard let sourceDir = sanitizePath(rawSourceDir) else {
            NSLog("[ScriptsUSB] SECURITY: Source directory path failed sanitization: %@", rawSourceDir)
            return .failure(.scriptsPathSanitizationFailed(path: rawSourceDir))
        }

        guard isPathWithinAllowedDirectories(sourceDir) else {
            NSLog("[ScriptsUSB] SECURITY: Source directory outside allowed paths: %@", sourceDir)
            return .failure(.scriptsPathOutsideAllowed(path: sourceDir))
        }

        NSLog("[ScriptsUSB] Creating writable scripts disk from: \(sourceDir)")

        // Remove old disk image if exists
        if FileManager.default.fileExists(atPath: scriptsDiskPath) {
            try? FileManager.default.removeItem(atPath: scriptsDiskPath)
        }

        // Create a writable DMG with FAT32 filesystem (10MB should be plenty)
        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createProcess.arguments = [
            "create",
            "-size", "10m",
            "-fs", "MS-DOS FAT32",
            "-volname", "SecVF_SCRIPTS",
            "-format", "UDRW",  // Read-write disk image
            scriptsDiskPath
        ]

        let createPipe = Pipe()
        createProcess.standardOutput = createPipe
        createProcess.standardError = createPipe

        do {
            try createProcess.run()
            createProcess.waitUntilExit()

            if createProcess.terminationStatus != 0 {
                let output = String(data: createPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ScriptsUSB] ERROR creating disk image: \(output)")
                return .failure(.scriptsDiskCreationFailed(reason: output))
            }
        } catch {
            NSLog("[ScriptsUSB] ERROR running hdiutil create: \(error)")
            return .failure(.scriptsDiskCreationFailed(reason: error.localizedDescription))
        }

        NSLog("[ScriptsUSB] Disk image created, mounting to copy scripts...")

        // Create mount point
        try? FileManager.default.createDirectory(atPath: scriptsMountPath, withIntermediateDirectories: true)

        // Mount the disk image
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = [
            "attach",
            scriptsDiskPath,
            "-mountpoint", scriptsMountPath,
            "-nobrowse"  // Don't show in Finder
        ]

        let mountPipe = Pipe()
        mountProcess.standardOutput = mountPipe
        mountProcess.standardError = mountPipe

        do {
            try mountProcess.run()
            mountProcess.waitUntilExit()

            if mountProcess.terminationStatus != 0 {
                let output = String(data: mountPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ScriptsUSB] ERROR mounting disk image: \(output)")
                return .failure(.scriptsDiskCreationFailed(reason: "Mount failed: \(output)"))
            }
        } catch {
            NSLog("[ScriptsUSB] ERROR running hdiutil attach: \(error)")
            return .failure(.scriptsDiskCreationFailed(reason: "Mount failed: \(error.localizedDescription)"))
        }

        NSLog("[ScriptsUSB] Disk mounted, copying scripts...")

        // Copy scripts to mounted disk
        do {
            let scriptsDestPath = scriptsMountPath + "/scripts"
            try FileManager.default.createDirectory(atPath: scriptsDestPath, withIntermediateDirectories: true)

            // Copy all .sh files. Resolve symlinks before copying so a stray
            // symlink in the source tree (legitimate in dev mode pointing to
            // ~/Code/SecVF/scripts/...) cannot bake an arbitrary host file
            // into the disk image we hand to the guest.
            let contents = try FileManager.default.contentsOfDirectory(atPath: sourceDir)
            for file in contents {
                if file.hasSuffix(".sh") || file == "README.md" {
                    let sourcePath = sourceDir + "/" + file
                    guard let realSource = resolveAndValidateSourceFile(sourcePath) else {
                        NSLog("[ScriptsUSB] SECURITY: Skipping %@ (symlink resolution failed allowlist)", file)
                        continue
                    }
                    let destPath = scriptsDestPath + "/" + file
                    try FileManager.default.copyItem(atPath: realSource, toPath: destPath)
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
               sudo mount /dev/sdb1 /mnt/scripts

            2. Make scripts executable:
               chmod +x /mnt/scripts/scripts/*.sh

            3. Run the router setup:
               cd /mnt/scripts/scripts
               sudo ./kali-router-setup.sh

            4. Run FakeNet for malware analysis:
               sudo ./kali-fakenet-setup.sh start

            Available Scripts:
            ------------------
            - kali-router-setup.sh      - Configure Kali as network router
            - kali-router-quick-setup.sh - Quick network config only
            - kali-fakenet-setup.sh     - Fake internet for malware analysis
            - macos-network-setup.sh    - Configure macOS VM networking
            - test_virtual_switch.sh    - Test virtual network switch

            For more information, see README.md
            """
            try readmeContent.write(toFile: scriptsMountPath + "/README.txt", atomically: true, encoding: .utf8)

        } catch {
            NSLog("[ScriptsUSB] ERROR copying scripts: \(error)")
            // Detach before returning
            let detachProcess = Process()
            detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachProcess.arguments = ["detach", scriptsMountPath, "-force"]
            try? detachProcess.run()
            detachProcess.waitUntilExit()
            return .failure(.scriptsCopyFailed(underlying: error))
        }

        // Unmount the disk image
        let detachProcess = Process()
        detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detachProcess.arguments = ["detach", scriptsMountPath]

        let detachPipe = Pipe()
        detachProcess.standardOutput = detachPipe
        detachProcess.standardError = detachPipe

        do {
            try detachProcess.run()
            detachProcess.waitUntilExit()

            if detachProcess.terminationStatus != 0 {
                let output = String(data: detachPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ScriptsUSB] WARNING: Error detaching disk image: \(output)")
                // Try force detach
                let forceDetach = Process()
                forceDetach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                forceDetach.arguments = ["detach", scriptsMountPath, "-force"]
                try? forceDetach.run()
                forceDetach.waitUntilExit()
            }
        } catch {
            NSLog("[ScriptsUSB] ERROR running hdiutil detach: \(error)")
        }

        // Clean up mount point
        try? FileManager.default.removeItem(atPath: scriptsMountPath)

        NSLog("[ScriptsUSB] Successfully created writable scripts disk: \(scriptsDiskPath)")
        return .success(URL(fileURLWithPath: scriptsDiskPath))
    }

    /// Create or update the scripts ISO (for macOS VMs - read-only is fine)
    /// Returns Result with the URL of the created ISO, or typed error on failure
    func createScriptsISO(from scriptsDirectory: String? = nil) -> Result<URL, SecVFError> {
        createDiskLock.lock()
        defer { createDiskLock.unlock() }
        let rawSourceDir = scriptsDirectory ?? getScriptsSourceDirectory()

        guard let rawSourceDir = rawSourceDir else {
            NSLog("[ScriptsUSB] ERROR: Could not find scripts source directory")
            return .failure(.scriptsSourceNotFound)
        }

        // SECURITY: Sanitize and validate the source directory path
        guard let sourceDir = sanitizePath(rawSourceDir) else {
            NSLog("[ScriptsUSB] SECURITY: Source directory path failed sanitization: %@", rawSourceDir)
            return .failure(.scriptsPathSanitizationFailed(path: rawSourceDir))
        }

        guard isPathWithinAllowedDirectories(sourceDir) else {
            NSLog("[ScriptsUSB] SECURITY: Source directory outside allowed paths: %@", sourceDir)
            return .failure(.scriptsPathOutsideAllowed(path: sourceDir))
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

            // Copy all .sh files. See createScriptsDisk above — resolve
            // symlinks and re-validate against the allowlist before copying.
            let contents = try FileManager.default.contentsOfDirectory(atPath: sourceDir)
            for file in contents {
                if file.hasSuffix(".sh") || file == "README.md" {
                    let sourcePath = sourceDir + "/" + file
                    guard let realSource = resolveAndValidateSourceFile(sourcePath) else {
                        NSLog("[ScriptsUSB] SECURITY: Skipping %@ (symlink resolution failed allowlist)", file)
                        continue
                    }
                    let destPath = scriptsDestPath + "/" + file
                    try FileManager.default.copyItem(atPath: realSource, toPath: destPath)
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
            return .failure(.scriptsCopyFailed(underlying: error))
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

                return .success(URL(fileURLWithPath: scriptsISOPath))
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("[ScriptsUSB] ERROR creating ISO: \(output)")
                return .failure(.scriptsISOCreationFailed(reason: output))
            }
        } catch {
            NSLog("[ScriptsUSB] ERROR running hdiutil: \(error)")
            return .failure(.scriptsISOCreationFailed(reason: error.localizedDescription))
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

        // Check common development directories (no hardcoded user-specific paths)
        let commonDevPaths = [
            "/Developer/SecVF/scripts",
            "/Projects/SecVF/scripts",
            "/Code/SecVF/scripts",
            "/src/SecVF/scripts"
        ]
        for relativePath in commonDevPaths {
            let fullPath = NSHomeDirectory() + relativePath
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
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
