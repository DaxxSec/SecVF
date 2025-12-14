//
//  ProtocolInfo.swift
//  SecVF
//
//  Type-safe network protocol information
//

import Cocoa

/// Describes a network protocol with its display properties
struct ProtocolInfo {
    /// Protocol name (e.g., "TCP", "UDP")
    let name: String

    /// Display color for the protocol
    let color: NSColor

    /// Common ports associated with this protocol (empty for transport protocols)
    let ports: [Int]

    /// Human-readable description
    let description: String

    // MARK: - Protocol Database

    /// All known protocols with their metadata
    static let all: [String: ProtocolInfo] = [
        "TCP": ProtocolInfo(
            name: "TCP",
            color: NetworkProtocolColors.color(for: "TCP"),
            ports: [],
            description: "Transmission Control Protocol - Connection-oriented reliable delivery"
        ),
        "UDP": ProtocolInfo(
            name: "UDP",
            color: NetworkProtocolColors.color(for: "UDP"),
            ports: [],
            description: "User Datagram Protocol - Connectionless unreliable delivery"
        ),
        "DNS": ProtocolInfo(
            name: "DNS",
            color: NetworkProtocolColors.color(for: "DNS"),
            ports: [53],
            description: "Domain Name System - Resolves hostnames to IP addresses"
        ),
        "HTTP": ProtocolInfo(
            name: "HTTP",
            color: NetworkProtocolColors.color(for: "HTTP"),
            ports: [80, 8080],
            description: "Hypertext Transfer Protocol - Web traffic"
        ),
        "HTTPS": ProtocolInfo(
            name: "HTTPS",
            color: NetworkProtocolColors.color(for: "HTTPS"),
            ports: [443],
            description: "HTTP Secure - Encrypted web traffic"
        ),
        "SSH": ProtocolInfo(
            name: "SSH",
            color: NetworkProtocolColors.color(for: "SSH"),
            ports: [22],
            description: "Secure Shell - Encrypted remote access"
        ),
        "ARP": ProtocolInfo(
            name: "ARP",
            color: NetworkProtocolColors.color(for: "ARP"),
            ports: [],
            description: "Address Resolution Protocol - Maps IP to MAC addresses"
        ),
        "ICMP": ProtocolInfo(
            name: "ICMP",
            color: NetworkProtocolColors.color(for: "ICMP"),
            ports: [],
            description: "Internet Control Message Protocol - Network diagnostics (ping)"
        ),
        "TLS": ProtocolInfo(
            name: "TLS",
            color: NetworkProtocolColors.color(for: "TLS"),
            ports: [],
            description: "Transport Layer Security - Encryption layer"
        ),
        "FTP": ProtocolInfo(
            name: "FTP",
            color: NetworkProtocolColors.color(for: "FTP"),
            ports: [20, 21],
            description: "File Transfer Protocol"
        ),
        "SMTP": ProtocolInfo(
            name: "SMTP",
            color: NetworkProtocolColors.color(for: "SMTP"),
            ports: [25, 587],
            description: "Simple Mail Transfer Protocol - Email sending"
        ),
        "DHCP": ProtocolInfo(
            name: "DHCP",
            color: NetworkProtocolColors.color(for: "DHCP"),
            ports: [67, 68],
            description: "Dynamic Host Configuration Protocol - IP address assignment"
        ),
        "NTP": ProtocolInfo(
            name: "NTP",
            color: NetworkProtocolColors.color(for: "NTP"),
            ports: [123],
            description: "Network Time Protocol - Time synchronization"
        )
    ]

    // MARK: - Lookup

    /// Look up protocol information by name
    /// - Parameter name: Protocol name (case-insensitive)
    /// - Returns: ProtocolInfo if found, nil otherwise
    static func lookup(_ name: String) -> ProtocolInfo? {
        return all[name.uppercased()]
    }

    /// Get the color for a protocol (convenience method)
    /// - Parameter name: Protocol name
    /// - Returns: The display color for the protocol
    static func color(for name: String) -> NSColor {
        return lookup(name)?.color ?? NetworkProtocolColors.color(for: name)
    }

    /// Get the description for a protocol
    /// - Parameter name: Protocol name
    /// - Returns: Human-readable description or generic text
    static func description(for name: String) -> String {
        return lookup(name)?.description ?? "Unknown protocol"
    }
}
