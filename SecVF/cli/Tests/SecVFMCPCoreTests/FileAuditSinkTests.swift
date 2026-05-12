//
//  FileAuditSinkTests.swift
//  SecVFMCPCoreTests
//
//  TDD for FileAuditSink — the production sink that writes audit lines
//  to ~/.avf/logs/mcp-audit-YYYY-MM-DD.log via O_APPEND + 0o600. Mirrors
//  the AVFAuditLog pattern from the main SecVF app (Batch 5 in the
//  pre-launch audit). Tests use a tempdir so they're hermetic.
//

import Testing
import Foundation
@testable import SecVFMCPCore

@Suite("FileAuditSink")
struct FileAuditSinkTests {

    // MARK: - basic append

    @Test("appended lines persist to file")
    func appendPersists() async throws {
        let tmpDir = try makeTempLogDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sink = FileAuditSink(directory: tmpDir.path)
        sink.append(jsonLine: #"{"tool":"secvf_vm_list","result":"ok"}"# + "\n")
        sink.append(jsonLine: #"{"tool":"secvf_vm_status","result":"ok"}"# + "\n")

        // Wait briefly for any internal queue to drain.
        try await Task.sleep(nanoseconds: 50_000_000)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let logFile = files.first(where: { $0.hasPrefix("mcp-audit-") && $0.hasSuffix(".log") })
        #expect(logFile != nil)

        let content = try String(contentsOfFile: tmpDir.path + "/" + (logFile ?? ""), encoding: .utf8)
        #expect(content.contains("secvf_vm_list"))
        #expect(content.contains("secvf_vm_status"))
        // Each line should be a complete JSON object terminated by newline.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
    }

    @Test("log filename uses YYYY-MM-DD format")
    func filenameUsesDateFormat() async throws {
        let tmpDir = try makeTempLogDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sink = FileAuditSink(directory: tmpDir.path)
        sink.append(jsonLine: #"{"x":1}"# + "\n")
        try await Task.sleep(nanoseconds: 50_000_000)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let logFile = files.first(where: { $0.hasPrefix("mcp-audit-") }) ?? ""
        // Filename like mcp-audit-2026-05-11.log
        let pattern = #"^mcp-audit-\d{4}-\d{2}-\d{2}\.log$"#
        #expect(logFile.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("file mode is 0o600 on first create")
    func filePermissionsAre600() async throws {
        let tmpDir = try makeTempLogDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sink = FileAuditSink(directory: tmpDir.path)
        sink.append(jsonLine: #"{"x":1}"# + "\n")
        try await Task.sleep(nanoseconds: 50_000_000)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let logFile = files.first(where: { $0.hasPrefix("mcp-audit-") }) ?? ""
        let attrs = try FileManager.default.attributesOfItem(
            atPath: tmpDir.path + "/" + logFile
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }

    @Test("missing directory is created on first append")
    func directoryCreatedOnFirstAppend() async throws {
        let tmpRoot = try makeTempLogDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let nested = tmpRoot.appendingPathComponent("nested-sub")
        // nested does NOT exist yet
        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let sink = FileAuditSink(directory: nested.path)
        sink.append(jsonLine: #"{"x":1}"# + "\n")
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("concurrent appends from multiple tasks preserve all lines")
    func concurrentAppendsPreserveAllLines() async throws {
        let tmpDir = try makeTempLogDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sink = FileAuditSink(directory: tmpDir.path)
        let n = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    sink.append(jsonLine: #"{"i":\#(i)}"# + "\n")
                }
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let logFile = files.first(where: { $0.hasPrefix("mcp-audit-") }) ?? ""
        let content = try String(contentsOfFile: tmpDir.path + "/" + logFile, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        // All N appends should be present + line-coherent (each is valid JSON)
        #expect(lines.count == n)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!)
            #expect(obj as? [String: Any] != nil)
        }
    }

    // MARK: - helpers

    private func makeTempLogDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("secvf-mcp-audit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
