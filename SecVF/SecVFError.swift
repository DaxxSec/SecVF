//
//  SecVFError.swift
//  SecVF
//
//  Typed error definitions for graceful error handling
//  Replaces fatalError() calls with recoverable errors
//

import Foundation

/// Errors that can occur during VM operations
enum SecVFError: LocalizedError {
    // MARK: - VM Configuration Errors
    case vmConfigNotFound(vmId: UUID)
    case vmConfigInvalid(reason: String)

    // MARK: - Disk Errors
    case diskAttachmentFailed(path: String, underlying: Error?)
    case diskImageNotFound(path: String)
    case installerISONotFound(vmId: UUID)
    case installerAttachmentFailed(path: String)
    case invalidDiskConfiguration

    // MARK: - Auxiliary Storage Errors
    case auxiliaryStorageLocked(path: String)

    // MARK: - Machine Identifier Errors
    case machineIdentifierNotFound(path: String)
    case machineIdentifierDataInvalid
    case machineIdentifierCreationFailed

    // MARK: - NVRAM/EFI Errors
    case nvramNotFound(path: String)
    case nvramCreationFailed(path: String)

    // MARK: - macOS-Specific Errors
    case macOSVersionTooOld(required: String, current: String)
    case appleSiliconRequired
    case hardwareModelNotFound
    case hardwareModelDataInvalid
    case hardwareModelCreationFailed
    case auxiliaryStorageFailed(path: String)
    case restoreImageNotProvided
    case restoreImageHardwareModelFailed

    // MARK: - VM Lifecycle Errors
    case configurationValidationFailed(underlying: Error)
    case vmStartFailed(underlying: Error)
    case vmAlreadyRunning(vmId: UUID)
    case vmNotRunning(vmId: UUID)

    // MARK: - Network Errors
    case networkConfigurationFailed(reason: String)
    case virtualSwitchConnectionFailed

    // MARK: - ISO Verification Errors
    case checksumUnavailable(distro: String, reason: String)

    // MARK: - Graphics Errors
    case graphicsConfigurationFailed

    // MARK: - Scripts USB Errors
    case scriptsSourceNotFound
    case scriptsPathSanitizationFailed(path: String)
    case scriptsPathOutsideAllowed(path: String)
    case scriptsDiskCreationFailed(reason: String)
    case scriptsISOCreationFailed(reason: String)
    case scriptsCopyFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        // VM Configuration
        case .vmConfigNotFound(let vmId):
            return "VM configuration not found for ID: \(vmId.uuidString)"
        case .vmConfigInvalid(let reason):
            return "VM configuration is invalid: \(reason)"

        // Disk
        case .diskAttachmentFailed(let path, let error):
            let underlying = error?.localizedDescription ?? "unknown error"
            return "Failed to create disk attachment at \(path): \(underlying)"
        case .diskImageNotFound(let path):
            return "Disk image not found at: \(path)"
        case .installerISONotFound(let vmId):
            return "Installer ISO not found for VM: \(vmId.uuidString)"
        case .installerAttachmentFailed(let path):
            return "Failed to create installer disk attachment at: \(path)"
        case .invalidDiskConfiguration:
            return "Invalid disk configuration provided"

        // Machine Identifier
        case .machineIdentifierNotFound(let path):
            return "Machine identifier file not found at: \(path)"
        case .machineIdentifierDataInvalid:
            return "Machine identifier data is invalid or corrupted"
        case .machineIdentifierCreationFailed:
            return "Failed to create machine identifier from data"

        // NVRAM/EFI
        case .nvramNotFound(let path):
            return "NVRAM/EFI variable store not found at: \(path)"
        case .nvramCreationFailed(let path):
            return "Failed to create NVRAM at: \(path)"

        // macOS-Specific
        case .macOSVersionTooOld(let required, let current):
            return "macOS \(required) or later required (current: \(current))"
        case .appleSiliconRequired:
            return "macOS guest VMs are only supported on Apple Silicon"
        case .hardwareModelNotFound:
            return "Hardware model file not found"
        case .hardwareModelDataInvalid:
            return "Hardware model data is invalid or corrupted"
        case .hardwareModelCreationFailed:
            return "Failed to create hardware model from data"
        case .auxiliaryStorageFailed(let path):
            return "Failed to create auxiliary storage at: \(path)"
        case .auxiliaryStorageLocked(let path):
            return "Auxiliary storage at \(path) is locked by another process — refusing to corrupt a running VM's state"
        case .restoreImageNotProvided:
            return "No restore image (IPSW) path provided for macOS installation"
        case .restoreImageHardwareModelFailed:
            return "Failed to extract hardware model from restore image"

