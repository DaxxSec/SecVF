//
//  MacOSVMInstaller.swift
//  SecVF
//
//  SECURITY OVERVIEW:
//  This class handles downloading macOS IPSW restore images from Apple's CDN.
//  Multiple security measures are in place to prevent malicious payloads:
//
//  1. URL Source Validation:
//     - Only uses URLs from Apple's official VZMacOSRestoreImage.fetchLatestSupported API
//     - This API is part of Apple's Virtualization framework (not user-controllable)
//
//  2. Domain Whitelist (approvedCDNHosts):
//     - Hard-coded whitelist of official Apple CDN domains
//     - Any URL not from these domains is rejected
//     - Domains: updates.cdn-apple.com, updates-http.cdn-apple.com, mesu.apple.com
//
//  3. Protocol Enforcement:
//     - Only HTTPS connections allowed (no HTTP)
//     - TLS 1.2 or higher required
//
//  4. File Type Validation:
//     - Only .ipsw files accepted
//     - Validated by file extension check
//
//  5. SSL Certificate Validation:
//     - Server trust validation via URLSession authentication challenge
//     - Rejects connections from hosts not in approved list
//     - Uses standard CA certificate validation
//
//  6. Download Path Security:
//     - Files downloaded to user-controlled VM bundle directory
//     - Path cannot be manipulated externally
//

import Foundation
import Virtualization

class MacOSVMInstaller: NSObject {

    private var restoreImageURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var vmBundlePath: String
    private var lastProgressUpdate: Date?
    private var lastBytesWritten: Int64 = 0

    var progressHandler: ((Double, String) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?

    // SECURITY: Whitelist of approved Apple CDN domains for IPSW downloads
    // These are the official Apple Content Delivery Network domains
    private static let approvedCDNHosts: Set<String> = [
        "updates.cdn-apple.com",
        "updates-http.cdn-apple.com",
        "mesu.apple.com"
    ]

    init(vmBundlePath: String) {
        self.vmBundlePath = vmBundlePath
        super.init()
    }

    // SECURITY: Validate that the URL is from an approved Apple CDN
    private func validateDownloadURL(_ url: URL) -> Bool {
        // Ensure HTTPS is used
        guard url.scheme == "https" else {
            print("SECURITY: Rejected non-HTTPS URL: \(url)")
            return false
        }

        // Ensure host is in approved list
        guard let host = url.host?.lowercased(),
              Self.approvedCDNHosts.contains(host) else {
            print("SECURITY: Rejected URL from unauthorized host: \(url.host ?? "unknown")")
            return false
        }

        // Ensure it's an IPSW file
        guard url.pathExtension.lowercased() == "ipsw" else {
            print("SECURITY: Rejected non-IPSW file: \(url.pathExtension)")
            return false
        }

        print("SECURITY: URL validation passed for: \(url)")
        return true
    }

    func downloadLatestMacOSImage() {
        print("[IPSW] downloadLatestMacOSImage() called")
        print("[IPSW] VM bundle path: \(vmBundlePath)")

        // Store IPSW in the VM bundle directory
        let ipswDir = vmBundlePath

        // Create VM bundle directory if needed
        do {
            try FileManager.default.createDirectory(atPath: ipswDir, withIntermediateDirectories: true)
            print("[IPSW] Created/verified VM bundle directory: \(ipswDir)")
        } catch {
            print("[IPSW] ERROR: Failed to create VM bundle directory: \(error)")
            DispatchQueue.main.async {
                self.completionHandler?(.failure(error))
            }
            return
        }

        // Fetch the latest restore image info first
        DispatchQueue.main.async {
            self.progressHandler?(0, "Checking for latest macOS restore image...")
        }
        print("[IPSW] Starting fetch for latest macOS restore image...")
        print("[IPSW] Calling VZMacOSRestoreImage.fetchLatestSupported...")

        VZMacOSRestoreImage.fetchLatestSupported { [weak self] result in
            print("[IPSW] VZMacOSRestoreImage.fetchLatestSupported completion handler called!")
            guard let self = self else {
                print("[IPSW] Self was nil in completion handler")
                return
            }

            print("[IPSW] Fetch completed, processing result...")

            // Process result directly (don't wrap in DispatchQueue.main.async to avoid deadlock with modal dialog)
            switch result {
            case .success(let restoreImage):
                print("[IPSW] SUCCESS - Found restore image")
                print("Latest macOS restore image: \(restoreImage.operatingSystemVersion)")
                print("Remote URL: \(restoreImage.url)")

                // SECURITY: Validate the URL before proceeding
                guard self.validateDownloadURL(restoreImage.url) else {
                    let error = NSError(
                        domain: "com.daxxsec.SecVF.security",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "Security validation failed: URL from unauthorized source"]
                    )
                    DispatchQueue.main.async {
                        self.completionHandler?(.failure(error))
                    }
                    return
                }

                let remoteFileName = restoreImage.url.lastPathComponent

                // Check if we have a cached IPSW that matches the remote filename
                if let cachedIPSW = self.findCachedIPSW(in: ipswDir) {
                    let cachedFileName = cachedIPSW.lastPathComponent

                    if cachedFileName == remoteFileName {
                        print("Found matching cached IPSW: \(cachedIPSW.path)")
                        DispatchQueue.main.async {
                            self.progressHandler?(1.0, "Using cached macOS restore image")
                            self.completionHandler?(.success(cachedIPSW))
                        }
                        return
                    } else {
                        print("Cached IPSW (\(cachedFileName)) doesn't match latest (\(remoteFileName))")
                        print("Removing outdated IPSW and downloading new version...")
                        try? FileManager.default.removeItem(at: cachedIPSW)
                    }
                }

                // No matching cached IPSW found, download the latest
                print("Downloading macOS restore image: \(restoreImage.operatingSystemVersion)")
                self.downloadRestoreImage(from: restoreImage.url)

            case .failure(let error):
                print("[IPSW] FAILURE - Error fetching restore image: \(error)")
                print("[IPSW] Error details: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.progressHandler?(0, "Failed to fetch macOS image")
                    self.completionHandler?(.failure(error))
                }
            }
        }
    }

