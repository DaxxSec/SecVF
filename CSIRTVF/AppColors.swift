//
//  AppColors.swift
//  SecVF
//
//  Centralized color definitions for consistent theming
//

import Cocoa

/// Centralized color palette for the SecVF cybersecurity theme
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

    // MARK: - Border Colors

    /// Subtle cyan grid/border (0.0, 0.6, 0.8) at 30% opacity
    static let borderCyan = NSColor(red: 0.0, green: 0.6, blue: 0.8, alpha: 0.3)

    /// Yellow border for warnings (0.8, 0.6, 0.0) at 40% opacity
    static let borderYellow = NSColor(red: 0.8, green: 0.6, blue: 0.0, alpha: 0.4)

    // MARK: - Status Colors

    /// Running VM status - green (0.0, 1.0, 0.6)
    static let statusRunning = NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)

    /// Paused VM status - yellow (1.0, 0.8, 0.0)
    static let statusPaused = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    /// Stopped VM status - grey (0.6, 0.6, 0.6)
    static let statusStopped = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)

    // MARK: - Network Security Colors

    /// Isolated/Virtual network - safe green (0.0, 0.8, 0.4)
    static let networkIsolated = NSColor(red: 0.0, green: 0.8, blue: 0.4, alpha: 1.0)

    /// NAT network - warning red (0.95, 0.25, 0.25)
    static let networkNAT = NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1.0)

    // MARK: - Text Colors

    /// Light text (0.8, 0.8, 0.8)
    static let textLight = NSColor(white: 0.8, alpha: 1.0)

    /// Muted text (0.6, 0.6, 0.6)
    static let textMuted = NSColor(white: 0.6, alpha: 1.0)

    /// Cyan text for highlights
    static let textCyan = NSColor(red: 0.3, green: 0.8, blue: 0.9, alpha: 1.0)
}
