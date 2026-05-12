//
//  ProductionBridges.swift
//  SecVFMCPCore
//
//  File-backed bridge implementations that read directly from ~/.avf.
//  These replace the stub bridges in `secvf-mcp/main.swift` for the
//  read paths (list / status). Mutating paths (start / stop) require
//  the SecVF GUI app to be running because VZ lifecycle has to happen
//  in-process there; bridges surface a structured "host_app_required"
//  error pointing to that.
//
//  The actual host-app integration goes through DistributedNotification-
//  Center — that wiring lives in `secvf-mcp/main.swift` rather than
//  here, because the bridges in this file are pure data-reading.
//

import Foundation

public actor FileBackedVMBridge: VMBridge {
    public let avfRoot: String

    public init(avfRoot: String = NSHomeDirectory() + "/.avf") {
        self.avfRoot = avfRoot
    }

    public func listVMs() async -> [VMRecord] {
        var vms: [VMRecord] = []
        for (subdir, osType) in [("Linux", "Linux"), ("MacOS", "macOS")] {
            let dir = avfRoot + "/" + subdir
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for entry in entries where entry.hasSuffix(".bundle") {
                let bundlePath = dir + "/" + entry
                if let vm = loadVMRecord(bundlePath: bundlePath, osType: osType) {
                    vms.append(vm)
                }
            }
        }
        return vms
    }

    public func status(forVM name: String) async -> VMRecord? {
        let all = await listVMs()
        return all.first(where: { $0.name == name })
    }

    public func start(vmNamed name: String) async -> BridgeOutcome {
        // First confirm the VM actually exists; agents passing typos
        // should get vm_not_found, not host_app_required.
        guard await status(forVM: name) != nil else {
            return BridgeOutcome(
                success: false,
                errorCode: "vm_not_found",
                errorMessage: "no VM named '\(name)'"
            )
        }
        return BridgeOutcome(
            success: false,
            errorCode: "host_app_required",
            errorMessage: "starting a VM requires the SecVF GUI app to be running. The MCP server will signal it via DistributedNotificationCenter; if SecVF.app is not running, launch it first."
        )
    }

    public func stop(vmNamed name: String) async -> BridgeOutcome {
        guard await status(forVM: name) != nil else {
            return BridgeOutcome(
                success: false,
                errorCode: "vm_not_found",
                errorMessage: "no VM named '\(name)'"
            )
        }
        return BridgeOutcome(
            success: false,
            errorCode: "host_app_required",
            errorMessage: "stopping a VM requires the SecVF GUI app to be running."
        )
    }

    // MARK: - private

    private func loadVMRecord(bundlePath: String, osType: String) -> VMRecord? {
        let bundleName = URL(fileURLWithPath: bundlePath)
            .lastPathComponent
            .replacingOccurrences(of: ".bundle", with: "")

        // Try metadata.json, then manifest.json (AI sandbox format).
        var record = readMetadata(at: bundlePath + "/metadata.json")
            ?? readMetadata(at: bundlePath + "/manifest.json")
            ?? [:]

        let id = (record["id"] as? String) ?? ""
        let name = (record["name"] as? String) ?? bundleName

        // "Running" detection: production version checks pgrep for the SecVF
        // process bound to this VM. Read-only mode reports "unknown" because
        // we don't want to spawn subprocesses on a per-call basis from inside
        // an agent loop. Live status comes from secvf_switch_status or the
        // dedicated future secvf_vm_running tool.
        _ = record  // keep extending record locally so unused-var clippy stays quiet

        return VMRecord(
            id: id,
            name: name,
            osType: osType,
            status: "unknown"
        )
    }

    private func readMetadata(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }
}
