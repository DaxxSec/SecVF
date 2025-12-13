import ArgumentParser
import Foundation

struct VMCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Virtual machine management commands",
        subcommands: [
            VMList.self,
            VMCreate.self,
            VMStart.self,
            VMStop.self,
            VMStatus.self,
            VMDelete.self,
            VMSSH.self,
            VMCopyTo.self,
            VMCopyFrom.self,
            VMSnapshot.self,
        ]
    )
}

// MARK: - VM List

struct VMList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all virtual machines"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .long, help: "Filter by status (running, stopped, paused)")
    var status: String?

    @Option(name: .long, help: "Filter by OS type (linux, macos)")
    var osType: String?

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let vms = vmManager.listVMs()

        var filteredVMs = vms

        if let statusFilter = status {
            filteredVMs = filteredVMs.filter { $0["status"] as? String == statusFilter }
        }

        if let osFilter = osType {
            filteredVMs = filteredVMs.filter {
                ($0["osType"] as? String)?.lowercased().contains(osFilter.lowercased()) ?? false
            }
        }

        if options.json {
            JSONOutput(success: true, data: filteredVMs).print()
        } else {
            if filteredVMs.isEmpty {
                print("No virtual machines found.")
                return
            }

            print("NAME                    OS        STATUS    CPU  RAM    NETWORK")
            print(String(repeating: "-", count: 70))

            for vm in filteredVMs {
                let name = (vm["name"] as? String ?? "Unknown").padding(toLength: 23, withPad: " ", startingAt: 0)
                let os = (vm["osType"] as? String ?? "Unknown").padding(toLength: 9, withPad: " ", startingAt: 0)
                let status = (vm["status"] as? String ?? "Unknown").padding(toLength: 9, withPad: " ", startingAt: 0)
                let cpu = String(vm["cpuCount"] as? Int ?? 0).padding(toLength: 4, withPad: " ", startingAt: 0)
                let ram = formatMemory(vm["memorySize"] as? UInt64 ?? 0).padding(toLength: 6, withPad: " ", startingAt: 0)
                let network = vm["networkMode"] as? String ?? "NAT"

                let statusIcon = switch status.trimmingCharacters(in: .whitespaces) {
                    case "running": "●"
                    case "paused": "◐"
                    default: "○"
                }

                print("\(statusIcon) \(name) \(os) \(status) \(cpu) \(ram) \(network)")
            }
        }
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.0fGB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0fMB", mb)
    }
}

// MARK: - VM Create

struct VMCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(name: .long, help: "Operating system (linux, macos)")
    var os: String = "linux"

    @Option(name: .long, help: "Linux distribution (kali, ubuntu, debian, fedora, arch, manjaro)")
    var distro: String = "kali"

    @Option(name: .long, help: "Number of CPU cores")
    var cpu: Int = 2

    @Option(name: .long, help: "Memory size in MB")
    var ram: Int = 4096

    @Option(name: .long, help: "Disk size in GB")
    var disk: Int = 64

    @Option(name: .long, help: "Network mode (nat, virtual, isolated)")
    var network: String = "nat"

    @Flag(name: .long, help: "Configure as security router VM")
    var router = false

    @Flag(name: .long, help: "Start VM immediately after creation")
    var start = false

    mutating func run() throws {
        let vmManager = VMManagerBridge()

        let config: [String: Any] = [
            "name": name,
            "osType": os.lowercased() == "macos" ? "macOS" : "Linux",
            "linuxDistribution": distro,
            "cpuCount": cpu,
            "memorySize": UInt64(ram) * 1024 * 1024,
            "diskSize": UInt64(disk) * 1024 * 1024 * 1024,
            "networkMode": network,
            "isRouter": router
        ]

        let result = vmManager.createVM(config: config)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "VM created successfully", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Created VM: \(name)")
                print("  OS: \(os)")
                print("  CPU: \(cpu) cores")
                print("  RAM: \(ram) MB")
                print("  Disk: \(disk) GB")
                print("  Network: \(network)")

                if start {
                    print("\nStarting VM...")
                    let startResult = vmManager.startVM(name: name)
                    if let error = startResult["error"] as? String {
                        print("Error starting VM: \(error)")
                    } else {
                        print("✓ VM started")
                    }
                }
            }
        }
    }
}

// MARK: - VM Start

