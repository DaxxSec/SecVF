import ArgumentParser
import Foundation

struct USBCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usb",
        abstract: "USB device management commands",
        subcommands: [
            USBList.self,
            USBMount.self,
            USBEject.self,
            USBCreateVirtual.self,
        ]
    )
}

// MARK: - USB List

struct USBList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List connected USB devices"
    )

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Include virtual USB disks")
    var includeVirtual = false

    mutating func run() throws {
        let usbManager = USBManagerBridge()
        var devices = usbManager.listDevices()

        if includeVirtual {
            devices += usbManager.listVirtualDisks()
        }

        if options.json {
            JSONOutput(success: true, data: devices).print()
        } else {
            if devices.isEmpty {
                print("No USB devices found.")
                return
            }

            print("DEVICE                  VENDOR        TYPE       MOUNTED TO      STATUS")
            print(String(repeating: "-", count: 75))

            for device in devices {
                let name = (device["name"] as? String ?? "Unknown").padding(toLength: 23, withPad: " ", startingAt: 0)
                let vendor = (device["vendor"] as? String ?? "Unknown").padding(toLength: 13, withPad: " ", startingAt: 0)
                let type = (device["type"] as? String ?? "Physical").padding(toLength: 10, withPad: " ", startingAt: 0)
                let mountedTo = (device["mountedTo"] as? String ?? "--").padding(toLength: 15, withPad: " ", startingAt: 0)
                let status = device["status"] as? String ?? "Available"

                let icon = switch type.trimmingCharacters(in: .whitespaces) {
                    case "Virtual": "◎"
                    default: device["mountedTo"] != nil ? "◉" : "○"
                }

                print("\(icon) \(name) \(vendor) \(type) \(mountedTo) \(status)")
            }
        }
    }
}

// MARK: - USB Mount

struct USBMount: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Mount USB device to a virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "USB device name or ID")
    var device: String

    @Option(name: .long, help: "Target VM name")
    var to: String

    mutating func run() throws {
        let usbManager = USBManagerBridge()
        let result = usbManager.mountDevice(device: device, toVM: to)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Device mounted", data: ["device": device, "vm": to]).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Mounted '\(device)' to VM '\(to)'")
            }
        }
    }
}

// MARK: - USB Eject

struct USBEject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "Eject USB device from virtual machine"
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "USB device name or ID")
    var device: String

    mutating func run() throws {
        let usbManager = USBManagerBridge()
        let result = usbManager.ejectDevice(device: device)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Device ejected").print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                print("✓ Ejected '\(device)'")
            }
        }
    }
}

// MARK: - USB Create Virtual

struct USBCreateVirtual: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-virtual",
        abstract: "Create a virtual USB disk image"
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "Virtual disk name")
    var name: String

    @Option(name: .shortAndLong, help: "Size in MB")
    var size: Int = 256

    @Option(name: .long, help: "Format: dmg, iso")
    var format: String = "dmg"

    @Option(name: .long, help: "Source directory to include")
    var source: String?

    mutating func run() throws {
        let usbManager = USBManagerBridge()
        let result = usbManager.createVirtualDisk(name: name, sizeMB: size, format: format, source: source)

        if options.json {
            if let error = result["error"] as? String {
                JSONOutput(success: false, message: error).print()
            } else {
                JSONOutput(success: true, message: "Virtual disk created", data: result).print()
            }
        } else {
            if let error = result["error"] as? String {
                print("Error: \(error)")
            } else {
                let path = result["path"] as? String ?? ""
                print("✓ Created virtual disk: \(path)")
                print("  Size: \(size) MB")
                print("  Format: \(format.uppercased())")
            }
        }
    }
}
