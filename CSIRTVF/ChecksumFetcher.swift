//
//  ChecksumFetcher.swift
//  SecVF
//
//  SECURITY: Dynamically fetches SHA256 checksums from official Linux distro CDNs.
//  This ensures ISO integrity verification uses current checksums rather than
//  potentially stale hardcoded values.
//
//  Supported checksum file formats:
//  - sha256sums: Standard "<hash>  <filename>" format (Ubuntu, Debian, Kali)
//  - fedora: Fedora's "SHA256 (<filename>) = <hash>" format
//

import Foundation

/// Format of the checksum file served by the distro
enum ChecksumFileFormat: String, Codable {
    /// Standard format: "<sha256hash>  <filename>" or "<sha256hash> *<filename>"
    case sha256sums

    /// Fedora format: "SHA256 (<filename>) = <sha256hash>"
    case fedora

    /// Single hash file (just the hash, no filename)
    case singleHash
}

/// Result of a checksum fetch operation
enum ChecksumFetchResult {
    case success(checksum: String, fetchedAt: Date)
    case notFound(reason: String)
    case networkError(Error)
    case securityError(String)
}

/// Caches fetched checksums to avoid repeated network requests
struct CachedChecksum: Codable {
    let distroID: String
    let checksum: String
    let fetchedAt: Date
    let sourceURL: String

    /// Checksums are valid for 24 hours
    var isExpired: Bool {
        return Date().timeIntervalSince(fetchedAt) > 24 * 60 * 60
    }
}

/// Fetches SHA256 checksums from official Linux distribution download servers
class ChecksumFetcher {
    static let shared = ChecksumFetcher()

    /// Cache file location
    private let cacheFilePath: String

    /// In-memory cache
    private var checksumCache: [String: CachedChecksum] = [:]

    /// Approved domains for checksum fetching (same as ISO downloads)
    private var approvedDomains: Set<String> {
        return DistroConfigurationManager.shared.approvedDomains
    }

    private init() {
        cacheFilePath = NSHomeDirectory() + "/.avf/checksums-cache.json"
        loadCache()
    }

    // MARK: - Public API

    /// Fetch checksum for a distribution, using cache if available and not expired
    /// - Parameters:
    ///   - distroID: The distribution identifier (e.g., "Ubuntu Desktop")
    ///   - checksumURL: URL to the checksum file
    ///   - format: Format of the checksum file
    ///   - isoFilename: Filename to look for in the checksum file
    ///   - completion: Called with the fetch result
    func fetchChecksum(
        distroID: String,
        checksumURL: String,
        format: ChecksumFileFormat,
        isoFilename: String,
        completion: @escaping (ChecksumFetchResult) -> Void
    ) {
        // Check cache first
        if let cached = checksumCache[distroID], !cached.isExpired {
            NSLog("[ChecksumFetcher] Using cached checksum for \(distroID)")
            completion(.success(checksum: cached.checksum, fetchedAt: cached.fetchedAt))
            return
        }

        // Validate URL
        guard let url = URL(string: checksumURL) else {
            completion(.securityError("Invalid checksum URL: \(checksumURL)"))
            return
        }

        // SECURITY: Verify URL is from approved domain
        guard let host = url.host?.lowercased(), approvedDomains.contains(host) else {
            completion(.securityError("Checksum URL not from approved domain: \(url.host ?? "unknown")"))
            return
        }

        // SECURITY: Require HTTPS
        guard url.scheme == "https" else {
            completion(.securityError("Checksum URL must use HTTPS"))
            return
        }

        NSLog("[ChecksumFetcher] Fetching checksum from: \(checksumURL)")

        // Fetch checksum file
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.tlsMinimumSupportedProtocolVersion = .TLSv12

        let session = URLSession(configuration: config)
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                NSLog("[ChecksumFetcher] Network error: \(error.localizedDescription)")
                completion(.networkError(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(.notFound(reason: "HTTP \(statusCode)"))
                return
            }

            guard let data = data,
                  let content = String(data: data, encoding: .utf8) else {
                completion(.notFound(reason: "Could not decode response"))
                return
            }

            // Parse checksum from content
            if let checksum = self?.parseChecksum(from: content, format: format, filename: isoFilename) {
                // Cache the result
                let cached = CachedChecksum(
                    distroID: distroID,
                    checksum: checksum,
                    fetchedAt: Date(),
                    sourceURL: checksumURL
                )
                self?.checksumCache[distroID] = cached
                self?.saveCache()

                NSLog("[ChecksumFetcher] Successfully fetched checksum for \(distroID): \(checksum.prefix(16))...")
                completion(.success(checksum: checksum, fetchedAt: Date()))
            } else {
                completion(.notFound(reason: "Could not find checksum for \(isoFilename) in checksum file"))
            }
        }
        task.resume()
    }

