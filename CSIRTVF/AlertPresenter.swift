//
//  AlertPresenter.swift
//  SecVF
//
//  Centralized error presentation utility
//  Provides consistent error dialogs throughout the app
//

import Cocoa

/// Centralized utility for presenting alerts and error dialogs
struct AlertPresenter {

    // MARK: - Error Presentation

    /// Show an error alert to the user
    /// - Parameters:
    ///   - error: The error to display
    ///   - title: Optional custom title (defaults to "Error")
    static func showError(_ error: Error, title: String = "Error") {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")

            // Add recovery suggestion if available
            if let secvfError = error as? SecVFError,
               let suggestion = secvfError.recoverySuggestion {
                alert.informativeText += "\n\n\(suggestion)"
            }

            alert.runModal()
        }
    }

    /// Show a VM-specific error alert
    /// - Parameters:
    ///   - error: The SecVF error
    ///   - vmName: Name of the VM that encountered the error
    static func showVMError(_ error: SecVFError, vmName: String) {
        error.logToAudit()
        showError(error, title: "VM Error: \(vmName)")
    }

    /// Show a VM error with option to view logs
    /// - Parameters:
    ///   - error: The SecVF error
    ///   - vmName: Name of the VM
    ///   - showLogOption: Whether to show "View Log" button
    static func showVMErrorWithLogOption(_ error: SecVFError, vmName: String, showLogOption: Bool = true) {
        error.logToAudit()

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "VM Error: \(vmName)"
            alert.informativeText = error.localizedDescription

            if let suggestion = error.recoverySuggestion {
                alert.informativeText += "\n\n\(suggestion)"
            }

            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")

            if showLogOption {
                alert.addButton(withTitle: "View Log")
            }

            let response = alert.runModal()

            if showLogOption && response == .alertSecondButtonReturn {
                // Open log directory in Finder
                let logsPath = NSHomeDirectory() + "/.avf/logs/"
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath)
            }
        }
    }

    // MARK: - Confirmation Dialogs

    /// Show a confirmation dialog
    /// - Parameters:
    ///   - title: Dialog title
    ///   - message: Dialog message
    ///   - confirmAction: Text for confirm button (default: "OK")
    ///   - style: Alert style (default: .warning)
    /// - Returns: True if user confirmed, false otherwise
    static func showConfirmation(
        title: String,
        message: String,
        confirmAction: String = "OK",
        style: NSAlert.Style = .warning
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: confirmAction)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Show a destructive confirmation dialog (red button)
    /// - Parameters:
    ///   - title: Dialog title
    ///   - message: Dialog message
    ///   - destructiveAction: Text for destructive button
    /// - Returns: True if user confirmed destructive action
    static func showDestructiveConfirmation(
        title: String,
        message: String,
        destructiveAction: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: destructiveAction)
        alert.addButton(withTitle: "Cancel")

        // Make the first button have destructive appearance
        if let button = alert.buttons.first {
            button.hasDestructiveAction = true
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Info/Warning Alerts

    /// Show an informational alert
    static func showInfo(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Show a warning alert
    static func showWarning(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Security Alerts

    /// Show a security warning with audit logging
    static func showSecurityWarning(title: String, message: String) {
        // Log to security audit
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] SECURITY WARNING: \(title) - \(message)\n"

        let logsDir = NSHomeDirectory() + "/.avf/logs/"
        let logPath = logsDir + "security-alerts.log"

        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }

        showWarning(title: "Security Warning: \(title)", message: message)
    }
}
