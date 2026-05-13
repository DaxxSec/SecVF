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
    ///
    /// Filter strings target the `PacketFilter` expression parser (parens
    /// + `port == N` + `length > N` etc.), NOT the old flat substring
    /// engine. Titles describe what the filter actually matches —
    /// presets that overpromise relative to what the parser can detect
    /// have been honestly renamed to "(inspect manually)" so the
    /// operator's expectations match reality. Issue #11 tracks the
    /// gap between these and full Wireshark semantics.
    static let sections: [Section] = [
        Section(title: "── C2 DETECTION ──", presets: [
            Preset(title: "Non-Apple DNS (Suspicious)",
                   filter: "dns and not apple and not icloud"),
            Preset(title: "Direct IP Connections (No DNS)",
                   filter: "tcp and not dns and not arp"),
            // Leading `.` in the substrings + parens make this honest:
            // matches DNS packets whose info contains the literal ".tk"
            // / ".ml" / ".ga" / ".cf" / ".gq" rather than every packet
            // whose info contains those two letters anywhere.
            Preset(title: "Suspicious TLDs (.tk/.ml/.ga/.cf)",
                   filter: #"dns and (info contains ".tk" or info contains ".ml" or info contains ".ga" or info contains ".cf" or info contains ".gq")"#),
            Preset(title: "HTTP (inspect for non-browser UA manually)",
                   filter: "http"),
            // Now actually correct: numeric port comparison, not
            // substring match. Port 8080 / 5300 / 4430 etc. correctly
            // pass through this filter.
            Preset(title: "Non-Standard Ports",
                   filter: "tcp and port != 80 and port != 443 and port != 22 and port != 53"),
            Preset(title: "TCP (inspect for short-connection beacons manually)",
                   filter: "tcp"),
        ]),
        Section(title: "── DATA EXFIL ──", presets: [
            // Length predicate makes these match what the title says:
            // unusually-long DNS queries / large TCP / ICMP-with-payload.
            Preset(title: "DNS Tunneling (Long Queries)",
                   filter: "dns and length > 100"),
            Preset(title: "Large Outbound Transfers",
                   filter: "tcp and length > 1000"),
            Preset(title: "ICMP with Payload (Covert Channel)",
                   filter: "icmp and length > 64"),
            Preset(title: "HTTP (inspect for base64 payloads manually)",
                   filter: "http"),
        ]),
        Section(title: "── TLS ANALYSIS ──", presets: [
            // The engine can't distinguish "handshake" / "self-signed" /
            // "without-SNI" / "cert exchange" without per-packet TLS
            // record inspection. Collapse to one honest entry and one
            // inspection-prompt entry.
            Preset(title: "All TLS / SSL",
                   filter: "tls or ssl"),
            Preset(title: "TLS (inspect handshake/SNI/certs manually)",
                   filter: "tls or ssl"),
        ]),
        Section(title: "── RECON & SCANNING ──", presets: [
            Preset(title: "TCP (inspect for SYN-flood patterns manually)",
                   filter: "tcp"),
            Preset(title: "ARP Requests (Host Discovery)",
                   filter: "arp"),
            Preset(title: "ICMP Echo (Ping Sweep)",
                   filter: "icmp"),
            Preset(title: "SMB Enumeration",
                   filter: "smb or port == 445 or port == 139"),
        ]),
        Section(title: "── LATERAL MOVEMENT ──", presets: [
            Preset(title: "SSH Traffic",
                   filter: "port == 22 or ssh"),
            Preset(title: "Remote Desktop (RDP/VNC)",
                   filter: "port == 3389 or port == 5900 or port == 5901"),
            Preset(title: "File Sharing (SMB/AFP)",
                   filter: "smb or afp or port == 445 or port == 548"),
        ]),
        Section(title: "── PROTOCOLS ──", presets: [
            Preset(title: "All DNS Traffic",
                   filter: "dns"),
            Preset(title: "All HTTP/HTTPS",
                   filter: "http or https or port == 80 or port == 443"),
            Preset(title: "All TCP",
                   filter: "tcp"),
            Preset(title: "All UDP",
                   filter: "udp"),
            Preset(title: "All ARP",
                   filter: "arp"),
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
