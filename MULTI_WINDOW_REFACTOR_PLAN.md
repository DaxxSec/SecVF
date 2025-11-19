# Multi-Window Refactoring Plan for SecVF

## Problem
The current AppDelegate uses a single `@IBOutlet var window: NSWindow!` which causes the first VM's window to disappear when a second VM starts, because the window reference gets overwritten and ARC deallocates the previous window.

## Solution Overview
Refactor to dictionary-based multi-window architecture where each VM has its own window, view, and virtual machine instance.

## Changes Required

### 1. Class Properties (DONE)
Changed from:
```swift
@IBOutlet var window: NSWindow!
@IBOutlet weak var virtualMachineView: VZVirtualMachineView!
private var virtualMachine: VZVirtualMachine!
private var installerISOPath: URL?
private var needsInstall = true
private var vmConfig: VMConfiguration!
```

To:
```swift
private var vmWindows: [UUID: NSWindow] = [:]
private var virtualMachines: [UUID: VZVirtualMachine] = [:]
private var vmConfigs: [UUID: VMConfiguration] = [:]
private var vmViews: [UUID: VZVirtualMachineView] = [:]
private var installerISOPaths: [UUID: URL] = [:]
private var needsInstallFlags: [UUID: Bool] = [:]
```

### 2. Notification Handlers (DONE)
- `handleStartVM(_:)` - Updated to store VM config in dictionary
- `handleStartVMWithISO(_:)` - Updated to use dictionary
- `showMainWindowAndStartVM(for:)` - New method that creates window per VM

### 3. Helper Methods (IN PROGRESS)
Need to update all these to accept `vmId: UUID` parameter:
- `createBlockDeviceConfiguration(for:)` - DONE
- `computeCPUCount(for:)` - DONE
- `computeMemorySize(for:)` - DONE
- `createNetworkDeviceConfiguration(for:)` - TODO
- `createGraphicsDeviceConfiguration(for:isMacOS:)` - TODO
- `createUSBMassStorageDeviceConfiguration(for:)` - TODO
- `createAndSaveMachineIdentifier(for:)` - TODO
- `retrieveMachineIdentifier(for:)` - TODO
- `createEFIVariableStore(for:)` - TODO
- `retrieveEFIVariableStore(for:)` - TODO
- All macOS-specific methods need vmId parameter

### 4. Main VM Creation Methods (TODO)
- `createVirtualMachine(for:)` - Complete rewrite needed
- `configureAndStartVirtualMachine(for:)` - Complete rewrite needed
- `installMacOS(for:)` - Update to use vmId

###5. Delegate Methods (TODO)
- `windowWillClose(_:)` - Update to identify which VM's window is closing
- `guestDidStop(_:)` - Update to identify which VM stopped
- `virtualMachine(_:didStopWithError:)` - Update to identify which VM

### 6. ApplicationDidFinishLaunching (DONE)
- Already hides main window
- No changes needed

## Implementation Strategy

Given the complexity, I recommend a phased approach:

**Phase 1** (This commit): Create minimum viable multi-window support
- Keep existing single-VM code path working
- Add multi-window support for new VM instances
- Use a hybrid approach where first VM uses existing code, additional VMs use new code

**Phase 2** (Next commit): Full refactor
- Convert all methods to use vmId parameter
- Remove all single-VM instance variables
- Update all delegate methods

**Phase 3** (Testing):
- Test with 2+ VMs running simultaneously
- Verify window closing doesn't stop wrong VM
- Verify VM stopping cleans up correct resources

## Simplified Alternative Approach

Instead of full refactor, we can use a minimal fix:
1. Create windows programmatically (no @IBOutlet)
2. Use window.identifier to track which VM owns which window
3. Keep dictionaries for tracking VM instances
4. Minimal changes to existing methods

This gets us 80% of the benefit with 20% of the work.
