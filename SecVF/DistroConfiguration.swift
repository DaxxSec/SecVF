//
//  DistroConfiguration.swift
//  SecVF
//
//  Externalized Linux distribution configuration loaded from JSON.
//  Allows updating distro versions, URLs, and checksums without recompiling.
//
//  The JSON config file is loaded from:
//  1. User override: ~/.avf/distros.json (if exists)
//  2. Bundle default: Resources/distros.json
//

import Foundation

// MARK: - Data Model

/// Strategy for parsing version directories
enum VersionDiscoveryStrategy: String, Codable {
    case ubuntuReleases      // /releases/{version}/release/
    case debianCurrent       // /debian-cd/current/ with version in filename
    case kaliReleases        // /kali-{version}/
    case fedoraReleases      // /pub/fedora/linux/releases/{version}/
    case archMonthly         // /iso/{YYYY.MM.DD}/
    case manjaroReleases     // /{edition}/{version}/
    case genericDirectory    // Simple directory listing
}

/// Represents a discovered distro version with download info
struct DiscoveredVersion: Identifiable, Hashable {
    let id = UUID()
    let version: String
    let displayName: String
    let downloadURL: String
    let checksumURL: String?
    let releaseDate: Date?
    let fileSize: Int64?

    func hash(into hasher: inout Hasher) {
        hasher.combine(version)
        hasher.combine(downloadURL)
    }

    static func == (lhs: DiscoveredVersion, rhs: DiscoveredVersion) -> Bool {
        lhs.version == rhs.version && lhs.downloadURL == rhs.downloadURL
    }
}

/// Version discovery configuration for dynamic version detection
struct VersionDiscoveryConfig: Codable {
    /// Whether version discovery is enabled for this distro
    let enabled: Bool

    /// Base URL for version discovery (e.g., "https://cdimage.ubuntu.com/releases/")
    let baseURL: String

    /// Strategy for parsing the directory listing
    let strategy: VersionDiscoveryStrategy

    /// Filename pattern to match (e.g., "ubuntu-*-desktop-arm64.iso")
    let filenamePattern: String

    /// Target architecture (e.g., "arm64", "aarch64", "x86_64")
    let architecture: String
}

/// Configuration for a single Linux distribution
struct DistroConfiguration: Codable, Identifiable {
    /// Unique identifier matching LinuxDistro raw value (e.g., "Ubuntu Desktop", "Kali")
    let id: String

    /// Display name shown in UI
    let displayName: String

    /// Version string (e.g., "24.04", "2025.3")
    let version: String

    /// Release date in YYYY-MM-DD format
    let releaseDate: String

    /// Official download URL (must be HTTPS from approved domain)
    let downloadURL: String

    /// SHA256 checksum for integrity verification (fallback if dynamic fetch fails)
    let sha256Checksum: String

    /// Maximum expected file size in GB (for DoS protection)
    let expectedMaxSizeGB: Double

    /// URL to fetch current SHA256 checksum from official source (optional)
    /// If provided, checksum will be fetched dynamically at download time
    let checksumURL: String?

    /// Format of the checksum file (defaults to sha256sums if not specified)
    let checksumFormat: ChecksumFileFormat?

    /// Version discovery configuration for dynamic version detection
    let versionDiscovery: VersionDiscoveryConfig?

    /// Coding keys to handle optional fields with defaults
    enum CodingKeys: String, CodingKey {
        case id, displayName, version, releaseDate, downloadURL
        case sha256Checksum, expectedMaxSizeGB, checksumURL, checksumFormat
        case versionDiscovery
    }

