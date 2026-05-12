//
//  CapabilityTierTests.swift
//  SecVFMCPCoreTests
//
//  TDD: written BEFORE the implementation. These tests define the contract
//  for capability-tier-based tool gating. The MCP server starts with a tier
//  flag; only tools at or below that tier are exposed to the agent.
//

import Testing
@testable import SecVFMCPCore

@Suite("CapabilityTier")
struct CapabilityTierTests {

    // MARK: - read-only tier

    @Test("read-only tier exposes discovery tools")
    func readOnlyExposesDiscovery() {
        let registry = ToolRegistry(tier: .readOnly)
        #expect(registry.exposedToolNames.contains("secvf_vm_list"))
        #expect(registry.exposedToolNames.contains("secvf_vm_status"))
        #expect(registry.exposedToolNames.contains("secvf_switch_status"))
        #expect(registry.exposedToolNames.contains("secvf_capture_status"))
    }

    @Test("read-only tier exposes log tools")
    func readOnlyExposesLogs() {
        let registry = ToolRegistry(tier: .readOnly)
        #expect(registry.exposedToolNames.contains("secvf_logs_security"))
        #expect(registry.exposedToolNames.contains("secvf_logs_network"))
        #expect(registry.exposedToolNames.contains("secvf_logs_audit"))
    }

    @Test("read-only tier hides mutating tools")
    func readOnlyHidesMutating() {
        let registry = ToolRegistry(tier: .readOnly)
        #expect(!registry.exposedToolNames.contains("secvf_vm_start"))
        #expect(!registry.exposedToolNames.contains("secvf_vm_stop"))
        #expect(!registry.exposedToolNames.contains("secvf_capture_start"))
    }

    @Test("read-only tier hides destructive tools")
    func readOnlyHidesDestructive() {
        let registry = ToolRegistry(tier: .readOnly)
        #expect(!registry.exposedToolNames.contains("secvf_vm_create"))
        #expect(!registry.exposedToolNames.contains("secvf_vm_delete"))
        #expect(!registry.exposedToolNames.contains("secvf_vm_clone"))
    }

    // MARK: - safe-mutate tier (default)

    @Test("safe-mutate tier exposes discovery + log tools")
    func safeMutateExposesDiscoveryAndLogs() {
        let registry = ToolRegistry(tier: .safeMutate)
        #expect(registry.exposedToolNames.contains("secvf_vm_list"))
        #expect(registry.exposedToolNames.contains("secvf_logs_security"))
    }

    @Test("safe-mutate tier exposes lifecycle tools")
    func safeMutateExposesLifecycle() {
        let registry = ToolRegistry(tier: .safeMutate)
        #expect(registry.exposedToolNames.contains("secvf_vm_start"))
        #expect(registry.exposedToolNames.contains("secvf_vm_stop"))
        #expect(registry.exposedToolNames.contains("secvf_vm_pause"))
        #expect(registry.exposedToolNames.contains("secvf_vm_resume"))
    }

    @Test("safe-mutate tier exposes capture tools")
    func safeMutateExposesCapture() {
        let registry = ToolRegistry(tier: .safeMutate)
        #expect(registry.exposedToolNames.contains("secvf_capture_start"))
        #expect(registry.exposedToolNames.contains("secvf_capture_stop"))
    }

    @Test("safe-mutate tier still hides destructive tools")
    func safeMutateHidesDestructive() {
        let registry = ToolRegistry(tier: .safeMutate)
        #expect(!registry.exposedToolNames.contains("secvf_vm_create"))
        #expect(!registry.exposedToolNames.contains("secvf_vm_delete"))
        #expect(!registry.exposedToolNames.contains("secvf_vm_clone"))
    }

    // MARK: - full tier

    @Test("full tier exposes everything including destructive")
    func fullExposesEverything() {
        let registry = ToolRegistry(tier: .full)
        #expect(registry.exposedToolNames.contains("secvf_vm_list"))
        #expect(registry.exposedToolNames.contains("secvf_vm_start"))
        #expect(registry.exposedToolNames.contains("secvf_vm_create"))
        #expect(registry.exposedToolNames.contains("secvf_vm_delete"))
        #expect(registry.exposedToolNames.contains("secvf_vm_clone"))
    }

    // MARK: - tier ordering

    @Test("each tier exposes a strict superset of the tier below")
    func tierSupersetOrdering() {
        let readOnly = ToolRegistry(tier: .readOnly).exposedToolNames
        let safeMutate = ToolRegistry(tier: .safeMutate).exposedToolNames
        let full = ToolRegistry(tier: .full).exposedToolNames

        #expect(readOnly.isSubset(of: safeMutate))
        #expect(safeMutate.isSubset(of: full))
    }

    // MARK: - tier parsing (CLI flag → enum)

    @Test("tier parses from CLI string")
    func tierParsesFromString() throws {
        #expect(try CapabilityTier(parsing: "read-only") == .readOnly)
        #expect(try CapabilityTier(parsing: "safe-mutate") == .safeMutate)
        #expect(try CapabilityTier(parsing: "full") == .full)
    }

    @Test("tier rejects unknown strings")
    func tierRejectsUnknown() {
        #expect(throws: CapabilityTierError.self) {
            try CapabilityTier(parsing: "god-mode")
        }
    }
}
