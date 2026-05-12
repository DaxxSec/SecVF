//
//  ToolRegistry.swift
//  SecVFMCPCore
//
//  The set of tools the server exposes for a given CapabilityTier.
//  Centralizing the catalog here means there's exactly one place to look
//  to answer "what can the agent do at tier X?"
//
//  All tool descriptors are declared as static constants below. Adding a
//  new tool = adding a descriptor + including it in `allDescriptors`. The
//  filtering by tier is purely a category-min-tier check (see ToolCategory).
//

import Foundation

public struct ToolRegistry {
    public let tier: CapabilityTier
    public let descriptors: [ToolDescriptor]

    public init(tier: CapabilityTier, descriptors: [ToolDescriptor] = ToolRegistry.allDescriptors) {
        self.tier = tier
        self.descriptors = descriptors.filter { $0.isExposed(at: tier) }
    }

    /// The names of all tools exposed at the configured tier.
    public var exposedToolNames: Set<String> {
        Set(descriptors.map(\.name))
    }

    public func descriptor(named name: String) -> ToolDescriptor? {
        descriptors.first(where: { $0.name == name })
    }

    // MARK: - Catalog
    //
    // Every tool we ship is declared here. The capability tier filtering is
    // automatic from `category.minimumTier`. To add a tool: append a
    // descriptor below + implement the dispatcher in MCPServer.

    public static let allDescriptors: [ToolDescriptor] = [
        // === Discovery (read-only) ===
        ToolDescriptor(
            name: "secvf_vm_list",
            category: .discovery,
            direction: .input,  // host-only operation, no VM bytes flow in
            description: "List all VMs registered with SecVF. Returns metadata only (no VM-derived content)."
        ),
        ToolDescriptor(
            name: "secvf_vm_status",
            category: .discovery,
            direction: .input,
            description: "Detailed status for a single VM by name or id."
        ),
        ToolDescriptor(
            name: "secvf_switch_status",
            category: .discovery,
            direction: .input,
            description: "Virtual switch state: running flag, connected ports, learned MACs."
        ),
        ToolDescriptor(
            name: "secvf_capture_status",
            category: .discovery,
            direction: .input,
            description: "Packet capture state: running, started_at, packets_captured."
        ),
        ToolDescriptor(
            name: "secvf_iso_list",
            category: .discovery,
            direction: .input,
            description: "List cached ISO/IPSW images with SHA-256 and sizes."
        ),

        // === Forensics (read-only outputs from VMs/captures — UNTRUSTED) ===
        ToolDescriptor(
            name: "secvf_logs_security",
            category: .forensics,
            direction: .input,  // logs are host-written, host-controlled
            description: "Read security log entries by date range and severity."
        ),
        ToolDescriptor(
            name: "secvf_logs_network",
            category: .forensics,
            direction: .input,
            description: "Read virtual-switch network log entries."
        ),
        ToolDescriptor(
            name: "secvf_logs_audit",
            category: .forensics,
            direction: .input,
            description: "Read SecVF error audit log."
        ),
        ToolDescriptor(
            name: "secvf_packets_recent",
            category: .forensics,
            direction: .output,  // VM-derived content — UNTRUSTED
            description: "Most recent packet metadata captured on the virtual switch."
        ),
        ToolDescriptor(
            name: "secvf_packets_query",
            category: .forensics,
            direction: .output,  // UNTRUSTED
            description: "Query packets via Wireshark display filter."
        ),

        // === Lifecycle (safe-mutate) ===
        ToolDescriptor(
            name: "secvf_vm_start",
            category: .lifecycle,
            direction: .input,
            description: "Start a VM by name. Returns boot time."
        ),
        ToolDescriptor(
            name: "secvf_vm_stop",
            category: .lifecycle,
            direction: .input,
            description: "Graceful stop. Waits up to timeout_seconds for guest shutdown."
        ),
        ToolDescriptor(
            name: "secvf_vm_force_stop",
            category: .lifecycle,
            direction: .input,
            description: "Hard kill — bypasses guest shutdown."
        ),
        ToolDescriptor(
            name: "secvf_vm_pause",
            category: .lifecycle,
            direction: .input,
            description: "Pause a running VM (memory frozen)."
        ),
        ToolDescriptor(
            name: "secvf_vm_resume",
            category: .lifecycle,
            direction: .input,
            description: "Resume a paused VM."
        ),

        // === Capture (safe-mutate) ===
        ToolDescriptor(
            name: "secvf_capture_start",
            category: .capture,
            direction: .input,
            description: "Start capturing on the virtual switch."
        ),
        ToolDescriptor(
            name: "secvf_capture_stop",
            category: .capture,
            direction: .input,
            description: "Stop capture and finalize PCAP."
        ),

        // === Destructive (full tier only) ===
        ToolDescriptor(
            name: "secvf_vm_create",
            category: .destructive,
            direction: .input,
            description: "Create a new VM bundle. Destructive on disk (allocates space)."
        ),
        ToolDescriptor(
            name: "secvf_vm_clone",
            category: .destructive,
            direction: .input,
            description: "Clone an existing VM. Destructive on disk."
        ),
        ToolDescriptor(
            name: "secvf_vm_delete",
            category: .destructive,
            direction: .input,
            description: "Delete a VM bundle. Refuses if VM is running."
        ),
    ]
}
