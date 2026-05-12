//
//  ISOCacheManagerWindow.swift
//  SecVF
//
//  ISO CACHE MANAGER WINDOW
//  Displays and manages cached ISO/IPSW files for VM installations.
//  Provides checksum verification, update checking, and cache cleanup.
//

import Cocoa
import CryptoKit

/// Represents a cached ISO/IPSW entry with metadata
struct CachedImageEntry {
    let name: String
    let osType: String // "Linux" or "macOS"
    let version: String
    let path: String
    let sizeGB: Double
    let downloadDate: Date?
    let sha256Status: ChecksumStatus
    let lastUsedDate: Date?
    let distro: LinuxDistro? // For Linux ISOs

    enum ChecksumStatus {
        case verified
        case notVerified
        case placeholder
        case verifying
        case failed

        var displayString: String {
            switch self {
            case .verified: return "Verified"
            case .notVerified: return "Not Verified"
            case .placeholder: return "No Checksum"
            case .verifying: return "Verifying..."
            case .failed: return "Failed"
            }
        }

        var color: NSColor {
            switch self {
            case .verified:    return AppColors.statusRunning    // OD green — passed checksum
            case .notVerified: return AppColors.accentYellow     // amber — needs verification
            case .placeholder: return AppColors.statusStopped    // slate — no checksum recorded
            case .verifying:   return AppColors.accentODGlow     // OD highlight — in flight
            case .failed:      return AppColors.accentRed        // red — mismatch
            }
        }
    }
}

