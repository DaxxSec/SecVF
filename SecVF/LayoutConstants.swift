//
//  LayoutConstants.swift
//  SecVF
//
//  Centralized layout, spacing, typography, and radius tokens.
//  Use these instead of magic numbers so the UI scales consistently.
//

import Cocoa

/// Centralized layout, spacing, typography, and radius tokens.
///
/// **How to use:**
/// - Spacing: prefer the `spacing*` scale (xs/sm/md/lg/xl) over raw padding numbers
/// - Typography: prefer the `fontSize*` scale, used together with `font(size:weight:)`
/// - Radius: prefer the `cornerRadius*` scale for any layer rounding
///
/// Component-specific values (sidebar, packet panel, etc.) stay here too so the
/// design system has a single source of truth.
struct LayoutConstants {

    // MARK: - Spacing Scale (4pt grid)

    /// 4pt — hairline gap between tightly related elements
    static let spacingXS: CGFloat = 4

    /// 8pt — inner padding of compact controls
    static let spacingSM: CGFloat = 8

    /// 12pt — standard padding inside cards / between siblings
    static let spacingMD: CGFloat = 12

    /// 16pt — comfortable section padding
    static let spacingLG: CGFloat = 16

    /// 24pt — large section break
    static let spacingXL: CGFloat = 24

    /// 32pt — major group separation
    static let spacingXXL: CGFloat = 32

    // MARK: - Typography Scale

    /// 9pt — captions, badges, footnotes
    static let fontSizeCaption: CGFloat = 9

    /// 10pt — secondary labels, small metadata
    static let fontSizeSmall: CGFloat = 10

    /// 11pt — body text, button labels (default control size on macOS)
    static let fontSizeBody: CGFloat = 11

    /// 13pt — emphasized body / subheaders
    static let fontSizeSubtitle: CGFloat = 13

    /// 15pt — section headers
    static let fontSizeHeader: CGFloat = 15

    /// 18pt — window / panel titles
    static let fontSizeTitle: CGFloat = 18

    /// 22pt — hero / branding
    static let fontSizeLargeTitle: CGFloat = 22

    // MARK: - Corner Radius Scale

    /// 4pt — buttons, small controls
    static let cornerRadiusSM: CGFloat = 4

    /// 6pt — cards, segmented controls
    static let cornerRadiusMD: CGFloat = 6

    /// 10pt — panels, modals
    static let cornerRadiusLG: CGFloat = 10

    /// 16pt — pill / circular elements
    static let cornerRadiusPill: CGFloat = 16

    // MARK: - Border Width

    static let borderHairline: CGFloat = 1.0
    static let borderEmphasis: CGFloat = 2.0

    // MARK: - Sidebar
    static let sidebarWidth: CGFloat = 220
    static let activePanelWidth: CGFloat = 220

    // MARK: - Logo
    static let logoWidth: CGFloat = 170
    static let logoHeight: CGFloat = 120

    // MARK: - Button Row
    static let buttonRowHeight: CGFloat = 50
    static let buttonWidth: CGFloat = 92  // Matches XIB defaults
    static let buttonHeight: CGFloat = 32
    static let buttonSpacing: CGFloat = 10

    // MARK: - Packet Panel
    static let packetPanelHeight: CGFloat = 180

    // MARK: - Padding
    /// Legacy 15pt padding — use `spacingLG` (16pt) for new code.
    static let standardPadding: CGFloat = 15

    // MARK: - Window
    static let minWindowWidth: CGFloat = 1150
    static let minWindowHeight: CGFloat = 600
    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 720

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

    // MARK: - VM Status Card
    static let vmCardWidth: CGFloat = 188
    static let vmCardHeight: CGFloat = 85

    // MARK: - Packet Analysis Window
    static let packetWindowWidth: CGFloat = 950
    static let packetWindowHeight: CGFloat = 700
    static let packetWindowMinWidth: CGFloat = 700
    static let packetWindowMinHeight: CGFloat = 500

    // MARK: - ISO Cache Window
    static let isoWindowWidth: CGFloat = 1000
    static let isoWindowHeight: CGFloat = 640
}
