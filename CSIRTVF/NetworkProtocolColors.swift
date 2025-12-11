//
//  NetworkProtocolColors.swift
//  SecVF
//
//  Centralized protocol color mapping for packet display
//

import Cocoa

/// Provides consistent color mapping for network protocols
struct NetworkProtocolColors {

    /// Get the display color for a network protocol
    /// - Parameter proto: The protocol name (e.g., "TCP", "UDP", "DNS")
    /// - Returns: The NSColor for displaying that protocol
    static func color(for proto: String) -> NSColor {
        switch proto.uppercased() {
        case "TCP":
            return NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)   // Light blue
        case "UDP":
            return NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1.0)   // Light green
        case "HTTP", "HTTPS":
            return NSColor(red: 0.0, green: 1.0, blue: 0.6, alpha: 1.0)   // Neon green
        case "DNS":
            return NSColor(red: 1.0, green: 1.0, blue: 0.4, alpha: 1.0)   // Yellow
        case "ARP":
            return NSColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1.0)   // Orange
        case "ICMP":
            return NSColor(red: 1.0, green: 0.4, blue: 0.8, alpha: 1.0)   // Pink
        case "TLS", "SSL":
            return NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)   // Purple
        case "IPV6":
            return NSColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1.0)   // Purple
        case "SSH":
            return NSColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1.0)   // Sky blue
        case "FTP":
            return NSColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0)   // Gold
        case "SMTP", "IMAP", "POP3":
            return NSColor(red: 0.8, green: 0.4, blue: 0.6, alpha: 1.0)   // Mauve
        case "NTP":
            return NSColor(red: 0.6, green: 0.6, blue: 0.9, alpha: 1.0)   // Lavender
        case "DHCP":
            return NSColor(red: 0.4, green: 0.9, blue: 0.9, alpha: 1.0)   // Teal
        default:
            return NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1.0)   // Default cyan
        }
    }

    /// All supported protocol names for legend display
    static let supportedProtocols = ["TCP", "UDP", "HTTP", "DNS", "ARP", "ICMP", "TLS"]
}
