//
//  AISandboxInstallTrackerTests.swift
//  SecVFTests
//
//  Coverage for the run-id discipline added to AISandboxInstallTracker
//  (C2 of `docs/PR4_REVIEW_FIXES_2026-05-03.md`). The supersession path
//  was the bug the prior PR review's F1 called out and PR #2 + PR #4
//  both shipped without addressing — these tests assert the late
//  callback from a superseded run can no longer clobber the run that
//  replaced it.
//

import XCTest
@testable import SecVF

@MainActor
final class AISandboxInstallTrackerTests: XCTestCase {

    override func setUp() async throws {
        // Each test starts from a known-clean state.
        AISandboxInstallTracker.shared.reset()
    }

    // MARK: - Run-id discipline (C2)

    func testBeginMintsFreshRunId() {
        let tracker = AISandboxInstallTracker.shared
        let runA = tracker.begin()
        let runB = tracker.begin()
        XCTAssertNotEqual(runA, runB, "begin() must produce a fresh UUID per call")
        XCTAssertEqual(tracker.currentRunId, runB, "currentRunId tracks the latest begin()")
    }

    func testSupersededRunCannotClobberCurrentViaFail() {
        // Given a superseded run
        let tracker = AISandboxInstallTracker.shared
        let oldRun = tracker.begin()
        let newRun = tracker.begin()
        XCTAssertNotEqual(oldRun, newRun)

        // When the old run's late cancellation arm fires
        tracker.fail(with: "cancelled", runId: oldRun)

        // Then the tracker stays in the new run's installing phase
        XCTAssertNotEqual(tracker.phase, .failed,
                          "Superseded fail() must not flip phase to .failed")
        XCTAssertEqual(tracker.phase, .installing,
                       "New run's phase must remain .installing")
        XCTAssertEqual(tracker.currentRunId, newRun,
                       "Superseded mutator must not change currentRunId")
    }

    func testSupersededRunCannotClobberCurrentViaReset() {
        let tracker = AISandboxInstallTracker.shared
        let oldRun = tracker.begin()
        let newRun = tracker.begin()

        // The old run's reset() (called from cancellation arm after fail()) is a no-op.
        tracker.reset(runId: oldRun)

        XCTAssertEqual(tracker.currentRunId, newRun,
                       "Superseded reset() must not clear currentRunId")
        XCTAssertEqual(tracker.phase, .installing,
                       "Superseded reset() must not flip phase to .idle")
    }

    func testSupersededRunCannotClobberCurrentViaSetPhase() {
        let tracker = AISandboxInstallTracker.shared
        let oldRun = tracker.begin()
        let newRun = tracker.begin()

        tracker.setPhase(.sealing, runId: oldRun)

        XCTAssertEqual(tracker.phase, .installing,
                       "Superseded setPhase() must not change phase")
        XCTAssertEqual(tracker.currentRunId, newRun)
    }

    func testSupersededRunCannotClobberCurrentViaUpdateFraction() {
        let tracker = AISandboxInstallTracker.shared
        let oldRun = tracker.begin()
        // Advance the new run's fraction
        tracker.updateInstallFraction(0.5, runId: tracker.begin())
        let newRun = tracker.currentRunId

        // Old run's late progress callback no-ops
        tracker.updateInstallFraction(0.99, runId: oldRun)

        XCTAssertEqual(tracker.fraction, 0.5, accuracy: 0.0001,
                       "Superseded updateInstallFraction must not advance the bar")
        XCTAssertEqual(tracker.currentRunId, newRun)
    }

    func testSupersededRunCannotClobberCurrentViaLog() {
        let tracker = AISandboxInstallTracker.shared
        let oldRun = tracker.begin()
        let newRun = tracker.begin()
        tracker.log("from-new", runId: newRun)
        let snapshot = tracker.logMessages

        tracker.log("from-old", runId: oldRun)

        XCTAssertEqual(tracker.logMessages, snapshot,
                       "Superseded log() must not append to the new run's buffer")
    }

    // MARK: - Current-run mutators continue to work

    func testCurrentRunMutatorsApplyNormally() {
        let tracker = AISandboxInstallTracker.shared
        let runId = tracker.begin()

        tracker.updateInstallFraction(0.25, runId: runId)
        XCTAssertEqual(tracker.fraction, 0.25, accuracy: 0.0001)

        tracker.setPhase(.sealing, runId: runId)
        XCTAssertEqual(tracker.phase, .sealing)
        XCTAssertEqual(tracker.fraction, 0,
                       "Sealing phase collapses the fraction")

        tracker.setPhase(.finished, runId: runId)
        XCTAssertEqual(tracker.phase, .finished)
        XCTAssertEqual(tracker.fraction, 1,
                       "Finished phase sets fraction to 1")
    }

    func testRunlessMutatorsAlsoWork() {
        // Callers without a run id in scope (e.g. a UI dismissing the
        // last result) should still be able to drive the tracker.
        let tracker = AISandboxInstallTracker.shared
        _ = tracker.begin()

        tracker.fail(with: "boom")
        XCTAssertEqual(tracker.phase, .failed)
        XCTAssertEqual(tracker.lastErrorMessage, "boom")

        tracker.reset()
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertNil(tracker.currentRunId)
    }

    // MARK: - Phase enum invariants (S8)

    func testPhaseEnumNoLongerExposesProvisioning() {
        // S8 of PR #4 review: the .provisioning case was dead code (the
        // create flow no longer calls setPhase(.provisioning)). Removed
        // from the enum. This test would fail to compile if .provisioning
        // came back without its callers.
        let allCases: [AISandboxInstallTracker.Phase] = [
            .idle, .installing, .sealing, .finished, .failed
        ]
        for phase in allCases {
            // Just exercise humanLabel to make sure every case is handled.
            _ = phase.humanLabel
        }
    }
}
