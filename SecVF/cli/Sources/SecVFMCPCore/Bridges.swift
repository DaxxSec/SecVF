//
//  Bridges.swift
//  SecVFMCPCore
//
//  Protocol-based bridges to SecVF state. Each bridge is the abstract
//  shape of one subsystem (VMs, virtual switch, packet capture, etc.).
//  Tests inject in-memory actors; production wires concrete adapters that
//  call into the existing CLI bridges at `secvf-cli/Bridges/`.
//
//  Every method is `async` because production implementations may shell
//  into subprocesses (the existing secvf-cli bridges) or perform file I/O.
//  Tests use actor-based mocks for thread safety.
//

import Foundation

// MARK: - Common record types

/// One VM as surfaced to the MCP layer. Fewer fields than internal types
/// because agents shouldn't need bundle paths, machine identifiers, etc.
public struct VMRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    public let osType: String        // "Linux" | "macOS" | "AISandbox"
    public let status: String        // "running" | "stopped" | "paused"

    public init(id: String, name: String, osType: String, status: String) {
        self.id = id
        self.name = name
        self.osType = osType
        self.status = status
    }
}

public struct SwitchStatusRecord: Sendable, Equatable {
    public let running: Bool
    public let connectedPorts: Int
    public let learnedMACs: Int
    public let packetsTotal: Int
    public let dropsTotal: Int

    public init(running: Bool, connectedPorts: Int, learnedMACs: Int,
                packetsTotal: Int, dropsTotal: Int) {
        self.running = running
        self.connectedPorts = connectedPorts
        self.learnedMACs = learnedMACs
        self.packetsTotal = packetsTotal
        self.dropsTotal = dropsTotal
    }
}

public struct CaptureStatusRecord: Sendable, Equatable {
    public let running: Bool
    public let startedAt: Date?
    public let packetsCaptured: Int
    public let bytesCaptured: Int
    public let currentPcapPath: String?

    public init(running: Bool, startedAt: Date?, packetsCaptured: Int,
                bytesCaptured: Int, currentPcapPath: String?) {
        self.running = running
        self.startedAt = startedAt
        self.packetsCaptured = packetsCaptured
        self.bytesCaptured = bytesCaptured
        self.currentPcapPath = currentPcapPath
    }
}

/// Generic outcome shape for mutating operations. Tools dressed up as MCP
/// success/failure based on this.
public struct BridgeOutcome: Sendable {
    public let success: Bool
    public let errorCode: String?
    public let errorMessage: String?

    public init(success: Bool, errorCode: String? = nil, errorMessage: String? = nil) {
        self.success = success
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

// MARK: - Bridge protocols

/// VM lifecycle + discovery.
public protocol VMBridge: Sendable {
    func listVMs() async -> [VMRecord]
    func status(forVM name: String) async -> VMRecord?
    func start(vmNamed: String) async -> BridgeOutcome
    func stop(vmNamed: String) async -> BridgeOutcome
}

/// Virtual switch state.
public protocol SwitchBridge: Sendable {
    func status() async -> SwitchStatusRecord
}

/// Packet capture lifecycle.
public protocol CaptureBridge: Sendable {
    func status() async -> CaptureStatusRecord
    func start(vm: String?, bpfFilter: String?, pcapPath: String?) async -> BridgeOutcome
    func stop() async -> BridgeOutcome
}
