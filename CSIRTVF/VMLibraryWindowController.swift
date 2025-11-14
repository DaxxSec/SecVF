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

        print("DEBUG: windowDidLoad - VM count: \(vmManager.virtualMachines.count)")

        // Set window delegate to handle close button
        window?.delegate = self

        // Configure table view
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(startVM(_:))

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
        vmManager.loadVirtualMachines()
        DispatchQueue.main.async {
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
                guard let osPopup = networkPopup?.superview?.subviews.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("macOS") }) else { return }

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
                let linuxVMs = vmManager.vms.filter { $0.osType.lowercased().contains("linux") }

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
        osPopup.target = configDelegate
        osPopup.action = #selector(VMConfigDelegate.osTypeChanged(_:))
        networkPopup.target = configDelegate
        networkPopup.action = #selector(VMConfigDelegate.networkModeChanged(_:))

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
                        if let routerVM = vmManager.vms.first(where: { $0.name == selectedRouterName }) {
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
