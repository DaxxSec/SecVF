//
//  TestHelpers.swift
//  SecVFTests
//
//  Test utilities and helpers for SecVF testing
//

import XCTest
import Foundation

// MARK: - Test File System Utilities

class TestFileSystemHelper {
    /// Creates a temporary directory for testing
    static func createTemporaryTestDirectory(prefix: String = "SecVFTest_") -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString)

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Removes a temporary test directory
    static func removeTestDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a mock VM bundle with the specified structure
    static func createMockVMBundle(at path: URL, name: String) throws -> URL {
        let bundlePath = path.appendingPathComponent("\(name).bundle")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)

        // Create mock metadata.json
        let metadata: [String: Any] = [
            "name": name,
            "cpuCount": 2,
            "memorySize": 4294967296,
            "diskSize": 21474836480,
            "networkMode": "NAT",
            "osType": "Linux"
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
        try metadataData.write(to: bundlePath.appendingPathComponent("metadata.json"))

        // Create mock disk.img (empty sparse file)
        FileManager.default.createFile(atPath: bundlePath.appendingPathComponent("disk.img").path, contents: nil)

        // Create mock NVRAM
        FileManager.default.createFile(atPath: bundlePath.appendingPathComponent("NVRAM").path, contents: Data(repeating: 0, count: 256))

        return bundlePath
    }

    /// Verifies that a VM bundle has the expected structure
    static func verifyVMBundleStructure(at bundlePath: URL) -> Bool {
        let fm = FileManager.default
        let requiredFiles = ["metadata.json", "disk.img", "NVRAM"]

        for file in requiredFiles {
            if !fm.fileExists(atPath: bundlePath.appendingPathComponent(file).path) {
                return false
            }
        }
        return true
    }
}

// MARK: - XCTest Extensions

extension XCTestCase {
    /// Assert that a file exists at the given path
    func XCTAssertFileExists(_ path: URL, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        let exists = FileManager.default.fileExists(atPath: path.path)
        XCTAssertTrue(exists, message.isEmpty ? "File should exist at \(path.path)" : message, file: file, line: line)
    }

    /// Assert that a file does NOT exist at the given path
    func XCTAssertFileNotExists(_ path: URL, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        let exists = FileManager.default.fileExists(atPath: path.path)
        XCTAssertFalse(exists, message.isEmpty ? "File should not exist at \(path.path)" : message, file: file, line: line)
    }

    /// Assert that a directory exists at the given path
    func XCTAssertDirectoryExists(_ path: URL, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue,
                      message.isEmpty ? "Directory should exist at \(path.path)" : message,
                      file: file, line: line)
    }

    /// Assert that JSON data can be decoded into the expected type
    func XCTAssertJSONDecodable<T: Decodable>(_ data: Data, type: T.Type, file: StaticString = #file, line: UInt = #line) throws -> T? {
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            return decoded
        } catch {
            XCTFail("Failed to decode JSON: \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - Mock Network Configuration

struct MockNetworkConfiguration {
    static func createNATConfig() -> (mode: String, routerID: String?) {
        return ("NAT", nil)
    }

    static func createVirtualNetworkConfig(routerID: String) -> (mode: String, routerID: String?) {
        return ("Virtual", routerID)
    }
}

// MARK: - Test Data Generators

struct TestDataGenerator {
    static func randomVMName() -> String {
        return "TestVM_\(UUID().uuidString.prefix(8))"
    }

    static func randomMachineIdentifier() -> Data {
        return Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    static func validCPUCount() -> Int {
        return [1, 2, 4, 8].randomElement()!
    }

    static func validMemorySize() -> UInt64 {
        // 2GB, 4GB, 8GB, 16GB
        return [2, 4, 8, 16].randomElement()! * 1024 * 1024 * 1024
    }

    static func validDiskSize() -> UInt64 {
        // 20GB, 50GB, 100GB
        return [20, 50, 100].randomElement()! * 1024 * 1024 * 1024
    }
}

// MARK: - Async Test Utilities

extension XCTestCase {
    /// Wait for a condition to be true with a timeout
    func waitForCondition(timeout: TimeInterval = 5.0,
                          pollingInterval: TimeInterval = 0.1,
                          condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollingInterval))
        }

        return false
    }
}

// MARK: - String Extensions for Testing

extension String {
    var isValidVMName: Bool {
        // VM names should not contain path separators or other invalid characters
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return self.rangeOfCharacter(from: invalidChars) == nil && !self.isEmpty
    }
}