        // VM Lifecycle
        case .configurationValidationFailed(let error):
            return "VM configuration validation failed: \(error.localizedDescription)"
        case .vmStartFailed(let error):
            return "Failed to start virtual machine: \(error.localizedDescription)"
        case .vmAlreadyRunning(let vmId):
            return "VM is already running: \(vmId.uuidString)"
        case .vmNotRunning(let vmId):
            return "VM is not running: \(vmId.uuidString)"

        // Network
        case .networkConfigurationFailed(let reason):
            return "Network configuration failed: \(reason)"
        case .virtualSwitchConnectionFailed:
            return "Failed to connect to virtual network switch"

        // ISO Verification
        case .checksumUnavailable(let distro, let reason):
            return "SECURITY: SHA256 checksum unavailable for \(distro) — refusing to use unverified ISO (\(reason))"

        // Graphics
        case .graphicsConfigurationFailed:
            return "Failed to configure graphics device"

        // Scripts USB
        case .scriptsSourceNotFound:
            return "Could not find scripts source directory"
        case .scriptsPathSanitizationFailed(let path):
            return "Scripts path failed security validation: \(path)"
        case .scriptsPathOutsideAllowed(let path):
            return "Scripts path outside allowed directories: \(path)"
        case .scriptsDiskCreationFailed(let reason):
            return "Failed to create scripts disk image: \(reason)"
        case .scriptsISOCreationFailed(let reason):
            return "Failed to create scripts ISO: \(reason)"
        case .scriptsCopyFailed(let error):
            return "Failed to copy scripts: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .vmConfigNotFound:
            return "The VM may have been deleted. Try refreshing the VM list."
        case .diskImageNotFound, .diskAttachmentFailed:
            return "Check that the VM's disk image exists and is not corrupted."
        case .installerISONotFound:
            return "Download the installer ISO again using the ISO Cache Manager."
        case .macOSVersionTooOld:
            return "Update your Mac to the latest version of macOS."
        case .appleSiliconRequired:
            return "macOS VMs can only run on Macs with Apple Silicon (M1/M2/M3)."
        case .configurationValidationFailed:
            return "Check the VM configuration for invalid settings."
        case .vmStartFailed:
            return "Try stopping any other running VMs and restart this one."
        case .scriptsSourceNotFound:
            return "Ensure the scripts folder is included in the app bundle or accessible from the development path."
        case .scriptsPathSanitizationFailed, .scriptsPathOutsideAllowed:
            return "Only use scripts from trusted locations within your home directory or app bundle."
        case .scriptsDiskCreationFailed, .scriptsISOCreationFailed:
            return "Check that you have write permissions to ~/.avf and sufficient disk space."
        case .auxiliaryStorageLocked(let path):
            return """
                Another VZ instance is holding an exclusive flock on this file. Quit SecVF.app, then in Terminal:
                    lsof "\(path)"          # find the PID holding the lock
                    sudo kill -9 <PID>      # or: sudo pkill -9 -f SecVF
                Then relaunch SecVF and try again. If the file is from a partial install, you can also `rm` it.
                """
        case .checksumUnavailable:
            return "Wait for the official mirror's checksum file to come back online, or pick a distro version whose checksum can be fetched. Do not boot an unverified ISO."
        default:
            return nil
        }
    }
}

// MARK: - Error Logging Extension

extension SecVFError {
    /// Log error to security audit log
    func logToAudit() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // Tokenize the home prefix so logs shared with vendors / IR partners
        // don't leak the operator's identity via `/Users/<name>/...` paths.
        let safeDesc = self.localizedDescription
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let logEntry = "[\(timestamp)] ERROR: \(safeDesc)\n"

        let logsDir = NSHomeDirectory() + "/.avf/logs/"
        let logPath = logsDir + "error-audit.log"

        // Ensure directory exists with restrictive perms
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
                // Explicit 0o600 on first create — without it, default umask
                // on a multi-user Mac leaves the audit log world-readable,
                // exposing error history to other local accounts.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logPath
                )
            }
        }

        // Also log to system console
        NSLog("[SecVF ERROR] %@", safeDesc)
    }
}