struct VMStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Flag(name: .long, help: "Run VM in foreground (attach to console)")
    var foreground = false

    @Flag(name: .long, help: "Wait for VM to be fully booted")
    var wait = false

    @Option(name: .long, help: "Timeout in seconds when waiting for boot")
    var timeout: Int = 120

    mutating func run() async throws {
        let vmManager = VMManagerBridge()

        // Check if VM exists
        guard let vm = vmManager.findVMByName(name: name) else {
            if options.json {
                JSONOutput(success: false, message: "VM '\(name)' not found").print()
            } else {
                print("Error: VM '\(name)' not found")
            }
            return
        }

        // Check if already running
        if VMProcessManager.shared.isVMRunning(name: name) {
            if options.json {
                JSONOutput(success: false, message: "VM '\(name)' is already running").print()
            } else {
                print("Error: VM '\(name)' is already running")
            }
            return
        }

        guard let bundlePath = vm["path"] as? String else {
            if options.json {
                JSONOutput(success: false, message: "VM bundle path not found").print()
            } else {
                print("Error: VM bundle path not found")
            }
            return
        }

        if foreground {
            // Run VM in foreground (blocking)
            if !options.json {
                print("Starting VM '\(name)' in foreground mode...")
                print("Press Ctrl+C to stop the VM")
            }

            let runner = VMRunner(vmName: name, bundlePath: bundlePath)
            VMProcessManager.shared.writePidFile(for: name)

            do {
                try await runner.start()
            } catch {
                VMProcessManager.shared.removePidFile(for: name)
                if options.json {
                    JSONOutput(success: false, message: "Failed to start VM: \(error.localizedDescription)").print()
                } else {
                    print("Error: \(error.localizedDescription)")
                }
                return
            }

            VMProcessManager.shared.removePidFile(for: name)
        } else {
            // Spawn background process
            let executablePath = CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["vm", "start", name, "--foreground"]

            // Detach from terminal
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()

                // Wait a moment to check if it started
                Thread.sleep(forTimeInterval: 1)

                if VMProcessManager.shared.isVMRunning(name: name) {
                    if options.json {
                        JSONOutput(success: true, message: "VM started", data: ["name": name, "pid": process.processIdentifier]).print()
                    } else {
                        print("✓ Started VM: \(name) (PID: \(process.processIdentifier))")
                    }
                } else {
                    if options.json {
                        JSONOutput(success: false, message: "VM failed to start").print()
                    } else {
                        print("Error: VM failed to start")
                    }
                }
            } catch {
                if options.json {
                    JSONOutput(success: false, message: "Failed to spawn VM process: \(error.localizedDescription)").print()
                } else {
                    print("Error: \(error.localizedDescription)")
                }
            }

            if wait && !options.json {
                print("Waiting for boot (timeout: \(timeout)s)...")
                let startTime = Date()
                while Date().timeIntervalSince(startTime) < Double(timeout) {
                    if vmManager.isSSHAvailable(name: name) {
                        print("✓ VM is ready (SSH available)")
                        return
                    }
                    Thread.sleep(forTimeInterval: 2)
                    print(".", terminator: "")
                    fflush(stdout)
                }
                print("\nWarning: Timeout waiting for SSH")
            }
        }
    }
}

// MARK: - VM Stop

struct VMStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Flag(name: .long, help: "Force stop (power off)")
    var force = false

    mutating func run() throws {
        // First try to stop via PID file (headless mode)
        if VMProcessManager.shared.isVMRunning(name: name) {
            let success = VMProcessManager.shared.stopVM(name: name, force: force)
            if success {
                if options.json {
                    JSONOutput(success: true, message: "VM stopped", data: ["name": name]).print()
                } else {
                    print("✓ Stopped VM: \(name)")
                }
                return
            }
        }

        // Fall back to notification-based stop (for GUI app)
        let vmManager = VMManagerBridge()
        let result = vmManager.stopVM(name: name, force: force)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "VM stopped", data: ["name": name]).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Stopped VM: \(name)")
            }
        }
    }
}

// MARK: - VM Status

