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
    static let openPacketAnalysis = Notification.Name("openPacketAnalysis")
}
