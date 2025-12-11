//
//  LayoutConstants.swift
//  SecVF
//
//  Centralized layout constants to eliminate magic numbers
//

import Cocoa

/// Centralized layout constants for consistent UI sizing throughout the app
struct LayoutConstants {

    // MARK: - Sidebar
    static let sidebarWidth: CGFloat = 220
    static let activePanelWidth: CGFloat = 220

    // MARK: - Logo
    static let logoWidth: CGFloat = 170
    static let logoHeight: CGFloat = 120

    // MARK: - Button Row
    static let buttonRowHeight: CGFloat = 50
    static let buttonWidth: CGFloat = 80
    static let buttonSpacing: CGFloat = 10

    // MARK: - Packet Panel
    static let packetPanelHeight: CGFloat = 180

    // MARK: - Padding
    static let standardPadding: CGFloat = 15

    // MARK: - Window
    static let minWindowWidth: CGFloat = 1150
    static let minWindowHeight: CGFloat = 600
    static let defaultWindowWidth: CGFloat = 1150
    static let defaultWindowHeight: CGFloat = 650

    // MARK: - Info Labels
    static let infoLabelY: CGFloat = 115
    static let infoRowHeight: CGFloat = 14

    // MARK: - Toolbar
    static let toolbarHeight: CGFloat = 80

    // MARK: - Hex Icon
    static let hexRadius: CGFloat = 42

    // MARK: - Lock Icon
    static let lockWidth: CGFloat = 20
    static let lockHeight: CGFloat = 24

    // MARK: - Packet Analysis Window
    static let packetWindowWidth: CGFloat = 950
    static let packetWindowHeight: CGFloat = 700
    static let packetWindowMinWidth: CGFloat = 700
    static let packetWindowMinHeight: CGFloat = 500
}