struct VMStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get status of a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let status = vmManager.getVMStatus(name: name)

        if options.json {
            JSONOutput(success: true, data: status).print()
        } else {
            if let error = status["error"] as? String {
                print("Error: \(error)")
            } else {
                print("VM: \(name)")
                print("  Status: \(status["status"] ?? "unknown")")
                print("  OS: \(status["osType"] ?? "unknown")")
                print("  CPU: \(status["cpuCount"] ?? 0) cores")
                if let mem = status["memorySize"] as? UInt64 {
                    print("  RAM: \(mem / (1024*1024*1024)) GB")
                }
                print("  Network: \(status["networkMode"] ?? "unknown")")
                if let ip = status["ipAddress"] as? String {
                    print("  IP: \(ip)")
                }
                if let uptime = status["uptime"] as? TimeInterval {
                    print("  Uptime: \(formatUptime(uptime))")
                }
            }
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

// MARK: - VM Delete

struct VMDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Flag(name: .long, help: "Force delete without confirmation")
    var force = false

    mutating func run() throws {
        let vmManager = VMManagerBridge()

        if !force && !options.json {
            print("Are you sure you want to delete '\(name)'? This cannot be undone. [y/N] ", terminator: "")
            if let response = readLine()?.lowercased(), response != "y" && response != "yes" {
                print("Cancelled.")
                return
            }
        }

        let result = vmManager.deleteVM(name: name)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "VM deleted", data: ["name": name]).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Deleted VM: \(name)")
            }
        }
    }
}

// MARK: - VM SSH

struct VMSSH: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "SSH into a virtual machine or execute a command"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Option(name: .shortAndLong, help: "Command to execute (non-interactive)")
    var command: String?

    @Option(name: .shortAndLong, help: "SSH user (default: root)")
    var user: String = "root"

    @Option(name: .shortAndLong, help: "SSH port (default: 22)")
    var port: Int = 22

    mutating func run() throws {
        let vmManager = VMManagerBridge()

        // Get VM IP address
        guard let ip = vmManager.getVMIP(name: name) else {
            if options.json {
                JSONOutput(success: false, message: "Could not get VM IP address. Is the VM running?").print()
            } else {
                print("Error: Could not get VM IP address. Is the VM running?")
            }
            return
        }

        // Get SSH key path
        let keyPath = "\(NSHomeDirectory())/.avf/keys/\(name)/id_ed25519"
        let keyExists = FileManager.default.fileExists(atPath: keyPath)

        var sshArgs = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]

        if keyExists {
            sshArgs += ["-i", keyPath]
        }

        sshArgs += ["-p", String(port), "\(user)@\(ip)"]

        if let cmd = command {
            // Execute command and capture output
            sshArgs.append(cmd)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if options.json {
                JSONOutput(
                    success: process.terminationStatus == 0,
                    message: process.terminationStatus == 0 ? nil : "Command failed",
                    data: [
                        "exitCode": process.terminationStatus,
                        "stdout": output,
                        "stderr": errorOutput
                    ]
                ).print()
            } else {
                if !output.isEmpty {
                    print(output, terminator: "")
                }
                if !errorOutput.isEmpty {
                    fputs(errorOutput, stderr)
                }
                if process.terminationStatus != 0 {
                    Darwin.exit(process.terminationStatus)
                }
            }
        } else {
            // Interactive SSH session
            if options.json {
                JSONOutput(success: false, message: "Interactive SSH not supported in JSON mode. Use --command.").print()
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArgs
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()
            Darwin.exit(process.terminationStatus)
        }
    }
}

// MARK: - VM Copy To

struct VMCopyTo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-to",
        abstract: "Copy files to a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Argument(help: "Local source path")
    var source: String

    @Argument(help: "Remote destination path")
    var destination: String

    @Option(name: .shortAndLong, help: "SSH user (default: root)")
    var user: String = "root"

    @Flag(name: .shortAndLong, help: "Recursive copy for directories")
    var recursive = false

    mutating func run() throws {
        let vmManager = VMManagerBridge()

        guard let ip = vmManager.getVMIP(name: name) else {
            if options.json {
                JSONOutput(success: false, message: "Could not get VM IP address").print()
            } else {
                print("Error: Could not get VM IP address. Is the VM running?")
            }
            return
        }

        let keyPath = "\(NSHomeDirectory())/.avf/keys/\(name)/id_ed25519"
        var scpArgs = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]

        if FileManager.default.fileExists(atPath: keyPath) {
            scpArgs += ["-i", keyPath]
        }

        if recursive {
            scpArgs.append("-r")
        }

        scpArgs += [source, "\(user)@\(ip):\(destination)"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = scpArgs

        if !options.json {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }

        try process.run()
        process.waitUntilExit()

        if options.json {
            JSONOutput(
                success: process.terminationStatus == 0,
                message: process.terminationStatus == 0 ? "File copied successfully" : "Copy failed"
            ).print()
        } else if process.terminationStatus == 0 {
            print("✓ Copied \(source) to \(name):\(destination)")
        }
    }
}

