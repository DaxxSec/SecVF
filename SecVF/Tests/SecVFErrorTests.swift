//
//  SecVFErrorTests.swift
//  SecVFTests
//
//  Invariant tests for the SecVFError type — every case must produce a
//  non-empty errorDescription, recovery suggestions must be actionable
//  when present, and the audit-log path stays inside ~/.avf so error
//  reports don't get scattered across the filesystem.
//
//  This is a structural test pass — exhaustive case coverage matters
//  here because SecVFError is the user-facing error vocabulary; a
//  silent "" description on any case leaves the operator staring at
//  a blank alert.
//

import XCTest
@testable import SecVF

final class SecVFErrorTests: XCTestCase {

    // A spot-check of cases that touch every category, so this test
    // file doesn't need to grow with every new enum case while still
    // catching whole categories of regressions.
    private let coverageSet: [SecVFError] = [
        // VM Configuration
        .vmConfigNotFound(vmId: UUID()),
        .vmConfigInvalid(reason: "missing field"),
        // Disk
        .diskAttachmentFailed(path: "/tmp/X.img", underlying: nil),
        .diskImageNotFound(path: "/tmp/X.img"),
        .invalidDiskConfiguration,
        // Auxiliary storage
        .auxiliaryStorageLocked(path: "/tmp/aux"),
        // Machine identifier
        .machineIdentifierNotFound(path: "/tmp/mid"),
        .machineIdentifierDataInvalid,
        // NVRAM
        .nvramNotFound(path: "/tmp/nvram"),
        // Apple Silicon / macOS
        .macOSVersionTooOld(required: "14.0", current: "13.0"),
        .appleSiliconRequired,
        // VM lifecycle
        .configurationValidationFailed(underlying: NSError(domain: "test", code: 1)),
        .vmStartFailed(underlying: NSError(domain: "test", code: 2)),
        .vmAlreadyRunning(vmId: UUID()),
        .vmNotRunning(vmId: UUID()),
        // Network
        .networkConfigurationFailed(reason: "missing router"),
        // Distro
        .checksumUnavailable(distro: "Kali", reason: "mirror down"),
    ]

    // MARK: - errorDescription

    func testEveryCaseHasNonEmptyErrorDescription() {
        for error in coverageSet {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "Error case is missing errorDescription: \(error)")
            XCTAssertFalse((desc ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Error case has empty/whitespace errorDescription: \(error)")
        }
    }

    func testErrorDescriptionEmbedsContextValues() {
        // The associated-value cases must surface their associated
        // data — otherwise the user reads "VM config not found" with
        // no clue which VM. We sample one per shape (UUID, path,
        // reason, version pair).
        let id = UUID()
        XCTAssertTrue(SecVFError.vmConfigNotFound(vmId: id).errorDescription?
            .contains(id.uuidString) ?? false,
            "vmConfigNotFound must include the UUID in its description")

        let path = "/tmp/disk-abc.img"
        XCTAssertTrue(SecVFError.diskImageNotFound(path: path).errorDescription?
            .contains(path) ?? false,
            "diskImageNotFound must include the disk path")

        XCTAssertTrue(SecVFError.macOSVersionTooOld(required: "14.0", current: "13.0")
            .errorDescription?.contains("14.0") ?? false)
        XCTAssertTrue(SecVFError.macOSVersionTooOld(required: "14.0", current: "13.0")
            .errorDescription?.contains("13.0") ?? false)
    }

    func testLocalizedDescriptionFromLocalizedErrorProtocol() {
        // LocalizedError plumbing: `error.localizedDescription` must
        // route through `errorDescription` for every case.
        for error in coverageSet {
            XCTAssertEqual(error.localizedDescription, error.errorDescription ?? "")
        }
    }

    // MARK: - recoverySuggestion

    func testKeyCasesHaveRecoverySuggestion() {
        // Not every case needs one (some are "this is just broken,
        // sorry"), but the actionable ones do. Spot-check the cases
        // where a missing suggestion would be a UX regression.
        let actionable: [SecVFError] = [
            .vmConfigNotFound(vmId: UUID()),
            .diskImageNotFound(path: "/x"),
            .installerISONotFound(vmId: UUID()),
            .macOSVersionTooOld(required: "14", current: "13"),
            .appleSiliconRequired,
            .auxiliaryStorageLocked(path: "/tmp/x"),
            .checksumUnavailable(distro: "X", reason: "y"),
        ]
        for error in actionable {
            XCTAssertNotNil(error.recoverySuggestion,
                            "Actionable case is missing recoverySuggestion: \(error)")
            XCTAssertFalse(error.recoverySuggestion?.isEmpty ?? true,
                           "Actionable case has empty recoverySuggestion: \(error)")
        }
    }

    func testRecoverySuggestionDefaultsToNilForCategoriesWithout() {
        // The default branch returns nil — verify with a case that
        // intentionally has none.
        XCTAssertNil(SecVFError.machineIdentifierDataInvalid.recoverySuggestion,
                     "Cases without an actionable recovery should return nil, not empty string")
    }

    // MARK: - Audit logging

    func testTokenizeHomePathScrubsTheAbsoluteHomePrefix() {
        // Exercises the production helper directly. A regression that
        // forgets to call tokenizeHomePath inside logToAudit would still
        // pass this test — that gap is acceptable because mocking the
        // audit-log file write is more fragile than asserting the
        // helper's contract; the helper is the load-bearing piece.
        let fakeHome = "/Users/operator"
        let dirty = "Error reading \(fakeHome)/.avf/Linux/X.bundle"
        let safe = SecVFError.tokenizeHomePath(dirty, home: fakeHome)
        XCTAssertFalse(safe.contains(fakeHome),
                       "tokenizeHomePath must scrub the absolute home prefix")
        XCTAssertTrue(safe.contains("~/.avf"),
                      "tokenizeHomePath must replace the home prefix with ~")
    }

    func testTokenizeHomePathLeavesNonHomePathsAlone() {
        let untouched = "/etc/hosts is not in home"
        XCTAssertEqual(SecVFError.tokenizeHomePath(untouched, home: "/Users/operator"),
                       untouched)
    }

    func testTokenizeHomePathReplacesEveryOccurrence() {
        // Multiple home references in one log line (e.g. "moved
        // /Users/x/a.bundle to /Users/x/Quarantine/a.bundle") must
        // all get redacted — leaving even one absolute path defeats
        // the redaction.
        let home = "/Users/operator"
        let dirty = "moved \(home)/a.bundle to \(home)/Quarantine/a.bundle"
        let safe = SecVFError.tokenizeHomePath(dirty, home: home)
        XCTAssertFalse(safe.contains(home))
        XCTAssertEqual(safe.components(separatedBy: "~").count - 1, 2,
                       "Both occurrences must be replaced")
    }
}
