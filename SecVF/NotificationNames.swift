//
//  NotificationNames.swift
//  SecVF
//
//  Centralized notification name definitions for VM lifecycle events.
//

import Foundation

extension Notification.Name {
    /// Start a VM - post with userInfo containing VMConfiguration
    static let startVM = Notification.Name("startVM")

    /// Start a VM with a specific ISO attached
    static let startVMWithISO = Notification.Name("startVMWithISO")

    /// Stop a running VM
    static let stopVM = Notification.Name("stopVM")

    /// Pause or resume a VM
    static let pauseVM = Notification.Name("pauseVM")

    /// VM status has changed (running, stopped, paused)
    static let vmStatusChanged = Notification.Name("vmStatusChanged")

    /// Request opening the packet analysis window. The AppDelegate owns the
    /// only PacketAnalysisWindowController; other UIs (library button, future
    /// menu items) post this notification instead of creating their own — two
    /// independent windows confused the operator and split packet rendering.
    /// Optional userInfo:
    ///   - "presetTitle": String — when present, AppDelegate calls the
    ///     window's `applyPresetByTitle(_:)` immediately after showing it so
    ///     the user lands on the pre-filtered packet list.
    static let openPacketAnalysis = Notification.Name("openPacketAnalysis")

    /// Request booting the AI Sandbox session VM. Posted by the library
    /// window's AI Sandbox tab when the user clicks Start; AppDelegate
    /// reads `userInfo["inRecoveryMode"]: Bool` to decide which boot
    /// path to dispatch (normal vs. macOS Recovery).
    static let bootAISandbox = Notification.Name("bootAISandbox")

    /// Background bundle-size measurement finished. `object` is the
    /// VMConfiguration.id (UUID); `userInfo["bytes"]: Int64` is the
    /// measured allocated-on-disk size. Used by the selected-VM detail
    /// card to refresh the Disk cell once a background scan completes.
    static let vmBundleSizeUpdated = Notification.Name("vmBundleSizeUpdated")

    /// Bring an already-running VM's guest console window to the front.
    /// `object` is the VMConfiguration.id (UUID). Posted by the library
    /// window's Console quick-action button; AppDelegate looks the
    /// window up in `vmWindows[id]` and orders it front.
    static let focusVMConsole = Notification.Name("focusVMConsole")
}
