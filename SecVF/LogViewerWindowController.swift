//
//  LogViewerWindowController.swift
//  SecVF
//
//  LOG VIEWER WINDOW
//  Displays real-time security and network logs from ~/.avf/logs/
//  for monitoring VM activity during malware analysis sessions.
//

import Cocoa

enum LogType: String {
    case security = "security"
    case network = "network"
    case isoCache = "iso-cache-audit"

    var displayName: String {
        switch self {
        case .security: return "Security Logs"
        case .network: return "Network Logs"
        case .isoCache: return "ISO Cache Audit"
        }
    }
}

@MainActor
class LogViewerWindowController: NSWindowController {

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var logType: LogType
    private var refreshTimer: Timer?
    private var lastFileSize: UInt64 = 0
    private var autoScrollCheckbox: NSButton!

    init(logType: LogType) {
        self.logType = logType

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = logType.displayName
        window.center()

        super.init(window: window)

        setupUI()
        loadLogContent()
        startAutoRefresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Directly invalidate timer in deinit (nonisolated context)
        refreshTimer?.invalidate()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Toolbar with controls
        let toolbar = NSView(frame: NSRect(x: 0, y: window.contentView!.bounds.height - 40, width: window.contentView!.bounds.width, height: 40))
        toolbar.autoresizingMask = [.width, .minYMargin]

        // Refresh button
        let refreshButton = NSButton(frame: NSRect(x: 10, y: 8, width: 80, height: 24))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshLogs)
        toolbar.addSubview(refreshButton)

        // Clear button
        let clearButton = NSButton(frame: NSRect(x: 100, y: 8, width: 80, height: 24))
        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearLogs)
        toolbar.addSubview(clearButton)

        // Auto-scroll checkbox
        autoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: nil)
        autoScrollCheckbox.frame = NSRect(x: 190, y: 10, width: 100, height: 20)
        autoScrollCheckbox.state = .on
        toolbar.addSubview(autoScrollCheckbox)

        // Status label
        let statusLabel = NSTextField(labelWithString: "Auto-refresh: Every 2 seconds")
        statusLabel.frame = NSRect(x: 300, y: 12, width: 250, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        toolbar.addSubview(statusLabel)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 0, y: 0, width: toolbar.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        toolbar.addSubview(separator)

        contentView.addSubview(toolbar)

        // Text view with scroll view
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: window.contentView!.bounds.width, height: window.contentView!.bounds.height - 40))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder

        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        window.contentView = contentView
    }

    // MARK: - Log Loading

    private func loadLogContent() {
        let logPath = getLogPath()

        guard FileManager.default.fileExists(atPath: logPath) else {
            textView.string = "No logs available yet.\n\nLog file will be created at:\n\(logPath)\n\nLogs are generated when:\n- VMs are started/stopped (Security Logs)\n- Network packets are transmitted (Network Logs)"
            return
        }

        do {
            // Get file attributes to check if file has changed
            let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
            let fileSize = attributes[.size] as? UInt64 ?? 0

            // Only reload if file size changed
            if fileSize != lastFileSize {
                let content = try String(contentsOfFile: logPath, encoding: .utf8)

                // Apply syntax highlighting based on log type
                let attributedString = highlightLogContent(content)
                textView.textStorage?.setAttributedString(attributedString)

                lastFileSize = fileSize

                // Auto-scroll to bottom if enabled
                if autoScrollCheckbox.state == .on {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        } catch {
            textView.string = "Error loading log file:\n\(error.localizedDescription)\n\nPath: \(logPath)"
        }
    }

    private func highlightLogContent(_ content: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: content)
        let fullRange = NSRange(location: 0, length: content.count)

        // Base font
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: fullRange)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // Highlight severity levels
        let lines = content.components(separatedBy: .newlines)
        var currentPosition = 0

        for line in lines {
            let lineLength = line.count
            let lineRange = NSRange(location: currentPosition, length: lineLength)

            // Color by severity
            if line.contains("[INFO]") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: lineRange)
            } else if line.contains("[WARNING]") || line.contains("[DEFAULT]") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: lineRange)
            } else if line.contains("[ERROR]") || line.contains("[CRITICAL]") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: lineRange)
                attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: lineRange)
            } else if line.contains("[FAULT]") || line.contains("[EMERGENCY]") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemPink, range: lineRange)
                attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: lineRange)
            } else if line.contains("SECURITY") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: lineRange)
                attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), range: lineRange)
            }

            // ISO Cache specific highlighting
            if logType == .isoCache {
                if line.contains("SECURITY ALERT") {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: lineRange)
                    attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: lineRange)
                } else if line.contains("Download requested") || line.contains("Download") {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemCyan, range: lineRange)
                } else if line.contains("Creating security router") {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: lineRange)
                } else if line.contains("Kali") || line.contains("Ubuntu") || line.contains("Debian") {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: lineRange)
                }
            }

            // Highlight timestamps
            if let timestampRange = line.range(of: "\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\]", options: .regularExpression) {
                let nsRange = NSRange(timestampRange, in: line)
                let adjustedRange = NSRange(location: currentPosition + nsRange.location, length: nsRange.length)
                attributed.addAttribute(.foregroundColor, value: NSColor.systemGray, range: adjustedRange)
            }

            currentPosition += lineLength + 1 // +1 for newline
        }

        return attributed
    }

    private func getLogPath() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())

        // SECURITY: Use URL-based path construction to prevent path injection
        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".avf")
            .appendingPathComponent("logs")
        let logFile = "\(logType.rawValue)-\(dateStr).log"
        return logDir.appendingPathComponent(logFile).path
    }

    // MARK: - Auto-Refresh

    private func startAutoRefresh() {
        // Refresh every 2 seconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer callback is nonisolated, dispatch to main actor
            // Bind weak self to let to avoid 'reference to captured var' in @Sendable Task closure
            guard let self else { return }
            Task { @MainActor in
                self.loadLogContent()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Actions

    @objc private func refreshLogs() {
        lastFileSize = 0 // Force reload
        loadLogContent()
    }

    @objc private func clearLogs() {
        textView.string = ""

        let alert = NSAlert()
        alert.messageText = "Clear Log File?"
        alert.informativeText = "This will permanently delete the current log file:\n\(getLogPath())\n\nThis action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try "".write(toFile: getLogPath(), atomically: true, encoding: .utf8)
                textView.string = "Log file cleared.\n"
                lastFileSize = 0
            } catch {
                textView.string = "Error clearing log file:\n\(error.localizedDescription)"
            }
        }
    }
}
