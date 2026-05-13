//
//  AppColors.swift
//  SecVF
//
//  Centralized color palette for the SecVF tactical theme.
//  Use these tokens instead of inline NSColor literals so colors stay consistent.
//

import Cocoa

/// Centralized color palette for the SecVF tactical theme.
///
/// **Palette family:** dark gun-metal grey base + OD (olive drab) green +
/// safety orange. Reads like SOC / red-team operator tooling (Burp Suite,
/// Metasploit, terminal-heavy SIEMs) rather than consumer cyberpunk.
///
/// **Hue strategy:**
/// - **OD green** = primary / operational / "go" / running state
/// - **Orange** = attention / live data / hot accents
/// - **Amber** = caution / paused
/// - **Red** = destructive / errors / NAT egress (deliberately dangerous)
/// - **Slate grey** = nominal / inactive / muted text
/// - **Magenta** = AI sandbox / install progress (reserved, rarely used)
///
/// **Naming compatibility:** Token names that historically referred to
/// "cyan" (accentCyan, accentNeonCyan, borderCyan…) are kept and re-aliased
/// to the OD palette. This lets the existing UI code adopt the new palette
/// without a sweeping rename, and matches the mockup at
/// docs/ui-redesign-mockup.html where the same trick is used in CSS.
enum AppColors {

    // MARK: - Background Colors

    /// App canvas — dark gun-metal (0.082, 0.094, 0.122)
    static let backgroundPrimary = NSColor(red: 0.082, green: 0.094, blue: 0.122, alpha: 1.0)

    /// Panel background — slightly lighter than canvas (0.094, 0.110, 0.141)
    static let backgroundSecondary = NSColor(red: 0.094, green: 0.110, blue: 0.141, alpha: 1.0)

    /// Toolbar / chrome background (0.106, 0.122, 0.153)
    static let backgroundTertiary = NSColor(red: 0.106, green: 0.122, blue: 0.153, alpha: 1.0)

    /// Button resting background (0.130, 0.149, 0.192)
    static let backgroundButton = NSColor(red: 0.130, green: 0.149, blue: 0.192, alpha: 1.0)

    /// Button hover state (0.165, 0.188, 0.243)
    static let backgroundButtonHover = NSColor(red: 0.165, green: 0.188, blue: 0.243, alpha: 1.0)

    /// Nested panel (slightly darker than secondary) (0.071, 0.082, 0.106)
    static let backgroundPanel = NSColor(red: 0.071, green: 0.082, blue: 0.106, alpha: 1.0)

    /// Selected table row — OD-tinted so selection feels "operational"
    /// (0.165, 0.204, 0.141)
    static let backgroundRowSelected = NSColor(red: 0.165, green: 0.204, blue: 0.141, alpha: 1.0)

    /// Hovered row (0.149, 0.173, 0.220)
    static let backgroundRowHover = NSColor(red: 0.149, green: 0.173, blue: 0.220, alpha: 1.0)

    // MARK: - Gradient Colors (Sidebar)

    /// Sidebar gradient top (0.039, 0.051, 0.082)
    static let gradientTop = NSColor(red: 0.039, green: 0.051, blue: 0.082, alpha: 1.0)

    /// Sidebar gradient bottom (0.051, 0.075, 0.125)
    static let gradientBottom = NSColor(red: 0.051, green: 0.075, blue: 0.125, alpha: 1.0)

    // MARK: - Accent Colors
    //
    // The "cyan" names are kept for code-call-site compatibility and now
    // resolve to OD green. New code should prefer the `accentOD*` aliases
    // below; both point at the same NSColor instance.

    /// Primary OD-green accent — the "cyan" of the old palette
    /// (0.561, 0.651, 0.325) ≈ #8FA653
    static let accentCyan = NSColor(red: 0.561, green: 0.651, blue: 0.325, alpha: 1.0)
    /// Semantic alias — prefer in new code
    static let accentOD = accentCyan

    /// Bright OD highlight / glow (0.659, 0.769, 0.431) ≈ #A8C46E
    static let accentNeonCyan = NSColor(red: 0.659, green: 0.769, blue: 0.431, alpha: 1.0)
    /// Semantic alias — prefer in new code
    static let accentODGlow = accentNeonCyan

    /// Running-state green — slightly more saturated than the OD primary
    /// (0.478, 0.690, 0.369) ≈ #7AB05E
    static let accentNeonGreen = NSColor(red: 0.478, green: 0.690, blue: 0.369, alpha: 1.0)

    /// Deprecated lime VF accent — kept for any stragglers, redirected to OD
    static let accentOliveGreen = accentNeonCyan

