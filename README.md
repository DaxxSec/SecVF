# SecVF

A macOS application for managing and running multiple Linux and macOS virtual machines using the Virtualization framework.

## Overview

SecVF (formerly Sandboxes of the sea) is a VM management application that allows you to create, manage, and run multiple virtual machines on your Mac. The app provides a library interface for organizing your VMs and supports both Linux and macOS guests.

[class_VZVirtualMachineConfiguration]:https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration
[class_VZLinuxBootLoader]:https://developer.apple.com/documentation/virtualization/vzlinuxbootloader
[class_VZVirtualMachine]:https://developer.apple.com/documentation/virtualization/vzvirtualmachine
[property_bootLoader]:https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/3656716-bootloader
[method_start]:https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656826-start
[method_guestDidStop]:https://developer.apple.com/documentation/virtualization/vzvirtualmachinedelegate/3656730-guestdidstop

## Download a Linux installation image 

Before you run the sample program, you need to download an ISO installation image from a Linux distribution website. Some common Linux distributions include:

- [Debian](https://www.debian.org/distrib/)
- [Fedora](https://getfedora.org/en/workstation/download/)
- [Ubuntu](https://ubuntu.com/download/desktop)


- Important: The Virtualization framework can run Linux VMs on a Mac with Apple silicon, and on an Intel-based Mac. The Linux ISO image you download must support the CPU architecture of your Mac. For a Mac with Apple silicon, download a Linux ISO image for ARM, which is usually indicated by `aarch64` or `arm64` in the image filename. For an Intel-based Mac, download a Linux ISO image for Intel-compatible CPUs, which is usually indicated by `x86_64` or `amd64` in the image filename.

- Note: If you need to run Intel Linux binaries in ARM Linux on a Mac with Apple silicon, the Virtualization framework supports this capability using the Rosetta translation environment. For more information, see [Running Intel Binaries in Linux VMs with Rosetta](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta).


## Features

- **VM Library Management**: Browse all your VMs in a convenient table view
- **Create New VMs**: Configure CPU, memory, disk size, OS type, and Rosetta support
- **Import Existing VMs**: Import VM bundles from anywhere on your system
- **Clone VMs**: Duplicate existing VMs with a new name
- **Rename & Delete**: Organize your VM collection
- **Multi-VM Support**: Manage multiple VMs (runs one at a time)
- **Auto-Migration**: Automatically migrates old single-VM setup to the new library structure

## Getting Started

- Note: The default deployment target is macOS 14. If you need to build for a different version of macOS, change the deployment target as appropriate.

1. Launch Xcode and open `SecVF.xcodeproj`.

2. Navigate to the Signing & Capabilities panel and select your team ID.

3. Build and run the application.

### First Launch

When you launch SecVF, you'll see the **Virtual Machine Library** window displaying all your VMs.

**If you have an old VM**: If you previously used this app and have a `GUI Linux VM.bundle` in your home directory, or VMs in `~/VirtualMachines/`, they will be automatically migrated to the new library structure at `~/.avf/Linux/` or `~/.avf/MacOS/`.

### Creating a New VM

1. Click the **New** button in the VM Library window
2. Configure your VM:
   - **Name**: Give your VM a descriptive name
   - **OS Type**: Select Linux or macOS from the dropdown
   - **CPU Cores**: Number of CPU cores to allocate (default: 2)
   - **Memory (GB)**: Amount of RAM to allocate (default: 4 GB)
   - **Disk (GB)**: Virtual disk size (default: 64 GB)
   - **Enable Rosetta**: Check to enable x86_64 emulation on ARM Macs (for running Intel binaries in ARM Linux)
   - **Install from ISO**: Check to install from an ISO image
3. Click **Select ISO** to choose your installation ISO file
4. The VM will boot into the installer. Follow the OS installation instructions.
5. When installation completes, the VM is ready to use.

### VM Storage

VMs are organized by OS type in `~/.avf/` with each VM in its own bundle:

```
~/.avf/
  ├── Linux/
  │   └── Ubuntu.bundle/
  │       ├── Disk.img           # Main disk image
  │       ├── NVRAM              # EFI variable store
  │       ├── MachineIdentifier  # VZGenericMachineIdentifier data
  │       └── metadata.json      # VM configuration metadata
  └── MacOS/
      └── macOS Sonoma.bundle/
          ├── Disk.img
          ├── NVRAM
          ├── MachineIdentifier
          ├── metadata.json
          └── UniversalMac_15.0_24A335_Restore.ipsw  # macOS restore image (downloaded)
```

### Managing VMs

- **Start a VM**: Select a VM from the library and click **Start** (or double-click the VM)
- **Import a VM**: Click **Import** and select an existing VM bundle
- **Clone a VM**: Select a VM and click **Clone** to create a duplicate
- **Rename a VM**: Select a VM and click **Rename**
- **Delete a VM**: Select a VM and click **Delete** (this cannot be undone)


## Install GUI Linux from an ISO image

The sample app configures a `VZDiskImageStorageDeviceAttachment` object with the downloaded ISO image attached, and creates a `VZUSBMassStorageDeviceConfiguration` with it to emulate a USB thumb drive that's plugged in to the VM.

``` swift
private func createUSBMassStorageDeviceConfiguration() -> VZUSBMassStorageDeviceConfiguration {
    guard let intallerDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: installerISOPath!, readOnly: true) else {
        fatalError("Failed to create installer's disk attachment.")
    }

    return VZUSBMassStorageDeviceConfiguration(attachment: intallerDiskAttachment)
}
```


## Set up the VM

The sample app uses a [`VZVirtualMachineConfiguration`][class_VZVirtualMachineConfiguration] object to configure the basic characteristics of the VM, such as the CPU count, memory size, various device configurations, and a `VZEFIBootloader` to load the Linux operating system into the VM.

``` swift
let virtualMachineConfiguration = VZVirtualMachineConfiguration()

virtualMachineConfiguration.cpuCount = computeCPUCount()
virtualMachineConfiguration.memorySize = computeMemorySize()

let platform = VZGenericPlatformConfiguration()
let bootloader = VZEFIBootLoader()
let disksArray = NSMutableArray()

if needsInstall {
    // This is a fresh install: Create a new machine identifier and EFI variable store,
    // and configure a USB mass storage device to boot the ISO image.
    platform.machineIdentifier = createAndSaveMachineIdentifier()
    bootloader.variableStore = createEFIVariableStore()
    disksArray.add(createUSBMassStorageDeviceConfiguration())
} else {
    // The VM is booting from a disk image that already has the OS installed.
    // Retrieve the machine identifier and EFI variable store that were saved to
    // disk during installation.
    platform.machineIdentifier = retrieveMachineIdentifier()
    bootloader.variableStore = retrieveEFIVariableStore()
}

virtualMachineConfiguration.platform = platform
virtualMachineConfiguration.bootLoader = bootloader

disksArray.add(createBlockDeviceConfiguration())
guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
    fatalError("Invalid disksArray.")
}
virtualMachineConfiguration.storageDevices = disks

virtualMachineConfiguration.networkDevices = [createNetworkDeviceConfiguration()]
virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration()]
virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]

virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]

try! virtualMachineConfiguration.validate()
virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
```

## Enable copy-and-paste support between the host and the guest

In macOS 13 and later, the Virtualization framework supports copy-and-paste of text and images between the Mac host and Linux guests through the SPICE agent clipboard-sharing capability. The example below shows the steps for configuring `VZVirtioConsoleDeviceConfiguration` and `VZSpiceAgentPortAttachment` to enable this capability:
``` swift
private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
    let consoleDevice = VZVirtioConsoleDeviceConfiguration()

    let spiceAgentPort = VZVirtioConsolePortConfiguration()
    spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
    spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
    consoleDevice.ports[0] = spiceAgentPort

    return consoleDevice
}
```

- Important: To use the copy-and-paste capability in Linux, the user needs to install the spice-vdagent package, which is available through most Linux package managers. Developers need to communicate this requirement to users of their apps.


## Start the VM

After building the configuration data for the VM, the sample app uses the `VZVirtualMachine` object to start the execution of the Linux guest operating system.

Before calling the VM's [`start`][method_start] method, the sample app configures a delegate object to receive messages about the state of the virtual machine. When the Linux operating system shuts down, the VM calls the delegate's [`guestDidStop`][method_guestDidStop] method. In response, the delegate method prints a message and exits the sample.

``` swift
self.virtualMachineView.virtualMachine = self.virtualMachine

if #available(macOS 14.0, *) {
    // Configure the app to automatically respond changes in the display size.
    self.virtualMachineView.automaticallyReconfiguresDisplay = true
}

self.virtualMachine.delegate = self
self.virtualMachine.start(completionHandler: { (result) in
    switch result {
    case let .failure(error):
        fatalError("Virtual machine failed to start with error: \(error)")

    default:
        print("Virtual machine successfully started.")
    }
})
```

The app sets the display to automatically resize when the window size changes.
