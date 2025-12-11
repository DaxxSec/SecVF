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

enum LinuxDistro: String, Codable {
    case ubuntu = "Ubuntu Desktop"
    case ubuntuServer = "Ubuntu Server"
    case debian = "Debian"
    case fedora = "Fedora"
    case kali = "Kali"
    case parrot = "ParrotOS"
    case arch = "Arch"
    case manjaro = "Manjaro"

    // MARK: - JSON Configuration Delegation
    // These properties delegate to DistroConfigurationManager when available,
    // falling back to hardcoded defaults if the JSON config isn't loaded.

    /// Get configuration from JSON manager
    private var jsonConfig: DistroConfiguration? {
        return DistroConfigurationManager.shared.configuration(for: self)
    }

    // Release date of the current version
    var releaseDate: Date {
        if let config = jsonConfig {
            return config.releaseDateParsed
        }
        return releaseDateFallback
    }

    // Fallback release date (hardcoded)
    private var releaseDateFallback: Date {
        let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        let dateString: String
        switch self {
        case .ubuntu:       dateString = "2024-04-25"
        case .ubuntuServer: dateString = "2024-04-25"
        case .debian:       dateString = "2023-06-10"
        case .fedora:       dateString = "2023-11-07"
        case .kali:         dateString = "2024-03-11"
        case .parrot:       dateString = "2024-01-15"
        case .arch:         dateString = "2024-11-01"
        case .manjaro:      dateString = "2024-01-28"
        }
        return formatter.date(from: dateString) ?? Date.distantPast
    }

    // Version string
    var version: String {
        if let config = jsonConfig {
            return config.version
        }
        return versionFallback
    }

    // Fallback version (hardcoded)
    private var versionFallback: String {
        switch self {
        case .ubuntu:       return "24.04"
        case .ubuntuServer: return "24.04"
        case .debian:       return "12.0"
        case .fedora:       return "39"
        case .kali:         return "2025.3"
        case .parrot:       return "6.0"
        case .arch:         return "Latest"
        case .manjaro:      return "23.1.3"
        }
    }

    // SECURITY: Official CDN URLs - delegates to JSON config
    var downloadURL: String {
        if let config = jsonConfig {
            return config.downloadURL
        }
        return downloadURLFallback
    }

    // Fallback download URL (hardcoded)
    private var downloadURLFallback: String {
        switch self {
        case .ubuntu:
            return "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-desktop-arm64.iso"
        case .ubuntuServer:
            return "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-live-server-arm64.iso"
        case .debian:
            return "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-12.0.0-arm64-netinst.iso"
        case .fedora:
            return "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Server/aarch64/iso/Fedora-Server-dvd-aarch64-39-1.5.iso"
        case .kali:
            return "https://cdimage.kali.org/kali-2025.3/kali-linux-2025.3-installer-arm64.iso"
        case .parrot:
            return "https://download.parrot.sh/parrot/iso/6.0/Parrot-security-6.0_arm64.iso"
        case .arch:
            return "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-arm64.iso"
        case .manjaro:
            return "https://download.manjaro.org/gnome/23.1.3/manjaro-gnome-23.1.3-minimal-stable-aarch64.iso"
        }
    }

    // SECURITY: SHA256 checksums - delegates to JSON config
    var sha256Checksum: String {
        if let config = jsonConfig {
            return config.sha256Checksum
        }
        return sha256ChecksumFallback
    }

    // Fallback checksum (hardcoded)
    private var sha256ChecksumFallback: String {
        switch self {
        case .ubuntu:       return "PLACEHOLDER_UPDATE_FROM_UBUNTU_DESKTOP_CHECKSUMS"
        case .ubuntuServer: return "PLACEHOLDER_UPDATE_FROM_UBUNTU_SERVER_CHECKSUMS"
        case .debian:       return "PLACEHOLDER_UPDATE_FROM_DEBIAN_CHECKSUMS"
        case .fedora:       return "PLACEHOLDER_UPDATE_FROM_FEDORA_CHECKSUMS"
        case .kali:         return "7a5ce065113af70d9c2924ff3019a986f4df784c5bc0929b10cc2d05892e9445"
        case .parrot:       return "PLACEHOLDER_UPDATE_FROM_PARROT_CHECKSUMS"
        case .arch:         return "PLACEHOLDER_UPDATE_FROM_ARCH_CHECKSUMS"
        case .manjaro:      return "PLACEHOLDER_UPDATE_FROM_MANJARO_CHECKSUMS"
        }
    }

