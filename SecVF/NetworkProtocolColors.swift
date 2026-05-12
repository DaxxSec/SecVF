//
//  NetworkProtocolColors.swift
//  SecVF
//
//  Centralized protocol color mapping for packet display.
//  All color values source from `AppColors.proto*` so the legend, packet
//  log row tints, and sparkline shading stay in lock-step with the
//  tactical palette.
//

import Cocoa

/// Provides consistent color mapping for network protocols.
struct NetworkProtocolColors {

    /// Get the display color for a network protocol.
    /// - Parameter proto: The protocol name (e.g., "TCP", "UDP", "DNS").
    /// - Returns: The NSColor for displaying that protocol. Falls back to
    ///   `AppColors.textOD` for any unrecognized protocol so unknown rows
    ///   stay in the OD family rather than introducing a stray hue.
    static func color(for proto: String) -> NSColor {
        switch proto.uppercased() {
        case "TCP":             return AppColors.protoTCP
        case "UDP":             return AppColors.protoUDP
        case "HTTP", "HTTPS":   return AppColors.protoHTTP
        case "DNS":             return AppColors.protoDNS
        case "ARP":             return AppColors.protoARP
        case "ICMP":            return AppColors.protoICMP
        case "TLS", "SSL":      return AppColors.protoTLS
        case "IPV6":            return AppColors.protoIPv6
        // Lesser-seen protocols share the IPv6 / ARP families since we
        // don't have dedicated tokens for them. Keeps the palette tight.
        case "SSH":             return AppColors.protoTCP        // TCP-coded
        case "FTP":             return AppColors.protoUDP        // soft contrast
        case "SMTP", "IMAP", "POP3": return AppColors.accentPurple
        case "NTP":             return AppColors.protoIPv6       // purple family
        case "DHCP":            return AppColors.accentTeal
        default:                return AppColors.textOD
        }
    }

    /// All supported protocol names for legend display
    static let supportedProtocols = ["TCP", "UDP", "HTTP", "DNS", "ARP", "ICMP", "TLS"]
}
