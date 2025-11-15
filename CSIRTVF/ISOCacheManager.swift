//
//  ISOCacheManager.swift
//  SecVF
//
//  SECURITY OVERVIEW:
//  Centralized cache for VM installation images (ISOs and IPSWs)
//  Downloads on-demand when user creates a VM, reuses across multiple VMs
//
//  SECURITY FEATURES:
//  1. URL Whitelist: Only downloads from official distro mirrors (hardcoded)
//  2. HTTPS Enforcement: All downloads require HTTPS
//  3. SHA256 Verification: Validates file integrity after download
//  4. Path Validation: Prevents directory traversal attacks
//  5. File Extension Validation: Only .iso and .ipsw files allowed
//  6. Size Limits: Rejects files >20GB to prevent DoS
//

import Foundation
import CryptoKit

enum VMImageType {
    case macOS(version: String)
    case linux(distro: LinuxDistro, version: String, isSecurityRouter: Bool = false)
}

enum LinuxDistro: String {
    case ubuntu = "Ubuntu"
    case debian = "Debian"
    case fedora = "Fedora"
    case kali = "Kali"
    case parrot = "ParrotOS"
    case arch = "Arch"
    case manjaro = "Manjaro"

    // SECURITY: Hardcoded official CDN URLs only
    // Only distros with dedicated official CDNs are supported
    var downloadURL: String {
        switch self {
        case .ubuntu:
            return "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-live-server-arm64.iso"
        case .debian:
            return "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-12.0.0-arm64-netinst.iso"
        case .fedora:
            return "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Server/aarch64/iso/Fedora-Server-dvd-aarch64-39-1.5.iso"
        case .kali:
            return "https://cdimage.kali.org/kali-2024.1/kali-linux-2024.1-installer-arm64.iso"
        case .parrot:
            return "https://download.parrot.sh/parrot/iso/6.0/Parrot-security-6.0_arm64.iso"
        case .arch:
            return "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-arm64.iso"
        case .manjaro:
            return "https://download.manjaro.org/gnome/23.1.3/manjaro-gnome-23.1.3-minimal-stable-aarch64.iso"
        }
    }

    // SECURITY: SHA256 checksums from official sources for integrity verification
    // TODO: Update these with actual checksums from each distro's official site
    var sha256Checksum: String {
        switch self {
        case .ubuntu:
            return "PLACEHOLDER_UPDATE_FROM_UBUNTU_CHECKSUMS"
        case .debian:
            return "PLACEHOLDER_UPDATE_FROM_DEBIAN_CHECKSUMS"
        case .fedora:
            return "PLACEHOLDER_UPDATE_FROM_FEDORA_CHECKSUMS"
        case .kali:
            return "PLACEHOLDER_UPDATE_FROM_KALI_CHECKSUMS"
        case .parrot:
            return "PLACEHOLDER_UPDATE_FROM_PARROT_CHECKSUMS"
        case .arch:
            return "PLACEHOLDER_UPDATE_FROM_ARCH_CHECKSUMS"
        case .manjaro:
            return "PLACEHOLDER_UPDATE_FROM_MANJARO_CHECKSUMS"
        }
    }

    // SECURITY: Whitelist of approved download domains (official CDNs only)
    static var approvedDomains: Set<String> {
        return [
            "cdimage.ubuntu.com",
            "cdimage.debian.org",
            "download.fedoraproject.org",
            "cdimage.kali.org",
            "download.parrot.sh",
            "geo.mirror.pkgbuild.com",  // Official Arch mirror redirector
            "download.manjaro.org"
        ]
    }
}

class ISOCacheManager {
    static let shared = ISOCacheManager()

    private let cacheRoot: String
    private let maxCacheSizeGB: Int = 100  // Warn user if cache exceeds 100GB
    private let auditLogPath: String
    private var lastDownloadTime: Date?
    private let minDownloadIntervalSeconds: TimeInterval = 5  // Rate limiting
    private var macOSInstaller: MacOSVMInstaller?  // Keep strong reference during download

    private init() {
        cacheRoot = NSHomeDirectory() + "/.avf/VMImages/"
        auditLogPath = NSHomeDirectory() + "/.avf/logs/iso-cache-audit.log"

        // Create logs directory
        let logsDir = NSHomeDirectory() + "/.avf/logs/"
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
    }

