//
//  AISandboxNodeTests.swift
//  SecVFTests
//
//  Unit tests for the AI Sandbox tree-view node model + bundle row
//  added in the tactical UI redesign (`feat/ui-tactical-redesign`).
//
//  These tests don't touch the on-disk ~/.avf/AISandbox directory —
//  they exercise the data structures in isolation so they're safe to
//  run on any machine.
//

import XCTest
@testable import SecVF

final class AISandboxNodeTests: XCTestCase {

    // MARK: - AISandboxBundleRow.sessionID

    func testSessionIDExtractedFromBundlePath() {
        let url = URL(fileURLWithPath: "/tmp/AISandbox/sessions/ai-sandbox-exec-abc12345.bundle")
        let row = AISandboxBundleRow(
            url: url,
            displayName: "exec-abc12345",
            isBase: false,
            id: nil,
            createdAt: nil,
            diskBytes: 0)
        XCTAssertEqual(row.sessionID, "abc12345")
    }

    func testSessionIDIsNilForBaseBundle() {
        let url = URL(fileURLWithPath: "/tmp/AISandbox/ai-sandbox-base-v1.bundle")
        let row = AISandboxBundleRow(
            url: url,
            displayName: "base",
            isBase: true,                     // base bundles never have a session id
            id: nil,
            createdAt: nil,
            diskBytes: 0)
        XCTAssertNil(row.sessionID,
                     "Base-bundle rows must not surface a sessionID — bootAISandboxSession uses nil to mean 'clone fresh'")
    }

    func testSessionIDIsNilForUnrecognizedPath() {
        // A session-flagged row whose URL doesn't match the expected
        // "ai-sandbox-exec-<id>.bundle" naming should fall back to nil.
        let url = URL(fileURLWithPath: "/tmp/AISandbox/sessions/totally-different.bundle")
        let row = AISandboxBundleRow(
            url: url,
            displayName: "totally-different",
            isBase: false,
            id: nil,
            createdAt: nil,
            diskBytes: 0)
        XCTAssertNil(row.sessionID)
    }

    // MARK: - AISandboxNode hierarchy

    func testBaseNodeWithSessionsBehavesAsParent() {
        let baseRow = AISandboxBundleRow(
            url: URL(fileURLWithPath: "/tmp/x/ai-sandbox-base-v1.bundle"),
            displayName: "base", isBase: true,
            id: nil, createdAt: nil, diskBytes: 0)
        let sessionRow = AISandboxBundleRow(
            url: URL(fileURLWithPath: "/tmp/x/sessions/ai-sandbox-exec-a1b2c3d4.bundle"),
            displayName: "exec-a1b2c3d4", isBase: false,
            id: nil, createdAt: nil, diskBytes: 0)
        let sessionNode = AISandboxNode(bundle: sessionRow, children: nil)
        let baseNode = AISandboxNode(bundle: baseRow, children: [sessionNode])

        XCTAssertTrue(baseNode.bundle.isBase)
        XCTAssertNotNil(baseNode.children)
        XCTAssertEqual(baseNode.children?.count, 1)
        XCTAssertFalse(baseNode.children?[0].bundle.isBase ?? true)
        XCTAssertNil(baseNode.children?[0].children,
                     "Session leaves must have nil children — only the base is expandable")
    }

    func testBaseNodeWithNoSessionsStillExpandsRule() {
        // The outline view treats nil-children as "not expandable" but
        // an empty-array children counts as "expandable but empty". Confirm
        // the model preserves this distinction so the disclosure triangle
        // behavior is what the user expects.
        let baseRow = AISandboxBundleRow(
            url: URL(fileURLWithPath: "/tmp/x/ai-sandbox-base-v1.bundle"),
            displayName: "base", isBase: true,
            id: nil, createdAt: nil, diskBytes: 0)

        let emptyChildren = AISandboxNode(bundle: baseRow, children: [])
        let nilChildren   = AISandboxNode(bundle: baseRow, children: nil)

        XCTAssertEqual(emptyChildren.children?.count, 0)
        XCTAssertNil(nilChildren.children)
    }

    // MARK: - Reference identity (NSOutlineView relies on this)

    func testNodesUseReferenceIdentityForEquality() {
        // NSOutlineView identifies items by object identity for reference
        // types, so two nodes wrapping the same bundle row must NOT
        // compare equal unless they're literally the same instance. This
        // is what lets the outline track selection + expansion correctly.
        let row = AISandboxBundleRow(
            url: URL(fileURLWithPath: "/tmp/x/ai-sandbox-base-v1.bundle"),
            displayName: "base", isBase: true,
            id: nil, createdAt: nil, diskBytes: 0)

        let nodeA = AISandboxNode(bundle: row, children: nil)
        let nodeB = AISandboxNode(bundle: row, children: nil)

        XCTAssertFalse(nodeA === nodeB,
                       "Distinct AISandboxNode instances are required for reliable NSOutlineView identity tracking")
    }
}
