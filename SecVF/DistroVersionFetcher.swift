//
//  DistroVersionFetcher.swift
//  SecVF
//
//  DYNAMIC VERSION DISCOVERY
//  Queries official distro release directories to discover available versions.
//  Supports multiple directory structures and parsing strategies.
//

import Foundation

// NOTE: DiscoveredVersion and VersionDiscoveryStrategy are defined in DistroConfiguration.swift

/// Result of version discovery
enum VersionDiscoveryResult {
    case success([DiscoveredVersion])
    case noVersionsFound(reason: String)
    case networkError(Error)
    case parseError(String)
}

/// Fetches available versions from distro release servers
@MainActor
class DistroVersionFetcher {
    static let shared = DistroVersionFetcher()

    // Cache discovered versions (15 min TTL)
    private var versionCache: [String: (versions: [DiscoveredVersion], fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 15 * 60

    private init() {}

    // MARK: - Public API

    /// Fetch available versions for a distro
    func fetchVersions(
        for distroID: String,
        baseURL: String,
        strategy: VersionDiscoveryStrategy,
        filenamePattern: String,
        architecture: String = "arm64",
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        // Check cache first
        if let cached = versionCache[distroID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            NSLog("[VersionFetcher] Cache hit for \(distroID)")
            completion(.success(cached.versions))
            return
        }

        NSLog("[VersionFetcher] Fetching versions for \(distroID) from \(baseURL)")

        // Fetch based on strategy
        switch strategy {
        case .ubuntuReleases:
            fetchUbuntuVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .debianCurrent:
            fetchDebianVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .kaliReleases:
            fetchKaliVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .fedoraReleases:
            fetchFedoraVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .archMonthly:
            fetchArchVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .manjaroReleases:
            fetchManjaroVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        case .genericDirectory:
            fetchGenericVersions(distroID: distroID, baseURL: baseURL, pattern: filenamePattern, arch: architecture, completion: completion)
        }
    }

    /// Clear the version cache
    func clearCache() {
        versionCache.removeAll()
    }

    // MARK: - Ubuntu Version Discovery
    // Structure: /releases/ -> list of versions -> /release/ -> ISO files

    private func fetchUbuntuVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        // First, get list of version directories
        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Parse version directories (e.g., "24.04.1/", "24.04.2/", "24.04/")
                let versionPattern = #"href="(\d+\.\d+(?:\.\d+)?)/""#
                guard let regex = try? NSRegularExpression(pattern: versionPattern) else {
                    completion(.parseError("Invalid regex pattern"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var versions: [String] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let version = String(html[range])
                        // Filter to LTS versions and recent releases
                        if version.hasPrefix("24.") || version.hasPrefix("22.04") || version.hasPrefix("25.") {
                            versions.append(version)
                        }
                    }
                }

                // Sort versions descending
                versions = versions.sorted { v1, v2 in
                    v1.compare(v2, options: .numeric) == .orderedDescending
                }

                // Take top 5 versions
                versions = Array(versions.prefix(5))

                // Now fetch ISO details for each version
                self?.fetchUbuntuISOsForVersions(distroID: distroID, baseURL: baseURL, versions: versions, pattern: pattern, arch: arch, completion: completion)

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    private func fetchUbuntuISOsForVersions(
        distroID: String,
        baseURL: String,
        versions: [String],
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        var discoveredVersions: [DiscoveredVersion] = []
        let group = DispatchGroup()

        for version in versions {
            group.enter()

            let releaseURL = "\(baseURL)\(version)/release/"
            guard let url = URL(string: releaseURL) else {
                group.leave()
                continue
            }

            fetchDirectoryListing(url: url) { result in
                defer { group.leave() }

                switch result {
                case .success(let html):
                    // Find ISO files matching pattern (e.g., "ubuntu-*-desktop-arm64.iso")
                    let isoPattern = pattern
                        .replacingOccurrences(of: "*", with: "[^\"]+")
                        .replacingOccurrences(of: ".", with: "\\.")
                    let fullPattern = #"href="(\#(isoPattern))""#

                    guard let regex = try? NSRegularExpression(pattern: fullPattern) else { return }

                    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

                    for match in matches {
                        if let range = Range(match.range(at: 1), in: html) {
                            let filename = String(html[range])

                            // Skip torrents and zsync files
                            if filename.hasSuffix(".torrent") || filename.hasSuffix(".zsync") {
                                continue
                            }

                            // Extract version from filename
                            let fileVersion = self.extractVersionFromFilename(filename, pattern: "ubuntu-([0-9.]+)")

                            let discovered = DiscoveredVersion(
                                version: fileVersion ?? version,
                                displayName: "Ubuntu \(fileVersion ?? version)",
                                downloadURL: "\(releaseURL)\(filename)",
                                checksumURL: "\(releaseURL)SHA256SUMS",
                                releaseDate: nil,
                                fileSize: nil
                            )
                            discoveredVersions.append(discovered)
                        }
                    }

                case .failure:
                    break // Skip failed version directories
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            // Remove duplicates and sort
            let uniqueVersions = Array(Set(discoveredVersions)).sorted {
                $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }

            if uniqueVersions.isEmpty {
                completion(.noVersionsFound(reason: "No ISO files found matching pattern"))
            } else {
                // Cache results
                self?.versionCache[distroID] = (versions: uniqueVersions, fetchedAt: Date())
                completion(.success(uniqueVersions))
            }
        }
    }

    // MARK: - Kali Version Discovery
    // Structure: / -> kali-{version}/ -> ISO files

    private func fetchKaliVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Parse kali version directories (e.g., "kali-2024.4/")
                let versionPattern = #"href="kali-(\d{4}\.\d+)/""#
                guard let regex = try? NSRegularExpression(pattern: versionPattern) else {
                    completion(.parseError("Invalid regex pattern"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var versions: [(version: String, dir: String)] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let version = String(html[range])
                        versions.append((version: version, dir: "kali-\(version)"))
                    }
                }

                // Sort descending, take top 5
                versions = versions.sorted { $0.version > $1.version }
                versions = Array(versions.prefix(5))

                // Build discovered versions
                var discovered: [DiscoveredVersion] = []
                for v in versions {
                    let filename = "kali-linux-\(v.version)-installer-\(arch).iso"
                    let downloadURL = "\(baseURL)\(v.dir)/\(filename)"
                    let checksumURL = "\(baseURL)\(v.dir)/SHA256SUMS"

                    discovered.append(DiscoveredVersion(
                        version: v.version,
                        displayName: "Kali Linux \(v.version)",
                        downloadURL: downloadURL,
                        checksumURL: checksumURL,
                        releaseDate: nil,
                        fileSize: nil
                    ))
                }

                if discovered.isEmpty {
                    completion(.noVersionsFound(reason: "No Kali versions found"))
                } else {
                    self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                    completion(.success(discovered))
                }

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    // MARK: - Debian Version Discovery

    private func fetchDebianVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        // Debian uses "current" symlink, so we fetch the actual directory
        let currentURL = baseURL.replacingOccurrences(of: "/current/", with: "/current/")
        guard let url = URL(string: currentURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Find debian ISO files
                let isoPattern = #"href="(debian-[\d.]+-\#(arch)-netinst\.iso)""#
                guard let regex = try? NSRegularExpression(pattern: isoPattern) else {
                    completion(.parseError("Invalid regex"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var discovered: [DiscoveredVersion] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let filename = String(html[range])
                        let version = self?.extractVersionFromFilename(filename, pattern: "debian-([0-9.]+)") ?? "current"

                        discovered.append(DiscoveredVersion(
                            version: version,
                            displayName: "Debian \(version)",
                            downloadURL: "\(currentURL)\(filename)",
                            checksumURL: "\(currentURL)SHA256SUMS",
                            releaseDate: nil,
                            fileSize: nil
                        ))
                    }
                }

                if discovered.isEmpty {
                    completion(.noVersionsFound(reason: "No Debian ISOs found"))
                } else {
                    self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                    completion(.success(discovered))
                }

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    // MARK: - Fedora Version Discovery

    private func fetchFedoraVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Parse Fedora version directories (e.g., "41/", "40/")
                let versionPattern = #"href="(\d{2})/""#
                guard let regex = try? NSRegularExpression(pattern: versionPattern) else {
                    completion(.parseError("Invalid regex"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var versions: [String] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let version = String(html[range])
                        if let v = Int(version), v >= 38 { // Recent Fedora versions
                            versions.append(version)
                        }
                    }
                }

                versions = versions.sorted { Int($0) ?? 0 > Int($1) ?? 0 }
                versions = Array(versions.prefix(3))

                // Build URLs - Fedora has complex versioning (41-1.4, etc.)
                var discovered: [DiscoveredVersion] = []
                for version in versions {
                    // Use a common subrelease pattern
                    let filename = "Fedora-Server-dvd-aarch64-\(version)-1.4.iso"
                    let downloadURL = "\(baseURL)\(version)/Server/aarch64/iso/\(filename)"
                    let checksumURL = "\(baseURL)\(version)/Server/aarch64/iso/Fedora-Server-\(version)-1.4-aarch64-CHECKSUM"

                    discovered.append(DiscoveredVersion(
                        version: version,
                        displayName: "Fedora Server \(version)",
                        downloadURL: downloadURL,
                        checksumURL: checksumURL,
                        releaseDate: nil,
                        fileSize: nil
                    ))
                }

                if discovered.isEmpty {
                    completion(.noVersionsFound(reason: "No Fedora versions found"))
                } else {
                    self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                    completion(.success(discovered))
                }

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    // MARK: - Arch Version Discovery

    private func fetchArchVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Parse date-based directories (e.g., "2024.12.01/")
                let versionPattern = #"href="(\d{4}\.\d{2}\.\d{2})/""#
                guard let regex = try? NSRegularExpression(pattern: versionPattern) else {
                    completion(.parseError("Invalid regex"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var versions: [String] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        versions.append(String(html[range]))
                    }
                }

                versions = versions.sorted { $0 > $1 }
                versions = Array(versions.prefix(5))

                var discovered: [DiscoveredVersion] = []
                for version in versions {
                    let filename = "archlinux-\(version)-x86_64.iso"
                    let downloadURL = "\(baseURL)\(version)/\(filename)"
                    let checksumURL = "\(baseURL)\(version)/sha256sums.txt"

                    discovered.append(DiscoveredVersion(
                        version: version,
                        displayName: "Arch Linux \(version)",
                        downloadURL: downloadURL,
                        checksumURL: checksumURL,
                        releaseDate: nil,
                        fileSize: nil
                    ))
                }

                if discovered.isEmpty {
                    completion(.noVersionsFound(reason: "No Arch versions found"))
                } else {
                    self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                    completion(.success(discovered))
                }

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    // MARK: - Manjaro Version Discovery

    private func fetchManjaroVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Parse version directories (e.g., "24.2.0/")
                let versionPattern = #"href="(\d+\.\d+\.\d+)/""#
                guard let regex = try? NSRegularExpression(pattern: versionPattern) else {
                    completion(.parseError("Invalid regex"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var versions: [String] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        versions.append(String(html[range]))
                    }
                }

                versions = versions.sorted { v1, v2 in
                    v1.compare(v2, options: .numeric) == .orderedDescending
                }
                versions = Array(versions.prefix(3))

                // Manjaro filenames include date, need to fetch actual directory
                self?.fetchManjaroISOsForVersions(distroID: distroID, baseURL: baseURL, versions: versions, completion: completion)

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    private func fetchManjaroISOsForVersions(
        distroID: String,
        baseURL: String,
        versions: [String],
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        var discovered: [DiscoveredVersion] = []
        let group = DispatchGroup()

        for version in versions {
            group.enter()

            let versionURL = "\(baseURL)\(version)/"
            guard let url = URL(string: versionURL) else {
                group.leave()
                continue
            }

            fetchDirectoryListing(url: url) { result in
                defer { group.leave() }

                switch result {
                case .success(let html):
                    // Find the ISO file
                    let isoPattern = #"href="(manjaro-gnome-[^"]+\.iso)""#
                    guard let regex = try? NSRegularExpression(pattern: isoPattern) else { return }

                    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

                    if let match = matches.first,
                       let range = Range(match.range(at: 1), in: html) {
                        let filename = String(html[range])

                        discovered.append(DiscoveredVersion(
                            version: version,
                            displayName: "Manjaro \(version)",
                            downloadURL: "\(versionURL)\(filename)",
                            checksumURL: "\(versionURL)\(filename).sha256",
                            releaseDate: nil,
                            fileSize: nil
                        ))
                    }

                case .failure:
                    break
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if discovered.isEmpty {
                completion(.noVersionsFound(reason: "No Manjaro ISOs found"))
            } else {
                self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                completion(.success(discovered))
            }
        }
    }

    // MARK: - Generic Version Discovery

    private func fetchGenericVersions(
        distroID: String,
        baseURL: String,
        pattern: String,
        arch: String,
        completion: @escaping (VersionDiscoveryResult) -> Void
    ) {
        guard let url = URL(string: baseURL) else {
            completion(.parseError("Invalid base URL"))
            return
        }

        fetchDirectoryListing(url: url) { [weak self] result in
            switch result {
            case .success(let html):
                // Generic ISO pattern matching
                let isoPattern = pattern
                    .replacingOccurrences(of: "*", with: "[^\"]+")
                    .replacingOccurrences(of: ".", with: "\\.")
                let fullPattern = #"href="(\#(isoPattern))""#

                guard let regex = try? NSRegularExpression(pattern: fullPattern) else {
                    completion(.parseError("Invalid pattern"))
                    return
                }

                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var discovered: [DiscoveredVersion] = []

                for match in matches {
                    if let range = Range(match.range(at: 1), in: html) {
                        let filename = String(html[range])
                        let version = self?.extractVersionFromFilename(filename, pattern: #"[\d.]+"#) ?? "latest"

                        discovered.append(DiscoveredVersion(
                            version: version,
                            displayName: "\(distroID) \(version)",
                            downloadURL: "\(baseURL)\(filename)",
                            checksumURL: nil,
                            releaseDate: nil,
                            fileSize: nil
                        ))
                    }
                }

                if discovered.isEmpty {
                    completion(.noVersionsFound(reason: "No ISOs found matching pattern"))
                } else {
                    self?.versionCache[distroID] = (versions: discovered, fetchedAt: Date())
                    completion(.success(discovered))
                }

            case .failure(let error):
                completion(.networkError(error))
            }
        }
    }

    // MARK: - Helpers

    private func fetchDirectoryListing(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data,
                      let html = String(data: data, encoding: .utf8) else {
                    completion(.failure(NSError(domain: "VersionFetcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
                    return
                }

                completion(.success(html))
            }
        }.resume()
    }

    private func extractVersionFromFilename(_ filename: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let versionRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }

        return String(filename[versionRange])
    }
}