    /// Synchronously get cached checksum if available and not expired
    func getCachedChecksum(for distroID: String) -> String? {
        if let cached = checksumCache[distroID], !cached.isExpired {
            return cached.checksum
        }
        return nil
    }

    /// Clear all cached checksums
    func clearCache() {
        checksumCache.removeAll()
        try? FileManager.default.removeItem(atPath: cacheFilePath)
        NSLog("[ChecksumFetcher] Cache cleared")
    }

    // MARK: - Checksum Parsing

    /// Parse checksum from file content based on format
    private func parseChecksum(from content: String, format: ChecksumFileFormat, filename: String) -> String? {
        let lines = content.components(separatedBy: .newlines)

        switch format {
        case .sha256sums:
            // Format: "<hash>  <filename>" or "<hash> *<filename>"
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines and comments
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                // Split by whitespace (hash is first, filename may have * prefix)
                let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }

                let hash = String(parts[0])
                var file = String(parts[1]).trimmingCharacters(in: .whitespaces)

                // Remove * prefix if present (binary mode indicator)
                if file.hasPrefix("*") {
                    file = String(file.dropFirst())
                }

                // Check if this is the file we're looking for
                if file == filename || file.hasSuffix("/" + filename) {
                    // Validate hash format (64 hex characters for SHA256)
                    if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
                        return hash.lowercased()
                    }
                }
            }

        case .fedora:
            // Format: "SHA256 (<filename>) = <hash>"
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("SHA256") else { continue }

                // Extract filename and hash using regex-like parsing
                // SHA256 (Fedora-Server-dvd-aarch64-39-1.5.iso) = abc123...
                if let openParen = trimmed.firstIndex(of: "("),
                   let closeParen = trimmed.firstIndex(of: ")"),
                   let equals = trimmed.firstIndex(of: "=") {
                    let fileStart = trimmed.index(after: openParen)
                    let file = String(trimmed[fileStart..<closeParen])
                    let hashStart = trimmed.index(after: equals)
                    let hash = String(trimmed[hashStart...]).trimmingCharacters(in: .whitespaces)

                    if file == filename || file.hasSuffix("/" + filename) {
                        if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
                            return hash.lowercased()
                        }
                    }
                }
            }

        case .singleHash:
            // Just a single hash in the file
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) {
                return trimmed.lowercased()
            }
        }

        return nil
    }

    // MARK: - Cache Persistence

    private func loadCache() {
        guard FileManager.default.fileExists(atPath: cacheFilePath) else { return }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: cacheFilePath))
            let cached = try JSONDecoder().decode([String: CachedChecksum].self, from: data)

            // Only load non-expired entries
            checksumCache = cached.filter { !$0.value.isExpired }
            NSLog("[ChecksumFetcher] Loaded \(checksumCache.count) cached checksums")
        } catch {
            NSLog("[ChecksumFetcher] Error loading cache: \(error)")
        }
    }

    private func saveCache() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(checksumCache)

            // Ensure directory exists
            let dir = (cacheFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            try data.write(to: URL(fileURLWithPath: cacheFilePath))
        } catch {
            NSLog("[ChecksumFetcher] Error saving cache: \(error)")
        }
    }
}
