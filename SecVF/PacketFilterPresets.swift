//
//  PacketFilterPresets.swift
//  SecVF
//
//  Centralized malware-analysis filter preset catalog. Used by:
//   - PacketAnalysisWindowController (deep-filter dropdown)
//   - VMLibraryWindowController (Filter button in the LIVE TRAFFIC panel)
//
//  Each preset has a human-readable title, a section header, and a
//  packet-filter expression that the consuming view applies to its
//  packet display.
//

import Cocoa

enum PacketFilterPresets {

    /// A logical grouping of presets (used as a menu section header).
    struct Section {
        let title: String       // displayed as a disabled menu item ("── C2 DETECTION ──")
        let presets: [Preset]
    }

    /// A single filter preset. `filter` is the expression applied to
    /// PacketAnalysisWindowController's currentFilter / display logic.
    struct Preset {
        let title: String       // displayed as the menu item label
        let filter: String      // lowercased filter expression
    }

    /// The full catalog, ordered for menu display.
    static let sections: [Section] = [
        Section(title: "── C2 DETECTION ──", presets: [
            Preset(title: "Non-Apple DNS (Suspicious)",      filter: "dns and not apple and not icloud"),
            Preset(title: "Direct IP Connections (No DNS)",  filter: "tcp and not dns and not arp"),
            Preset(title: "Suspicious TLDs (.tk/.ml/.ga/.cf)", filter: "dns and (tk or ml or ga or cf or gq)"),
            Preset(title: "Non-Browser HTTP (curl/wget/python)", filter: "http"),
            Preset(title: "Non-Standard Ports",              filter: "tcp and not 80 and not 443 and not 22 and not 53"),
            Preset(title: "Short TCP Connections (Beacon)",  filter: "tcp"),
        ]),
        Section(title: "── DATA EXFIL ──", presets: [
            Preset(title: "DNS Tunneling (Long Queries)",    filter: "dns"),
            Preset(title: "Large Outbound Transfers",        filter: "tcp"),
            Preset(title: "ICMP with Payload (Covert Channel)", filter: "icmp"),
            Preset(title: "Base64 in HTTP",                  filter: "http"),
        ]),
        Section(title: "── TLS ANALYSIS ──", presets: [
            Preset(title: "TLS Handshakes Only",             filter: "tls or ssl"),
            Preset(title: "Self-Signed Certificates",        filter: "tls or ssl"),
            Preset(title: "TLS Without SNI (Hidden Dest)",   filter: "tls or ssl"),
            Preset(title: "Certificate Exchange",            filter: "tls or ssl"),
        ]),
        Section(title: "── RECON & SCANNING ──", presets: [
            Preset(title: "Port Scanning (SYN Flood)",       filter: "tcp"),
            Preset(title: "ARP Requests (Host Discovery)",   filter: "arp"),
            Preset(title: "ICMP Echo (Ping Sweep)",          filter: "icmp"),
            Preset(title: "SMB Enumeration",                 filter: "smb or tcp 445 or tcp 139"),
        ]),
        Section(title: "── LATERAL MOVEMENT ──", presets: [
            Preset(title: "SSH Traffic",                     filter: "tcp 22 or ssh"),
            Preset(title: "Remote Desktop (RDP/VNC)",        filter: "tcp 3389 or tcp 5900 or tcp 5901"),
            Preset(title: "File Sharing (SMB/AFP)",          filter: "smb or afp or tcp 445 or tcp 548"),
        ]),
        Section(title: "── PROTOCOLS ──", presets: [
            Preset(title: "All DNS Traffic",   filter: "dns"),
            Preset(title: "All HTTP/HTTPS",    filter: "http or https or tcp 80 or tcp 443"),
            Preset(title: "All TCP",           filter: "tcp"),
            Preset(title: "All UDP",           filter: "udp"),
            Preset(title: "All ARP",           filter: "arp"),
        ]),
    ]

    /// Look up the filter expression for a given preset title. Returns nil
    /// if the title isn't a recognized preset.
    static func filter(for title: String) -> String? {
        for section in sections {
            if let p = section.presets.first(where: { $0.title == title }) {
                return p.filter
            }
        }
        return nil
    }

    /// Build a fresh NSMenu populated with all presets, grouped under
    /// disabled section headers and separated by NSMenuItem.separator(). The
    /// caller is responsible for showing the menu (popUp / contextMenu /
    /// addItem to an NSPopUpButton).
    ///
    /// - Parameter target: the action target for each preset menu item.
    /// - Parameter action: the selector invoked when the user picks a preset.
    ///   The menu item's `title` carries the preset name; the handler can
    ///   look up the filter via `PacketFilterPresets.filter(for:)`.
    static func buildMenu(target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Malware Analysis Filters")
        populateMenu(menu, target: target, action: action)
        return menu
    }

    /// Append preset items onto an existing menu (e.g. an NSPopUpButton's
    /// own menu so the popup's title item is preserved). Avoids the
    /// allocate-a-fresh-menu-and-copy-every-item dance that buildMenu
    /// callers used to do.
    static func populateMenu(_ menu: NSMenu,
                             target: AnyObject?,
                             action: Selector) {
        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for preset in section.presets {
                let item = NSMenuItem(title: preset.title, action: action, keyEquivalent: "")
                item.target = target
                menu.addItem(item)
            }
        }
    }
}