    /// Custom decoder to handle optional fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        version = try container.decode(String.self, forKey: .version)
        releaseDate = try container.decode(String.self, forKey: .releaseDate)
        downloadURL = try container.decode(String.self, forKey: .downloadURL)
        sha256Checksum = try container.decode(String.self, forKey: .sha256Checksum)
        expectedMaxSizeGB = try container.decode(Double.self, forKey: .expectedMaxSizeGB)
        checksumURL = try container.decodeIfPresent(String.self, forKey: .checksumURL)
        checksumFormat = try container.decodeIfPresent(ChecksumFileFormat.self, forKey: .checksumFormat)
        versionDiscovery = try container.decodeIfPresent(VersionDiscoveryConfig.self, forKey: .versionDiscovery)
    }

    /// Manual initializer for hardcoded defaults
    init(id: String, displayName: String, version: String, releaseDate: String,
         downloadURL: String, sha256Checksum: String, expectedMaxSizeGB: Double,
         checksumURL: String? = nil, checksumFormat: ChecksumFileFormat? = nil,
         versionDiscovery: VersionDiscoveryConfig? = nil) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.releaseDate = releaseDate
        self.downloadURL = downloadURL
        self.sha256Checksum = sha256Checksum
        self.expectedMaxSizeGB = expectedMaxSizeGB
        self.checksumURL = checksumURL
        self.checksumFormat = checksumFormat
        self.versionDiscovery = versionDiscovery
    }

    /// Parsed release date
    var releaseDateParsed: Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: releaseDate) ?? Date.distantPast
    }

    /// Get the ISO filename from the download URL
    var isoFilename: String {
        return URL(string: downloadURL)?.lastPathComponent ?? ""
    }
}

/// Root structure of the distros.json file
struct DistroConfigurationFile: Codable {
    /// Schema version for future compatibility
    let schemaVersion: Int

    /// Last updated timestamp
    let lastUpdated: String

    /// Whitelist of approved download domains
    let approvedDomains: [String]

    /// Array of distribution configurations
    let distributions: [DistroConfiguration]
}

// MARK: - Configuration Manager

/// Loads and manages Linux distribution configurations from JSON
class DistroConfigurationManager {
    static let shared = DistroConfigurationManager()

    /// Loaded configuration file
    private(set) var configFile: DistroConfigurationFile?

    /// Distributions indexed by ID for quick lookup
    private var distrosByID: [String: DistroConfiguration] = [:]

    /// Path to user override file
    private let userConfigPath: String

    /// Whether configuration was successfully loaded
    var isLoaded: Bool { configFile != nil }

    private init() {
        userConfigPath = NSHomeDirectory() + "/.avf/distros.json"
        loadConfiguration()
    }

    /// Reload configuration from disk
    func reloadConfiguration() {
        loadConfiguration()
    }

    /// Load configuration, preferring user override over bundle default
    private func loadConfiguration() {
        // First, load bundle config to get the authoritative approved domains list
        var bundleApprovedDomains: Set<String> = []
        if let bundlePath = Bundle.main.path(forResource: "distros", ofType: "json"),
           let bundleConfig = loadConfigFromPath(bundlePath) {
            bundleApprovedDomains = Set(bundleConfig.approvedDomains)
        }

        // Try user override first (but validate against bundle's approved domains)
        if FileManager.default.fileExists(atPath: userConfigPath) {
            if let userConfig = loadConfigFromPath(userConfigPath) {
                // SECURITY: Validate that user config only uses approved domains from bundle
                if validateUserConfig(userConfig, approvedDomains: bundleApprovedDomains) {
                    configFile = userConfig
                    buildIndex()
                    NSLog("DistroConfigurationManager: Loaded user config from \(userConfigPath)")
                    return
                } else {
                    NSLog("DistroConfigurationManager: SECURITY - User config rejected (unapproved domains)")
                }
            }
            NSLog("DistroConfigurationManager: Failed to load user config, falling back to bundle")
        }

        // Fall back to bundle default
        if let bundlePath = Bundle.main.path(forResource: "distros", ofType: "json") {
            if loadFromPath(bundlePath) {
                NSLog("DistroConfigurationManager: Loaded bundle config from \(bundlePath)")
                return
            }
        }

        // If all else fails, use hardcoded defaults
        NSLog("DistroConfigurationManager: No config found, using hardcoded defaults")
        loadHardcodedDefaults()
    }

