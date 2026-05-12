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
            description: "List all VMs registered with SecVF. Returns metadata only (no VM-derived content).",
            inputSchema: .empty
        ),
        ToolDescriptor(
            name: "secvf_vm_status",
            category: .discovery,
            direction: .input,
            description: "Detailed status for a single VM by name or id.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name (preferred) or id"),
                ],
                required: ["vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_switch_status",
            category: .discovery,
            direction: .input,
            description: "Virtual switch state: running flag, connected ports, learned MACs.",
            inputSchema: .empty
        ),
        ToolDescriptor(
            name: "secvf_capture_status",
            category: .discovery,
            direction: .input,
            description: "Packet capture state: running, started_at, packets_captured.",
            inputSchema: .empty
        ),
        ToolDescriptor(
            name: "secvf_iso_list",
            category: .discovery,
            direction: .input,
            description: "List cached ISO/IPSW images with SHA-256 and sizes.",
            inputSchema: .empty
        ),

        // === Forensics (read-only outputs from VMs/captures — UNTRUSTED) ===
        ToolDescriptor(
            name: "secvf_logs_security",
            category: .forensics,
            direction: .input,  // logs are host-written, host-controlled
            description: "Read security log entries by date range and severity.",
            inputSchema: InputSchema(
                properties: [
                    "since": InputSchemaProperty(type: "string", description: "ISO-8601 timestamp; only entries on/after this time"),
                    "until": InputSchemaProperty(type: "string", description: "ISO-8601 timestamp; only entries before this time"),
                    "severity": InputSchemaProperty(type: "string", description: "info | warning | critical | emergency"),
                    "vm": InputSchemaProperty(type: "string", description: "Filter by VM name"),
                    "limit": InputSchemaProperty(type: "integer", description: "Max entries to return (default 50, cap 500)"),
                ]
            )
        ),
        ToolDescriptor(
            name: "secvf_logs_network",
            category: .forensics,
            direction: .input,
            description: "Read virtual-switch network log entries.",
            inputSchema: InputSchema(
                properties: [
                    "since": InputSchemaProperty(type: "string", description: "ISO-8601 timestamp"),
                    "limit": InputSchemaProperty(type: "integer", description: "Max entries"),
                ]
            )
        ),
        ToolDescriptor(
            name: "secvf_logs_audit",
            category: .forensics,
            direction: .input,
            description: "Read SecVF error audit log.",
            inputSchema: InputSchema(
                properties: [
                    "limit": InputSchemaProperty(type: "integer", description: "Max entries"),
                ]
            )
        ),
        ToolDescriptor(
            name: "secvf_packets_recent",
            category: .forensics,
            direction: .output,  // VM-derived content — UNTRUSTED
            description: "Most recent packet metadata captured on the virtual switch.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "Filter by source VM"),
                    "limit": InputSchemaProperty(type: "integer", description: "Max packets (default 50)"),
                ]
            )
        ),
        ToolDescriptor(
            name: "secvf_packets_query",
            category: .forensics,
            direction: .output,  // UNTRUSTED
            description: "Query packets via Wireshark display filter.",
            inputSchema: InputSchema(
                properties: [
                    "filter": InputSchemaProperty(type: "string", description: "Wireshark display filter expression (e.g. 'http or dns')"),
                    "limit": InputSchemaProperty(type: "integer", description: "Max matches"),
                ],
                required: ["filter"]
            )
        ),

        // === Lifecycle (safe-mutate) ===
        ToolDescriptor(
            name: "secvf_vm_start",
            category: .lifecycle,
            direction: .input,
            description: "Start a VM by name. Returns boot time.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                ],
                required: ["vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_stop",
            category: .lifecycle,
            direction: .input,
            description: "Graceful stop. Waits up to timeout_seconds for guest shutdown.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                    "timeout_seconds": InputSchemaProperty(type: "integer", description: "Max wait for graceful shutdown (default 30)"),
                ],
                required: ["vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_force_stop",
            category: .lifecycle,
            direction: .input,
            description: "Hard kill — bypasses guest shutdown.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                ],
                required: ["vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_pause",
            category: .lifecycle,
            direction: .input,
            description: "Pause a running VM (memory frozen).",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                ],
                required: ["vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_resume",
            category: .lifecycle,
            direction: .input,
            description: "Resume a paused VM.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                ],
                required: ["vm"]
            )
        ),

        // === Capture (safe-mutate) ===
        ToolDescriptor(
            name: "secvf_capture_start",
            category: .capture,
            direction: .input,
            description: "Start capturing on the virtual switch.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "Filter to one VM (optional; defaults to all)"),
                    "bpf_filter": InputSchemaProperty(type: "string", description: "BPF filter expression"),
                    "pcap_path": InputSchemaProperty(type: "string", description: "Output PCAP path (optional)"),
                ]
            )
        ),
        ToolDescriptor(
            name: "secvf_capture_stop",
            category: .capture,
            direction: .input,
            description: "Stop capture and finalize PCAP.",
            inputSchema: .empty
        ),

        // === Composite workflows (safe-mutate) ===
        ToolDescriptor(
            name: "secvf_detonate_start",
            category: .workflow,
            direction: .input,
            description: "Start a detonation workflow: clone template VM, mount sample, boot, capture, snapshot. Returns a run_id; poll with secvf_run_status, fetch result with secvf_run_result.",
            inputSchema: InputSchema(
                properties: [
                    "sample_path": InputSchemaProperty(type: "string", description: "Path to the sample file to mount in the guest"),
                    "template_vm": InputSchemaProperty(type: "string", description: "VM template to clone for this run"),
                    "timeout_seconds": InputSchemaProperty(type: "integer", description: "How long to capture for after boot (default 60)"),
                ],
                required: ["sample_path", "template_vm"]
            )
        ),
        ToolDescriptor(
            name: "secvf_run_status",
            category: .workflow,
            direction: .input,
            description: "Poll the state of an active detonation run.",
            inputSchema: InputSchema(
                properties: [
                    "run_id": InputSchemaProperty(type: "string", description: "Run id returned by secvf_detonate_start"),
                ],
                required: ["run_id"]
            )
        ),
        ToolDescriptor(
            name: "secvf_run_result",
            category: .workflow,
            direction: .output,  // contains VM-derived content — UNTRUSTED
            description: "Fetch the final report for a completed detonation run.",
            inputSchema: InputSchema(
                properties: [
                    "run_id": InputSchemaProperty(type: "string", description: "Run id returned by secvf_detonate_start"),
                ],
                required: ["run_id"]
            )
        ),

        // === Destructive (full tier only) ===
        ToolDescriptor(
            name: "secvf_vm_create",
            category: .destructive,
            direction: .input,
            description: "Create a new VM bundle. Destructive on disk (allocates space).",
            inputSchema: InputSchema(
                properties: [
                    "name": InputSchemaProperty(type: "string", description: "Unique VM name"),
                    "os_type": InputSchemaProperty(type: "string", description: "Linux | macOS"),
                    "cpu_count": InputSchemaProperty(type: "integer", description: "vCPU count"),
                    "memory_gib": InputSchemaProperty(type: "integer", description: "RAM in GiB"),
                    "disk_gib": InputSchemaProperty(type: "integer", description: "Disk size in GiB"),
                ],
                required: ["name", "os_type"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_clone",
            category: .destructive,
            direction: .input,
            description: "Clone an existing VM. Destructive on disk.",
            inputSchema: InputSchema(
                properties: [
                    "source": InputSchemaProperty(type: "string", description: "Source VM name"),
                    "name": InputSchemaProperty(type: "string", description: "New VM name"),
                ],
                required: ["source", "name"]
            )
        ),
        ToolDescriptor(
            name: "secvf_vm_delete",
            category: .destructive,
            direction: .input,
            description: "Delete a VM bundle. Refuses if VM is running.",
            inputSchema: InputSchema(
                properties: [
                    "vm": InputSchemaProperty(type: "string", description: "VM name"),
                ],
                required: ["vm"]
            )
        ),
    ]
}
