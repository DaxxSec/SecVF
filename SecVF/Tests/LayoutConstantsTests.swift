//
//  LayoutConstantsTests.swift
//  SecVFTests
//
//  Invariant tests for the shared design-token scale. These don't test
//  behavior — they pin the *shape* of the scale so a future "rebalance
//  these numbers" PR can't silently break the 4pt rhythm or let the
//  typography sizes drift out of order. Every tactical view depends on
//  these tokens; a misordered scale would cascade into layout bugs all
//  over the library window.
//

import XCTest
@testable import SecVF

final class LayoutConstantsTests: XCTestCase {

    // MARK: - Spacing scale (4pt grid)

    func testSpacingScaleIsStrictlyMonotonic() {
        XCTAssertLessThan(LayoutConstants.spacingXS,  LayoutConstants.spacingSM)
        XCTAssertLessThan(LayoutConstants.spacingSM,  LayoutConstants.spacingMD)
        XCTAssertLessThan(LayoutConstants.spacingMD,  LayoutConstants.spacingLG)
        XCTAssertLessThan(LayoutConstants.spacingLG,  LayoutConstants.spacingXL)
        XCTAssertLessThan(LayoutConstants.spacingXL,  LayoutConstants.spacingXXL)
    }

    func testSpacingScaleIsOnTheFourPtGrid() {
        // The "4pt grid" promise — every step in the scale must be a
        // multiple of 4. Off-grid values bleed into Cocoa's
        // half-pixel-rounded layout and produce blurry edges.
        let scale: [CGFloat] = [
            LayoutConstants.spacingXS,
            LayoutConstants.spacingSM,
            LayoutConstants.spacingMD,
            LayoutConstants.spacingLG,
            LayoutConstants.spacingXL,
            LayoutConstants.spacingXXL,
        ]
        for value in scale {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0,
                           "Spacing value \(value) must be on the 4pt grid")
        }
    }

    // MARK: - Typography scale

    func testTypographyScaleIsStrictlyMonotonic() {
        XCTAssertLessThan(LayoutConstants.fontSizeCaption,    LayoutConstants.fontSizeSmall)
        XCTAssertLessThan(LayoutConstants.fontSizeSmall,      LayoutConstants.fontSizeBody)
        XCTAssertLessThan(LayoutConstants.fontSizeBody,       LayoutConstants.fontSizeSubtitle)
        XCTAssertLessThan(LayoutConstants.fontSizeSubtitle,   LayoutConstants.fontSizeHeader)
        XCTAssertLessThan(LayoutConstants.fontSizeHeader,     LayoutConstants.fontSizeTitle)
        XCTAssertLessThan(LayoutConstants.fontSizeTitle,      LayoutConstants.fontSizeLargeTitle)
    }

    func testTypographyBodyMatchesMacOSDefaultControlSize() {
        // 11pt is the macOS default control-size font; the tactical
        // toolbar buttons explicitly target this so the pills match
        // surrounding native controls' visual weight.
        XCTAssertEqual(LayoutConstants.fontSizeBody, 11)
    }

    // MARK: - Corner radius scale

    func testCornerRadiusScaleIsStrictlyMonotonic() {
        XCTAssertLessThan(LayoutConstants.cornerRadiusSM,   LayoutConstants.cornerRadiusMD)
        XCTAssertLessThan(LayoutConstants.cornerRadiusMD,   LayoutConstants.cornerRadiusLG)
        XCTAssertLessThan(LayoutConstants.cornerRadiusLG,   LayoutConstants.cornerRadiusPill)
    }

    func testCornerRadiusPillCanFormCapsuleOnButtonHeight() {
        // The pill radius is the "infinite" end of the scale — it
        // should be at least half the button height so a 32pt-tall
        // pill button reads as a true capsule, not a rounded rect.
        XCTAssertGreaterThanOrEqual(LayoutConstants.cornerRadiusPill,
                                    LayoutConstants.buttonHeight / 2)
    }

    // MARK: - Border widths

    func testBorderWidthsAreOrdered() {
        XCTAssertLessThan(LayoutConstants.borderHairline, LayoutConstants.borderEmphasis,
                          "Hairline must be thinner than emphasis — emphasis is for primary/selected states")
        XCTAssertEqual(LayoutConstants.borderHairline, 1.0,
                       "Hairline borders are explicitly 1pt — used as the default tactical pill border")
    }

    // MARK: - Window sizing

    func testWindowDefaultsAreAtLeastTheMinimum() {
        XCTAssertGreaterThanOrEqual(LayoutConstants.defaultWindowWidth,
                                    LayoutConstants.minWindowWidth)
        XCTAssertGreaterThanOrEqual(LayoutConstants.defaultWindowHeight,
                                    LayoutConstants.minWindowHeight)
    }

    func testPacketWindowDefaultsAreAtLeastTheMinimum() {
        XCTAssertGreaterThanOrEqual(LayoutConstants.packetWindowWidth,
                                    LayoutConstants.packetWindowMinWidth)
        XCTAssertGreaterThanOrEqual(LayoutConstants.packetWindowHeight,
                                    LayoutConstants.packetWindowMinHeight)
    }

    // MARK: - Sidebar geometry

    func testSidebarWidthIsWideEnoughForLogo() {
        // The sidebar must hold the centered logo with at least some
        // breathing room on each side, or the logo will visually
        // collide with the gradient edge.
        XCTAssertGreaterThanOrEqual(LayoutConstants.sidebarWidth,
                                    LayoutConstants.logoWidth + 16)
    }

    // MARK: - Button row

    func testButtonHeightFitsInsideButtonRow() {
        XCTAssertLessThanOrEqual(LayoutConstants.buttonHeight,
                                 LayoutConstants.buttonRowHeight)
    }
}
