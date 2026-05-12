//
//  AppColors.swift
//  SecVF
//
//  Centralized color palette for the SecVF cybersecurity theme.
//  Use these tokens instead of inline NSColor literals so colors stay consistent.
//

import Cocoa

/// Centralized color palette for the SecVF cybersecurity theme.
///
/// **Hue strategy:**
/// - Cyan = primary brand / interactive
/// - Green = safe / running / isolated
/// - Yellow = paused / warning
/// - Red = NAT / danger / stop
/// - Magenta/Purple = AI / sandbox installs
/// - Orange = HTTP / external traffic
enum AppColors {

    // MARK: - Background Colors

    /// Deep black background (0.05, 0.05, 0.08)
    static let backgroundPrimary = NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0)

    /// Darker grey background for tables (0.08, 0.08, 0.12)
    static let backgroundSecondary = NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)

    /// Charcoal background for toolbar (0.06, 0.06, 0.10)
    static let backgroundTertiary = NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0)

    /// Button background color (0.15, 0.15, 0.2)
    static let backgroundButton = NSColor(red: 0.15, green: 0.15, blue: 0.2, alpha: 1.0)

    /// Button background — hovered/highlighted (0.20, 0.20, 0.26)
    static let backgroundButtonHover = NSColor(red: 0.20, green: 0.20, blue: 0.26, alpha: 1.0)

    /// Slightly darker than secondary — for nested panels (0.04, 0.04, 0.08)
    static let backgroundPanel = NSColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1.0)

    // MARK: - Gradient Colors (Sidebar)

    /// Gradient top - Deep black (0.03, 0.03, 0.06)
    static let gradientTop = NSColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1.0)

    /// Gradient bottom - Charcoal with blue tint (0.06, 0.08, 0.12)
    static let gradientBottom = NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)

    // MARK: - Accent Colors

    /// Primary cyan accent (0.0, 0.7, 0.9)
    static let accentCyan = NSColor(red: 0.0, green: 0.7, blue: 0.9, alpha: 1.0)

    /// Neon cyan for titles (0.0, 0.9, 1.0)
    static let accentNeonCyan = NSColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 1.0)

    /// Neon green (0.0, 1.0, 0.6)
    static let accentNeonGreen = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)

    /// Olive green for VF branding (0.5, 0.85, 0.3)
    static let accentOliveGreen = NSColor(red: 0.5, green: 0.85, blue: 0.3, alpha: 1.0)

    /// Danger / destructive red (0.95, 0.35, 0.35)
    static let accentRed = NSColor(red: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)

    /// Warning yellow (1.0, 0.8, 0.0)
    static let accentYellow = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    /// Orange — HTTP / external (1.0, 0.6, 0.3)
    static let accentOrange = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)

    /// Magenta — AI sandbox / install progress (0.78, 0.30, 0.95)
    static let accentMagenta = NSColor(red: 0.78, green: 0.30, blue: 0.95, alpha: 1.0)

    /// Purple — IPv6 / secondary protocol (0.8, 0.6, 1.0)
    static let accentPurple = NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)

    /// Teal — TLS / encrypted (0.3, 1.0, 0.8)
    static let accentTeal = NSColor(red: 0.3, green: 1.0, blue: 0.8, alpha: 1.0)

    // MARK: - Border Colors

    /// Subtle cyan grid/border (0.0, 0.6, 0.8) at 30% opacity
    static let borderCyan = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.3)

    /// Stronger cyan border for emphasis (50% opacity)
    static let borderCyanEmphasis = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.5)

    /// Yellow border for warnings (0.8, 0.6, 0.0) at 40% opacity
    static let borderYellow = NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 0.4)

    /// Magenta border for install progress (65% opacity)
    static let borderMagenta = NSColor(red: 0.78, green: 0.30, blue: 0.95, alpha: 0.65)

    /// Red border for danger / NAT mode (50% opacity)
    static let borderRed = NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 0.5)

    // MARK: - Status Colors

    /// Running VM status - green (0.0, 1.0, 0.6)
    static let statusRunning = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)

    /// Paused VM status - yellow (1.0, 0.8, 0.0)
    static let statusPaused = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    /// Stopped VM status - grey (0.6, 0.6, 0.6)
    static let statusStopped = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)

    /// Error VM status - red (1.0, 0.5, 0.5)
    static let statusError = NSColor(red: 1.0, green: 0.5, blue: 0.5, alpha: 1.0)

    // MARK: - Network Security Colors

    /// Isolated/Virtual network - safe green (0.0, 0.8, 0.4)
    static let networkIsolated = NSColor(red: 0.0, green: 0.8, blue: 0.4, alpha: 1.0)

    /// NAT network - warning red (0.95, 0.25, 0.25)
    static let networkNAT = NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1.0)

    // MARK: - Text Colors

    /// High-contrast title text (0.92, 0.92, 0.95)
    static let textPrimary = NSColor(white: 0.92, alpha: 1.0)

    /// Light text (0.8, 0.8, 0.8)
    static let textLight = NSColor(white: 0.8, alpha: 1.0)

    /// Muted text (0.6, 0.6, 0.6)
    static let textMuted = NSColor(white: 0.6, alpha: 1.0)

    /// Subtle text — captions, footnotes (0.45, 0.45, 0.50)
    static let textSubtle = NSColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 1.0)

    /// Cyan text for highlights
    static let textCyan = NSColor(red: 0.3, green: 0.8, blue: 0.9, alpha: 1.0)

    // MARK: - Protocol Colors (Packet Capture)
    //
    // Used by the protocol legend and per-packet row tinting. Keep these in sync
    // with the legend rendered by VMLibraryWindowController.

    static let protoTCP   = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)   // Cyan
    static let protoUDP   = NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)   // Green
    static let protoDNS   = NSColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1.0)   // Yellow
    static let protoHTTP  = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)   // Orange
    static let protoARP   = NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1.0)   // Gray
    static let protoICMP  = NSColor(red: 1.0, green: 0.5, blue: 0.5, alpha: 1.0)   // Red/Pink
    static let protoIPv6  = NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)   // Purple
    static let protoTLS   = NSColor(red: 0.3, green: 1.0, blue: 0.8, alpha: 1.0)   // Teal
}