    /// Destructive / danger / error (1.0, 0.36, 0.36) ≈ #FF5C5C
    static let accentRed = NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1.0)

    /// Caution amber — paused state, warnings (0.961, 0.710, 0.267) ≈ #F5B544
    static let accentYellow = NSColor(red: 0.961, green: 0.710, blue: 0.267, alpha: 1.0)

    /// Safety orange — primary attention / hot accents / live data
    /// (0.914, 0.459, 0.125) ≈ #E97520
    static let accentOrange = NSColor(red: 0.914, green: 0.459, blue: 0.125, alpha: 1.0)

    /// Hot orange — pulse dots, live capture indicators, traffic spikes
    /// (1.0, 0.616, 0.235) ≈ #FF9D3C
    static let accentOrangeHot = NSColor(red: 1.0, green: 0.616, blue: 0.235, alpha: 1.0)

    /// Magenta — AI sandbox / install progress (0.773, 0.345, 0.953) ≈ #C558F3
    static let accentMagenta = NSColor(red: 0.773, green: 0.345, blue: 0.953, alpha: 1.0)

    /// Purple — IPv6 protocol, secondary accent (0.655, 0.545, 1.0) ≈ #A78BFF
    static let accentPurple = NSColor(red: 0.655, green: 0.545, blue: 1.0, alpha: 1.0)

    /// Teal — kept token but de-emphasized in tactical palette
    static let accentTeal = NSColor(red: 0.424, green: 0.949, blue: 0.784, alpha: 1.0)

    // MARK: - Border Colors

    /// Subtle OD border (re-aliased from old "borderCyan")
    /// (0.561, 0.651, 0.325) at 35% opacity
    static let borderCyan = NSColor(red: 0.561, green: 0.651, blue: 0.325, alpha: 0.35)
    /// Semantic alias
    static let borderOD = borderCyan

    /// Stronger OD border for emphasis (55% opacity)
    static let borderCyanEmphasis = NSColor(red: 0.659, green: 0.769, blue: 0.431, alpha: 0.55)
    /// Semantic alias
    static let borderODEmphasis = borderCyanEmphasis

    /// Amber border for warnings (40% opacity)
    static let borderYellow = NSColor(red: 0.961, green: 0.710, blue: 0.267, alpha: 0.40)

    /// Orange border for live / hot accents (45% opacity)
    static let borderOrange = NSColor(red: 0.914, green: 0.459, blue: 0.125, alpha: 0.45)

    /// Magenta border for AI install progress (65% opacity)
    static let borderMagenta = NSColor(red: 0.773, green: 0.345, blue: 0.953, alpha: 0.65)

    /// Red border for danger / NAT egress / destructive (50% opacity)
    static let borderRed = NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 0.50)

    // MARK: - Status Colors

    /// Running VM status — OD-saturated green
    static let statusRunning = accentNeonGreen

    /// Paused VM status — caution amber
    static let statusPaused = accentYellow

    /// Stopped VM status — slate grey (0.522, 0.553, 0.612)
    static let statusStopped = NSColor(red: 0.522, green: 0.553, blue: 0.612, alpha: 1.0)

    /// Error VM status — red
    static let statusError = accentRed

    // MARK: - Network Security Colors

    /// Isolated/Virtual network — safe OD green
    static let networkIsolated = accentNeonGreen

    /// NAT network — warning red (egress to host network is risky for malware work)
    static let networkNAT = NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1.0)

    // MARK: - Text Colors

    /// Title text (0.910, 0.922, 0.941)
    static let textPrimary = NSColor(red: 0.910, green: 0.922, blue: 0.941, alpha: 1.0)

    /// Body text (white 0.85)
    static let textLight = NSColor(white: 0.85, alpha: 1.0)

    /// Muted text (white 0.62)
    static let textMuted = NSColor(white: 0.62, alpha: 1.0)

    /// Subtle text — captions, footnotes (0.365, 0.384, 0.427)
    static let textSubtle = NSColor(red: 0.365, green: 0.384, blue: 0.427, alpha: 1.0)

    /// OD-tinted text accent (re-aliased from old "textCyan")
    /// (0.710, 0.788, 0.478) ≈ #B5C97A
    static let textCyan = NSColor(red: 0.710, green: 0.788, blue: 0.478, alpha: 1.0)
    /// Semantic alias
    static let textOD = textCyan

    // MARK: - Protocol Colors (Packet Capture)
    //
    // Re-tuned for the tactical palette so cyan disappears entirely. The
    // packet legend, per-row tinting, and protocol summary chart all read
    // from these tokens — a single source of truth.

    /// TCP — OD green
    static let protoTCP   = NSColor(red: 0.659, green: 0.769, blue: 0.431, alpha: 1.0)
    /// UDP — light OD
    static let protoUDP   = NSColor(red: 0.792, green: 0.863, blue: 0.573, alpha: 1.0)
    /// DNS — amber (queries deserve attention)
    static let protoDNS   = NSColor(red: 0.961, green: 0.710, blue: 0.267, alpha: 1.0)
    /// HTTP — hot orange (cleartext, sus)
    static let protoHTTP  = NSColor(red: 1.0,   green: 0.616, blue: 0.235, alpha: 1.0)
    /// ARP — slate
    static let protoARP   = NSColor(red: 0.667, green: 0.698, blue: 0.753, alpha: 1.0)
    /// ICMP — red (often used for covert channels)
    static let protoICMP  = NSColor(red: 1.0,   green: 0.361, blue: 0.361, alpha: 1.0)
    /// IPv6 — magenta
    static let protoIPv6  = NSColor(red: 0.773, green: 0.345, blue: 0.953, alpha: 1.0)
    /// TLS — safety orange (encrypted, but worth eyeballing)
    static let protoTLS   = NSColor(red: 0.914, green: 0.459, blue: 0.125, alpha: 1.0)
}