    /// SECURITY: Validate user config against bundle's approved domains
    /// This prevents users from accidentally or maliciously adding untrusted download sources
    private func validateUserConfig(_ config: DistroConfigurationFile, approvedDomains: Set<String>) -> Bool {
        // If bundle has no approved domains, fall back to config's own domains (less secure)
        let domainsToCheck = approvedDomains.isEmpty ? Set(config.approvedDomains) : approvedDomains

        for distro in config.distributions {
            guard let url = URL(string: distro.downloadURL),
                  url.scheme == "https",
                  let host = url.host?.lowercased(),
                  domainsToCheck.contains(host) else {
                NSLog("DistroConfigurationManager: SECURITY ALERT - Rejected URL from unapproved domain: \(distro.downloadURL)")
                return false
            }
        }
        return true
    }

    /// Load and parse config from path without setting it as active
    private func loadConfigFromPath(_ path: String) -> DistroConfigurationFile? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(DistroConfigurationFile.self, from: data)
        } catch {
            NSLog("DistroConfigurationManager: Error parsing \(path): \(error)")
            return nil
        }
    }

    /// Build the distrosByID index from current configFile
    private func buildIndex() {
        distrosByID = [:]
        for distro in configFile?.distributions ?? [] {
            distrosByID[distro.id] = distro
        }
    }

    /// Load configuration from a specific file path
    private func loadFromPath(_ path: String) -> Bool {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            configFile = try decoder.decode(DistroConfigurationFile.self, from: data)

            // Build index
            distrosByID = [:]
            for distro in configFile?.distributions ?? [] {
                distrosByID[distro.id] = distro
            }

            return true
        } catch {
            NSLog("DistroConfigurationManager: Error loading \(path): \(error)")
            return false
        }
    }

    /// Fallback hardcoded defaults matching the original LinuxDistro enum
    private func loadHardcodedDefaults() {
        let defaults = DistroConfigurationFile(
            schemaVersion: 1,
            lastUpdated: "2024-12-10",
            approvedDomains: [
                "cdimage.ubuntu.com",
                "cdimage.debian.org",
                "download.fedoraproject.org",
                "cdimage.kali.org",
                "download.parrot.sh",
                "geo.mirror.pkgbuild.com",
                "download.manjaro.org"
            ],
            distributions: [
                DistroConfiguration(
                    id: "Ubuntu Desktop",
                    displayName: "Ubuntu Desktop",
                    version: "24.04",
                    releaseDate: "2024-04-25",
                    downloadURL: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-desktop-arm64.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_UBUNTU_DESKTOP_CHECKSUMS",
                    expectedMaxSizeGB: 6.0
                ),
                DistroConfiguration(
                    id: "Ubuntu Server",
                    displayName: "Ubuntu Server",
                    version: "24.04",
                    releaseDate: "2024-04-25",
                    downloadURL: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04-live-server-arm64.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_UBUNTU_SERVER_CHECKSUMS",
                    expectedMaxSizeGB: 3.0
                ),
                DistroConfiguration(
                    id: "Debian",
                    displayName: "Debian",
                    version: "12.0",
                    releaseDate: "2023-06-10",
                    downloadURL: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-12.0.0-arm64-netinst.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_DEBIAN_CHECKSUMS",
                    expectedMaxSizeGB: 4.0
                ),
                DistroConfiguration(
                    id: "Fedora",
                    displayName: "Fedora",
                    version: "39",
                    releaseDate: "2023-11-07",
                    downloadURL: "https://download.fedoraproject.org/pub/fedora/linux/releases/39/Server/aarch64/iso/Fedora-Server-dvd-aarch64-39-1.5.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_FEDORA_CHECKSUMS",
                    expectedMaxSizeGB: 7.0
                ),
                DistroConfiguration(
                    id: "Kali",
                    displayName: "Kali Linux",
                    version: "2025.3",
                    releaseDate: "2024-03-11",
                    downloadURL: "https://cdimage.kali.org/kali-2025.3/kali-linux-2025.3-installer-arm64.iso",
                    sha256Checksum: "7a5ce065113af70d9c2924ff3019a986f4df784c5bc0929b10cc2d05892e9445",
                    expectedMaxSizeGB: 8.0
                ),
                DistroConfiguration(
                    id: "ParrotOS",
                    displayName: "Parrot Security",
                    version: "6.0",
                    releaseDate: "2024-01-15",
                    downloadURL: "https://download.parrot.sh/parrot/iso/6.0/Parrot-security-6.0_arm64.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_PARROT_CHECKSUMS",
                    expectedMaxSizeGB: 6.0
                ),
                DistroConfiguration(
                    id: "Arch",
                    displayName: "Arch Linux",
                    version: "Latest",
                    releaseDate: "2024-11-01",
                    downloadURL: "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-arm64.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_ARCH_CHECKSUMS",
                    expectedMaxSizeGB: 2.0
                ),
                DistroConfiguration(
                    id: "Manjaro",
                    displayName: "Manjaro",
                    version: "23.1.3",
                    releaseDate: "2024-01-28",
                    downloadURL: "https://download.manjaro.org/gnome/23.1.3/manjaro-gnome-23.1.3-minimal-stable-aarch64.iso",
                    sha256Checksum: "PLACEHOLDER_UPDATE_FROM_MANJARO_CHECKSUMS",
                    expectedMaxSizeGB: 5.0
                )
            ]
        )

        configFile = defaults
        distrosByID = [:]
        for distro in defaults.distributions {
            distrosByID[distro.id] = distro
        }
    }

    // MARK: - Public API

    /// Get configuration for a specific distribution
    /// - Parameter distro: The LinuxDistro enum case
    /// - Returns: Configuration if found, nil otherwise
    func configuration(for distro: LinuxDistro) -> DistroConfiguration? {
        return distrosByID[distro.rawValue]
    }

    /// Get all available distributions
    var allDistributions: [DistroConfiguration] {
        return configFile?.distributions ?? []
    }

    /// Get approved download domains
    var approvedDomains: Set<String> {
        return Set(configFile?.approvedDomains ?? [])
    }

    /// Check if a URL is from an approved domain
    func isApprovedDomain(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return approvedDomains.contains(host)
    }

    /// TTL between distro version refreshes. Stored in UserDefaults so we
    /// don't spam mirrors on every launch (S9 of PR #4 review).
    private static let refreshTTLSeconds: TimeInterval = 6 * 60 * 60   // 6h
    private static let lastRefreshDefaultsKey = "com.secvf.distro.lastRefreshAttempt"

    /// Check all distros with version discovery enabled against their mirrors.
    /// Updates the user config (`~/.avf/distros.json`) with any newer versions found.
    /// Calls `progress` on the main thread for each distro checked.
    /// Calls `completion` on the main thread when all checks are done.
    ///
    /// Rate-limited: skips if a refresh attempt landed within `refreshTTLSeconds`.
    /// Pass `force: true` to bypass the TTL (e.g. for a manual "Check Now" menu item).
    @MainActor
    func refreshDistroVersions(
        force: Bool = false,
        progress: @escaping (_ distroName: String, _ status: String) -> Void,
        completion: @escaping (_ updated: [String], _ errors: [String]) -> Void
    ) {
        // S9: skip if we refreshed recently. Prevents launch from blocking on
        // every cold start while a slow mirror times out, and stops us from
        // pestering distro CDNs on every relaunch in the same session.
        if !force,
           let last = UserDefaults.standard.object(forKey: Self.lastRefreshDefaultsKey) as? Date,
           Date().timeIntervalSince(last) < Self.refreshTTLSeconds {
            NSLog("[DistroRefresh] Skipped — last attempt %.0fs ago, TTL %.0fs",
                  Date().timeIntervalSince(last), Self.refreshTTLSeconds)
            completion([], [])
            return
        }
        // Stamp the attempt up front so a hung or slow refresh still counts
        // toward the rate limit (failures shouldn't trigger immediate retry).
        UserDefaults.standard.set(Date(), forKey: Self.lastRefreshDefaultsKey)

        guard let config = configFile else {
            completion([], ["No distro configuration loaded"])
            return
        }

        let discoverable = config.distributions.filter {
            $0.versionDiscovery?.enabled == true
        }

        guard !discoverable.isEmpty else {
            completion([], [])
            return
        }

        let group = DispatchGroup()
        var updatedDistros: [String] = []
        var errorMessages: [String] = []
        var updatedConfigs: [String: DiscoveredVersion] = [:]

        for distro in discoverable {
            guard let discovery = distro.versionDiscovery else { continue }
            group.enter()

            progress(distro.displayName, "Checking...")

            DistroVersionFetcher.shared.clearCacheForDistro(distro.id)
            DistroVersionFetcher.shared.fetchVersions(
                for: distro.id,
                baseURL: discovery.baseURL,
                strategy: discovery.strategy,
                filenamePattern: discovery.filenamePattern,
                architecture: discovery.architecture
            ) { result in
                switch result {
                case .success(let versions):
                    guard let latest = versions.first else {
                        progress(distro.displayName, "No versions found")
                        group.leave()
                        return
                    }
                    let currentVersion = distro.version
                    let isNewer = latest.version.compare(currentVersion, options: .numeric) == .orderedDescending
                    if isNewer {
                        NSLog("[DistroRefresh] %@: %@ -> %@ (update available)", distro.displayName, currentVersion, latest.version)
                        progress(distro.displayName, "\(currentVersion) -> \(latest.version)")
                        updatedConfigs[distro.id] = latest
                        updatedDistros.append("\(distro.displayName): \(currentVersion) -> \(latest.version)")
                    } else {
                        NSLog("[DistroRefresh] %@: %@ is current", distro.displayName, currentVersion)
                        progress(distro.displayName, "\(currentVersion) (current)")
                    }

                case .noVersionsFound(let reason):
                    NSLog("[DistroRefresh] %@: no versions — %@", distro.displayName, reason)
                    progress(distro.displayName, "Skipped")

                case .networkError(let err):
                    NSLog("[DistroRefresh] %@: network error — %@", distro.displayName, err.localizedDescription)
                    errorMessages.append("\(distro.displayName): \(err.localizedDescription)")
                    progress(distro.displayName, "Offline")

                case .parseError(let msg):
                    NSLog("[DistroRefresh] %@: parse error — %@", distro.displayName, msg)
                    errorMessages.append("\(distro.displayName): \(msg)")
                    progress(distro.displayName, "Error")
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !updatedConfigs.isEmpty else {
                completion(updatedDistros, errorMessages)
                return
            }

            // Rebuild config with updated versions
            let newDistros = config.distributions.map { distro -> DistroConfiguration in
                guard let latest = updatedConfigs[distro.id] else { return distro }
                let today = {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.locale = Locale(identifier: "en_US_POSIX")
                    return f.string(from: Date())
                }()
                return DistroConfiguration(
                    id: distro.id,
                    displayName: distro.displayName,
                    version: latest.version,
                    releaseDate: today,
                    downloadURL: latest.downloadURL,
                    sha256Checksum: "FETCH_FROM_CHECKSUM_URL",
                    expectedMaxSizeGB: distro.expectedMaxSizeGB,
                    checksumURL: latest.checksumURL ?? distro.checksumURL,
                    checksumFormat: distro.checksumFormat,
                    versionDiscovery: distro.versionDiscovery
                )
            }

            let today = {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f.string(from: Date())
            }()

            self.configFile = DistroConfigurationFile(
                schemaVersion: config.schemaVersion,
                lastUpdated: today,
                approvedDomains: config.approvedDomains,
                distributions: newDistros
            )
            self.distrosByID = Dictionary(uniqueKeysWithValues: newDistros.map { ($0.id, $0) })

            do {
                try self.saveUserConfiguration()
                NSLog("[DistroRefresh] Saved updated config with %d updates", updatedConfigs.count)
            } catch {
                errorMessages.append("Failed to save: \(error.localizedDescription)")
            }

            completion(updatedDistros, errorMessages)
        }
    }

    /// Save current configuration to user override file
    /// Useful for programmatic updates
    func saveUserConfiguration() throws {
        guard let config = configFile else {
            throw NSError(domain: "DistroConfigurationManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No configuration loaded"])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        // Ensure directory exists
        let dir = (userConfigPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try data.write(to: URL(fileURLWithPath: userConfigPath))
        NSLog("DistroConfigurationManager: Saved user config to \(userConfigPath)")
    }
}