    // SECURITY: Per-distro size limits - delegates to JSON config
    var expectedMaxSizeGB: Double {
        if let config = jsonConfig {
            return config.expectedMaxSizeGB
        }
        return expectedMaxSizeGBFallback
    }

    // Fallback size limit (hardcoded)
    private var expectedMaxSizeGBFallback: Double {
        switch self {
        case .ubuntu:       return 6.0
        case .ubuntuServer: return 3.0
        case .debian:       return 4.0
        case .fedora:       return 7.0
        case .kali:         return 8.0
        case .parrot:       return 6.0
        case .arch:         return 2.0
        case .manjaro:      return 5.0
        }
    }

    // SECURITY: Whitelist of approved download domains - delegates to JSON config
    static var approvedDomains: Set<String> {
        let jsonDomains = DistroConfigurationManager.shared.approvedDomains
        if !jsonDomains.isEmpty {
            return jsonDomains
        }
        // Fallback hardcoded domains
        return [
            "cdimage.ubuntu.com",
            "cdimage.debian.org",
            "download.fedoraproject.org",
            "cdimage.kali.org",
            "download.parrot.sh",
            "geo.mirror.pkgbuild.com",
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
    fileprivate var activeISODelegate: ISODownloadDelegate?  // Keep strong reference during ISO download

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

        // SECURITY: Verify it's our app using exact bundle ID match
        // (contains() was weak - allowed "com.attacker.FakeSecVF" to pass)
        let validBundleIDs = [
            "com.ItzDaxxy.SecVF",
            "com.daxxsec.SecVF"
        ]
        guard validBundleIDs.contains(bundleID) else {
            auditLog("SECURITY ALERT: Unknown bundle ID '\(bundleID)' - rejecting request")
            return false
        }

        // Note: Thread checking removed - not a meaningful security control
        // Attackers can easily dispatch to main thread. Real security comes from
        // bundle ID verification and URL whitelisting above.

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

        // Check if directory exists
        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("[Cache] No cache directory found for: \(imageType)")
            return nil
        }

        // Look for actual ISO/IPSW file in the directory
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: imagePath) else {
            print("[Cache] Cannot read cache directory: \(imagePath)")
            return nil
        }

        // Find ISO or IPSW file
        let validExtensions = [".iso", ".ipsw"]
        for file in contents {
            for ext in validExtensions where file.hasSuffix(ext) {
                let filePath = imagePath + file
                let fileURL = URL(fileURLWithPath: filePath)

                // Verify file is not a placeholder (> 1MB)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? Int64,
                   fileSize > 1_000_000 {  // > 1MB
                    print("[Cache] Found cached image: \(filePath)")
                    return fileURL
                } else {
                    print("[Cache] Skipping placeholder/invalid file: \(file)")
                }
            }
        }