@MainActor
class ISOCacheManagerWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - UI Components
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var checkAllButton: NSButton!
    private var clearAllButton: NSButton!
    private var refreshButton: NSButton!
    private var totalSizeLabel: NSTextField!
    private var searchField: NSSearchField!

    // MARK: - Data
    private var cachedImages: [CachedImageEntry] = []
    private var filteredImages: [CachedImageEntry] = []
    private var isVerifying = false

    // MARK: - Initialization

    init() {
        // Create window with cybersecurity dark theme
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ISO Cache Manager"
        window.center()
        window.minSize = NSSize(width: 800, height: 400)

        super.init(window: window)

        applyDarkTheme()
        setupUI()
        loadCachedImages()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Theme

    private func applyDarkTheme() {
        guard let window = window, let contentView = window.contentView else { return }

        // Set window appearance to dark
        window.appearance = NSAppearance(named: .darkAqua)

        // Tactical dark background
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = AppColors.backgroundPrimary.cgColor
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        let bounds = contentView.bounds

        // Header section with title and search
        let headerView = createHeaderView(width: bounds.width)
        headerView.frame.origin.y = bounds.height - 80
        headerView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(headerView)

        // Toolbar with action buttons
        let toolbarView = createToolbar(width: bounds.width)
        toolbarView.frame.origin.y = bounds.height - 130
        toolbarView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(toolbarView)

        // Table view
        setupTableView(contentView: contentView, topOffset: 130)

        // Footer with statistics
        let footerView = createFooter(width: bounds.width)
        footerView.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(footerView)
    }

    private func createHeaderView(width: CGFloat) -> NSView {
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        headerView.wantsLayer = true

        // Title with icon
        let titleLabel = NSTextField(labelWithString: "ISO/IPSW Cache")
        titleLabel.frame = NSRect(x: 20, y: 40, width: 300, height: 30)
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .heavy)
        titleLabel.textColor = AppColors.accentODGlow
        headerView.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Manage downloaded VM installation images")
        subtitleLabel.frame = NSRect(x: 20, y: 20, width: 400, height: 18)
        subtitleLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeSubtitle, weight: .regular)
        subtitleLabel.textColor = AppColors.textOD
        headerView.addSubview(subtitleLabel)

        // Search field
        searchField = NSSearchField(frame: NSRect(x: width - 270, y: 30, width: 250, height: 28))
        searchField.placeholderString = "Filter by name..."
        searchField.autoresizingMask = [.minXMargin]
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        headerView.addSubview(searchField)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 20, y: 0, width: width - 40, height: 1))
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = AppColors.borderOD
        separator.autoresizingMask = [.width]
        headerView.addSubview(separator)

        return headerView
    }

    private func createToolbar(width: CGFloat) -> NSView {
        let toolbarView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        toolbarView.wantsLayer = true

        var xOffset: CGFloat = LayoutConstants.spacingLG

        // Refresh button
        refreshButton = createStyledButton(title: "Refresh", x: xOffset, action: #selector(refreshCache))
        refreshButton.toolTip = "Re-scan the on-disk cache and refresh the list"
        toolbarView.addSubview(refreshButton)
        xOffset += 110

        // "Check All Updates" is constructed for callsite compatibility but
        // kept hidden — the underlying upstream-version check isn't implemented
        // yet. Surface it once `checkAllForUpdates()` does real work.
        checkAllButton = createStyledButton(title: "Check All Updates", x: xOffset, action: #selector(checkAllForUpdates))
        checkAllButton.isHidden = true
        toolbarView.addSubview(checkAllButton)

        // Clear All button — destructive, tinted red
        clearAllButton = createStyledButton(title: "Clear All", x: xOffset, action: #selector(clearAllCache))
        clearAllButton.bezelColor = AppColors.accentRed
        clearAllButton.toolTip = "Delete every cached ISO from disk (cannot be undone)"
        toolbarView.addSubview(clearAllButton)

        // Separator line
        let separator = NSBox(frame: NSRect(x: 20, y: 0, width: width - 40, height: 1))
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = AppColors.borderOD
        separator.autoresizingMask = [.width]
        toolbarView.addSubview(separator)

        return toolbarView
    }

    private func createStyledButton(title: String, x: CGFloat, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: x, y: 12, width: 140, height: 28))
        button.title = title
        button.bezelStyle = .rounded
        button.isBordered = true
        button.target = self
        button.action = action
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return button
    }

    private func setupTableView(contentView: NSView, topOffset: CGFloat) {
        let bounds = contentView.bounds

        // Create scroll view
        scrollView = NSScrollView(frame: NSRect(x: 20, y: 50, width: bounds.width - 40, height: bounds.height - topOffset - 60))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = AppColors.backgroundSecondary

        // Create table view
        tableView = NSTableView(frame: scrollView.bounds)
        tableView.style = .plain
        tableView.backgroundColor = AppColors.backgroundSecondary
        tableView.gridColor = AppColors.borderOD
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.rowSizeStyle = .medium
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        // Define columns
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 200
        nameColumn.minWidth = 150
        tableView.addTableColumn(nameColumn)

        let osColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("os"))
        osColumn.title = "OS"
        osColumn.width = 80
        osColumn.minWidth = 60
        tableView.addTableColumn(osColumn)

        let versionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        versionColumn.title = "Version"
        versionColumn.width = 100
        versionColumn.minWidth = 80
        tableView.addTableColumn(versionColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 60
        tableView.addTableColumn(sizeColumn)

        let downloadDateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("downloadDate"))
        downloadDateColumn.title = "Downloaded"
        downloadDateColumn.width = 140
        downloadDateColumn.minWidth = 100
        tableView.addTableColumn(downloadDateColumn)

        let checksumColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("checksum"))
        checksumColumn.title = "Checksum"
        checksumColumn.width = 100
        checksumColumn.minWidth = 80
        tableView.addTableColumn(checksumColumn)

        let actionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("actions"))
        actionsColumn.title = "Actions"
        actionsColumn.width = 220
        actionsColumn.minWidth = 200
        tableView.addTableColumn(actionsColumn)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func createFooter(width: CGFloat) -> NSView {
        let footerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        footerView.wantsLayer = true

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = footerView.bounds
        gradientLayer.colors = [
            AppColors.gradientTop.withAlphaComponent(0.95).cgColor,
            AppColors.gradientBottom.withAlphaComponent(0.95).cgColor
        ]
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        footerView.layer?.addSublayer(gradientLayer)

        // Top border
        let borderView = NSBox(frame: NSRect(x: 0, y: 49, width: width, height: 1))
        borderView.boxType = .custom
        borderView.borderWidth = 0
        borderView.fillColor = AppColors.borderODEmphasis
        borderView.autoresizingMask = [.width]
        footerView.addSubview(borderView)

        // Total cache size label
        totalSizeLabel = NSTextField(labelWithString: "Total Cache Size: Calculating...")
        totalSizeLabel.frame = NSRect(x: 20, y: 15, width: 400, height: 20)
        totalSizeLabel.font = NSFont.monospacedSystemFont(ofSize: LayoutConstants.fontSizeSubtitle, weight: .semibold)
        totalSizeLabel.textColor = AppColors.statusRunning
        totalSizeLabel.isEditable = false
        totalSizeLabel.isBordered = false
        totalSizeLabel.drawsBackground = false
        footerView.addSubview(totalSizeLabel)

        // Cache location label
        let cacheLocationLabel = NSTextField(labelWithString: "Cache Location: ~/.avf/VMImages/")
        cacheLocationLabel.frame = NSRect(x: width - 320, y: 15, width: 300, height: 20)
        cacheLocationLabel.alignment = .right
        cacheLocationLabel.font = NSFont.systemFont(ofSize: LayoutConstants.fontSizeBody, weight: .regular)
        cacheLocationLabel.textColor = AppColors.textOD
        cacheLocationLabel.isEditable = false
        cacheLocationLabel.isBordered = false
        cacheLocationLabel.drawsBackground = false
        cacheLocationLabel.autoresizingMask = [.minXMargin]
        footerView.addSubview(cacheLocationLabel)

        return footerView
    }

    // MARK: - Data Loading

    private func loadCachedImages() {
        cachedImages.removeAll()

        let cacheManager = ISOCacheManager.shared
        let images = cacheManager.listCachedImages()

        // Process each cached image
        for (name, sizeGB, path) in images {
            let entry = parseCachedImageEntry(name: name, sizeGB: sizeGB, path: path)
            cachedImages.append(entry)
        }

        // Sort by download date (most recent first)
        cachedImages.sort { entry1, entry2 in
            guard let date1 = entry1.downloadDate, let date2 = entry2.downloadDate else {
                return entry1.downloadDate != nil
            }
            return date1 > date2
        }

        filteredImages = cachedImages
        tableView.reloadData()
        updateTotalSizeLabel()
    }

    private func parseCachedImageEntry(name: String, sizeGB: Double, path: String) -> CachedImageEntry {
        var osType = "Unknown"
        var version = "Unknown"
        var distro: LinuxDistro? = nil
        var checksumStatus: CachedImageEntry.ChecksumStatus = .notVerified

        // Determine OS type from path
        if path.contains("/MacOS/") || path.contains("/macOS/") {
            osType = "macOS"
            // Parse version from directory name (e.g., "UniversalMac_15.6.1_2025-11-14")
            if let versionMatch = name.range(of: "\\d+\\.\\d+(\\.\\d+)?", options: .regularExpression) {
                version = String(name[versionMatch])
            }
        } else if path.contains("/Linux/") {
            osType = "Linux"
            // Parse distro and version from directory name (e.g., "Kali-2025.3")
            let components = name.split(separator: "-")
            if components.count >= 2 {
                let distroName = String(components[0])
                version = components.dropFirst().joined(separator: "-")

                // Map to LinuxDistro enum
                distro = LinuxDistro.allCases.first { $0.rawValue == distroName }

                // Check if checksum is available
                if let distro = distro {
                    if distro.sha256Checksum.hasPrefix("PLACEHOLDER") {
                        checksumStatus = .placeholder
                    } else {
                        checksumStatus = .notVerified
                    }
                }
            }
        }

        // Get download date from directory modification date
        var downloadDate: Date?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modDate = attrs[.modificationDate] as? Date {
            downloadDate = modDate
        }

        // Get last used date (if available) - could be tracked via metadata in future
        let lastUsedDate: Date? = nil

        return CachedImageEntry(
            name: name,
            osType: osType,
            version: version,
            path: path,
            sizeGB: sizeGB,
            downloadDate: downloadDate,
            sha256Status: checksumStatus,
            lastUsedDate: lastUsedDate,
            distro: distro
        )
    }

    private func updateTotalSizeLabel() {
        let totalSize = cachedImages.reduce(0.0) { $0 + $1.sizeGB }
        let count = cachedImages.count
        totalSizeLabel.stringValue = String(format: "Total Cache Size: %.2f GB (%d image%@)", totalSize, count, count == 1 ? "" : "s")
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredImages.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredImages.count else { return nil }

        let entry = filteredImages[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = identifier

            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

            cellView?.addSubview(textField)
            cellView?.textField = textField

            // Add constraints
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
            ])
        }

        switch identifier.rawValue {
        case "name":
            cellView?.textField?.stringValue = entry.name
            cellView?.textField?.textColor = AppColors.accentODGlow
            cellView?.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        case "os":
            cellView?.textField?.stringValue = entry.osType
            cellView?.textField?.textColor = .labelColor

        case "version":
            cellView?.textField?.stringValue = entry.version
            cellView?.textField?.textColor = .labelColor

        case "size":
            cellView?.textField?.stringValue = String(format: "%.2f GB", entry.sizeGB)
            cellView?.textField?.textColor = .labelColor

        case "downloadDate":
            if let date = entry.downloadDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                cellView?.textField?.stringValue = formatter.string(from: date)
            } else {
                cellView?.textField?.stringValue = "Unknown"
            }
            cellView?.textField?.textColor = .secondaryLabelColor

        case "checksum":
            cellView?.textField?.stringValue = entry.sha256Status.displayString
            cellView?.textField?.textColor = entry.sha256Status.color
            cellView?.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        case "actions":
            // Create custom view with action buttons
            cellView?.textField?.removeFromSuperview()

            // Remove existing buttons if any
            cellView?.subviews.forEach { $0.removeFromSuperview() }

            // Two-button layout (Verify / Delete). "Check Update" was hidden
            // until the upstream-version check is implemented — surfacing a
            // permanently-disabled button is confusing UX.
            let buttonContainer = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: 28))

            // Verify button
            let verifyButton = NSButton(frame: NSRect(x: 0, y: 4, width: 70, height: 20))
            verifyButton.title = "Verify"
            verifyButton.bezelStyle = .roundRect
            verifyButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            verifyButton.controlSize = .small
            verifyButton.target = self
            verifyButton.action = #selector(verifyChecksum(_:))
            verifyButton.tag = row
            verifyButton.isEnabled = entry.sha256Status != .placeholder
            verifyButton.toolTip = verifyButton.isEnabled
                ? "Re-hash the cached ISO and compare against the recorded SHA-256"
                : "No SHA-256 recorded for this image yet"
            buttonContainer.addSubview(verifyButton)

            // Delete button
            let deleteButton = NSButton(frame: NSRect(x: 80, y: 4, width: 70, height: 20))
            deleteButton.title = "Delete"
            deleteButton.bezelStyle = .roundRect
            deleteButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            deleteButton.controlSize = .small
            deleteButton.target = self
            deleteButton.action = #selector(deleteImage(_:))
            deleteButton.tag = row
            deleteButton.toolTip = "Remove this ISO from the on-disk cache"
            buttonContainer.addSubview(deleteButton)

            cellView?.addSubview(buttonContainer)

        default:
            break
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 32
    }

    // MARK: - Actions

    @objc private func refreshCache() {
        loadCachedImages()

        let alert = NSAlert()
        alert.messageText = "Cache Refreshed"
        alert.informativeText = "ISO cache has been refreshed successfully."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func checkAllForUpdates() {
        // Upstream-version checks are not implemented yet. The toolbar entry
        // is hidden in setupToolbar() so this stub should never fire in the
        // shipping build — kept here only as the IBAction target for any
        // dormant references.
        let alert = NSAlert()
        alert.messageText = "Update Check Not Available"
        alert.informativeText = "Automatic upstream-version checking isn't implemented yet. Re-run the distro picker to download the latest version manually."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func clearAllCache() {
        guard !cachedImages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Cache is Empty"
            alert.informativeText = "There are no cached images to delete."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let totalSize = cachedImages.reduce(0.0) { $0 + $1.sizeGB }

        let alert = NSAlert()
        alert.messageText = "Clear All Cached Images?"
        alert.informativeText = String(format: "This will delete all %d cached ISO/IPSW files (%.2f GB total).\n\nYou will need to re-download images when creating new VMs.\n\nThis action cannot be undone.", cachedImages.count, totalSize)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            var deletedCount = 0
            var failedCount = 0

            for entry in cachedImages {
                do {
                    try ISOCacheManager.shared.deleteCachedImage(at: entry.path)
                    deletedCount += 1
                } catch {
                    print("Failed to delete \(entry.name): \(error)")
                    failedCount += 1
                }
            }

            loadCachedImages()

            let resultAlert = NSAlert()
            resultAlert.messageText = "Cache Cleared"
            if failedCount == 0 {
                resultAlert.informativeText = "Successfully deleted \(deletedCount) cached image(s)."
                resultAlert.alertStyle = .informational
            } else {
                resultAlert.informativeText = "Deleted \(deletedCount) image(s), but \(failedCount) failed to delete."
                resultAlert.alertStyle = .warning
            }
            resultAlert.addButton(withTitle: "OK")
            resultAlert.runModal()
        }
    }

    @objc private func verifyChecksum(_ sender: NSButton) {
        let row = sender.tag
        guard row < filteredImages.count else { return }

        let entry = filteredImages[row]

        guard let distro = entry.distro else {
            let alert = NSAlert()
            alert.messageText = "Cannot Verify Checksum"
            alert.informativeText = "Checksum verification is only available for Linux distributions with known checksums."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard !distro.sha256Checksum.hasPrefix("PLACEHOLDER") else {
            let alert = NSAlert()
            alert.messageText = "No Checksum Available"
            alert.informativeText = "This distribution does not have a checksum configured yet."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Create progress alert
        let progressAlert = NSAlert()
        progressAlert.messageText = "Verifying Checksum"
        progressAlert.informativeText = "Computing SHA256 hash for \(entry.name)...\n\nThis may take a few minutes for large ISOs."
        progressAlert.alertStyle = .informational

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        progressAlert.accessoryView = progressIndicator

        // Show alert in background
        DispatchQueue.main.async {
            progressAlert.addButton(withTitle: "Cancel")
            progressAlert.runModal()
        }

        // Verify in background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Find the ISO file in the directory
            guard let isoURL = self.findISOInDirectory(path: entry.path) else {
                DispatchQueue.main.async {
                    NSApp.abortModal()
                    let alert = NSAlert()
                    alert.messageText = "ISO File Not Found"
                    alert.informativeText = "Could not find ISO file in cache directory."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }

            // Perform verification
            let isValid = ISOCacheManager.shared.verifySHA256(file: isoURL, expectedHash: distro.sha256Checksum)

            DispatchQueue.main.async {
                NSApp.abortModal()

                let resultAlert = NSAlert()
                if isValid {
                    resultAlert.messageText = "Checksum Verified"
                    resultAlert.informativeText = "The SHA256 checksum matches the expected value.\n\nThis ISO has not been tampered with."
                    resultAlert.alertStyle = .informational
                    resultAlert.addButton(withTitle: "OK")

                    // Update entry status
                    if let index = self.cachedImages.firstIndex(where: { $0.path == entry.path }) {
                        var updatedEntry = self.cachedImages[index]
                        updatedEntry = CachedImageEntry(
                            name: updatedEntry.name,
                            osType: updatedEntry.osType,
                            version: updatedEntry.version,
                            path: updatedEntry.path,
                            sizeGB: updatedEntry.sizeGB,
                            downloadDate: updatedEntry.downloadDate,
                            sha256Status: .verified,
                            lastUsedDate: updatedEntry.lastUsedDate,
                            distro: updatedEntry.distro
                        )
                        self.cachedImages[index] = updatedEntry
                        self.filteredImages = self.cachedImages
                        self.tableView.reloadData()
                    }
                } else {
                    resultAlert.messageText = "Checksum Verification Failed"
                    resultAlert.informativeText = "The SHA256 checksum does NOT match the expected value.\n\nThis ISO may be corrupted or tampered with.\n\nRecommendation: Delete and re-download this image."
                    resultAlert.alertStyle = .critical
                    resultAlert.addButton(withTitle: "OK")

                    // Update entry status
                    if let index = self.cachedImages.firstIndex(where: { $0.path == entry.path }) {
                        var updatedEntry = self.cachedImages[index]
                        updatedEntry = CachedImageEntry(
                            name: updatedEntry.name,
                            osType: updatedEntry.osType,
                            version: updatedEntry.version,
                            path: updatedEntry.path,
                            sizeGB: updatedEntry.sizeGB,
                            downloadDate: updatedEntry.downloadDate,
                            sha256Status: .failed,
                            lastUsedDate: updatedEntry.lastUsedDate,
                            distro: updatedEntry.distro
                        )
                        self.cachedImages[index] = updatedEntry
                        self.filteredImages = self.cachedImages
                        self.tableView.reloadData()
                    }
                }
                resultAlert.runModal()
            }
        }
    }

    @objc private func checkForUpdate(_ sender: NSButton) {
        // Placeholder for future update checking feature
        let alert = NSAlert()
        alert.messageText = "Check for Update"
        alert.informativeText = "This feature will check if a newer version of this distribution is available.\n\nNote: This feature is currently under development."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func deleteImage(_ sender: NSButton) {
        let row = sender.tag
        guard row < filteredImages.count else { return }

        let entry = filteredImages[row]

        let alert = NSAlert()
        alert.messageText = "Delete Cached Image?"
        alert.informativeText = String(format: "Are you sure you want to delete '%@' (%.2f GB)?\n\nYou will need to re-download this image if you create a new VM with this distribution.\n\nThis action cannot be undone.", entry.name, entry.sizeGB)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try ISOCacheManager.shared.deleteCachedImage(at: entry.path)

                // Remove from arrays
                cachedImages.removeAll { $0.path == entry.path }
                filteredImages.removeAll { $0.path == entry.path }

                tableView.reloadData()
                updateTotalSizeLabel()

                let successAlert = NSAlert()
                successAlert.messageText = "Image Deleted"
                successAlert.informativeText = "Successfully deleted \(entry.name)."
                successAlert.alertStyle = .informational
                successAlert.addButton(withTitle: "OK")
                successAlert.runModal()
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Delete Failed"
                errorAlert.informativeText = "Failed to delete image: \(error.localizedDescription)"
                errorAlert.alertStyle = .critical
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
            }
        }
    }

    @objc private func searchFieldChanged() {
        let searchText = searchField.stringValue.lowercased()

        if searchText.isEmpty {
            filteredImages = cachedImages
        } else {
            filteredImages = cachedImages.filter { entry in
                entry.name.lowercased().contains(searchText) ||
                entry.osType.lowercased().contains(searchText) ||
                entry.version.lowercased().contains(searchText)
            }
        }

        tableView.reloadData()
    }

    // MARK: - Helper Methods

    private func findISOInDirectory(path: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return nil
        }

        let validExtensions = [".iso", ".ipsw"]
        for file in contents {
            for ext in validExtensions where file.hasSuffix(ext) {
                let filePath = path + "/" + file
                return URL(fileURLWithPath: filePath)
            }
        }

        return nil
    }
}

// MARK: - LinuxDistro Extension

extension LinuxDistro: CaseIterable {
    static var allCases: [LinuxDistro] {
        return [.ubuntu, .ubuntuServer, .debian, .fedora, .kali, .parrot, .arch, .manjaro]
    }
}