// MARK: - VM Copy From

struct VMCopyFrom: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy-from",
        abstract: "Copy files from a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var name: String

    @Argument(help: "Remote source path")
    var source: String

    @Argument(help: "Local destination path")
    var destination: String

    @Option(name: .shortAndLong, help: "SSH user (default: root)")
    var user: String = "root"

    @Flag(name: .shortAndLong, help: "Recursive copy for directories")
    var recursive = false

    mutating func run() throws {
        let vmManager = VMManagerBridge()

        guard let ip = vmManager.getVMIP(name: name) else {
            if options.json {
                JSONOutput(success: false, message: "Could not get VM IP address").print()
            } else {
                print("Error: Could not get VM IP address. Is the VM running?")
            }
            return
        }

        let keyPath = "\(NSHomeDirectory())/.avf/keys/\(name)/id_ed25519"
        var scpArgs = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]

        if FileManager.default.fileExists(atPath: keyPath) {
            scpArgs += ["-i", keyPath]
        }

        if recursive {
            scpArgs.append("-r")
        }

        scpArgs += ["\(user)@\(ip):\(source)", destination]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = scpArgs

        if !options.json {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }

        try process.run()
        process.waitUntilExit()

        if options.json {
            JSONOutput(
                success: process.terminationStatus == 0,
                message: process.terminationStatus == 0 ? "File copied successfully" : "Copy failed"
            ).print()
        } else if process.terminationStatus == 0 {
            print("✓ Copied \(name):\(source) to \(destination)")
        }
    }
}

// MARK: - VM Snapshot

struct VMSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Manage VM snapshots",
        subcommands: [
            SnapshotCreate.self,
            SnapshotList.self,
            SnapshotRestore.self,
            SnapshotDelete.self,
        ]
    )
}

struct SnapshotCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a snapshot"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var vmName: String

    @Option(name: .shortAndLong, help: "Snapshot name")
    var name: String

    @Option(name: .shortAndLong, help: "Snapshot description")
    var description: String?

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let result = vmManager.createSnapshot(vmName: vmName, snapshotName: name, description: description)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Snapshot created", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Created snapshot '\(name)' for VM '\(vmName)'")
            }
        }
    }
}

struct SnapshotList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List snapshots"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var vmName: String

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let snapshots = vmManager.listSnapshots(vmName: vmName)

        if options.json {
            JSONOutput(success: true, data: snapshots).print()
        } else {
            if snapshots.isEmpty {
                print("No snapshots for VM '\(vmName)'")
            } else {
                print("SNAPSHOT NAME       CREATED              SIZE      DESCRIPTION")
                print(String(repeating: "-", count: 70))
                for snap in snapshots {
                    let name = (snap["name"] as? String ?? "").padding(toLength: 19, withPad: " ", startingAt: 0)
                    let created = (snap["created"] as? String ?? "").padding(toLength: 20, withPad: " ", startingAt: 0)
                    let size = (snap["size"] as? String ?? "").padding(toLength: 9, withPad: " ", startingAt: 0)
                    let desc = snap["description"] as? String ?? ""
                    print("\(name) \(created) \(size) \(desc)")
                }
            }
        }
    }
}

struct SnapshotRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a snapshot"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var vmName: String

    @Option(name: .shortAndLong, help: "Snapshot name to restore")
    var name: String

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let result = vmManager.restoreSnapshot(vmName: vmName, snapshotName: name)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Snapshot restored").print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Restored snapshot '\(name)' for VM '\(vmName)'")
            }
        }
    }
}

struct SnapshotDelete: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a snapshot"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Name of the virtual machine")
    var vmName: String

    @Option(name: .shortAndLong, help: "Snapshot name to delete")
    var name: String

    mutating func run() throws {
        let vmManager = VMManagerBridge()
        let result = vmManager.deleteSnapshot(vmName: vmName, snapshotName: name)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Snapshot deleted").print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Deleted snapshot '\(name)' from VM '\(vmName)'")
            }
        }
    }
}
