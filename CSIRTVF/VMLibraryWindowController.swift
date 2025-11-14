//
//  VMLibraryWindowController.swift
//  SecVF
//

import Cocoa
import Virtualization

class VMLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var startButton: NSButton!
    @IBOutlet weak var newButton: NSButton!
    @IBOutlet weak var deleteButton: NSButton!
    @IBOutlet weak var renameButton: NSButton!
    @IBOutlet weak var cloneButton: NSButton!
    @IBOutlet weak var importButton: NSButton!

    private var vmManager = VMManager.shared
    var selectedVM: VMConfiguration?

    override var windowNibName: NSNib.Name? {
        return "VMLibraryWindow"
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        // Set window delegate to handle close button
        window?.delegate = self

        // Apply dark theme and add sidebar
        applyDarkTheme()
        addSidebar()

        // Configure table view
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(startVM(_:))

        // Load VMs asynchronously to avoid blocking main thread
        vmManager.initializeAsync { [weak self] in
            guard let self = self else { return }
            print("DEBUG: VM initialization complete - VM count: \(self.vmManager.virtualMachines.count)")
            self.tableView.reloadData()
        }

        // Force the table to use view-based mode
        tableView.rowSizeStyle = .default

        // Debug: Print all table columns and their identifiers
        print("DEBUG: Table has \(tableView.tableColumns.count) columns:")
        for column in tableView.tableColumns {
            print("  - Column identifier: \(column.identifier.rawValue)")
        }

        // Register for VM status change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVMStatusChanged(_:)),
            name: .vmStatusChanged,
            object: nil
        )

        // Update button states
        updateButtonStates()

        // Reload data
        tableView.reloadData()
    }

    // MARK: - Dark Theme & Sidebar

    private func applyDarkTheme() {
        guard let window = window, let contentView = window.contentView else { return }

        // Set window appearance to dark
        window.appearance = NSAppearance(named: .darkAqua)

        // Dark background for content view
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0).cgColor

        // Style table view with dark theme
        tableView.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0)
        tableView.enclosingScrollView?.backgroundColor = NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0)
        tableView.gridColor = NSColor(white: 0.25, alpha: 1.0)
    }

    private func addSidebar() {
        guard let window = window, let contentView = window.contentView else { return }

        let sidebarWidth: CGFloat = 250

        // Create sidebar view
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: contentView.bounds.height))
        sidebar.autoresizingMask = [.height]
        sidebar.wantsLayer = true

        // Gradient background for sidebar
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = sidebar.bounds
        gradientLayer.colors = [
            NSColor(red: 0.08, green: 0.12, blue: 0.24, alpha: 1.0).cgColor,  // Dark navy
            NSColor(red: 0.12, green: 0.16, blue: 0.32, alpha: 1.0).cgColor   // Lighter navy
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        sidebar.layer?.addSublayer(gradientLayer)

        // Logo
        let logoView = NSImageView(frame: NSRect(x: 40, y: contentView.bounds.height - 180, width: 170, height: 120))
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.image = createStylizedLogo()
        logoView.autoresizingMask = [.minYMargin]
        sidebar.addSubview(logoView)

        // Title
        let titleLabel = NSTextField(labelWithString: "SecVF")
        titleLabel.frame = NSRect(x: 20, y: contentView.bounds.height - 220, width: sidebarWidth - 40, height: 35)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .heavy)
        titleLabel.textColor = NSColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)  // Electric blue
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.autoresizingMask = [.minYMargin]
        sidebar.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "VM Sandbox Environment")
        subtitleLabel.frame = NSRect(x: 20, y: contentView.bounds.height - 245, width: sidebarWidth - 40, height: 20)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = NSColor(red: 0.6, green: 0.7, blue: 0.9, alpha: 1.0)
        subtitleLabel.isBordered = false
        subtitleLabel.isEditable = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.autoresizingMask = [.minYMargin]
        sidebar.addSubview(subtitleLabel)

        // Separator line
        let separator1 = createSeparator(y: contentView.bounds.height - 270, width: sidebarWidth)
        separator1.autoresizingMask = [.minYMargin, .width]
        sidebar.addSubview(separator1)

        // Info section
        let infoY = contentView.bounds.height - 310
        addInfoLabel(to: sidebar, text: "Developed by", y: infoY, bold: false)
        addInfoLabel(to: sidebar, text: "ItzDaxxy", y: infoY - 25, bold: true)
        addInfoLabel(to: sidebar, text: "", y: infoY - 55, bold: false, color: NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1.0))
        addInfoLabel(to: sidebar, text: "itzdaxxy@users.noreply.github.com", y: infoY - 80, bold: false, color: NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1.0))

        // Separator line
        let separator2 = createSeparator(y: 120, width: sidebarWidth)
        separator2.autoresizingMask = [.maxYMargin, .width]
        sidebar.addSubview(separator2)

        // Stats/Info at bottom
        let statsLabel = NSTextField(labelWithString: "🛡️ Malware Analysis\n🔒 Isolated Sandbox\n🌐 Virtual Networking")
        statsLabel.frame = NSRect(x: 20, y: 20, width: sidebarWidth - 40, height: 80)
        statsLabel.alignment = .left
        statsLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        statsLabel.isBordered = false
        statsLabel.isEditable = false
        statsLabel.drawsBackground = false
        statsLabel.autoresizingMask = [.maxYMargin]
        sidebar.addSubview(statsLabel)

        // Add sidebar to window
        contentView.addSubview(sidebar, positioned: .above, relativeTo: nil)

        // Adjust existing content to make room for sidebar
        adjustContentForSidebar(sidebarWidth: sidebarWidth)
    }

    private func createStylizedLogo() -> NSImage {
        let size = CGSize(width: 170, height: 120)
        let image = NSImage(size: size)

        image.lockFocus()

        // Shield outline with glow
        let shieldPath = NSBezierPath()
        shieldPath.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.95))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.15, y: size.height * 0.65),
            controlPoint1: CGPoint(x: size.width * 0.25, y: size.height * 0.88),
            controlPoint2: CGPoint(x: size.width * 0.15, y: size.height * 0.75)
        )
        shieldPath.line(to: CGPoint(x: size.width * 0.15, y: size.height * 0.35))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.5, y: size.height * 0.05),
            controlPoint1: CGPoint(x: size.width * 0.15, y: size.height * 0.2),
            controlPoint2: CGPoint(x: size.width * 0.3, y: size.height * 0.05)
        )
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.85, y: size.height * 0.35),
            controlPoint1: CGPoint(x: size.width * 0.7, y: size.height * 0.05),
            controlPoint2: CGPoint(x: size.width * 0.85, y: size.height * 0.2)
        )
        shieldPath.line(to: CGPoint(x: size.width * 0.85, y: size.height * 0.65))
        shieldPath.curve(
            to: CGPoint(x: size.width * 0.5, y: size.height * 0.95),
            controlPoint1: CGPoint(x: size.width * 0.85, y: size.height * 0.75),
            controlPoint2: CGPoint(x: size.width * 0.75, y: size.height * 0.88)
        )
        shieldPath.close()

        // Gradient fill
        let gradient = NSGradient(colors: [
            NSColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1.0),
            NSColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1.0),
            NSColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1.0)
        ])
        gradient?.draw(in: shieldPath, angle: -45)

        // Eye symbol (security/monitoring)
        let eyeOuter = NSBezierPath(ovalIn: NSRect(
            x: size.width * 0.32,
            y: size.height * 0.38,
            width: size.width * 0.36,
            height: size.height * 0.24
        ))
        NSColor.black.withAlphaComponent(0.4).setFill()
        eyeOuter.fill()

        // Pupil
        let pupil = NSBezierPath(ovalIn: NSRect(
            x: size.width * 0.43,
            y: size.height * 0.43,
            width: size.width * 0.14,
            height: size.height * 0.14
        ))
        NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0).setFill()
        pupil.fill()

        // Highlight
        let highlight = NSBezierPath(ovalIn: NSRect(
            x: size.width * 0.47,
            y: size.height * 0.49,
            width: size.width * 0.06,
            height: size.height * 0.06
        ))
        NSColor.white.setFill()
        highlight.fill()

        image.unlockFocus()
        return image
    }

    private func createSeparator(y: CGFloat, width: CGFloat) -> NSBox {
        let separator = NSBox(frame: NSRect(x: 20, y: y, width: width - 40, height: 1))
        separator.boxType = .separator
        separator.fillColor = NSColor(white: 0.3, alpha: 0.5)
        return separator
    }

    private func addInfoLabel(to view: NSView, text: String, y: CGFloat, bold: Bool, color: NSColor = NSColor(white: 0.8, alpha: 1.0)) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: y, width: 210, height: 20)
        label.alignment = .center
        label.font = bold ? NSFont.systemFont(ofSize: 13, weight: .bold) : NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.isBordered = false
        label.isEditable = false
        label.drawsBackground = false
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
    }

    private func adjustContentForSidebar(sidebarWidth: CGFloat) {
        guard let window = window, let contentView = window.contentView else { return }

        // Adjust all existing content to move right by sidebar width
        for subview in contentView.subviews {
            if subview.frame.minX < sidebarWidth {
                // Skip the sidebar itself
                continue
            }
            var frame = subview.frame
            frame.origin.x += sidebarWidth
            if let scrollView = subview as? NSScrollView {
                frame.size.width -= sidebarWidth
            }
            subview.frame = frame
        }

        // Increase window width to accommodate sidebar
        var windowFrame = window.frame
        windowFrame.size.width += sidebarWidth
        windowFrame.origin.x -= sidebarWidth / 2  // Keep window centered
        window.setFrame(windowFrame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // When user clicks the close button on the library window, quit the app
        NSApplication.shared.terminate(nil)
        return false
    }

    @objc private func handleVMStatusChanged(_ notification: Notification) {
        // Refresh the table to show updated status
        DispatchQueue.main.async {
            print("DEBUG: VM status changed, refreshing table")
            self.tableView.reloadData()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        let count = vmManager.virtualMachines.count
        print("DEBUG: numberOfRows called, returning \(count)")
        return count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        print("DEBUG: viewFor tableColumn called for row \(row), column identifier: \(tableColumn?.identifier.rawValue ?? "nil")")

        guard row < vmManager.virtualMachines.count else {
            print("DEBUG: Row \(row) out of bounds!")
            return nil
        }

        let vm = vmManager.virtualMachines[row]

        // Try to get existing cell, or create new one programmatically
        var cell = tableView.makeView(withIdentifier: tableColumn!.identifier, owner: self) as? NSTableCellView

        if cell == nil {
            print("DEBUG: Creating new cell programmatically for identifier: \(tableColumn?.identifier.rawValue ?? "nil")")
            cell = NSTableCellView()
            cell?.identifier = tableColumn!.identifier

            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell?.addSubview(textField)
            cell?.textField = textField

            // Add constraints
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
        }

        guard let finalCell = cell else {
            print("DEBUG: Failed to create cell")
            return nil
        }

        print("DEBUG: Cell ready for row \(row), column \(tableColumn?.identifier.rawValue ?? "nil")")

        switch tableColumn?.identifier.rawValue {
        case "NameColumn":
            finalCell.textField?.stringValue = vm.name
        case "StatusColumn":
            finalCell.textField?.stringValue = vm.statusDisplayString
        case "OSColumn":
            finalCell.textField?.stringValue = vm.osType
        case "CPUColumn":
            finalCell.textField?.stringValue = "\(vm.cpuCount) cores"
        case "MemoryColumn":
            finalCell.textField?.stringValue = vm.memoryDisplayString
        case "DiskColumn":
            finalCell.textField?.stringValue = vm.diskDisplayString
        case "LastUsedColumn":
            if let lastUsed = vm.lastUsedDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                finalCell.textField?.stringValue = formatter.string(from: lastUsed)
            } else {
                finalCell.textField?.stringValue = "Never"
            }
        default:
            break
        }

        return finalCell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    // MARK: - Actions

    @IBAction func startVM(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to start")
            return
        }

        selectedVM = vmManager.virtualMachines[selectedRow]

        // Update last used date
        vmManager.updateLastUsedDate(selectedVM!)

        // Hide this window (don't close it) and start the VM
        window?.orderOut(nil)

        // Notify app delegate to start VM
        NotificationCenter.default.post(name: .startVM, object: selectedVM)
    }

    @IBAction func newVM(_ sender: Any) {
        showNewVMDialog()
    }

    @IBAction func deleteVM(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to delete")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Delete VM?"
        alert.informativeText = "Are you sure you want to delete '\(vm.name)'? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try vmManager.deleteVM(vm)
                refreshTable()
            } catch {
                showAlert(message: "Failed to delete VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func renameVM(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to rename")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Rename VM"
        alert.informativeText = "Enter a new name for '\(vm.name)':"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = vm.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue
            do {
                try vmManager.renameVM(vm, newName: newName)
                refreshTable()
            } catch {
                showAlert(message: "Failed to rename VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func cloneVM(_ sender: Any) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else {
            showAlert(message: "Please select a VM to clone")
            return
        }

        let vm = vmManager.virtualMachines[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Clone VM"
        alert.informativeText = "Enter a name for the cloned VM:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = vm.name + " Copy"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue
            do {
                _ = try vmManager.cloneVM(vm, newName: newName)
                refreshTable()
            } catch {
                showAlert(message: "Failed to clone VM: \(error.localizedDescription)")
            }
        }
    }

    @IBAction func importVM(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.treatsFilePackagesAsDirectories = true
        openPanel.message = "Select a VM bundle to import"
        openPanel.allowedContentTypes = [.bundle]
        openPanel.allowsOtherFileTypes = true

        if openPanel.runModal() == .OK {
            guard let sourcePath = openPanel.url?.path else { return }

            let alert = NSAlert()
            alert.messageText = "Import VM"
            alert.informativeText = "Enter a name for the imported VM:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            textField.stringValue = "Imported VM"
            alert.accessoryView = textField

            if alert.runModal() == .alertFirstButtonReturn {
                let newName = textField.stringValue
                do {
                    _ = try vmManager.importVM(from: sourcePath, name: newName)
                    refreshTable()
                } catch {
                    showAlert(message: "Failed to import VM: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - macOS VM Download

    private func downloadAndPrepareMacOSVM(_ vmConfig: VMConfiguration) {
        // Create progress alert
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading macOS"
        progressAlert.informativeText = "Initializing..."
        progressAlert.alertStyle = .informational
        progressAlert.addButton(withTitle: "Cancel")

        // Create a container view for progress bar and percentage label
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 45))

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 20, width: 300, height: 20))
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100.0
        containerView.addSubview(progressIndicator)

        // Add percentage label below progress bar
        let percentageLabel = NSTextField(labelWithString: "0%")
        percentageLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        percentageLabel.alignment = .center
        percentageLabel.font = NSFont.systemFont(ofSize: 11)
        percentageLabel.textColor = .secondaryLabelColor
        containerView.addSubview(percentageLabel)

        progressAlert.accessoryView = containerView

        // Show alert in background
        DispatchQueue.main.async {
            let response = progressAlert.runModal()
            if response == .alertFirstButtonReturn {
                // User clicked Cancel
                print("Download cancelled by user")
            }
        }

        // Start download - pass the VM bundle path
        let installer = MacOSVMInstaller(vmBundlePath: vmConfig.bundlePath)

        installer.progressHandler = { [weak self] progress, message in
            DispatchQueue.main.async {
                progressAlert.informativeText = message
                let percentage = progress * 100.0
                progressIndicator.doubleValue = percentage
                percentageLabel.stringValue = String(format: "%.1f%%", percentage)
            }
        }

        installer.completionHandler = { [weak self] result in
            DispatchQueue.main.async {
                // Close progress window
                NSApp.abortModal()

                switch result {
                case .success(let ipswURL):
                    print("IPSW downloaded to: \(ipswURL.path)")
                    // Start VM with IPSW
                    self?.selectedVM = vmConfig
                    self?.vmManager.updateLastUsedDate(vmConfig)
                    self?.window?.orderOut(nil)
                    NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": vmConfig, "iso": ipswURL])

                case .failure(let error):
                    self?.showAlert(message: "Failed to download macOS: \(error.localizedDescription)")
                }
            }
        }

        installer.downloadLatestMacOSImage()
    }

    // MARK: - Helper Methods

    func refreshTableFromOutside() {
        // Public method that can be called from AppDelegate
        refreshTable()
    }

    private func refreshTable() {
        // Reload VMs from disk asynchronously
        vmManager.initializeAsync { [weak self] in
            guard let self = self else { return }
            print("DEBUG: Refreshing table with \(self.vmManager.virtualMachines.count) VMs")
            for (index, vm) in self.vmManager.virtualMachines.enumerated() {
                print("  - [\(index)] \(vm.name)")
            }
            self.tableView.reloadData()
            self.updateButtonStates()
        }
    }

    private func updateButtonStates() {
        let hasSelection = tableView.selectedRow >= 0
        startButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        renameButton.isEnabled = hasSelection
        cloneButton.isEnabled = hasSelection
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showNewVMDialog() {
        let alert = NSAlert()
        alert.messageText = "Create New VM"
        alert.informativeText = "Configure your new virtual machine:"
        alert.alertStyle = .informational

        let createButton = alert.addButton(withTitle: "Select ISO")
        alert.addButton(withTitle: "Cancel")

        // Create form (increased height for network configuration controls)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 290))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 260, width: 100, height: 20)
        view.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 110, y: 258, width: 280, height: 24))
        nameField.stringValue = "New VM"
        view.addSubview(nameField)

        // OS Type dropdown
        let osLabel = NSTextField(labelWithString: "OS Type:")
        osLabel.frame = NSRect(x: 0, y: 230, width: 100, height: 20)
        view.addSubview(osLabel)

        let osPopup = NSPopUpButton(frame: NSRect(x: 110, y: 225, width: 150, height: 26), pullsDown: false)
        osPopup.addItem(withTitle: "Linux")
        osPopup.addItem(withTitle: "macOS")
        osPopup.selectItem(at: 0) // Default to Linux
        view.addSubview(osPopup)

        // Delegate to handle dynamic UI updates
        class VMConfigDelegate: NSObject {
            weak var isoCheckbox: NSButton?
            weak var createButton: NSButton?
            weak var routerCheckbox: NSButton?
            weak var routerLabel: NSTextField?
            weak var routerPopup: NSPopUpButton?
            weak var networkPopup: NSPopUpButton?
            weak var osPopup: NSPopUpButton?
            weak var vmManager: VMManager?

            @objc func osTypeChanged(_ sender: NSPopUpButton) {
                let isMacOS = sender.titleOfSelectedItem == "macOS"
                isoCheckbox?.isHidden = isMacOS
                createButton?.title = isMacOS ? "Create" : "Select ISO"

                // Update network UI based on OS type
                updateNetworkUI()
            }

            @objc func networkModeChanged(_ sender: NSPopUpButton) {
                updateNetworkUI()
            }

            private func updateNetworkUI() {
                guard let osPopup = osPopup else { return }

                let isMacOS = osPopup.titleOfSelectedItem == "macOS"
                let isVirtual = networkPopup?.indexOfSelectedItem == 1

                // Show/hide router options based on OS type and network mode
                if isVirtual {
                    if isMacOS {
                        // macOS in virtual mode: show router selection dropdown
                        routerCheckbox?.isHidden = true
                        routerLabel?.isHidden = false
                        routerPopup?.isHidden = false

                        // Populate router dropdown with Linux VMs
                        populateRouterList()
                    } else {
                        // Linux in virtual mode: show "act as router" checkbox
                        routerCheckbox?.isHidden = false
                        routerLabel?.isHidden = true
                        routerPopup?.isHidden = true
                    }
                } else {
                    // NAT mode: hide all router options
                    routerCheckbox?.isHidden = true
                    routerLabel?.isHidden = true
                    routerPopup?.isHidden = true
                }
            }

            private func populateRouterList() {
                guard let vmManager = vmManager,
                      let routerPopup = routerPopup else { return }

                routerPopup.removeAllItems()

                // Get all Linux VMs that could act as routers
                let linuxVMs = vmManager.virtualMachines.filter { $0.osType.lowercased().contains("linux") }

                if linuxVMs.isEmpty {
                    routerPopup.addItem(withTitle: "No Linux VMs available")
                    routerPopup.isEnabled = false
                } else {
                    routerPopup.isEnabled = true
                    for vm in linuxVMs {
                        routerPopup.addItem(withTitle: vm.name)
                    }
                }
            }
        }
        let configDelegate = VMConfigDelegate()
        configDelegate.vmManager = vmManager

        // CPU count
        let cpuLabel = NSTextField(labelWithString: "CPU Cores:")
        cpuLabel.frame = NSRect(x: 0, y: 200, width: 100, height: 20)
        view.addSubview(cpuLabel)

        let cpuField = NSTextField(frame: NSRect(x: 110, y: 198, width: 100, height: 24))
        cpuField.stringValue = "2"
        view.addSubview(cpuField)

        // Memory size
        let memLabel = NSTextField(labelWithString: "Memory (GB):")
        memLabel.frame = NSRect(x: 0, y: 170, width: 100, height: 20)
        view.addSubview(memLabel)

        let memField = NSTextField(frame: NSRect(x: 110, y: 168, width: 100, height: 24))
        memField.stringValue = "4"
        view.addSubview(memField)

        // Disk size
        let diskLabel = NSTextField(labelWithString: "Disk (GB):")
        diskLabel.frame = NSRect(x: 0, y: 140, width: 100, height: 20)
        view.addSubview(diskLabel)

        let diskField = NSTextField(frame: NSRect(x: 110, y: 138, width: 100, height: 24))
        diskField.stringValue = "64"
        view.addSubview(diskField)

        // Network Mode dropdown
        let networkLabel = NSTextField(labelWithString: "Network:")
        networkLabel.frame = NSRect(x: 0, y: 110, width: 100, height: 20)
        view.addSubview(networkLabel)

        let networkPopup = NSPopUpButton(frame: NSRect(x: 110, y: 105, width: 200, height: 26), pullsDown: false)
        networkPopup.addItem(withTitle: "NAT (Internet Access)")
        networkPopup.addItem(withTitle: "Virtual Network (VM-to-VM)")
        networkPopup.selectItem(at: 0) // Default to NAT
        view.addSubview(networkPopup)

        // Linux Router checkbox (only for Linux VMs in Virtual Network mode)
        let routerCheckbox = NSButton(checkboxWithTitle: "Act as Router for other VMs", target: nil, action: nil)
        routerCheckbox.frame = NSRect(x: 110, y: 80, width: 250, height: 20)
        routerCheckbox.state = .off
        routerCheckbox.isHidden = true  // Hidden by default
        view.addSubview(routerCheckbox)

        // macOS Router selection (only for macOS VMs in Virtual Network mode)
        let routerLabel = NSTextField(labelWithString: "Route via:")
        routerLabel.frame = NSRect(x: 110, y: 80, width: 70, height: 20)
        routerLabel.isHidden = true  // Hidden by default
        view.addSubview(routerLabel)

        let routerPopup = NSPopUpButton(frame: NSRect(x: 185, y: 75, width: 200, height: 26), pullsDown: false)
        routerPopup.isHidden = true  // Hidden by default
        view.addSubview(routerPopup)

        // Rosetta support checkbox
        let rosettaCheckbox = NSButton(checkboxWithTitle: "Enable Rosetta (x86_64 emulation)", target: nil, action: nil)
        rosettaCheckbox.frame = NSRect(x: 110, y: 50, width: 250, height: 20)
        rosettaCheckbox.state = .off
        view.addSubview(rosettaCheckbox)

        // Install from ISO checkbox (only for Linux)
        let isoCheckbox = NSButton(checkboxWithTitle: "Install from ISO", target: nil, action: nil)
        isoCheckbox.frame = NSRect(x: 110, y: 25, width: 200, height: 20)
        isoCheckbox.state = .on
        view.addSubview(isoCheckbox)

        // Connect the delegate references
        configDelegate.isoCheckbox = isoCheckbox
        configDelegate.createButton = createButton
        configDelegate.routerCheckbox = routerCheckbox
        configDelegate.routerLabel = routerLabel
        configDelegate.routerPopup = routerPopup
        configDelegate.networkPopup = networkPopup
        configDelegate.osPopup = osPopup

        // Set up delegate actions
        osPopup.target = configDelegate
        osPopup.action = #selector(VMConfigDelegate.osTypeChanged(_:))
        networkPopup.target = configDelegate
        networkPopup.action = #selector(VMConfigDelegate.networkModeChanged(_:))

        alert.accessoryView = view

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue
            let osType = osPopup.titleOfSelectedItem ?? "Linux"
            let cpuCount = Int(cpuField.stringValue) ?? 2
            let memoryGB = UInt64(memField.stringValue) ?? 4
            let diskGB = UInt64(diskField.stringValue) ?? 64
            let enableRosetta = rosettaCheckbox.state == .on
            let needsISO = isoCheckbox.state == .on
            let networkModeIndex = networkPopup.indexOfSelectedItem
            let isLinuxRouter = routerCheckbox.state == .on
            let selectedRouterName = routerPopup.titleOfSelectedItem

            print("DEBUG: Creating VM with Rosetta: \(enableRosetta)")

            let memorySize = memoryGB * 1024 * 1024 * 1024
            let diskSize = diskGB * 1024 * 1024 * 1024

            do {
                var newVM = try vmManager.createVM(
                    name: name,
                    cpuCount: cpuCount,
                    memorySize: memorySize,
                    diskSize: diskSize,
                    osType: osType
                )

                // Configure network settings
                if networkModeIndex == 1 {  // Virtual Network mode
                    newVM.networkConfig.mode = .virtual

                    if osType.lowercased().contains("mac") {
                        // macOS VM - find router VM by name
                        if let routerVM = vmManager.virtualMachines.first(where: { $0.name == selectedRouterName }) {
                            newVM.networkConfig.routerVMId = routerVM.id
                            print("[Network] macOS VM \(name) will route through \(routerVM.name)")
                        }
                    } else {
                        // Linux VM - set as router if checkbox is checked
                        newVM.networkConfig.isRouter = isLinuxRouter
                        if isLinuxRouter {
                            print("[Network] Linux VM \(name) configured as virtual network router")
                        }
                    }
                } else {
                    // NAT mode (default)
                    newVM.networkConfig.mode = .nat
                    print("[Network] VM \(name) configured for NAT networking")
                }

                // Save updated VM configuration
                try vmManager.saveVMConfiguration(newVM)

                refreshTable()

                if osType == "macOS" {
                    // For macOS, automatically handle IPSW download/reuse
                    downloadAndPrepareMacOSVM(newVM)
                } else if needsISO {
                    // For Linux, ask for ISO file
                    let openPanel = NSOpenPanel()
                    openPanel.canChooseFiles = true
                    openPanel.allowsMultipleSelection = false
                    openPanel.message = "Select an ISO file to install from"
                    openPanel.allowedContentTypes = [.iso]

                    if openPanel.runModal() == .OK {
                        // Start VM with ISO
                        selectedVM = newVM
                        vmManager.updateLastUsedDate(newVM)
                        window?.orderOut(nil)
                        NotificationCenter.default.post(name: .startVMWithISO, object: ["vm": newVM, "iso": openPanel.url!])
                    }
                }
            } catch {
                showAlert(message: "Failed to create VM: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startVM = Notification.Name("startVM")
    static let startVMWithISO = Notification.Name("startVMWithISO")
    static let vmStatusChanged = Notification.Name("vmStatusChanged")
}

// MARK: - UTType Extensions

import UniformTypeIdentifiers

extension UTType {
    static let iso = UTType(filenameExtension: "iso")!
    static let bundle = UTType(filenameExtension: "bundle")!
}