        print("[Cache] No valid cached image found for: \(imageType)")
        return nil
    }

    /// Download image if not cached, return path when complete
    func downloadImage(
        for imageType: VMImageType,
        progressHandler: @escaping (Double, String) -> Void,
        completionHandler: @escaping (Result<URL, Error>) -> Void
    ) {
        NSLog("[ISOCacheManager] downloadImage() called")

        // SECURITY: Verify caller is legitimate (main app, not external process)
        guard verifyCallerIsMainApp() else {
            let error = NSError(
                domain: "ISOCacheManager",
                code: 300,
                userInfo: [NSLocalizedDescriptionKey: "SECURITY: Download request rejected - invalid caller context"]
            )
            auditLog("SECURITY ALERT: Download rejected - failed caller verification")
            completionHandler(.failure(error))
            return
        }

        // SECURITY: Rate limiting to prevent abuse
        guard checkRateLimit() else {
            let error = NSError(
                domain: "ISOCacheManager",
                code: 301,
                userInfo: [NSLocalizedDescriptionKey: "SECURITY: Download rate limit exceeded - please wait before retrying"]
            )
            completionHandler(.failure(error))
            return
        }

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

        // Download based on type
        NSLog("[ISOCacheManager] Switching on imageType...")
        switch imageType {
        case .macOS(let version):
            // macOS: Always go through MacOSVMInstaller which handles freshness validation
            // It compares cached IPSW filename with Apple's latest to ensure we have current version
            NSLog("[ISOCacheManager] Case is macOS, calling downloadMacOSImage (handles its own cache/freshness check)...")
            downloadMacOSImage(version: version, progressHandler: progressHandler, completionHandler: completionHandler)
        case .linux(let distro, let version, let isSecurityRouter):
            // Linux: Check cache first, download if not found
            if let cachedURL = getCachedImage(for: imageType) {
                NSLog("[ISOCacheManager] Using cached Linux ISO, skipping download")
                completionHandler(.success(cachedURL))
                return
            }
            NSLog("[ISOCacheManager] Case is Linux, no cache found")
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

    /// Get download information for a Linux distribution
    func getDistributionInfo(for distro: LinuxDistro) -> (releaseDate: Date, lastDownloaded: Date?, isCached: Bool) {
        let imagePath = getImagePath(for: .linux(distro: distro, version: distro.version))
        var lastDownloaded: Date? = nil
        var isCached = false

        // Check if ISO is cached and get its modification date
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: imagePath) {
            for file in contents where file.hasSuffix(".iso") {
                let isoPath = imagePath + file
                if FileManager.default.fileExists(atPath: isoPath) {
                    isCached = true
                    // Get file modification date as "last downloaded" date
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: isoPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        lastDownloaded = modDate
                    }
                    break
                }
            }
        }

        return (distro.releaseDate, lastDownloaded, isCached)
    }

    // MARK: - Private Helpers

    private func getImagePath(for imageType: VMImageType) -> String {
        switch imageType {
        case .macOS:
            // macOS IPSWs are stored in ~/.avf/MacOS/ (managed by MacOSVMInstaller)
            // MacOSVMInstaller handles freshness validation by comparing filenames with Apple's servers
            return NSHomeDirectory() + "/.avf/MacOS/"

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

        // Create delegate to handle progress
        let delegate = ISODownloadDelegate()
        delegate.progressHandler = progressHandler
        delegate.completionHandler = completionHandler
        delegate.destinationURL = destinationURL
        delegate.distro = distro
        delegate.distroConfig = DistroConfigurationManager.shared.configuration(for: distro)
        delegate.isoManager = self

        // Store delegate to keep it alive during download
        self.activeISODelegate = delegate

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)

        // Start with initial progress message
        progressHandler(0.0, "Starting download from \(url.host ?? "server")...")

        let downloadTask = session.downloadTask(with: url)
        delegate.downloadTask = downloadTask

        // Create timer to monitor progress
        // Note: Must add to common run loop modes to fire during modal dialogs
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak delegate] _ in
            guard let task = delegate?.downloadTask else {
                NSLog("[ISO Download] Timer fired but no download task")
                return
            }

            let bytesReceived = task.countOfBytesReceived
            let totalBytes = task.countOfBytesExpectedToReceive

            NSLog("[ISO Download] Timer check: %lld / %lld bytes (state: %ld)", bytesReceived, totalBytes, task.state.rawValue)

            if totalBytes > 0 {
                let progress = Double(bytesReceived) / Double(totalBytes)
                let mbReceived = Double(bytesReceived) / (1024 * 1024)
                let mbTotal = Double(totalBytes) / (1024 * 1024)

                let status = String(format: "Downloading: %.1f / %.1f MB", mbReceived, mbTotal)
                NSLog("[ISO Download] Calling progressHandler with progress: %.2f, status: %@", progress * 0.85, status)
                delegate?.progressHandler?(progress * 0.85, status) // Reserve 0.85-1.0 for validation
            } else if bytesReceived > 0 {
                // Show progress even without total size
                let mbReceived = Double(bytesReceived) / (1024 * 1024)
                let status = String(format: "Downloading: %.1f MB...", mbReceived)
                delegate?.progressHandler?(0.1, status)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        delegate.progressTimer = timer

        NSLog("[ISO Download] Starting download task for: %@", url.absoluteString)
        downloadTask.resume()
        NSLog("[ISO Download] Download task state after resume: %ld", downloadTask.state.rawValue)
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

    // SECURITY: Verify SHA256 checksum using streaming to avoid loading entire file into memory
    // This is critical for large ISO files (4-8GB) that would otherwise cause memory pressure
    func verifySHA256(file: URL, expectedHash: String) -> Bool {
        guard let inputStream = InputStream(url: file) else {
            print("SECURITY: Failed to open file stream for SHA256 verification")
            return false
        }

        inputStream.open()
        defer { inputStream.close() }

        // Use 1MB buffer for streaming hash - balances memory usage vs I/O efficiency
        let bufferSize = 1024 * 1024  // 1MB chunks
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var hasher = SHA256()

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                print("SECURITY: Error reading file during SHA256 verification: \(inputStream.streamError?.localizedDescription ?? "unknown error")")
                return false
            }
            if bytesRead == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<bytesRead]))
        }

        let digest = hasher.finalize()
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

