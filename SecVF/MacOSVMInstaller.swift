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
    private var downloadStartTime: Date?
    // Held so we can call finishTasksAndInvalidate(); URLSession strongly retains its
    // delegate, so without invalidation the installer leaks for the life of the process.
    private var session: URLSession?
    // Single-fire guard. didFinishDownloadingTo and didCompleteWithError can both fire
    // on the same task; without this the completion handler ran twice and the caller
    // would race a second VM install / cleanup against the first.
    private var completionFired = false

    var progressHandler: ((Double, String) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?

    private func fireCompletion(_ result: Result<URL, Error>) {
        guard !completionFired else { return }
        completionFired = true
        let handler = completionHandler
        completionHandler = nil
        handler?(result)
    }

    private func invalidateSession() {
        session?.finishTasksAndInvalidate()
        session = nil
    }

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

    // SECURITY: Validate that the URL is from an approved Apple CDN.
    // Internal (not private) so unit tests can exercise it directly.
    func validateDownloadURL(_ url: URL) -> Bool {
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
        NSLog("[IPSW] downloadLatestMacOSImage() called")
        NSLog("[IPSW] VM bundle path: %@", vmBundlePath)

        // Store IPSW centrally in ~/.avf/MacOS/ (shared across all macOS VMs)
        // This avoids storing a 12-15GB IPSW copy in each VM bundle
        let macOSRootDir = NSHomeDirectory() + "/.avf/MacOS/"
        let ipswDir = macOSRootDir

        NSLog("[IPSW] Central IPSW storage directory: %@", ipswDir)

        // Create central IPSW directory if needed
        do {
            try FileManager.default.createDirectory(atPath: ipswDir, withIntermediateDirectories: true)
            NSLog("[IPSW] Created/verified central IPSW directory: %@", ipswDir)
        } catch {
            NSLog("[IPSW] ERROR: Failed to create central IPSW directory: %@", error.localizedDescription)
            completionHandler?(.failure(error))
            return
        }

        // Fetch the latest restore image info first
        progressHandler?(0, "Checking for latest macOS restore image...")
        NSLog("[IPSW] Starting fetch for latest macOS restore image...")
        NSLog("[IPSW] Calling VZMacOSRestoreImage.fetchLatestSupported...")

        VZMacOSRestoreImage.fetchLatestSupported { [weak self] result in
            NSLog("[IPSW] VZMacOSRestoreImage.fetchLatestSupported completion handler called!")
            guard let self = self else {
                NSLog("[IPSW] Self was nil in completion handler")
                return
            }

            NSLog("[IPSW] Fetch completed, processing result...")

            // Process result directly (don't wrap in DispatchQueue.main.async to avoid deadlock with modal dialog)
            switch result {
            case .success(let restoreImage):
                NSLog("[IPSW] SUCCESS - Found restore image")
                let version = restoreImage.operatingSystemVersion
                NSLog("[IPSW] Latest macOS restore image: %d.%d.%d", version.majorVersion, version.minorVersion, version.patchVersion)
                NSLog("[IPSW] Remote URL: %@", restoreImage.url.absoluteString)

                // SECURITY: Validate the URL before proceeding
                NSLog("[IPSW] Validating download URL...")
                guard self.validateDownloadURL(restoreImage.url) else {
                    NSLog("[IPSW] URL validation FAILED!")
                    let error = NSError(
                        domain: "com.DaxxSec.SecVF.security",
                        code: 1001,
                        userInfo: [NSLocalizedDescriptionKey: "Security validation failed: URL from unauthorized source"]
                    )
                    self.completionHandler?(.failure(error))
                    return
                }
                NSLog("[IPSW] URL validation passed")

                let remoteFileName = restoreImage.url.lastPathComponent
                NSLog("[IPSW] Remote filename: %@", remoteFileName)

                // Check if we have a cached IPSW that matches the remote filename
                NSLog("[IPSW] Checking for cached IPSW in: %@", ipswDir)
                if let cachedIPSW = self.findCachedIPSW(in: ipswDir) {
                    let cachedFileName = cachedIPSW.lastPathComponent
                    NSLog("[IPSW] Found cached IPSW: %@", cachedFileName)

                    if cachedFileName == remoteFileName {
                        NSLog("[IPSW] Cached IPSW matches remote filename - using cached version")
                        self.progressHandler?(1.0, "Using cached macOS restore image")
                        self.completionHandler?(.success(cachedIPSW))
                        return
                    } else {
                        NSLog("[IPSW] Cached IPSW (%@) doesn't match latest (%@)", cachedFileName, remoteFileName)
                        NSLog("[IPSW] Removing outdated IPSW...")
                        try? FileManager.default.removeItem(at: cachedIPSW)
                    }
                } else {
                    NSLog("[IPSW] No cached IPSW found")
                }

                // No matching cached IPSW found, download the latest
                NSLog("[IPSW] Starting download of macOS restore image...")
                self.downloadRestoreImage(from: restoreImage.url)

            case .failure(let error):
                print("[IPSW] FAILURE - Error fetching restore image: \(error)")
                print("[IPSW] Error details: \(error.localizedDescription)")
                self.progressHandler?(0, "Failed to fetch macOS image")
                self.completionHandler?(.failure(error))
            }
        }
    }

    private func findCachedIPSW(in directory: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        // Look for any .ipsw file. Skip placeholders / truncated downloads
        // by gating on a minimum size — a partial IPSW left behind by a
        // crashed/canceled download would otherwise be returned here on the
        // next boot and silently fed into VZMacOSRestoreImage. Apple's own
        // signature validation catches this when actually used, but failing
        // earlier with a clearer error is much better UX. Min size mirrors
        // ISOCacheManager.getCachedImage's >1MB placeholder gate; real IPSWs
        // are 12–15 GB.
        let minIPSWSizeBytes: Int64 = 1_000_000  // 1 MB
        for file in contents {
            if file.hasSuffix(".ipsw") {
                let ipswPath = directory + file
                guard FileManager.default.fileExists(atPath: ipswPath) else { continue }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: ipswPath),
                   let size = attrs[.size] as? Int64,
                   size >= minIPSWSizeBytes {
                    return URL(fileURLWithPath: ipswPath)
                } else {
                    NSLog("[IPSW] Ignoring truncated/placeholder cached IPSW: %@", ipswPath)
                    // Don't auto-delete — let the user decide via Tools menu.
                }
            }
        }

        return nil
    }

    private func downloadRestoreImage(from url: URL) {
        NSLog("[IPSW] downloadRestoreImage() called")

        // SECURITY: Double-check URL validation before downloading
        NSLog("[IPSW] Re-validating URL before download...")
        guard validateDownloadURL(url) else {
            NSLog("[IPSW] URL RE-validation FAILED!")
            let error = NSError(
                domain: "com.DaxxSec.SecVF.security",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Security validation failed: Invalid download URL"]
            )
            completionHandler?(.failure(error))
            return
        }
        NSLog("[IPSW] URL re-validation passed")

        // Set destination path to central macOS directory (shared across all VMs)
        let fileName = url.lastPathComponent
        let macOSRootDir = NSHomeDirectory() + "/.avf/MacOS/"
        let destinationURL = URL(fileURLWithPath: macOSRootDir + fileName)

        NSLog("[IPSW] Starting download from: %@", url.absoluteString)
        NSLog("[IPSW] Destination: %@", destinationURL.path)

        // Extract host for display
        let host = url.host ?? "Apple CDN"
        NSLog("[IPSW] Calling progressHandler with 'Connecting to %@...'", host)
        progressHandler?(0, "Connecting to \(host)...")

        // SECURITY: Create session with secure configuration optimized for large downloads
        NSLog("[IPSW] Creating URLSession with TLS 1.2+ requirement...")
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12 // Require TLS 1.2 or higher
        config.timeoutIntervalForRequest = 120.0 // 2 min per-request timeout (CDN can be slow to respond)
        config.timeoutIntervalForResource = 14400.0 // 4 hours — 15GB IPSW at ~1 MB/s needs headroom
        config.waitsForConnectivity = true // Retry automatically on transient network drops
        config.networkServiceType = .responsiveData // Hint to OS: prioritize throughput
        config.httpMaximumConnectionsPerHost = 8 // Allow more concurrent connections to CDN

        // Use background queue for delegate to avoid blocking main thread (which is blocked by modal dialog).
        // Store the session so we can invalidate it on completion — URLSession holds a strong ref to its
        // delegate (us) until finishTasksAndInvalidate() is called.
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        // Reset single-fire guard for this download attempt.
        completionFired = false
        NSLog("[IPSW] Creating download task...")
        downloadTask = session.downloadTask(with: url)

        // Progress will be reported via delegate method didWriteData
        // (More reliable than KVO for large downloads)

        NSLog("[IPSW] Calling downloadTask.resume()...")
        downloadStartTime = Date()
        downloadTask?.resume()
        NSLog("[IPSW] Download task started!")

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
        NSLog("[IPSW] didFinishDownloadingTo called - temp location: %@", location.path)
        guard let destinationURL = restoreImageURL else {
            NSLog("[IPSW] ERROR: No destination URL set!")
            return
        }

        do {
            // Move downloaded file to permanent location
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                NSLog("[IPSW] Removing existing file at destination")
                try FileManager.default.removeItem(at: destinationURL)
            }
            NSLog("[IPSW] Moving file from %@ to %@", location.path, destinationURL.path)
            try FileManager.default.moveItem(at: location, to: destinationURL)

            NSLog("[IPSW] Successfully downloaded IPSW to: %@", destinationURL.path)
            progressHandler?(1.0, "Download complete!")
            fireCompletion(.success(destinationURL))

        } catch {
            NSLog("[IPSW] Failed to move downloaded file: %@", error.localizedDescription)
            fireCompletion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                   didCompleteWithError error: Error?) {
        if let error = error {
            NSLog("[IPSW] Download failed with error: %@", error.localizedDescription)
            fireCompletion(.failure(error))
        } else {
            NSLog("[IPSW] Download task completed successfully")
        }
        // Always invalidate the session at task end. didFinishDownloadingTo fires the
        // completion handler on success and this method always runs after that, so this
        // is the right place to break the URLSession→delegate retain cycle.
        invalidateSession()
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
                NSLog("[IPSW] WARNING: Download stalled for %ds at %.1f%%", Int(timeSinceLastProgress), progress * 100)
            }
        } else {
            lastProgressUpdate = now
            lastBytesWritten = totalBytesWritten
        }

        // Log progress every 5% to avoid flooding logs
        let progressPercent = progress * 100
        if Int(progressPercent) % 5 == 0 || progressPercent < 1.0 {
            NSLog("[IPSW] Download progress: %.1f%% - %.2f GB / %.2f GB", progressPercent, gbWritten, gbTotal)
        }

        // Calculate speed and ETA
        var speedStr = ""
        if let startTime = downloadStartTime {
            let elapsed = now.timeIntervalSince(startTime)
            if elapsed > 2 { // Wait a couple seconds for stable measurement
                let bytesPerSec = Double(totalBytesWritten) / elapsed
                let mbPerSec = bytesPerSec / (1024 * 1024)
                let remainingBytes = Double(totalBytesExpectedToWrite - totalBytesWritten)
                let etaSeconds = Int(remainingBytes / bytesPerSec)
                let etaMin = etaSeconds / 60
                let etaSec = etaSeconds % 60
                speedStr = String(format: " — %.1f MB/s, ~%d:%02d remaining", mbPerSec, etaMin, etaSec)
            }
        }

        // Update UI with detailed progress
        let message = String(format: "Downloading from %@: %.2f GB / %.2f GB%@",
                           host, gbWritten, gbTotal, speedStr)
        progressHandler?(progress, message)
    }

    // SECURITY: Validate SSL certificates for Apple CDN connections
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        print("SECURITY: Received authentication challenge for host: \(challenge.protectionSpace.host)")
        print("SECURITY: Authentication method: \(challenge.protectionSpace.authenticationMethod)")

        // For server trust (SSL) challenges from approved hosts, use default system validation
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let host = challenge.protectionSpace.host.lowercased()

            // Verify the host is in our approved list
            guard Self.approvedCDNHosts.contains(host) else {
                print("SECURITY: Rejected authentication for unauthorized host: \(host)")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // Use default system certificate validation (works with VPNs and corporate proxies)
            print("SECURITY: Using default certificate validation for approved host: \(host)")
            completionHandler(.performDefaultHandling, nil)
        } else {
            // For non-SSL challenges, cancel
            print("SECURITY: Non-SSL challenge, canceling")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