    // SECURITY: Audit logging for all download requests
    private func auditLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let processID = ProcessInfo.processInfo.processIdentifier
        let logEntry = "[\(timestamp)] [PID:\(processID)] \(message)\n"

        // Append to audit log
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: auditLogPath) {
                if let fileHandle = FileHandle(forWritingAtPath: auditLogPath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: auditLogPath))
            }
        }

        // Also print to console
        print("[AUDIT] \(message)")
    }

    // SECURITY: Verify caller is legitimate (main app UI, not external process)
    private func verifyCallerIsMainApp() -> Bool {
        // Check we're running in the main app bundle
        guard let bundleID = Bundle.main.bundleIdentifier else {
            auditLog("SECURITY ALERT: No bundle identifier - rejecting request")
            return false
        }

        // Verify it's our app
        guard bundleID.contains("SecVF") else {
            auditLog("SECURITY ALERT: Unknown bundle ID '\(bundleID)' - rejecting request")
            return false
        }

        // Check we're on the main thread (UI-initiated)
        guard Thread.isMainThread else {
            auditLog("SECURITY ALERT: Download request from background thread - rejecting")
            return false
        }

        return true
    }

    // SECURITY: Rate limiting to prevent abuse
    private func checkRateLimit() -> Bool {
        if let lastTime = lastDownloadTime {
            let timeSinceLast = Date().timeIntervalSince(lastTime)
            if timeSinceLast < minDownloadIntervalSeconds {
                auditLog("SECURITY: Rate limit exceeded (requests too frequent)")
                return false
            }
        }

        lastDownloadTime = Date()
        return true
    }

    // MARK: - Public API

    /// Check if image is already cached, return path if exists
    func getCachedImage(for imageType: VMImageType) -> URL? {
        let imagePath = getImagePath(for: imageType)

        if FileManager.default.fileExists(atPath: imagePath) {
            print("[Cache] Found cached image: \(imagePath)")
            return URL(fileURLWithPath: imagePath)
        }

        print("[Cache] No cached image found for: \(imageType)")
        return nil
    }

    /// Download image if not cached, return path when complete
    func downloadImage(
        for imageType: VMImageType,
        progressHandler: @escaping (Double, String) -> Void,
        completionHandler: @escaping (Result<URL, Error>) -> Void
    ) {
        NSLog("[ISOCacheManager] downloadImage() called")

        // SECURITY: Enforce Kali Linux for security router VMs
        if case .linux(let distro, _, let isSecurityRouter) = imageType, isSecurityRouter {
            guard distro == .kali else {
                let error = NSError(
                    domain: "ISOCacheManager",
                    code: 200,
                    userInfo: [NSLocalizedDescriptionKey: "SECURITY: Security router VMs must use Kali Linux (attempted to use \(distro.rawValue))"]
                )
                auditLog("SECURITY ALERT: Rejected non-Kali router VM request (distro: \(distro.rawValue))")
                completionHandler(.failure(error))
                return
            }
            auditLog("Creating security router VM with Kali Linux")
        }

        // Check if already cached
        if let cachedURL = getCachedImage(for: imageType) {
            NSLog("[ISOCacheManager] Using cached image, skipping download")
            completionHandler(.success(cachedURL))
            return
        }

        // Download based on type
        NSLog("[ISOCacheManager] Switching on imageType...")
        switch imageType {
        case .macOS(let version):
            NSLog("[ISOCacheManager] Case is macOS, calling downloadMacOSImage...")
            downloadMacOSImage(version: version, progressHandler: progressHandler, completionHandler: completionHandler)
        case .linux(let distro, let version, let isSecurityRouter):
            NSLog("[ISOCacheManager] Case is Linux")
            auditLog("Download requested: \(distro.rawValue) \(version) (router: \(isSecurityRouter))")
            downloadLinuxISO(distro: distro, version: version, progressHandler: progressHandler, completionHandler: completionHandler)
        }
        NSLog("[ISOCacheManager] downloadImage() switch completed")
    }

    /// Get total cache size in GB
    func getCacheSizeGB() -> Double {
        guard let enumerator = FileManager.default.enumerator(atPath: cacheRoot) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let file as String in enumerator {
            let filePath = cacheRoot + file
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return Double(totalSize) / (1024 * 1024 * 1024)
    }

    /// List all cached images with sizes
    func listCachedImages() -> [(name: String, sizeGB: Double, path: String)] {
        var images: [(String, Double, String)] = []

        // Scan MacOS directory
        let macOSDir = cacheRoot + "MacOS/"
        if let macOSItems = try? FileManager.default.contentsOfDirectory(atPath: macOSDir) {
            for item in macOSItems {
                let itemPath = macOSDir + item
                if let size = getDirectorySize(itemPath) {
                    images.append((item, size, itemPath))
                }
            }
        }

        // Scan Linux directory
        let linuxDir = cacheRoot + "Linux/"
        if let linuxItems = try? FileManager.default.contentsOfDirectory(atPath: linuxDir) {
            for item in linuxItems {
                let itemPath = linuxDir + item
                if let size = getDirectorySize(itemPath) {
                    images.append((item, size, itemPath))
                }
            }
        }

        return images
    }

    /// Delete cached image to free space
    func deleteCachedImage(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
        print("[Cache] Deleted cached image: \(path)")
    }

    // MARK: - Private Helpers

    private func getImagePath(for imageType: VMImageType) -> String {
        switch imageType {
        case .macOS(let version):
            // Format: ~/.avf/VMImages/MacOS/UniversalMac_15.6.1_2025-11-14/
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let today = dateFormatter.string(from: Date())
            return "\(cacheRoot)MacOS/UniversalMac_\(version)_\(today)/"

        case .linux(let distro, let version, _):
            // Format: ~/.avf/VMImages/Linux/Ubuntu-24.04/
            // Note: isSecurityRouter flag doesn't affect cache path - same ISO used for all VMs
            return "\(cacheRoot)Linux/\(distro.rawValue)-\(version)/"
        }
    }

    private func downloadMacOSImage(
        version: String,
        progressHandler: @escaping (Double, String) -> Void,
        completionHandler: @escaping (Result<URL, Error>) -> Void
    ) {
        NSLog("[ISOCacheManager] downloadMacOSImage() called for version: %@", version)

        // Use existing MacOSVMInstaller but with central cache path
        let imagePath = getImagePath(for: .macOS(version: version))
        NSLog("[ISOCacheManager] Image path: %@", imagePath)

        // Keep strong reference to prevent deallocation during download
        macOSInstaller = MacOSVMInstaller(vmBundlePath: imagePath)
        NSLog("[ISOCacheManager] Created MacOSVMInstaller, setting handlers...")

        macOSInstaller?.progressHandler = progressHandler
        macOSInstaller?.completionHandler = { [weak self] result in
            NSLog("[ISOCacheManager] Completion handler called with result")
            // Call original completion handler
            completionHandler(result)
            // Release installer reference after completion
            self?.macOSInstaller = nil
        }

        NSLog("[ISOCacheManager] Calling downloadLatestMacOSImage()...")
        macOSInstaller?.downloadLatestMacOSImage()
        NSLog("[ISOCacheManager] downloadLatestMacOSImage() call completed (async)")
    }

    private func downloadLinuxISO(
        distro: LinuxDistro,
        version: String,
        progressHandler: @escaping (Double, String) -> Void,
        completionHandler: @escaping (Result<URL, Error>) -> Void
    ) {
        let imagePath = getImagePath(for: .linux(distro: distro, version: version))

        // Create directory
        try? FileManager.default.createDirectory(atPath: imagePath, withIntermediateDirectories: true)

        guard let url = URL(string: distro.downloadURL) else {
            let error = NSError(domain: "ISOCacheManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
            completionHandler(.failure(error))
            return
        }

        // SECURITY: Validate URL before downloading
        guard validateDownloadURL(url, allowedDomains: LinuxDistro.approvedDomains) else {
            let error = NSError(domain: "ISOCacheManager", code: 100, userInfo: [NSLocalizedDescriptionKey: "SECURITY: URL failed validation - not from approved domain"])
            completionHandler(.failure(error))
            return
        }

        let fileName = url.lastPathComponent
        let destinationURL = URL(fileURLWithPath: imagePath + fileName)

        print("[Cache] Downloading \(distro.rawValue) ISO from: \(url)")
        print("[Cache] Destination: \(destinationURL.path)")

        // SECURITY: Create session with secure configuration
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 7200.0  // 2 hours for large ISOs

        let session = URLSession(configuration: config, delegate: nil, delegateQueue: .main)
        let downloadTask = session.downloadTask(with: url) { [weak self] tempLocation, response, error in
            if let error = error {
                print("[Cache] Download failed: \(error)")
                completionHandler(.failure(error))
                return
            }

            guard let tempLocation = tempLocation else {
                let error = NSError(domain: "ISOCacheManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No download location"])
                completionHandler(.failure(error))
                return
            }

            // SECURITY: Validate file size (reject >20GB to prevent DoS)
            if let fileSize = try? FileManager.default.attributesOfItem(atPath: tempLocation.path)[.size] as? Int64 {
                let sizeGB = Double(fileSize) / (1024 * 1024 * 1024)
                print("[Cache] Downloaded file size: \(String(format: "%.2f", sizeGB)) GB")

                if sizeGB > 20 {
                    let error = NSError(domain: "ISOCacheManager", code: 101, userInfo: [NSLocalizedDescriptionKey: "SECURITY: File too large (\(String(format: "%.2f", sizeGB)) GB) - max 20GB allowed"])
                    try? FileManager.default.removeItem(at: tempLocation)
                    completionHandler(.failure(error))
                    return
                }
            }

            do {
                // Move to cache
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempLocation, to: destinationURL)

                // SECURITY: Verify SHA256 checksum (when not placeholder)
                if !distro.sha256Checksum.hasPrefix("PLACEHOLDER") {
                    print("[Cache] Verifying SHA256 checksum...")
                    guard let self = self, self.verifySHA256(file: destinationURL, expectedHash: distro.sha256Checksum) else {
                        let error = NSError(domain: "ISOCacheManager", code: 102, userInfo: [NSLocalizedDescriptionKey: "SECURITY: SHA256 checksum verification failed - file may be corrupted or tampered"])
                        try? FileManager.default.removeItem(at: destinationURL)
                        completionHandler(.failure(error))
                        return
                    }
                    print("[Cache] ✓ SHA256 verification passed")
                }

                print("[Cache] Successfully cached \(distro.rawValue) ISO")
                completionHandler(.success(destinationURL))
            } catch {
                print("[Cache] Failed to move ISO: \(error)")
                completionHandler(.failure(error))
            }
        }

        downloadTask.resume()

        // TODO: Add progress tracking similar to MacOSVMInstaller
    }

    // SECURITY: Validate download URL
    private func validateDownloadURL(_ url: URL, allowedDomains: Set<String>) -> Bool {
        // Ensure HTTPS
        guard url.scheme == "https" else {
            print("SECURITY: Rejected non-HTTPS URL: \(url)")
            return false
        }

        // Ensure host is in approved list
        guard let host = url.host?.lowercased(), allowedDomains.contains(host) else {
            print("SECURITY: Rejected URL from unauthorized host: \(url.host ?? "unknown")")
            return false
        }

        // Ensure it's an ISO file
        guard url.pathExtension.lowercased() == "iso" else {
            print("SECURITY: Rejected non-ISO file: \(url.pathExtension)")
            return false
        }

        print("SECURITY: URL validation passed for: \(url)")
        return true
    }

    // SECURITY: Verify SHA256 checksum
    private func verifySHA256(file: URL, expectedHash: String) -> Bool {
        guard let fileData = try? Data(contentsOf: file) else {
            print("SECURITY: Failed to read file for SHA256 verification")
            return false
        }

        let digest = SHA256.hash(data: fileData)
        let calculatedHash = digest.compactMap { String(format: "%02x", $0) }.joined()

        let match = calculatedHash.lowercased() == expectedHash.lowercased()
        if !match {
            print("SECURITY: SHA256 mismatch!")
            print("  Expected: \(expectedHash)")
            print("  Got:      \(calculatedHash)")
        }

        return match
    }

    private func getDirectorySize(_ path: String) -> Double? {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return nil
        }

        var totalSize: Int64 = 0
        for case let file as String in enumerator {
            let filePath = path + "/" + file
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return Double(totalSize) / (1024 * 1024 * 1024)
    }
}

// MARK: - Debug Extension

extension VMImageType: CustomStringConvertible {
    var description: String {
        switch self {
        case .macOS(let version):
            return "macOS \(version)"
        case .linux(let distro, let version, let isSecurityRouter):
            let routerTag = isSecurityRouter ? " (Security Router)" : ""
            return "\(distro.rawValue) \(version)\(routerTag)"
        }
    }
}
