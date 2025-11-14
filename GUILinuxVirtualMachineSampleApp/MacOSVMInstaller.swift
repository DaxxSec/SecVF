//
//  MacOSVMInstaller.swift
//  GUILinuxVirtualMachineSampleApp
//

import Foundation
import Virtualization

class MacOSVMInstaller: NSObject {

    private var restoreImageURL: URL?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?
    private var vmBundlePath: String

    var progressHandler: ((Double, String) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?

    init(vmBundlePath: String) {
        self.vmBundlePath = vmBundlePath
        super.init()
    }

    func downloadLatestMacOSImage() {
        // Store IPSW in the VM bundle directory
        let ipswDir = vmBundlePath

        // Create VM bundle directory if needed
        try? FileManager.default.createDirectory(atPath: ipswDir, withIntermediateDirectories: true)

        // Check if we have a cached IPSW in this VM's directory
        if let cachedIPSW = findCachedIPSW(in: ipswDir) {
            print("Found cached IPSW in VM bundle: \(cachedIPSW.path)")
            progressHandler?(1.0, "Using cached macOS restore image")
            completionHandler?(.success(cachedIPSW))
            return
        }

        // No cached IPSW found, fetch latest
        progressHandler?(0, "Fetching latest macOS restore image information...")

        VZMacOSRestoreImage.fetchLatestSupported { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let restoreImage):
                print("Found macOS restore image: \(restoreImage.operatingSystemVersion)")
                self.downloadRestoreImage(from: restoreImage.url)

            case .failure(let error):
                print("Failed to fetch restore image: \(error)")
                self.completionHandler?(.failure(error))
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
        // Set destination path to VM bundle directory
        let fileName = url.lastPathComponent
        let destinationURL = URL(fileURLWithPath: vmBundlePath + fileName)

        print("Starting download from: \(url)")
        print("Destination: \(destinationURL.path)")

        progressHandler?(0, "Downloading macOS restore image (this may take a while)...")

        // Create download task
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)

        // Observe progress on main thread
        downloadObservation = downloadTask?.progress.observe(\.fractionCompleted, options: [.new, .initial]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                let percentComplete = progress.fractionCompleted * 100
                let bytesDownloaded = Double(progress.completedUnitCount) / (1024 * 1024 * 1024)
                let totalBytes = Double(progress.totalUnitCount) / (1024 * 1024 * 1024)

                print("Download progress: \(percentComplete)% - \(bytesDownloaded) GB / \(totalBytes) GB")

                let message = String(format: "Downloading: %.1f%% (%.2f GB / %.2f GB)",
                                   percentComplete, bytesDownloaded, totalBytes)
                self?.progressHandler?(progress.fractionCompleted, message)
            }
        }

        downloadTask?.resume()
        print("Download task started")

        // Store destination for later
        restoreImageURL = destinationURL
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadObservation?.invalidate()
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
        let mbWritten = Double(totalBytesWritten) / (1024 * 1024)
        let mbTotal = Double(totalBytesExpectedToWrite) / (1024 * 1024)
        print("Download progress via delegate: \(progress * 100)% - \(mbWritten) MB / \(mbTotal) MB")
    }
}
