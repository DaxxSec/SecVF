//
//  TacticalUITests.swift
//  SecVFTests
//
//  Unit tests for the tactical UI components shipped in the redesign
//  branch (`feat/ui-tactical-redesign`): TacticalHoverButton state
//  transitions and TacticalTableRowView properties.
//
//  Note: AppKit hover events fire through NSTrackingArea + the window
//  server, which doesn't synthesize mouseEntered/Exited inside tests.
//  We exercise the same public path manually (calling setHoverTreatment
//  + flipping isEnabled) so the visual state machine still gets a
//  round-trip exercise without depending on the runtime mouse loop.
//

import XCTest
@testable import SecVF

@MainActor
final class TacticalUITests: XCTestCase {

    // MARK: - TacticalHoverButton

    func testHoverButtonAcceptsIdleAndHoverTreatment() {
        let btn = TacticalHoverButton(title: "Test", target: nil, action: nil)
        btn.setHoverTreatment(
            idleBorder: AppColors.borderOD,
            hoverBorder: AppColors.accentODGlow,
            idleBackground: AppColors.backgroundButton,
            hoverBackground: AppColors.backgroundButton
        )
        XCTAssertEqual(btn.idleBorderColor, AppColors.borderOD)
        XCTAssertEqual(btn.hoverBorderColor, AppColors.accentODGlow)
    }

    func testHoverButtonNilArgsPreserveCurrentValues() {
        let btn = TacticalHoverButton(title: "Test", target: nil, action: nil)
        let originalIdle = btn.idleBorderColor
        // Pass only a hover override — the idle slot should be untouched.
        btn.setHoverTreatment(hoverBorder: AppColors.accentOrange)
        XCTAssertEqual(btn.idleBorderColor, originalIdle)
        XCTAssertEqual(btn.hoverBorderColor, AppColors.accentOrange)
    }

    func testHoverButtonDisabledDropsHoverAndDimsBorder() {
        let btn = TacticalHoverButton(title: "Test", target: nil, action: nil)
        btn.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        btn.setHoverTreatment(idleBorder: AppColors.borderOD,
                              hoverBorder: AppColors.accentODGlow)
        // Trigger a hover-like state by enabling first, then flipping
        // to disabled — the property observer should release the hover
        // latch immediately, so the layer goes back to the idle color.
        btn.isEnabled = true
        btn.isEnabled = false
        XCTAssertFalse(btn.isEnabled)
        // Border should match idle (mouse-not-inside) when disabled.
        XCTAssertEqual(btn.layer?.borderColor, AppColors.borderOD.cgColor)
    }

    func testHoverButtonAddsTrackingAreaOnLayout() {
        let btn = TacticalHoverButton(title: "Test", target: nil, action: nil)
        btn.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        btn.updateTrackingAreas()
        XCTAssertFalse(btn.trackingAreas.isEmpty,
                       "TacticalHoverButton should install a tracking area in updateTrackingAreas")
    }

    // MARK: - TacticalTableRowView

    func testRowViewDefaultAccentStripeWidth() {
        let row = TacticalTableRowView()
        XCTAssertEqual(row.accentStripeWidth, 2,
                       "Default accent stripe should be 2pt — outline-view callers set 0 to suppress")
    }

    func testRowViewAccentStripeWidthIsMutable() {
        let row = TacticalTableRowView()
        row.accentStripeWidth = 0
        XCTAssertEqual(row.accentStripeWidth, 0)
    }

    func testRowViewDefaultSelectionTintIsODGreen() {
        let row = TacticalTableRowView()
        XCTAssertEqual(row.selectionTint, AppColors.accentODGlow)
    }

    // (drawSelection coverage requires a real CGContext; AppKit provides
    // one on the live draw path but we can't easily synthesise that here
    // without an off-screen NSBitmapImageRep + lockFocus dance — defer.)

    // MARK: - TacticalTableHeaderCell

    func testHeaderCellUppercasesCaption() {
        let cell = TacticalTableHeaderCell(textCell: "Name")
        XCTAssertEqual(cell.stringValue, "NAME",
                       "Header captions should be uppercased on init to match the tactical aesthetic")
    }

    func testHeaderCellUsesMonospacedFont() {
        let cell = TacticalTableHeaderCell(textCell: "Status")
        XCTAssertNotNil(cell.font)
        // Monospaced system font has the special "AppleSystemUIFontMonospaced"
        // family name on modern macOS; check via familyName prefix.
        let familyName = cell.font?.familyName ?? ""
        XCTAssertTrue(familyName.contains("Monospaced") || familyName.contains(".AppleSystemUIFontMonospaced"),
                      "Header should use monospaced system font (got \(familyName))")
    }
}