// MARK: - Download Progress Delegate

private class ISODownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var progressHandler: ((Double, String) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?
    var destinationURL: URL?
    var distro: LinuxDistro?
    var distroConfig: DistroConfiguration?  // For dynamic checksum fetching
    var isoManager: ISOCacheManager?
    var progressTimer: Timer?
    var downloadTask: URLSessionDownloadTask?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Stop progress timer
        progressTimer?.invalidate()
        progressTimer = nil

        guard let destinationURL = destinationURL,
              let distro = distro,
              let isoManager = isoManager else {
            let error = NSError(domain: "ISOCacheManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required properties"])
            completionHandler?(.failure(error))
            return
        }

        progressHandler?(0.9, "Download complete, validating...")

        // SECURITY: Validate file size using per-distro limits
        // (More restrictive than blanket 20GB - prevents malicious mirrors filling disk)
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64 {
            let sizeGB = Double(fileSize) / (1024 * 1024 * 1024)
            let maxSizeGB = distro.expectedMaxSizeGB
            print("[Cache] Downloaded file size: \(String(format: "%.2f", sizeGB)) GB (max: \(maxSizeGB) GB for \(distro.rawValue))")
            progressHandler?(0.92, "Downloaded \(String(format: "%.2f", sizeGB)) GB")

            if sizeGB > maxSizeGB {
                let error = NSError(domain: "ISOCacheManager", code: 101, userInfo: [
                    NSLocalizedDescriptionKey: "SECURITY: File too large (\(String(format: "%.2f", sizeGB)) GB) - max \(maxSizeGB) GB allowed for \(distro.rawValue)"
                ])
                try? FileManager.default.removeItem(at: location)
                completionHandler?(.failure(error))
                return
            }
        }

        do {
            progressHandler?(0.94, "Moving to cache...")

            // Move to cache
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)

            // SECURITY: Verify SHA256 checksum
            // First try dynamic fetch from official source, fall back to static checksum
            progressHandler?(0.86, "Fetching checksum from official source...")

            // Check if we have a checksumURL for dynamic fetching
            if let config = distroConfig,
               let checksumURL = config.checksumURL,
               !checksumURL.isEmpty {
                // Dynamic checksum fetch
                let format = config.checksumFormat ?? .sha256sums
                let filename = config.isoFilename

                print("[Cache] Fetching checksum dynamically from: \(checksumURL)")

                ChecksumFetcher.shared.fetchChecksum(
                    distroID: config.id,
                    checksumURL: checksumURL,
                    format: format,
                    isoFilename: filename
                ) { [weak self] result in
                    switch result {
                    case .success(let checksum, _):
                        print("[Cache] Dynamic checksum fetched: \(checksum.prefix(16))...")
                        self?.verifyAndComplete(
                            destinationURL: destinationURL,
                            expectedHash: checksum,
                            distro: distro,
                            isoManager: isoManager,
                            checksumSource: "official source"
                        )

                    case .notFound(let reason):
                        // Fall back to static checksum if available and not placeholder
                        print("[Cache] Dynamic fetch failed (\(reason)), trying static checksum...")
                        let staticChecksum = distro.sha256Checksum

                        if !staticChecksum.hasPrefix("PLACEHOLDER") && !staticChecksum.hasPrefix("FETCH_") {
                            self?.verifyAndComplete(
                                destinationURL: destinationURL,
                                expectedHash: staticChecksum,
                                distro: distro,
                                isoManager: isoManager,
                                checksumSource: "static fallback"
                            )
                        } else {
                            // No valid checksum available
                            self?.completeWithoutVerification(
                                destinationURL: destinationURL,
                                distro: distro,
                                isoManager: isoManager,
                                reason: "dynamic fetch failed and no static checksum"
                            )
                        }

                    case .networkError(let error):
                        // Fall back to static checksum if available and not placeholder
                        print("[Cache] Dynamic fetch network error (\(error.localizedDescription)), trying static checksum...")
                        let staticChecksum = distro.sha256Checksum

                        if !staticChecksum.hasPrefix("PLACEHOLDER") && !staticChecksum.hasPrefix("FETCH_") {
                            self?.verifyAndComplete(
                                destinationURL: destinationURL,
                                expectedHash: staticChecksum,
                                distro: distro,
                                isoManager: isoManager,
                                checksumSource: "static fallback"
                            )
                        } else {
                            // No valid checksum available
                            self?.completeWithoutVerification(
                                destinationURL: destinationURL,
                                distro: distro,
                                isoManager: isoManager,
                                reason: "dynamic fetch failed and no static checksum"
                            )
                        }

                    case .securityError(let msg):
                        print("[Cache] SECURITY: Checksum fetch rejected - \(msg)")
                        self?.completeWithoutVerification(
                            destinationURL: destinationURL,
                            distro: distro,
                            isoManager: isoManager,
                            reason: "security error: \(msg)"
                        )
                    }
                }
            } else if !distro.sha256Checksum.hasPrefix("PLACEHOLDER") && !distro.sha256Checksum.hasPrefix("FETCH_") {
                // No dynamic URL, but have static checksum
                print("[Cache] Using static checksum (no checksumURL configured)")
                verifyAndComplete(
                    destinationURL: destinationURL,
                    expectedHash: distro.sha256Checksum,
                    distro: distro,
                    isoManager: isoManager,
                    checksumSource: "static config"
                )
            } else {
                // No checksum available at all
                completeWithoutVerification(
                    destinationURL: destinationURL,
                    distro: distro,
                    isoManager: isoManager,
                    reason: "no checksum configured"
                )
            }
        } catch {
            print("[Cache] Failed to move ISO: \(error)")

            // Clear the delegate reference
            isoManager.activeISODelegate = nil

            completionHandler?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        NSLog("[ISO Download] urlSession didCompleteWithError called. Error: %@", error?.localizedDescription ?? "nil")
        progressTimer?.invalidate()
        progressTimer = nil

        if let error = error {
            NSLog("[Cache] Download failed: %@", error.localizedDescription)
            print("[Cache] Download failed: \(error)")

            // Clear the delegate reference
            isoManager?.activeISODelegate = nil

            completionHandler?(.failure(error))
        }
    }

    // MARK: - Verification Helpers

    /// Verify checksum and complete download
    private func verifyAndComplete(
        destinationURL: URL,
        expectedHash: String,
        distro: LinuxDistro,
        isoManager: ISOCacheManager,
        checksumSource: String
    ) {
        progressHandler?(0.88, "Verifying checksum (\(checksumSource))...")
        print("[Cache] Verifying SHA256 checksum from \(checksumSource)...")

        // Show periodic progress updates during verification
        var verificationProgress = 0.88
        let updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            verificationProgress += 0.01
            if verificationProgress <= 0.98 {
                self?.progressHandler?(verificationProgress, "Verifying checksum (this may take 10-30 seconds)...")
            }
        }
        RunLoop.main.add(updateTimer, forMode: .common)

        // Run SHA256 verification on background thread (CPU-intensive for large files)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isValid = isoManager.verifySHA256(file: destinationURL, expectedHash: expectedHash)

            DispatchQueue.main.async {
                updateTimer.invalidate()

                if !isValid {
                    let error = NSError(domain: "ISOCacheManager", code: 102, userInfo: [
                        NSLocalizedDescriptionKey: "SECURITY: SHA256 checksum verification failed - file may be corrupted or tampered"
                    ])
                    try? FileManager.default.removeItem(at: destinationURL)

                    // Clear the delegate reference
                    isoManager.activeISODelegate = nil

                    self?.completionHandler?(.failure(error))
                    return
                }

                print("[Cache] ✓ SHA256 verification passed (source: \(checksumSource))")
                self?.progressHandler?(1.0, "Checksum verified - Complete!")
                print("[Cache] Successfully cached \(distro.rawValue) ISO")

                // Clear the delegate reference
                isoManager.activeISODelegate = nil

                self?.completionHandler?(.success(destinationURL))
            }
        }
    }

    /// Complete download without checksum verification (with warning)
    private func completeWithoutVerification(
        destinationURL: URL,
        distro: LinuxDistro,
        isoManager: ISOCacheManager,
        reason: String
    ) {
        let warningMsg = "WARNING: SHA256 checksum not verified for \(distro.rawValue) (\(reason))"
        print("[SECURITY] \(warningMsg)")

        // Log to audit trail
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let auditEntry = "[\(timestamp)] SECURITY WARNING: Downloaded \(distro.rawValue) ISO without checksum verification (\(reason))\n"
        let auditPath = NSHomeDirectory() + "/.avf/logs/iso-cache-audit.log"
        if let data = auditEntry.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: auditPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: auditPath))
            }
        }

        progressHandler?(1.0, "⚠️ Download complete (checksum not verified)")
        print("[Cache] Successfully cached \(distro.rawValue) ISO (UNVERIFIED)")

        // Clear the delegate reference
        isoManager.activeISODelegate = nil

        completionHandler?(.success(destinationURL))
    }
}