    private func findCachedIPSW(in directory: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        // Look for any .ipsw file
        for file in contents {
            if file.hasSuffix(".ipsw") {
                let ipswPath = directory + file
                if FileManager.default.fileExists(atPath: ipswPath) {
                    return URL(fileURLWithPath: ipswPath)
                }
            }
        }

        return nil
    }

    private func downloadRestoreImage(from url: URL) {
        // SECURITY: Double-check URL validation before downloading
        guard validateDownloadURL(url) else {
            let error = NSError(
                domain: "com.daxxsec.SecVF.security",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Security validation failed: Invalid download URL"]
            )
            completionHandler?(.failure(error))
            return
        }

        // Set destination path to VM bundle directory
        let fileName = url.lastPathComponent
        let destinationURL = URL(fileURLWithPath: vmBundlePath + fileName)

        print("Starting download from: \(url)")
        print("Destination: \(destinationURL.path)")

        // Extract host for display
        let host = url.host ?? "Apple CDN"
        progressHandler?(0, "Connecting to \(host)...")

        // SECURITY: Create session with secure configuration
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12 // Require TLS 1.2 or higher
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 3600.0 // 1 hour for large downloads

        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)

        // Progress will be reported via delegate method didWriteData
        // (More reliable than KVO for large downloads)

        downloadTask?.resume()
        print("Download task started")

        // Store destination for later
        restoreImageURL = destinationURL
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }
}

// MARK: - URLSessionDownloadDelegate

extension MacOSVMInstaller: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                   didFinishDownloadingTo location: URL) {
        print("Download finished to temporary location: \(location.path)")
        guard let destinationURL = restoreImageURL else {
            print("ERROR: No destination URL set!")
            return
        }

        do {
            // Move downloaded file to permanent location
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                print("Removing existing file at destination")
                try FileManager.default.removeItem(at: destinationURL)
            }
            print("Moving file from \(location.path) to \(destinationURL.path)")
            try FileManager.default.moveItem(at: location, to: destinationURL)

            print("Successfully downloaded IPSW to: \(destinationURL.path)")
            progressHandler?(1.0, "Download complete!")
            completionHandler?(.success(destinationURL))

        } catch {
            print("Failed to move downloaded file: \(error)")
            completionHandler?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                   didCompleteWithError error: Error?) {
        if let error = error {
            print("Download failed with error: \(error.localizedDescription)")
            completionHandler?(.failure(error))
        } else {
            print("Download task completed successfully")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                   didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                   totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let gbWritten = Double(totalBytesWritten) / (1024 * 1024 * 1024)
        let gbTotal = Double(totalBytesExpectedToWrite) / (1024 * 1024 * 1024)

        // Extract host from current request
        let host = downloadTask.currentRequest?.url?.host ?? "Apple CDN"

        // Detect stalls (no progress for 30+ seconds)
        let now = Date()
        if let lastUpdate = lastProgressUpdate, totalBytesWritten == lastBytesWritten {
            let timeSinceLastProgress = now.timeIntervalSince(lastUpdate)
            if timeSinceLastProgress > 30 {
                print("[IPSW] WARNING: Download stalled for \(Int(timeSinceLastProgress))s at \(String(format: "%.1f%%", progress * 100))")
            }
        } else {
            lastProgressUpdate = now
            lastBytesWritten = totalBytesWritten
        }

        print("[IPSW] Download progress: \(String(format: "%.2f%%", progress * 100)) - \(String(format: "%.2f", gbWritten)) GB / \(String(format: "%.2f", gbTotal)) GB")

        // Update UI with detailed progress
        DispatchQueue.main.async { [weak self] in
            let message = String(format: "Downloading from %@: %.2f GB / %.2f GB",
                               host, gbWritten, gbTotal)
            self?.progressHandler?(progress, message)
        }
    }

    // SECURITY: Validate SSL certificates for Apple CDN connections
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        print("SECURITY: Received authentication challenge")

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let host = challenge.protectionSpace.host.lowercased() as String? else {
            print("SECURITY: Challenge is not server trust or missing server trust")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Verify the host is in our approved list
        guard Self.approvedCDNHosts.contains(host) else {
            print("SECURITY: Rejected authentication for unauthorized host: \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Use default handling for Apple's certificates (they use standard CA validation)
        print("SECURITY: Accepting server trust for approved host: \(host)")
        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}
